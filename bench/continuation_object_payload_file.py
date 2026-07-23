"""Independent durable payload copy-on-write adapter and crash worker."""

from __future__ import annotations

import fcntl
import hashlib
import os
from pathlib import Path
import stat
import struct
import sys
from typing import Any, Callable

from bench import continuation_object_payload_store as payload_store
from bench import continuation_object_store as object_store
from bench import continuation_object_sweep as sweep
from bench import continuation_object_sweep_record as sweep_record


class PayloadFileError(ValueError):
    """A payload file capability, record, or transition is invalid."""


Record = dict[str, Any]
RECLAIM_RECORD_BYTES = 968
RECLAIM_RECORD_MAGIC = b"GLPREC1\x00"
RECLAIM_RECORD_SCHEMA = 1
RECLAIM_RECORD_DOMAIN = (
    b"glacier-continuation-object-payload-reclaim-record-v1\x00"
)
LOCK_NAME = ".glacier-payload-lock-v1"
ACTIVE_NAME = ".glacier-payload-active-v1"
TARGET_CAPACITY = 16
TARGETS_OFFSET = 264
TARGETS_BYTES = TARGET_CAPACITY * 40
CHALLENGE_OFFSET = TARGETS_OFFSET + TARGETS_BYTES
RECORD_ROOT_OFFSET = CHALLENGE_OFFSET + 32
PHASE_PLAN_WRITE = "plan_write"
PHASE_PLAN_SYNC = "plan_sync"
PHASE_PLAN_DIRECTORY_SYNC = "plan_directory_sync"
PHASE_CANDIDATE_WRITE = "candidate_write"
PHASE_CANDIDATE_SYNC = "candidate_sync"
PHASE_PROMOTE_RENAME = "promote_rename"
PHASE_DIRECTORY_SYNC = "directory_sync"
IO_PHASES = (
    PHASE_PLAN_WRITE,
    PHASE_PLAN_SYNC,
    PHASE_PLAN_DIRECTORY_SYNC,
    PHASE_CANDIDATE_WRITE,
    PHASE_CANDIDATE_SYNC,
    PHASE_PROMOTE_RENAME,
    PHASE_DIRECTORY_SYNC,
)


def _u64(value: int) -> bytes:
    if not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise PayloadFileError("u64 out of range")
    return struct.pack("<Q", value)


def _digest(value: bytes, *, allow_zero: bool = False) -> bytes:
    if not isinstance(value, bytes) or len(value) != 32:
        raise PayloadFileError("invalid digest")
    if not allow_zero and value == bytes(32):
        raise PayloadFileError("zero digest")
    return value


def _hash(domain: bytes, *parts: bytes) -> bytes:
    hasher = hashlib.sha256()
    hasher.update(domain)
    for part in parts:
        hasher.update(part)
    return hasher.digest()


def _target_key(target: Record) -> tuple[bytes, int]:
    return (_digest(target["sha256"]), target["byte_length"])


def prepare_reclaim_record(
    preview: Record,
    sweep_record_sha256: bytes,
    storage_epoch: int,
    challenge_sha256: bytes,
    targets: list[Record],
) -> Record:
    payload_store.verify_reclaim_preview(preview)
    _digest(sweep_record_sha256)
    _digest(challenge_sha256)
    if storage_epoch == 0 or not targets or len(targets) > TARGET_CAPACITY:
        raise PayloadFileError("invalid reclaim metadata")
    try:
        targets_sha256 = object_store.retired_targets_root(targets)
    except object_store.StoreError as exc:
        raise PayloadFileError("invalid reclaim targets") from exc
    if targets_sha256 != preview["targets_sha256"]:
        raise PayloadFileError("reclaim target root mismatch")
    encoded = bytearray(RECLAIM_RECORD_BYTES)
    encoded[0:8] = RECLAIM_RECORD_MAGIC
    encoded[8:16] = _u64(RECLAIM_RECORD_SCHEMA)
    encoded[16:24] = _u64(RECLAIM_RECORD_BYTES)
    encoded[24:32] = _u64(storage_epoch)
    encoded[32:64] = preview["before"]["tenant_scope_sha256"]
    encoded[64:96] = sweep_record_sha256
    encoded[96:128] = targets_sha256
    encoded[128:160] = preview["before"]["snapshot_sha256"]
    encoded[160:192] = preview["after"]["snapshot_sha256"]
    encoded[192:224] = preview["preview_sha256"]
    encoded[224:232] = _u64(preview["before"]["encoded_bytes"])
    encoded[232:240] = _u64(preview["after"]["encoded_bytes"])
    encoded[240:248] = _u64(preview["freed_entries"])
    encoded[248:256] = _u64(preview["freed_payload_bytes"])
    encoded[256:264] = _u64(len(targets))
    cursor = TARGETS_OFFSET
    for target in targets:
        encoded[cursor : cursor + 8] = _u64(target["byte_length"])
        cursor += 8
        encoded[cursor : cursor + 32] = _digest(target["sha256"])
        cursor += 32
    encoded[CHALLENGE_OFFSET:RECORD_ROOT_OFFSET] = challenge_sha256
    record_sha256 = _hash(
        RECLAIM_RECORD_DOMAIN,
        bytes(encoded[:RECORD_ROOT_OFFSET]),
    )
    encoded[RECORD_ROOT_OFFSET:] = record_sha256
    return {"bytes": bytes(encoded), "record_sha256": record_sha256}


def decode_reclaim_record(encoded: bytes) -> Record:
    if not isinstance(encoded, bytes) or len(encoded) != RECLAIM_RECORD_BYTES:
        raise PayloadFileError("invalid reclaim record length")
    if encoded[:8] != RECLAIM_RECORD_MAGIC:
        raise PayloadFileError("invalid reclaim record magic")
    if struct.unpack_from("<Q", encoded, 8)[0] != RECLAIM_RECORD_SCHEMA:
        raise PayloadFileError("unsupported reclaim record")
    if struct.unpack_from("<Q", encoded, 16)[0] != RECLAIM_RECORD_BYTES:
        raise PayloadFileError("reclaim record size mismatch")
    target_count = struct.unpack_from("<Q", encoded, 256)[0]
    if not 0 < target_count <= TARGET_CAPACITY:
        raise PayloadFileError("invalid reclaim target count")
    targets = []
    cursor = TARGETS_OFFSET
    for _ in range(target_count):
        byte_length = struct.unpack_from("<Q", encoded, cursor)[0]
        cursor += 8
        sha256 = encoded[cursor : cursor + 32]
        cursor += 32
        targets.append({"byte_length": byte_length, "sha256": sha256})
    if any(encoded[cursor:CHALLENGE_OFFSET]):
        raise PayloadFileError("nonzero reclaim target padding")
    try:
        targets_sha256 = object_store.retired_targets_root(targets)
    except object_store.StoreError as exc:
        raise PayloadFileError("invalid reclaim targets") from exc
    record_sha256 = encoded[RECORD_ROOT_OFFSET:]
    expected_root = _hash(
        RECLAIM_RECORD_DOMAIN,
        encoded[:RECORD_ROOT_OFFSET],
    )
    decoded = {
        "storage_epoch": struct.unpack_from("<Q", encoded, 24)[0],
        "tenant_scope_sha256": encoded[32:64],
        "sweep_record_sha256": encoded[64:96],
        "targets_sha256": encoded[96:128],
        "before_snapshot_sha256": encoded[128:160],
        "after_snapshot_sha256": encoded[160:192],
        "preview_sha256": encoded[192:224],
        "before_encoded_bytes": struct.unpack_from("<Q", encoded, 224)[0],
        "after_encoded_bytes": struct.unpack_from("<Q", encoded, 232)[0],
        "freed_entries": struct.unpack_from("<Q", encoded, 240)[0],
        "freed_payload_bytes": struct.unpack_from("<Q", encoded, 248)[0],
        "targets": targets,
        "challenge_sha256": encoded[CHALLENGE_OFFSET:RECORD_ROOT_OFFSET],
        "record_sha256": record_sha256,
    }
    target_payload_bytes = sum(
        target["byte_length"] for target in targets
    )
    removed_encoded_bytes = target_count * payload_store.ENTRY_HEADER_BYTES
    removed_encoded_bytes += target_payload_bytes
    expected_preview_sha256 = payload_store.preview_root(
        {
            "before": {
                "snapshot_sha256": decoded["before_snapshot_sha256"],
            },
            "after": {
                "snapshot_sha256": decoded["after_snapshot_sha256"],
            },
            "targets_sha256": decoded["targets_sha256"],
            "freed_entries": decoded["freed_entries"],
            "freed_payload_bytes": decoded["freed_payload_bytes"],
        }
    )
    if (
        decoded["storage_epoch"] == 0
        or decoded["tenant_scope_sha256"] == bytes(32)
        or decoded["sweep_record_sha256"] == bytes(32)
        or decoded["targets_sha256"] == bytes(32)
        or decoded["before_snapshot_sha256"] == bytes(32)
        or decoded["after_snapshot_sha256"] == bytes(32)
        or decoded["preview_sha256"] == bytes(32)
        or decoded["challenge_sha256"] == bytes(32)
        or decoded["record_sha256"] == bytes(32)
        or decoded["before_snapshot_sha256"]
        == decoded["after_snapshot_sha256"]
        or decoded["before_encoded_bytes"]
        <= decoded["after_encoded_bytes"]
        or decoded["after_encoded_bytes"]
        < payload_store.MINIMUM_ENCODED_BYTES
        or decoded["before_encoded_bytes"] - decoded["after_encoded_bytes"]
        != removed_encoded_bytes
        or decoded["freed_entries"] != target_count
        or decoded["freed_payload_bytes"] != target_payload_bytes
        or targets_sha256 != decoded["targets_sha256"]
        or decoded["preview_sha256"] != expected_preview_sha256
        or record_sha256 != expected_root
    ):
        raise PayloadFileError("invalid reclaim record")
    return decoded


def verify_reclaim_record(
    prepared: Record,
    preview: Record,
    expected_sweep_record_sha256: bytes,
) -> None:
    payload_store.verify_reclaim_preview(preview)
    try:
        encoded = prepared["bytes"]
        decoded = decode_reclaim_record(encoded)
        valid = (
            prepared["record_sha256"] == decoded["record_sha256"]
            and decoded["tenant_scope_sha256"]
            == preview["before"]["tenant_scope_sha256"]
            and decoded["sweep_record_sha256"]
            == expected_sweep_record_sha256
            and decoded["targets_sha256"] == preview["targets_sha256"]
            and decoded["before_snapshot_sha256"]
            == preview["before"]["snapshot_sha256"]
            and decoded["after_snapshot_sha256"]
            == preview["after"]["snapshot_sha256"]
            and decoded["preview_sha256"] == preview["preview_sha256"]
            and decoded["before_encoded_bytes"]
            == preview["before"]["encoded_bytes"]
            and decoded["after_encoded_bytes"]
            == preview["after"]["encoded_bytes"]
            and decoded["freed_entries"] == preview["freed_entries"]
            and decoded["freed_payload_bytes"]
            == preview["freed_payload_bytes"]
        )
    except (KeyError, TypeError, PayloadFileError) as exc:
        raise PayloadFileError("invalid prepared reclaim record") from exc
    if not valid:
        raise PayloadFileError("reclaim record binding mismatch")


def reclaim_record_name(record_sha256: bytes) -> str:
    return f"payload-plan-{_digest(record_sha256).hex()}.record"


def candidate_name(record_sha256: bytes) -> str:
    return f"payload-next-{_digest(record_sha256).hex()}.snapshot"


def _open_flags(*, create: bool = False) -> int:
    flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise PayloadFileError("O_NOFOLLOW unavailable")
    flags |= nofollow
    if create:
        flags |= os.O_CREAT | os.O_EXCL
    return flags


def _inspect(fd: int, directory_fd: int, name: str) -> os.stat_result:
    file_stat = os.fstat(fd)
    entry_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(file_stat.st_mode)
        or not stat.S_ISREG(entry_stat.st_mode)
        or file_stat.st_dev != entry_stat.st_dev
        or file_stat.st_ino != entry_stat.st_ino
        or file_stat.st_size != entry_stat.st_size
        or file_stat.st_nlink != 1
        or entry_stat.st_nlink != 1
        or file_stat.st_mode & 0o077
        or entry_stat.st_mode & 0o077
    ):
        raise PayloadFileError("unsafe payload file identity")
    return file_stat


def _read_exact(directory_fd: int, name: str, max_bytes: int) -> bytes:
    fd = os.open(name, _open_flags(), dir_fd=directory_fd)
    try:
        before = _inspect(fd, directory_fd, name)
        if before.st_size > max_bytes:
            raise PayloadFileError("payload file exceeds capacity")
        data = os.pread(fd, before.st_size, 0)
        after = _inspect(fd, directory_fd, name)
        if len(data) != before.st_size or (
            before.st_dev,
            before.st_ino,
            before.st_size,
        ) != (after.st_dev, after.st_ino, after.st_size):
            raise PayloadFileError("payload file changed while reading")
        return data
    finally:
        os.close(fd)


def _write_all(fd: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(fd, data[offset:])
        if written <= 0:
            raise PayloadFileError("short payload write")
        offset += written


class LockedPayloadStore:
    def __init__(
        self,
        directory: str | os.PathLike[str],
        tenant_scope_sha256: bytes,
        max_bytes: int,
        storage_epoch: int,
        *,
        create: bool,
        initial_snapshot: bytes | None = None,
    ) -> None:
        self.directory = Path(directory)
        self.tenant_scope_sha256 = _digest(tenant_scope_sha256)
        if not isinstance(storage_epoch, int) or storage_epoch <= 0:
            raise PayloadFileError("invalid payload storage epoch")
        self.storage_epoch = storage_epoch
        self.max_bytes = max_bytes
        self.directory_fd = os.open(
            self.directory,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        self.lock_fd = -1
        try:
            self.lock_fd = os.open(
                LOCK_NAME,
                _open_flags(create=create),
                0o600,
                dir_fd=self.directory_fd,
            )
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            _inspect(self.lock_fd, self.directory_fd, LOCK_NAME)
            if create:
                if initial_snapshot is None or len(initial_snapshot) > max_bytes:
                    raise PayloadFileError("invalid initial payload snapshot")
                payload_store.decode_snapshot(
                    initial_snapshot,
                    tenant_scope_sha256,
                )
                active_fd = os.open(
                    ACTIVE_NAME,
                    _open_flags(create=True),
                    0o600,
                    dir_fd=self.directory_fd,
                )
                try:
                    _write_all(active_fd, initial_snapshot)
                    os.fsync(active_fd)
                    _inspect(active_fd, self.directory_fd, ACTIVE_NAME)
                finally:
                    os.close(active_fd)
                os.fsync(self.directory_fd)
            self._refresh()
        except BaseException:
            self.close()
            raise

    @classmethod
    def create(
        cls,
        directory: str | os.PathLike[str],
        tenant_scope_sha256: bytes,
        initial_snapshot: bytes,
        max_bytes: int,
        storage_epoch: int,
    ) -> LockedPayloadStore:
        return cls(
            directory,
            tenant_scope_sha256,
            max_bytes,
            storage_epoch,
            create=True,
            initial_snapshot=initial_snapshot,
        )

    @classmethod
    def open(
        cls,
        directory: str | os.PathLike[str],
        tenant_scope_sha256: bytes,
        max_bytes: int,
        storage_epoch: int,
    ) -> LockedPayloadStore:
        return cls(
            directory,
            tenant_scope_sha256,
            max_bytes,
            storage_epoch,
            create=False,
        )

    def _refresh(self) -> None:
        self.active = _read_exact(
            self.directory_fd,
            ACTIVE_NAME,
            self.max_bytes,
        )
        self.active_snapshot = payload_store.decode_snapshot(
            self.active,
            self.tenant_scope_sha256,
        )

    def publish_reclaim_record(
        self,
        prepared: Record,
        observer: Callable[[str], None] | None = None,
    ) -> None:
        decoded = decode_reclaim_record(prepared["bytes"])
        self._verify_record_scope(decoded)
        name = reclaim_record_name(prepared["record_sha256"])
        try:
            fd = os.open(
                name,
                _open_flags(create=True),
                0o600,
                dir_fd=self.directory_fd,
            )
        except FileExistsError:
            existing = _read_exact(
                self.directory_fd,
                name,
                RECLAIM_RECORD_BYTES,
            )
            if existing != prepared["bytes"]:
                raise PayloadFileError("foreign published reclaim record")
            fd = os.open(
                name,
                _open_flags(),
                dir_fd=self.directory_fd,
            )
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
            os.fsync(self.directory_fd)
            return
        try:
            _write_all(fd, prepared["bytes"])
            if observer is not None:
                observer(PHASE_PLAN_WRITE)
            os.fsync(fd)
            if observer is not None:
                observer(PHASE_PLAN_SYNC)
            _inspect(fd, self.directory_fd, name)
        finally:
            os.close(fd)
        os.fsync(self.directory_fd)
        if observer is not None:
            observer(PHASE_PLAN_DIRECTORY_SYNC)

    def _verify_sidecar(self, prepared: Record) -> None:
        decoded = decode_reclaim_record(prepared["bytes"])
        self._verify_record_scope(decoded)
        existing = _read_exact(
            self.directory_fd,
            reclaim_record_name(prepared["record_sha256"]),
            RECLAIM_RECORD_BYTES,
        )
        if existing != prepared["bytes"]:
            raise PayloadFileError("published reclaim record changed")

    def _verify_record_scope(self, decoded: Record) -> None:
        if (
            decoded["storage_epoch"] != self.storage_epoch
            or decoded["tenant_scope_sha256"] != self.tenant_scope_sha256
        ):
            raise PayloadFileError("reclaim record scope mismatch")

    def apply(
        self,
        preview: Record,
        prepared: Record,
        candidate: bytes,
        expected_sweep_record_sha256: bytes,
        observer: Callable[[str], None] | None = None,
    ) -> Record:
        verify_reclaim_record(
            prepared,
            preview,
            expected_sweep_record_sha256,
        )
        candidate_snapshot = payload_store.decode_snapshot(
            candidate,
            self.tenant_scope_sha256,
        )
        if candidate_snapshot["snapshot_sha256"] != preview["after"][
            "snapshot_sha256"
        ]:
            raise PayloadFileError("candidate snapshot mismatch")
        self._verify_sidecar(prepared)
        self._refresh()
        if (
            self.active_snapshot["snapshot_sha256"]
            == preview["after"]["snapshot_sha256"]
        ):
            os.fsync(self.directory_fd)
            return {
                "disposition": "already_applied",
                "active_snapshot": self.active_snapshot,
            }
        if (
            self.active_snapshot["snapshot_sha256"]
            != preview["before"]["snapshot_sha256"]
        ):
            raise PayloadFileError("active payload snapshot changed")
        name = candidate_name(prepared["record_sha256"])
        try:
            candidate_fd = os.open(
                name,
                _open_flags(create=True),
                0o600,
                dir_fd=self.directory_fd,
            )
        except FileExistsError:
            existing = _read_exact(self.directory_fd, name, self.max_bytes)
            if existing != candidate:
                raise PayloadFileError("existing candidate changed")
            candidate_fd = os.open(
                name,
                _open_flags(),
                dir_fd=self.directory_fd,
            )
        else:
            _write_all(candidate_fd, candidate)
            if observer is not None:
                observer(PHASE_CANDIDATE_WRITE)
        try:
            os.fsync(candidate_fd)
            if observer is not None:
                observer(PHASE_CANDIDATE_SYNC)
            _inspect(candidate_fd, self.directory_fd, name)
        finally:
            os.close(candidate_fd)
        self._refresh()
        if (
            self.active_snapshot["snapshot_sha256"]
            != preview["before"]["snapshot_sha256"]
        ):
            raise PayloadFileError("active payload snapshot changed")
        os.replace(
            name,
            ACTIVE_NAME,
            src_dir_fd=self.directory_fd,
            dst_dir_fd=self.directory_fd,
        )
        if observer is not None:
            observer(PHASE_PROMOTE_RENAME)
        os.fsync(self.directory_fd)
        if observer is not None:
            observer(PHASE_DIRECTORY_SYNC)
        self._refresh()
        if (
            self.active_snapshot["snapshot_sha256"]
            != preview["after"]["snapshot_sha256"]
        ):
            raise PayloadFileError("promoted payload snapshot changed")
        return {
            "disposition": "applied",
            "active_snapshot": self.active_snapshot,
        }

    def recover(
        self,
        prepared_sweep_record: bytes,
        prepared_reclaim: Record,
        observer: Callable[[str], None] | None = None,
    ) -> Record:
        decoded_reclaim = decode_reclaim_record(prepared_reclaim["bytes"])
        self._verify_record_scope(decoded_reclaim)
        if prepared_reclaim["record_sha256"] != decoded_reclaim[
            "record_sha256"
        ]:
            raise PayloadFileError("reclaim root changed")
        decoded_sweep = sweep_record.decode(prepared_sweep_record)
        if decoded_sweep["record_sha256"] != decoded_reclaim[
            "sweep_record_sha256"
        ]:
            raise PayloadFileError("sweep publication changed")
        sweep.verify_commit_receipt(
            decoded_sweep["input"]["commit_grant"],
            decoded_sweep["input"]["commit_receipt"],
            decoded_sweep["input"]["store_receipt"],
        )
        receipt = decoded_sweep["input"]["commit_receipt"]
        if (
            receipt["targets_sha256"]
            != decoded_reclaim["targets_sha256"]
            or receipt["freed_entries"]
            != decoded_reclaim["freed_entries"]
            or receipt["freed_payload_bytes"]
            != decoded_reclaim["freed_payload_bytes"]
        ):
            raise PayloadFileError("sweep reclaim binding mismatch")
        self._verify_sidecar(prepared_reclaim)
        self._refresh()
        if (
            self.active_snapshot["snapshot_sha256"]
            == decoded_reclaim["after_snapshot_sha256"]
            and self.active_snapshot["encoded_bytes"]
            == decoded_reclaim["after_encoded_bytes"]
        ):
            os.fsync(self.directory_fd)
            return {
                "disposition": "already_applied",
                "active_snapshot": self.active_snapshot,
            }
        if (
            self.active_snapshot["snapshot_sha256"]
            != decoded_reclaim["before_snapshot_sha256"]
            or self.active_snapshot["encoded_bytes"]
            != decoded_reclaim["before_encoded_bytes"]
        ):
            raise PayloadFileError("active payload snapshot changed")
        preview = payload_store.preview_reclaim(
            self.active,
            self.tenant_scope_sha256,
            decoded_reclaim["targets"],
        )
        verify_reclaim_record(
            prepared_reclaim,
            preview,
            decoded_sweep["record_sha256"],
        )
        return self.apply(
            preview,
            prepared_reclaim,
            preview["candidate"],
            decoded_sweep["record_sha256"],
            observer,
        )

    def close(self) -> None:
        if self.lock_fd >= 0:
            os.close(self.lock_fd)
            self.lock_fd = -1
        if getattr(self, "directory_fd", -1) >= 0:
            os.close(self.directory_fd)
            self.directory_fd = -1

    def __enter__(self) -> LockedPayloadStore:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def _crash_observer(target_phase: str) -> Callable[[str], None]:
    def observer(phase: str) -> None:
        if phase == target_phase:
            os.kill(os.getpid(), 9)

    return observer


def _child_recover(arguments: list[str]) -> int:
    if len(arguments) != 9:
        return 2
    directory = arguments[1]
    max_bytes = int(arguments[2])
    storage_epoch = int(arguments[3])
    tenant = bytes.fromhex(arguments[4])
    sweep_name = arguments[5]
    reclaim_name = arguments[6]
    phase = arguments[7]
    if arguments[8] != "_end" or phase not in IO_PHASES:
        return 2
    sweep_bytes = (Path(directory) / sweep_name).read_bytes()
    reclaim_bytes = (Path(directory) / reclaim_name).read_bytes()
    prepared = {
        "bytes": reclaim_bytes,
        "record_sha256": reclaim_bytes[RECORD_ROOT_OFFSET:],
    }
    with LockedPayloadStore.open(
        directory,
        tenant,
        max_bytes,
        storage_epoch,
    ) as store:
        if phase in {
            PHASE_PLAN_WRITE,
            PHASE_PLAN_SYNC,
            PHASE_PLAN_DIRECTORY_SYNC,
        }:
            store.publish_reclaim_record(
                prepared,
                _crash_observer(phase),
            )
            return 3
        store.recover(
            sweep_bytes,
            prepared,
            _crash_observer(phase),
        )
    return 3


def _main(arguments: list[str]) -> int:
    if arguments and arguments[0] == "_child-recover":
        return _child_recover(arguments)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
