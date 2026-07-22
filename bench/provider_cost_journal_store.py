"""POSIX crash/restart reference for the provider cost journal store v1."""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
from pathlib import Path
import signal
from typing import Any

from bench import provider_cost_journal as journal


class StoreError(RuntimeError):
    """The filesystem authority, recovery policy, or writer state is invalid."""


class InjectedFault(StoreError):
    """A deterministic append phase stopped the writer for fault testing."""


AFTER_BODY_WRITE = "after_body_write"
AFTER_BODY_SYNC = "after_body_sync"
AFTER_FOOTER_WRITE = "after_footer_write"
AFTER_FOOTER_SYNC = "after_footer_sync"
APPEND_PHASES = (
    AFTER_BODY_WRITE,
    AFTER_BODY_SYNC,
    AFTER_FOOTER_WRITE,
    AFTER_FOOTER_SYNC,
)
LOCK_HELD_EXIT = 85
UNEXPECTED_CHILD_RETURN = 86
CHILD_SIGNAL = signal.SIGKILL
MAX_JOURNAL_BYTES = (
    journal.HEADER_BYTES + journal.MAX_SUPPORTED_FRAMES * journal.FRAME_BYTES
)


def _validate_name(journal_name: str) -> None:
    if (
        not journal_name
        or journal_name in (".", "..")
        or "/" in journal_name
        or "\\" in journal_name
        or "\x00" in journal_name
    ):
        raise StoreError("journal name must be one path component")


def _write_all(fd: int, payload: bytes) -> None:
    position = 0
    while position < len(payload):
        written = os.write(fd, payload[position:])
        if written <= 0:
            raise StoreError("short filesystem write")
        position += written


def _pread_all(fd: int, length: int) -> bytes:
    output = bytearray()
    while len(output) < length:
        chunk = os.pread(fd, length - len(output), len(output))
        if not chunk:
            raise StoreError("short filesystem read")
        output.extend(chunk)
    return bytes(output)


def _sync_directory(directory: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_fd = os.open(directory, flags)
    try:
        try:
            os.fsync(directory_fd)
        except OSError as exc:
            if exc.errno in (errno.EINVAL, errno.ENOTSUP):
                return "unsupported"
            raise
    finally:
        os.close(directory_fd)
    return "synced"


class LockedStore:
    """One exclusive advisory lock and one append authority."""

    def __init__(
        self,
        fd: int,
        expected_header_sha256: bytes,
        encoded: bytes,
        recovered: dict[str, Any],
        *,
        directory_sync_status: str,
        repair_sync_exercised: bool,
    ) -> None:
        self.fd = fd
        self.expected_header_sha256 = expected_header_sha256
        self.encoded = bytearray(encoded)
        self.recovered = recovered
        self.directory_sync_status = directory_sync_status
        self.repair_sync_exercised = repair_sync_exercised
        self.state = "ready"

    @classmethod
    def create(
        cls,
        directory: str | os.PathLike[str],
        journal_name: str,
        header: dict[str, Any],
    ) -> LockedStore:
        _validate_name(journal_name)
        encoded = journal.encode_header(header)
        directory_path = Path(directory)
        path = directory_path / journal_name
        flags = os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
        fd = os.open(path, flags, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            _write_all(fd, encoded)
            os.fsync(fd)
            directory_sync_status = _sync_directory(directory_path)
            recovered = journal.recover(encoded, header["header_sha256"])
            return cls(
                fd,
                header["header_sha256"],
                encoded,
                recovered,
                directory_sync_status=directory_sync_status,
                repair_sync_exercised=False,
            )
        except BaseException:
            os.close(fd)
            raise

    @classmethod
    def open(
        cls,
        directory: str | os.PathLike[str],
        journal_name: str,
        expected_header_sha256: bytes,
        *,
        repair_torn_tail: bool = True,
        lock_nonblocking: bool = False,
    ) -> LockedStore:
        _validate_name(journal_name)
        path = Path(directory) / journal_name
        fd = os.open(path, os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        try:
            lock_mode = fcntl.LOCK_EX
            if lock_nonblocking:
                lock_mode |= fcntl.LOCK_NB
            fcntl.flock(fd, lock_mode)
            size = os.fstat(fd).st_size
            if size < journal.HEADER_BYTES:
                raise StoreError("journal header is incomplete")
            if size > MAX_JOURNAL_BYTES:
                raise StoreError("journal exceeds the fixed frame limit")
            encoded = _pread_all(fd, size)
            recovered = journal.recover(encoded, expected_header_sha256)
            repair_sync_exercised = False
            if recovered["status"] == "torn_tail":
                if not repair_torn_tail:
                    raise StoreError("torn tail requires explicit repair authority")
                committed = recovered["committed_bytes"]
                os.ftruncate(fd, committed)
                os.fsync(fd)
                encoded = encoded[:committed]
                repair_sync_exercised = True
            return cls(
                fd,
                expected_header_sha256,
                encoded,
                recovered,
                directory_sync_status="not_applicable",
                repair_sync_exercised=repair_sync_exercised,
            )
        except BaseException:
            os.close(fd)
            raise

    def append_frame(
        self,
        encoded_frame: bytes,
        *,
        fault_after_phase: str | None = None,
        hard_exit: bool = False,
    ) -> dict[str, Any]:
        if self.state != "ready":
            raise StoreError("writer must be reopened after an uncertain append")
        if fault_after_phase is not None and fault_after_phase not in APPEND_PHASES:
            raise StoreError("unknown append fault phase")
        if len(encoded_frame) != journal.FRAME_BYTES:
            raise StoreError("invalid frame length")
        if len(self.encoded) + len(encoded_frame) > MAX_JOURNAL_BYTES:
            raise StoreError("journal frame capacity exceeded")

        prospective_bytes = bytes(self.encoded) + encoded_frame
        prospective = journal.recover(
            prospective_bytes,
            self.expected_header_sha256,
        )
        if prospective["status"] != "clean":
            raise StoreError("append preflight did not form a complete frame")
        body, footer = journal.append_plan(encoded_frame)

        os.lseek(self.fd, len(self.encoded), os.SEEK_SET)
        self.state = "poisoned"
        _write_all(self.fd, body)
        self._checkpoint(AFTER_BODY_WRITE, fault_after_phase, hard_exit)
        os.fsync(self.fd)
        self._checkpoint(AFTER_BODY_SYNC, fault_after_phase, hard_exit)
        _write_all(self.fd, footer)
        self._checkpoint(AFTER_FOOTER_WRITE, fault_after_phase, hard_exit)
        os.fsync(self.fd)
        self._checkpoint(AFTER_FOOTER_SYNC, fault_after_phase, hard_exit)

        self.encoded.extend(encoded_frame)
        self.recovered = prospective
        self.repair_sync_exercised = False
        self.state = "ready"
        return {
            "sequence": prospective["ledger"]["committed_frames"],
            "committed_bytes": prospective["committed_bytes"],
            "final_chain_sha256": prospective["final_chain_sha256"],
            "ledger": prospective["ledger"],
            "body_sync_exercised": True,
            "footer_sync_exercised": True,
        }

    @staticmethod
    def _checkpoint(
        phase: str,
        fault_after_phase: str | None,
        hard_exit: bool,
    ) -> None:
        if phase != fault_after_phase:
            return
        if hard_exit:
            os.kill(os.getpid(), CHILD_SIGNAL)
            os._exit(128 + CHILD_SIGNAL)
        raise InjectedFault(phase)

    def close(self) -> None:
        if self.state == "closed":
            return
        os.close(self.fd)
        self.state = "closed"

    def __enter__(self) -> LockedStore:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def _demo_frame(frame_index: int) -> tuple[dict[str, Any], bytes]:
    header, encoded, _ = journal.build_demo_journal()
    if not 0 <= frame_index < 3:
        raise StoreError("demo frame index is out of range")
    start = journal.HEADER_BYTES + frame_index * journal.FRAME_BYTES
    return header, encoded[start : start + journal.FRAME_BYTES]


def _child_append(arguments: argparse.Namespace) -> int:
    header, frame = _demo_frame(arguments.frame_index)
    expected = bytes.fromhex(arguments.header_sha256)
    if expected != header["header_sha256"]:
        raise StoreError("child fixture header does not match the pinned root")
    with LockedStore.open(
        arguments.directory,
        arguments.journal_name,
        expected,
    ) as store:
        store.append_frame(
            frame,
            fault_after_phase=arguments.phase,
            hard_exit=True,
        )
    return UNEXPECTED_CHILD_RETURN


def _child_try_lock(arguments: argparse.Namespace) -> int:
    try:
        store = LockedStore.open(
            arguments.directory,
            arguments.journal_name,
            bytes.fromhex(arguments.header_sha256),
            lock_nonblocking=True,
        )
    except BlockingIOError:
        return LOCK_HELD_EXIT
    store.close()
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    append = commands.add_parser("_child-append")
    append.add_argument("directory")
    append.add_argument("journal_name")
    append.add_argument("header_sha256")
    append.add_argument("frame_index", type=int)
    append.add_argument("phase", choices=APPEND_PHASES)
    lock = commands.add_parser("_child-try-lock")
    lock.add_argument("directory")
    lock.add_argument("journal_name")
    lock.add_argument("header_sha256")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    if arguments.command == "_child-append":
        return _child_append(arguments)
    if arguments.command == "_child-try-lock":
        return _child_try_lock(arguments)
    raise StoreError("unknown command")


if __name__ == "__main__":
    raise SystemExit(main())
