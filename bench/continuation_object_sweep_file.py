"""Independent descriptor-relative sweep file adapter and subprocess probe."""

from __future__ import annotations

from collections.abc import Callable
import fcntl
import itertools
import os
import signal
import stat
import sys
from typing import Any

from bench import continuation_object_sweep_record as record
from bench import continuation_object_sweep_writer as writer


class FileAdapterError(writer.SweepWriterError):
    """The file capability, namespace identity, or I/O contract is invalid."""


MAX_NAME_BYTES = 255
LOCK_HELD_EXIT = 73
UNEXPECTED_RETURN_EXIT = 74
_GENERATIONS = itertools.count(1)

PhaseObserver = Callable[[str], None]
Snapshot = dict[str, Any]


def _validate_name(name: str) -> None:
    encoded = os.fsencode(name)
    if (
        not name
        or name in (".", "..")
        or len(encoded) > MAX_NAME_BYTES
        or "/" in name
        or "\\" in name
        or "\x00" in name
    ):
        raise FileAdapterError("invalid descriptor-relative file name")


def _next_generation() -> int:
    generation = next(_GENERATIONS)
    if not 0 < generation < 0xFFFFFFFFFFFFFFFF:
        raise FileAdapterError("lease generation exhausted")
    return generation


def _open_directory(directory: str | os.PathLike[str]) -> int:
    flags = os.O_RDONLY | os.O_CLOEXEC
    flags |= getattr(os, "O_DIRECTORY", 0)
    return os.open(os.fspath(directory), flags)


def _open_locked(
    directory_fd: int,
    name: str,
    *,
    create: bool,
    lock_nonblocking: bool,
) -> int:
    if not hasattr(os, "O_NOFOLLOW"):
        raise FileAdapterError("final-component no-follow is unavailable")
    flags = os.O_RDWR | os.O_CLOEXEC
    flags |= os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT | os.O_EXCL
    file_fd = os.open(name, flags, 0o600, dir_fd=directory_fd)
    try:
        lock_flags = fcntl.LOCK_EX
        if lock_nonblocking:
            lock_flags |= fcntl.LOCK_NB
        fcntl.flock(file_fd, lock_flags)
    except BaseException:
        os.close(file_fd)
        raise
    return file_fd


def _inspect_stat(
    value: os.stat_result,
    *,
    require_private_mode: bool,
) -> tuple[int, int, int]:
    if not stat.S_ISREG(value.st_mode):
        raise FileAdapterError("storage is not a regular file")
    if value.st_nlink != 1:
        raise FileAdapterError("storage has multiple hard links")
    if require_private_mode and stat.S_IMODE(value.st_mode) & 0o077:
        raise FileAdapterError("storage permissions are not owner-private")
    if value.st_size < 0:
        raise FileAdapterError("negative storage length")
    return value.st_dev, value.st_ino, value.st_size


def _inspect(
    directory_fd: int,
    file_fd: int,
    name: str,
    *,
    require_private_mode: bool,
) -> tuple[int, int, int]:
    file_view = _inspect_stat(
        os.fstat(file_fd),
        require_private_mode=require_private_mode,
    )
    entry_view = _inspect_stat(
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False),
        require_private_mode=require_private_mode,
    )
    if file_view != entry_view:
        raise FileAdapterError("directory entry identity changed")
    return file_view


def _read_exact(file_fd: int, length: int) -> bytes:
    output = bytearray(length)
    offset = 0
    while offset < length:
        chunk = os.pread(file_fd, length - offset, offset)
        if not chunk:
            raise FileAdapterError("short file read")
        output[offset : offset + len(chunk)] = chunk
        offset += len(chunk)
    return bytes(output)


def _pwrite_all(file_fd: int, payload: bytes, offset: int) -> None:
    written = 0
    while written < len(payload):
        count = os.pwrite(file_fd, payload[written:], offset + written)
        if count <= 0:
            raise FileAdapterError("short file write")
        written += count


class FileAppendCapability:
    def __init__(self, lease: LockedSweepFile) -> None:
        self._lease = lease
        self._generation = lease.generation
        self.snapshot = dict(lease.snapshot)

    def validate(self, expected_current_bytes: int) -> None:
        self._lease._validate_append(
            self._generation,
            self.snapshot["snapshot_sha256"],
            expected_current_bytes,
        )

    def append_body(self, payload: bytes) -> None:
        self._lease._append_body(self._generation, payload)

    def sync_body(self) -> None:
        self._lease._sync_body(self._generation)

    def append_footer(self, payload: bytes) -> None:
        self._lease._append_footer(self._generation, payload)

    def sync_footer(self) -> None:
        self._lease._sync_footer(self._generation)


class FileRepairCapability:
    def __init__(
        self,
        lease: LockedSweepFile,
        plan: dict[str, Any],
    ) -> None:
        self._lease = lease
        self._generation = lease.generation
        self.snapshot = dict(lease.snapshot)
        self.expected_current_bytes = self.snapshot["observed_bytes"]
        self.target_bytes = plan["truncate_to_bytes"]
        self.discarded_tail_bytes = plan["discard_tail_bytes"]
        self.final_record_sha256 = plan["classification"][
            "final_record_sha256"
        ]

    def validate(self) -> None:
        self._lease._validate_repair(self._generation)

    def truncate(self) -> None:
        self._lease._repair_truncate(
            self._generation,
            self.snapshot["snapshot_sha256"],
        )

    def sync(self) -> None:
        self._lease._repair_sync(self._generation)


class LockedSweepFile:
    """One locked, identity-fenced stream beneath an opened directory."""

    def __init__(
        self,
        directory_fd: int,
        file_fd: int,
        name: str,
        storage_epoch: int,
        max_bytes: int,
        generation: int,
        identity: tuple[int, int],
        observed: bytes,
        require_private_mode: bool,
        observer: PhaseObserver | None,
        directory_sync_status: str,
        file_sync_count: int,
    ) -> None:
        self.directory_fd = directory_fd
        self.file_fd = file_fd
        self.name = name
        self.storage_epoch = storage_epoch
        self.max_bytes = max_bytes
        self.generation = generation
        self.identity = identity
        self.observed = observed
        self.current_bytes = len(observed)
        self.require_private_mode = require_private_mode
        self.observer = observer
        self.directory_sync_status = directory_sync_status
        self.file_sync_count = file_sync_count
        self.identity_check_count = 2
        self.state = "ready"
        self.expected_phase = writer.BODY_WRITE
        self.append_generation = 0
        self.append_snapshot_sha256 = bytes(32)
        self.repair_generation = 0
        self.repair_snapshot_sha256 = bytes(32)
        self.repair_expected_bytes = 0
        self.repair_target_bytes = 0
        self.snapshot = writer.make_snapshot(
            storage_epoch,
            generation,
            observed,
            max_bytes,
        )

    @classmethod
    def create(
        cls,
        directory: str | os.PathLike[str],
        name: str,
        storage_epoch: int,
        max_bytes: int,
        *,
        lock_nonblocking: bool = True,
        require_private_mode: bool = True,
        observer: PhaseObserver | None = None,
    ) -> LockedSweepFile:
        _validate_name(name)
        if storage_epoch == 0 or max_bytes < record.ENCODED_BYTES:
            raise FileAdapterError("invalid storage epoch or capacity")
        directory_fd = _open_directory(directory)
        try:
            file_fd = _open_locked(
                directory_fd,
                name,
                create=True,
                lock_nonblocking=lock_nonblocking,
            )
        except BaseException:
            os.close(directory_fd)
            raise
        try:
            inspected = _inspect(
                directory_fd,
                file_fd,
                name,
                require_private_mode=require_private_mode,
            )
            if inspected[2] != 0:
                raise FileAdapterError("new file is not empty")
            os.fsync(file_fd)
            os.fsync(directory_fd)
            verified = _inspect(
                directory_fd,
                file_fd,
                name,
                require_private_mode=require_private_mode,
            )
            if inspected != verified:
                raise FileAdapterError("new file identity changed")
            return cls(
                directory_fd,
                file_fd,
                name,
                storage_epoch,
                max_bytes,
                _next_generation(),
                inspected[:2],
                b"",
                require_private_mode,
                observer,
                "synced",
                1,
            )
        except BaseException:
            os.close(file_fd)
            os.close(directory_fd)
            raise

    @classmethod
    def open(
        cls,
        directory: str | os.PathLike[str],
        name: str,
        storage_epoch: int,
        max_bytes: int,
        *,
        lock_nonblocking: bool = True,
        require_private_mode: bool = True,
        observer: PhaseObserver | None = None,
    ) -> LockedSweepFile:
        _validate_name(name)
        if storage_epoch == 0 or max_bytes < record.ENCODED_BYTES:
            raise FileAdapterError("invalid storage epoch or capacity")
        directory_fd = _open_directory(directory)
        try:
            file_fd = _open_locked(
                directory_fd,
                name,
                create=False,
                lock_nonblocking=lock_nonblocking,
            )
        except BaseException:
            os.close(directory_fd)
            raise
        try:
            inspected = _inspect(
                directory_fd,
                file_fd,
                name,
                require_private_mode=require_private_mode,
            )
            if inspected[2] > max_bytes:
                raise FileAdapterError("file exceeds configured capacity")
            observed = _read_exact(file_fd, inspected[2])
            verified = _inspect(
                directory_fd,
                file_fd,
                name,
                require_private_mode=require_private_mode,
            )
            if inspected != verified:
                raise FileAdapterError("file changed during snapshot read")
            return cls(
                directory_fd,
                file_fd,
                name,
                storage_epoch,
                max_bytes,
                _next_generation(),
                inspected[:2],
                observed,
                require_private_mode,
                observer,
                "not_applicable",
                0,
            )
        except BaseException:
            os.close(file_fd)
            os.close(directory_fd)
            raise

    def __enter__(self) -> LockedSweepFile:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        if self.state == "closed":
            return
        self.state = "closed"
        self.generation = 0
        self._clear_append_authorization()
        self._clear_repair_authorization()
        os.close(self.file_fd)
        os.close(self.directory_fd)

    def append_capability(self) -> FileAppendCapability:
        if (
            self.state != "ready"
            or self.expected_phase != writer.BODY_WRITE
            or self.current_bytes != self.snapshot["observed_bytes"]
        ):
            raise FileAdapterError("lease cannot mint append authority")
        self._verify_current(self.current_bytes)
        if self.append_generation not in (0, self.generation):
            raise FileAdapterError("foreign append authority is active")
        if (
            self.append_generation == self.generation
            and self.append_snapshot_sha256
            != self.snapshot["snapshot_sha256"]
        ):
            raise FileAdapterError("append snapshot binding changed")
        self.append_generation = self.generation
        self.append_snapshot_sha256 = self.snapshot["snapshot_sha256"]
        return FileAppendCapability(self)

    def prepare_repair(
        self,
        anchor: dict[str, Any],
    ) -> FileRepairCapability:
        if (
            self.state != "ready"
            or self.expected_phase != writer.BODY_WRITE
            or self.current_bytes != self.snapshot["observed_bytes"]
        ):
            raise FileAdapterError("lease cannot enter repair")
        self._verify_current(self.current_bytes)
        plan = writer.plan_recovery(self.observed, anchor, self.snapshot)
        if plan["action"] == "open_clean":
            raise FileAdapterError("repair is not required")
        if plan["action"] == "reject_corrupt":
            raise FileAdapterError("corrupt evidence cannot receive repair")
        self._clear_append_authorization()
        self.state = "repair_ready"
        self.expected_phase = writer.REPAIR_TRUNCATE
        self.repair_generation = self.generation
        self.repair_snapshot_sha256 = self.snapshot["snapshot_sha256"]
        self.repair_expected_bytes = self.snapshot["observed_bytes"]
        self.repair_target_bytes = plan["truncate_to_bytes"]
        return FileRepairCapability(self, plan)

    def _validate_generation(self, generation: int) -> None:
        if (
            generation == 0
            or self.generation != generation
            or self.state in ("closed", "poisoned")
        ):
            raise FileAdapterError("stale or poisoned file capability")

    def _verify_current(self, expected_bytes: int) -> None:
        try:
            current = _inspect(
                self.directory_fd,
                self.file_fd,
                self.name,
                require_private_mode=self.require_private_mode,
            )
        except OSError as exc:
            raise FileAdapterError("file identity check failed") from exc
        if current[:2] != self.identity or current[2] != expected_bytes:
            raise FileAdapterError("file identity or length changed")
        self.identity_check_count += 1

    def _observe(self, phase: str) -> None:
        if self.observer is not None:
            self.observer(phase)

    def _validate_append(
        self,
        generation: int,
        snapshot_sha256: bytes,
        expected_current_bytes: int,
    ) -> None:
        self._validate_generation(generation)
        if (
            self.state != "ready"
            or self.expected_phase != writer.BODY_WRITE
            or self.append_generation != generation
            or self.append_snapshot_sha256 != snapshot_sha256
            or self.current_bytes != expected_current_bytes
        ):
            raise FileAdapterError("append authority is stale")
        self._verify_current(expected_current_bytes)

    def _append_body(self, generation: int, payload: bytes) -> None:
        self._validate_generation(generation)
        if (
            self.state != "ready"
            or self.expected_phase != writer.BODY_WRITE
            or len(payload) != record.BODY_BYTES
        ):
            raise FileAdapterError("invalid body phase")
        if self.current_bytes + record.ENCODED_BYTES > self.max_bytes:
            raise FileAdapterError("storage capacity exceeded")
        self._verify_current(self.current_bytes)
        self.state = "poisoned"
        _pwrite_all(self.file_fd, payload, self.current_bytes)
        self.current_bytes += len(payload)
        self._observe(writer.BODY_WRITE)
        self._verify_current(self.current_bytes)
        self.expected_phase = writer.BODY_SYNC
        self.state = "append_active"

    def _sync_body(self, generation: int) -> None:
        self._validate_generation(generation)
        if (
            self.state != "append_active"
            or self.expected_phase != writer.BODY_SYNC
        ):
            raise FileAdapterError("invalid body sync phase")
        self.state = "poisoned"
        os.fsync(self.file_fd)
        self.file_sync_count += 1
        self._observe(writer.BODY_SYNC)
        self._verify_current(self.current_bytes)
        self.expected_phase = writer.FOOTER_WRITE
        self.state = "append_active"

    def _append_footer(self, generation: int, payload: bytes) -> None:
        self._validate_generation(generation)
        if (
            self.state != "append_active"
            or self.expected_phase != writer.FOOTER_WRITE
            or len(payload) != record.COMMIT_FOOTER_BYTES
        ):
            raise FileAdapterError("invalid footer phase")
        if self.current_bytes + len(payload) > self.max_bytes:
            raise FileAdapterError("storage capacity exceeded")
        self._verify_current(self.current_bytes)
        self.state = "poisoned"
        _pwrite_all(self.file_fd, payload, self.current_bytes)
        self.current_bytes += len(payload)
        self._observe(writer.FOOTER_WRITE)
        self._verify_current(self.current_bytes)
        self.expected_phase = writer.FOOTER_SYNC
        self.state = "append_active"

    def _sync_footer(self, generation: int) -> None:
        self._validate_generation(generation)
        if (
            self.state != "append_active"
            or self.expected_phase != writer.FOOTER_SYNC
        ):
            raise FileAdapterError("invalid footer sync phase")
        self.state = "poisoned"
        os.fsync(self.file_fd)
        self.file_sync_count += 1
        self._observe(writer.FOOTER_SYNC)
        self._verify_current(self.current_bytes)
        self.expected_phase = writer.BODY_WRITE
        self.state = "ready"

    def _validate_repair(self, generation: int) -> None:
        self._validate_generation(generation)
        if (
            self.state != "repair_ready"
            or self.expected_phase != writer.REPAIR_TRUNCATE
            or self.repair_generation != generation
        ):
            raise FileAdapterError("repair authority is stale")
        self._verify_current(self.repair_expected_bytes)

    def _repair_truncate(
        self,
        generation: int,
        snapshot_sha256: bytes,
    ) -> None:
        self._validate_generation(generation)
        if (
            self.state != "repair_ready"
            or self.expected_phase != writer.REPAIR_TRUNCATE
            or self.repair_generation != generation
            or self.current_bytes != self.repair_expected_bytes
            or not 0 <= self.repair_target_bytes <= self.repair_expected_bytes
            or self.repair_snapshot_sha256 != snapshot_sha256
        ):
            raise FileAdapterError("repair target binding changed")
        self._verify_current(self.repair_expected_bytes)
        self.state = "poisoned"
        os.ftruncate(self.file_fd, self.repair_target_bytes)
        self.current_bytes = self.repair_target_bytes
        self._observe(writer.REPAIR_TRUNCATE)
        self._verify_current(self.current_bytes)
        self.expected_phase = writer.REPAIR_SYNC
        self.state = "repair_active"

    def _repair_sync(self, generation: int) -> None:
        self._validate_generation(generation)
        if (
            self.state != "repair_active"
            or self.expected_phase != writer.REPAIR_SYNC
        ):
            raise FileAdapterError("invalid repair sync phase")
        self.state = "poisoned"
        os.fsync(self.file_fd)
        self.file_sync_count += 1
        self._observe(writer.REPAIR_SYNC)
        self._verify_current(self.current_bytes)
        self.expected_phase = writer.BODY_WRITE
        self.state = "repair_complete"

    def _clear_append_authorization(self) -> None:
        self.append_generation = 0
        self.append_snapshot_sha256 = bytes(32)

    def _clear_repair_authorization(self) -> None:
        self.repair_generation = 0
        self.repair_snapshot_sha256 = bytes(32)
        self.repair_expected_bytes = 0
        self.repair_target_bytes = 0


def _crash_observer(target_phase: str) -> PhaseObserver:
    def observer(phase: str) -> None:
        if phase == target_phase:
            os.kill(os.getpid(), signal.SIGKILL)

    return observer


def _child_try_lock(arguments: list[str]) -> int:
    if len(arguments) != 4:
        return UNEXPECTED_RETURN_EXIT
    directory, name, epoch_text, max_text = arguments
    try:
        with LockedSweepFile.open(
            directory,
            name,
            int(epoch_text),
            int(max_text),
        ):
            return UNEXPECTED_RETURN_EXIT
    except BlockingIOError:
        return LOCK_HELD_EXIT


def _child_append(arguments: list[str]) -> int:
    if len(arguments) != 6:
        return UNEXPECTED_RETURN_EXIT
    directory, name, epoch_text, max_text, record_hex, phase = arguments
    anchor = record.origin_recovery_anchor()
    with LockedSweepFile.open(
        directory,
        name,
        int(epoch_text),
        int(max_text),
        observer=_crash_observer(phase),
    ) as lease:
        stream_writer = writer.Writer.open_clean(
            lease.observed,
            anchor,
            lease.append_capability(),
        )
        stream_writer.append_record(bytes.fromhex(record_hex))
    return UNEXPECTED_RETURN_EXIT


def _child_repair(arguments: list[str]) -> int:
    if len(arguments) != 5:
        return UNEXPECTED_RETURN_EXIT
    directory, name, epoch_text, max_text, phase = arguments
    anchor = record.origin_recovery_anchor()
    with LockedSweepFile.open(
        directory,
        name,
        int(epoch_text),
        int(max_text),
        observer=_crash_observer(phase),
    ) as lease:
        repairer = writer.Repairer.create(
            lease.observed,
            anchor,
            lease.prepare_repair(anchor),
        )
        repairer.apply()
    return UNEXPECTED_RETURN_EXIT


def main(arguments: list[str] | None = None) -> int:
    values = sys.argv[1:] if arguments is None else arguments
    if not values:
        return UNEXPECTED_RETURN_EXIT
    command, *rest = values
    if command == "_child-try-lock":
        return _child_try_lock(rest)
    if command == "_child-append":
        return _child_append(rest)
    if command == "_child-repair":
        return _child_repair(rest)
    return UNEXPECTED_RETURN_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
