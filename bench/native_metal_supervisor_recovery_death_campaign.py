#!/usr/bin/env python3
"""Run the fixed W7b-b5 supervisor/recovery death campaign.

The public runner launches two fresh, session-isolated supervisors.  Each
supervisor cleanly reaps its native worker, retains an exclusive campaign-store
lock, publishes one fixed-size ready frame, and is then terminated by a
PID-only ``SIGKILL`` from the controller.  Fresh read-only auditors surround
the externally authorized resume and final roll-forward.

The retained 3,520-byte wire carries the fixed native campaign claims, but
arbitrary CLI paths do not independently establish external build provenance;
the runner therefore labels its receipt as claims-only, not as evidence.
``run_host_protocol_fixture`` exercises the host process, ``flock``,
fixed-frame, and two-``SIGKILL`` protocol without opening a device; it is
always ephemeral and explicitly returns ``evidence=False``.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any, Mapping, Optional, Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bench import native_metal_soak_report as soak
from bench import native_metal_supervisor_recovery_death_report as report
from bench import native_workload_campaign as campaign


class SupervisorRecoveryDeathCampaignError(ValueError):
    """The bounded native or host protocol could not be proven."""


ZERO_DIGEST = bytes(32)
U64_MAX = (1 << 64) - 1
MAX_PRIVATE_JSON_BYTES = 128 * 1024
MAX_COMPONENT_BYTES = 512 * 1024 * 1024
READY_TIMEOUT_SECONDS = 180.0
CHILD_TIMEOUT_SECONDS = 60.0
QUIESCENCE_SECONDS = 0.025

LOCK_IDENTITY_DOMAIN = (
    b"glacier-w7b-b5-supervisor-recovery-lock-identity-v1\x00"
)
CONTROLLER_AUTHORITY_DOMAIN = (
    b"glacier-w7b-b5-supervisor-recovery-controller-authority-v1\x00"
)
CONTENTION_ACK_DOMAIN = (
    b"glacier-w7b-b5-supervisor-lock-contention-ack-v1\x00"
)
RECOVERY_CONTENTION_ACK_DOMAIN = (
    b"glacier-w7b-b5-recovery-lock-contention-ack-v1\x00"
)
HOST_FRAME_DOMAIN = (
    b"glacier-w7b-b5-supervisor-recovery-host-fixture-frame-v1\x00"
)
HOST_MAGIC = b"GW7B5HST"
HOST_ACTIVE_NAME = "active.fixture"
HOST_CANDIDATE_NAME = "candidate.fixture"
HOST_GENERATION_SIX = b"generation-6\n"
HOST_GENERATION_ELEVEN = b"generation-11\n"
HOST_GENERATION_TWELVE = b"generation-12\n"

PYTHON_VERIFY_SCHEMA = (
    "glacier.native-metal-supervisor-recovery-death/"
    "python-verifier-v1"
)
RUN_RECEIPT_SCHEMA = (
    "glacier.native-metal-supervisor-recovery-death/campaign-v1"
)
HOST_RECEIPT_SCHEMA = (
    "glacier.native-metal-supervisor-recovery-death/host-fixture-v1"
)

_SCRIPT_PATH = Path(__file__).resolve()
_ROLE_CHOICES = (
    "supervisor",
    "audit-six",
    "recovery",
    "finalizer",
    "audit-final",
    "verify-report",
    "host-victim",
    "host-audit",
    "host-finalizer",
)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SupervisorRecoveryDeathCampaignError(message)


def _u64(value: int, label: str) -> bytes:
    _require(
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= U64_MAX,
        "%s is outside u64" % label,
    )
    return struct.pack("<Q", value)


def _hash_parts(domain: bytes, *parts: bytes) -> bytes:
    value = hashlib.sha256()
    value.update(domain)
    for part in parts:
        value.update(part)
    return value.digest()


def _file_sha256(path_value: os.PathLike[str] | str) -> bytes:
    path = Path(path_value)
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        before = os.fstat(descriptor)
        named_before = path.lstat()
        identity_before = (
            before.st_dev,
            before.st_ino,
            stat.S_IFMT(before.st_mode),
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_nlink,
        )
        _require(
            stat.S_ISREG(before.st_mode)
            and identity_before
            == (
                named_before.st_dev,
                named_before.st_ino,
                stat.S_IFMT(named_before.st_mode),
                named_before.st_size,
                named_before.st_mtime_ns,
                named_before.st_ctime_ns,
                named_before.st_nlink,
            )
            and before.st_nlink == 1
            and 0 < before.st_size <= MAX_COMPONENT_BYTES,
            "component named identity or size changed",
        )
        value = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            _require(
                total <= MAX_COMPONENT_BYTES,
                "component exceeded its read bound",
            )
            value.update(chunk)
        after = os.fstat(descriptor)
        named_after = path.lstat()
        _require(
            total == before.st_size
            and identity_before
            == (
                after.st_dev,
                after.st_ino,
                stat.S_IFMT(after.st_mode),
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
                after.st_nlink,
            )
            == (
                named_after.st_dev,
                named_after.st_ino,
                stat.S_IFMT(named_after.st_mode),
                named_after.st_size,
                named_after.st_mtime_ns,
                named_after.st_ctime_ns,
                named_after.st_nlink,
            ),
            "component changed while it was hashed",
        )
        return value.digest()
    finally:
        os.close(descriptor)


def _component_snapshot(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    zig_verifier: os.PathLike[str] | str,
) -> dict[str, bytes]:
    controller = _file_sha256(_SCRIPT_PATH)
    return {
        "controller_sha256": controller,
        "supervisor_sha256": controller,
        "recovery_sha256": controller,
        "worker_sha256": _file_sha256(worker),
        "metallib_sha256": _file_sha256(metallib),
        "verifier_sha256": _file_sha256(zig_verifier),
    }


def _verify_component_snapshot(
    snapshot: Mapping[str, bytes],
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    zig_verifier: os.PathLike[str] | str,
) -> None:
    _require(
        type(snapshot) is dict
        and snapshot == _component_snapshot(worker, metallib, zig_verifier),
        "campaign component provenance changed",
    )


def _jsonable(value: Any) -> Any:
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Mapping):
        return {
            str(key): _jsonable(item)
            for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
        }
    if isinstance(value, (tuple, list)):
        return [_jsonable(item) for item in value]
    return value


def _canonical_json_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        _jsonable(value),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _write_private_json(path: Path, value: Mapping[str, Any]) -> None:
    encoded = _canonical_json_bytes(value)
    _require(
        0 < len(encoded) <= MAX_PRIVATE_JSON_BYTES,
        "private protocol record exceeds its bound",
    )
    descriptor = os.open(
        path,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            _require(written > 0, "private protocol write made no progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)


def _read_private_json(path: Path, *, remove: bool = False) -> dict[str, Any]:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        named = path.lstat()
        _require(
            stat.S_ISREG(opened.st_mode)
            and opened.st_dev == named.st_dev
            and opened.st_ino == named.st_ino
            and opened.st_nlink == 1
            and stat.S_IMODE(opened.st_mode) == 0o600
            and 0 < opened.st_size <= MAX_PRIVATE_JSON_BYTES,
            "private protocol record identity changed",
        )
        encoded = bytearray()
        while len(encoded) <= MAX_PRIVATE_JSON_BYTES:
            chunk = os.read(
                descriptor,
                min(64 * 1024, MAX_PRIVATE_JSON_BYTES + 1 - len(encoded)),
            )
            if not chunk:
                break
            encoded.extend(chunk)
        _require(
            len(encoded) == opened.st_size <= MAX_PRIVATE_JSON_BYTES,
            "private protocol record length changed",
        )
    finally:
        os.close(descriptor)
    try:
        decoded = json.loads(bytes(encoded))
    except (TypeError, ValueError) as error:
        raise SupervisorRecoveryDeathCampaignError(
            "private protocol record is not JSON"
        ) from error
    _require(
        type(decoded) is dict
        and _canonical_json_bytes(decoded) == bytes(encoded),
        "private protocol record is not canonical",
    )
    if remove:
        named_after = path.lstat()
        _require(
            (
                named_after.st_dev,
                named_after.st_ino,
                stat.S_IFMT(named_after.st_mode),
                named_after.st_size,
                named_after.st_nlink,
            )
            == (
                opened.st_dev,
                opened.st_ino,
                stat.S_IFMT(opened.st_mode),
                opened.st_size,
                opened.st_nlink,
            ),
            "private protocol record changed before removal",
        )
        path.unlink()
        _fsync_directory(path.parent)
    return decoded


def _wait_private_json(
    path: Path,
    process: subprocess.Popen[bytes],
    *,
    timeout: float,
    remove: bool,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while not os.path.lexists(path):
        _require(
            process.poll() is None,
            "child exited before its private pre-ready handoff",
        )
        _require(
            time.monotonic() < deadline,
            "private pre-ready handoff timed out",
        )
        time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
    return _read_private_json(path, remove=remove)


def _hex_digest(value: Any, label: str) -> bytes:
    _require(
        isinstance(value, str) and len(value) == 64,
        "%s is not a digest" % label,
    )
    try:
        result = bytes.fromhex(value)
    except ValueError as error:
        raise SupervisorRecoveryDeathCampaignError(
            "%s is not hexadecimal" % label
        ) from error
    _require(result != ZERO_DIGEST, "%s is zero" % label)
    return result


def _identity_digest(device: int, inode: int) -> bytes:
    return _hash_parts(
        LOCK_IDENTITY_DOMAIN,
        _u64(device, "lock device"),
        _u64(inode, "lock inode"),
    )


def _contention_ack(
    *,
    controller_pid: int,
    supervisor_pid: int,
    worker_pid: int,
    lock_device: int,
    lock_inode: int,
    supervisor_challenge_sha256: bytes,
) -> dict[str, Any]:
    observation = _hash_parts(
        CONTENTION_ACK_DOMAIN,
        supervisor_challenge_sha256,
        _u64(controller_pid, "controller PID"),
        _u64(supervisor_pid, "supervisor PID"),
        _u64(worker_pid, "supervisor worker PID"),
        _u64(lock_device, "contention lock device"),
        _u64(lock_inode, "contention lock inode"),
    )
    return {
        "schema": "glacier.w7b-b5/supervisor-contention-ack-v1",
        "controller_pid": controller_pid,
        "supervisor_pid": supervisor_pid,
        "worker_pid": worker_pid,
        "lock_device": lock_device,
        "lock_inode": lock_inode,
        "supervisor_challenge_sha256": (
            supervisor_challenge_sha256.hex()
        ),
        "lock_contended": True,
        "observation_sha256": observation.hex(),
    }


def _validate_contention_ack(
    value: Mapping[str, Any],
    *,
    controller_pid: int,
    supervisor_pid: int,
    worker_pid: int,
    lock_device: int,
    lock_inode: int,
    supervisor_challenge_sha256: bytes,
) -> None:
    _require(
        dict(value)
        == _contention_ack(
            controller_pid=controller_pid,
            supervisor_pid=supervisor_pid,
            worker_pid=worker_pid,
            lock_device=lock_device,
            lock_inode=lock_inode,
            supervisor_challenge_sha256=supervisor_challenge_sha256,
        ),
        "supervisor contention ACK changed",
    )


def _recovery_contention_ack(
    *,
    controller_pid: int,
    recovery_pid: int,
    worker_pid: int,
    lock_device: int,
    lock_inode: int,
    recovery_challenge_sha256: bytes,
) -> dict[str, Any]:
    observation = _hash_parts(
        RECOVERY_CONTENTION_ACK_DOMAIN,
        recovery_challenge_sha256,
        _u64(controller_pid, "controller PID"),
        _u64(recovery_pid, "recovery PID"),
        _u64(worker_pid, "recovery worker PID"),
        _u64(lock_device, "recovery lock device"),
        _u64(lock_inode, "recovery lock inode"),
    )
    return {
        "schema": "glacier.w7b-b5/recovery-contention-ack-v1",
        "controller_pid": controller_pid,
        "recovery_pid": recovery_pid,
        "worker_pid": worker_pid,
        "lock_device": lock_device,
        "lock_inode": lock_inode,
        "recovery_challenge_sha256": recovery_challenge_sha256.hex(),
        "lock_contended": True,
        "observation_sha256": observation.hex(),
    }


def _validate_recovery_contention_ack(
    value: Mapping[str, Any],
    *,
    controller_pid: int,
    recovery_pid: int,
    worker_pid: int,
    lock_device: int,
    lock_inode: int,
    recovery_challenge_sha256: bytes,
) -> None:
    _require(
        dict(value)
        == _recovery_contention_ack(
            controller_pid=controller_pid,
            recovery_pid=recovery_pid,
            worker_pid=worker_pid,
            lock_device=lock_device,
            lock_inode=lock_inode,
            recovery_challenge_sha256=recovery_challenge_sha256,
        ),
        "recovery contention ACK changed",
    )


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_stdout_exact(encoded: bytes) -> None:
    view = memoryview(encoded)
    while view:
        written = os.write(sys.stdout.fileno(), view)
        _require(written > 0, "stdout write made no progress")
        view = view[written:]


def _module_command(*arguments: str) -> tuple[str, ...]:
    return (sys.executable, str(_SCRIPT_PATH), *arguments)


def _read_exact_frame(
    process: subprocess.Popen[bytes],
    expected_bytes: int,
    *,
    timeout: float,
    require_blocked: bool,
) -> bytes:
    _require(
        process.stdout is not None and process.stderr is not None,
        "child pipes are unavailable",
    )
    deadline = time.monotonic() + timeout
    result = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while len(result) < expected_bytes:
            remaining = deadline - time.monotonic()
            _require(remaining > 0, "child frame timed out")
            ready = selector.select(remaining)
            _require(ready, "child frame timed out")
            chunk = os.read(
                process.stdout.fileno(),
                expected_bytes - len(result),
            )
            _require(chunk, "child frame ended early")
            result.extend(chunk)
        if require_blocked:
            ready = selector.select(QUIESCENCE_SECONDS)
            if ready:
                extension = os.read(process.stdout.fileno(), 1)
                _require(extension == b"", "child frame has trailing bytes")
                _require(False, "child exited before its kill boundary")
            _require(
                process.poll() is None,
                "child exited before its kill boundary",
            )
    finally:
        selector.close()
    return bytes(result)


def _finish_clean_child(
    process: subprocess.Popen[bytes],
    expected_stdout_bytes: int,
    *,
    timeout: float = CHILD_TIMEOUT_SECONDS,
) -> bytes:
    _require(
        process.stdout is not None and process.stderr is not None,
        "child pipes are unavailable",
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        os.kill(process.pid, signal.SIGKILL)
        process.wait(timeout=5.0)
        raise SupervisorRecoveryDeathCampaignError(
            "clean child timed out"
        ) from error
    _require(process.returncode == 0, "clean child failed")
    _require(stderr == b"", "clean child wrote stderr")
    _require(
        len(stdout) == expected_stdout_bytes,
        "clean child stdout length changed",
    )
    return stdout


class _ChildRegistry:
    """Bound every spawned role and reap it on every exit path."""

    def __init__(self) -> None:
        self.processes: list[subprocess.Popen[bytes]] = []

    def add(
        self,
        process: subprocess.Popen[bytes],
    ) -> subprocess.Popen[bytes]:
        self.processes.append(process)
        return process

    def cleanup(self) -> None:
        for process in reversed(self.processes):
            if process.poll() is None:
                try:
                    if (
                        os.getpgid(process.pid) == process.pid
                        and os.getsid(process.pid) == process.pid
                    ):
                        os.killpg(process.pid, signal.SIGKILL)
                    else:
                        os.kill(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=5.0)
            except subprocess.TimeoutExpired as error:
                raise SupervisorRecoveryDeathCampaignError(
                    "child cleanup did not reap its process"
                ) from error
            for stream in (process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    with contextlib.suppress(OSError):
                        stream.read()
                    stream.close()
        _require(
            all(process.poll() is not None for process in self.processes),
            "child registry retained an active process",
        )

    def __enter__(self) -> "_ChildRegistry":
        return self

    def __exit__(
        self,
        _exception_type: object,
        _exception: object,
        _traceback: object,
    ) -> None:
        self.cleanup()


def _prove_lock_contended(
    lock_path: Path,
    expected_device: int,
    expected_inode: int,
) -> None:
    descriptor = os.open(
        lock_path,
        os.O_RDWR
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        _require(
            stat.S_ISREG(opened.st_mode)
            and (opened.st_dev, opened.st_ino)
            == (expected_device, expected_inode),
            "contended lock identity changed",
        )
        try:
            fcntl.flock(
                descriptor,
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except OSError as error:
            _require(
                error.errno in (errno.EACCES, errno.EAGAIN),
                "lock contention failed unexpectedly",
            )
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            _require(False, "exclusive campaign lock was not contended")
    finally:
        os.close(descriptor)


def _kill_ready_child(
    process: subprocess.Popen[bytes],
    ready: Mapping[str, Any],
    encoded_ready: bytes,
    lock_path: Path,
) -> None:
    pid = int(ready["pid"])
    _require(process.pid == pid, "ready frame PID changed")
    _require(
        os.getsid(process.pid) == process.pid,
        "victim process session is not isolated",
    )
    _prove_lock_contended(
        lock_path,
        int(ready["_lock_device"]),
        int(ready["_lock_inode"]),
    )
    os.kill(process.pid, signal.SIGKILL)
    try:
        returncode = process.wait(timeout=10.0)
    except subprocess.TimeoutExpired as error:
        raise SupervisorRecoveryDeathCampaignError(
            "SIGKILL victim did not exit"
        ) from error
    _require(
        returncode == -signal.SIGKILL,
        "victim did not return exact SIGKILL status",
    )
    _require(
        process.stdout is not None and process.stderr is not None,
        "victim pipes are unavailable",
    )
    trailing_stdout = process.stdout.read()
    stderr = process.stderr.read()
    _require(
        trailing_stdout == b"" and stderr == b"",
        "SIGKILL victim emitted trailing output",
    )
    _require(
        len(encoded_ready)
        in (report.SUPERVISOR_READY_BYTES, report.RECOVERY_READY_BYTES),
        "victim ready-frame length changed",
    )


class _SharedStoreView:
    """Minimal read-only store view protected by one shared ``flock``."""

    def __init__(self, root: Path, *, allow_candidate: bool) -> None:
        self.root = root
        self.allow_candidate = allow_candidate
        self.root_fd = -1
        self.lock_fd = -1
        self.directory_fds: dict[str, int] = {}
        self.directory_identities: dict[str, tuple[int, int]] = {}

    def __enter__(self) -> "_SharedStoreView":
        try:
            return self._open()
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def _open(self) -> "_SharedStoreView":
        self.root_fd = os.open(
            self.root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        root_info = os.fstat(self.root_fd)
        _require(
            stat.S_ISDIR(root_info.st_mode)
            and stat.S_IMODE(root_info.st_mode) & 0o077 == 0,
            "audit store root is not private",
        )
        self.root_identity = (root_info.st_dev, root_info.st_ino)
        for name in ("segments", "manifests", "environments"):
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=self.root_fd,
            )
            opened = os.fstat(descriptor)
            _require(
                stat.S_ISDIR(opened.st_mode)
                and opened.st_dev == root_info.st_dev
                and stat.S_IMODE(opened.st_mode) & 0o077 == 0,
                "audit object directory identity changed",
            )
            self.directory_fds[name] = descriptor
            self.directory_identities[name] = (
                opened.st_dev,
                opened.st_ino,
            )
        self.lock_fd = os.open(
            soak.LOCK_NAME,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=self.root_fd,
        )
        lock_info = os.fstat(self.lock_fd)
        _require(
            stat.S_ISREG(lock_info.st_mode)
            and lock_info.st_dev == root_info.st_dev
            and lock_info.st_nlink == 1,
            "audit lock identity changed",
        )
        self.lock_identity = (lock_info.st_dev, lock_info.st_ino)
        try:
            fcntl.flock(
                self.lock_fd,
                fcntl.LOCK_SH | fcntl.LOCK_NB,
            )
        except OSError as error:
            raise SupervisorRecoveryDeathCampaignError(
                "audit could not acquire the shared store lock"
            ) from error
        self._guard_namespace()
        return self

    def _guard_namespace(self) -> None:
        root_info = os.fstat(self.root_fd)
        named_root = self.root.lstat()
        _require(
            stat.S_ISDIR(root_info.st_mode)
            and (root_info.st_dev, root_info.st_ino)
            == self.root_identity
            == (named_root.st_dev, named_root.st_ino),
            "audit store root identity changed",
        )
        expected = {
            "segments",
            "manifests",
            "environments",
            soak.LOCK_NAME,
            soak.ACTIVE_SELECTOR_NAME,
        }
        if self.allow_candidate:
            expected.add(soak.SELECTOR_TEMP_NAME)
        _require(
            set(os.listdir(self.root_fd)) == expected,
            "audit store root shape changed",
        )
        lock_info = os.fstat(self.lock_fd)
        named_lock = os.stat(
            soak.LOCK_NAME,
            dir_fd=self.root_fd,
            follow_symlinks=False,
        )
        _require(
            stat.S_ISREG(lock_info.st_mode)
            and (lock_info.st_dev, lock_info.st_ino)
            == self.lock_identity
            == (named_lock.st_dev, named_lock.st_ino),
            "audit lock identity changed",
        )
        for name, descriptor in self.directory_fds.items():
            opened = os.fstat(descriptor)
            named = os.stat(name, dir_fd=self.root_fd, follow_symlinks=False)
            _require(
                stat.S_ISDIR(opened.st_mode)
                and (opened.st_dev, opened.st_ino)
                == self.directory_identities[name]
                == (named.st_dev, named.st_ino),
                "audit object-directory identity changed",
            )

    def snapshot(self, expected_generation: int) -> dict[str, Any]:
        self._guard_namespace()
        selector_wire = soak._read_regular_at(
            self.root_fd,
            soak.ACTIVE_SELECTOR_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        selector = campaign.decode_selector(selector_wire)
        _require(
            selector["generation"] == expected_generation,
            "audit selected generation changed",
        )
        manifest_wire = soak._read_regular_at(
            self.directory_fds["manifests"],
            selector["manifest_sha256"].hex() + ".bin",
            campaign.encoded_manifest_bytes(soak.SEGMENT_COUNT),
            expected_device=self.root_identity[0],
            require_private_single_link=True,
        )
        manifest = campaign.verify_manifest(manifest_wire)
        campaign.verify_selector(
            manifest_wire,
            selector_wire,
            selector["environment_sha256"],
        )
        _require(
            len(manifest["entries"]) == expected_generation,
            "audit manifest generation changed",
        )
        store_shape = soak._store_shape_sha256(self)
        self._guard_namespace()
        return {
            "selector_wire": selector_wire,
            "selector_sha256": selector["selector_sha256"],
            "manifest_sha256": manifest["manifest_sha256"],
            "final_entry_sha256": manifest["entries"][-1]["entry_sha256"],
            "store_shape_sha256": store_shape,
            "campaign_id_sha256": manifest["plan"]["campaign_id_sha256"],
            "plan": manifest["plan"],
        }

    def __exit__(
        self,
        _exception_type: object,
        _exception: object,
        _traceback: object,
    ) -> None:
        if self.lock_fd >= 0:
            with contextlib.suppress(OSError):
                fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)
            self.lock_fd = -1
        for descriptor in self.directory_fds.values():
            os.close(descriptor)
        self.directory_fds.clear()
        if self.root_fd >= 0:
            os.close(self.root_fd)
            self.root_fd = -1


def _record_components(config: Mapping[str, Any]) -> dict[str, bytes]:
    value = config.get("components")
    _require(type(value) is dict, "component config changed")
    names = (
        "controller_sha256",
        "supervisor_sha256",
        "recovery_sha256",
        "worker_sha256",
        "metallib_sha256",
        "verifier_sha256",
    )
    result = {
        name: _hex_digest(value.get(name), "component.%s" % name)
        for name in names
    }
    _require(
        result["controller_sha256"]
        == result["supervisor_sha256"]
        == result["recovery_sha256"],
        "shared controller role image changed",
    )
    return result


def _verify_child_components(
    components: Mapping[str, bytes],
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
) -> None:
    current_role = _file_sha256(_SCRIPT_PATH)
    _require(
        current_role
        == components["controller_sha256"]
        == components["supervisor_sha256"]
        == components["recovery_sha256"]
        and _file_sha256(worker) == components["worker_sha256"]
        and _file_sha256(metallib) == components["metallib_sha256"],
        "child component provenance changed",
    )


def _supervisor_ready_record(
    facts: Mapping[str, Any],
    plan: Mapping[str, Any],
    components: Mapping[str, bytes],
    supervisor_challenge_sha256: bytes,
) -> dict[str, Any]:
    lock_identity = _identity_digest(
        int(facts["lock_device"]),
        int(facts["lock_inode"]),
    )
    machine_join = report.derive_machine_join_sha256(
        plan["machine_sha256"],
        plan["backend_sha256"],
        plan["device_sha256"],
        plan["placement_sha256"],
    )
    return report.make_supervisor_ready(
        {
            "abi_version": report.SUPERVISOR_READY_ABI,
            "encoded_bytes": report.SUPERVISOR_READY_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "pid": os.getpid(),
            "worker_pid": int(facts["worker_pid"]),
            "worker_exit_code_bits": int(facts["worker_exit_code_bits"]),
            "worker_termination_signal": int(
                facts["worker_termination_signal"]
            ),
            "active_worker_count": 0,
            "lock_held": 1,
            "selected_generation": report.SUPERVISOR_GENERATION,
            "segment_count": report.SUPERVISOR_GENERATION,
            "publication_inflight": 0,
            "selector_bytes": report.SELECTOR_BYTES,
            "process_session_isolated": 1,
            "lock_contended": 1,
            "reserved": 0,
            "supervisor_challenge_sha256": (
                supervisor_challenge_sha256
            ),
            "supervisor_sha256": components["supervisor_sha256"],
            "worker_sha256": components["worker_sha256"],
            "metallib_sha256": components["metallib_sha256"],
            "campaign_id_sha256": _hex_digest(
                facts["campaign_id_sha256"],
                "prefix campaign",
            ),
            "manifest_sha256": _hex_digest(
                facts["manifest_sha256"],
                "prefix manifest",
            ),
            "selector_sha256": _hex_digest(
                facts["selector_sha256"],
                "prefix selector",
            ),
            "final_entry_sha256": _hex_digest(
                facts["final_entry_sha256"],
                "prefix final entry",
            ),
            "canonical_store_sha256": _hex_digest(
                facts["store_shape_sha256"],
                "prefix store shape",
            ),
            "lock_identity_sha256": lock_identity,
            "machine_join_sha256": machine_join,
            "root_sha256": ZERO_DIGEST,
        }
    )


def _generation_six_audit_record(
    snapshot: Mapping[str, Any],
    *,
    resume_grant_sha256: bytes,
) -> dict[str, Any]:
    return report.make_generation_six_audit(
        {
            "abi_version": report.GENERATION_SIX_AUDIT_ABI,
            "encoded_bytes": report.GENERATION_SIX_AUDIT_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "auditor_pid": os.getpid(),
            "selected_generation": report.SUPERVISOR_GENERATION,
            "segment_count": report.SUPERVISOR_GENERATION,
            "require_complete": 0,
            "complete": 0,
            "shared_lock": 1,
            "unknown_object_count": 0,
            "temporary_object_count": 0,
            "hardlink_count": 0,
            "symlink_count": 0,
            "process_generation_count": 1,
            "total_records": report.GENERATION_SIX_RECORDS,
            "total_completed": report.GENERATION_SIX_COMPLETED,
            "resume_grant_sha256": resume_grant_sha256,
            "campaign_id_sha256": snapshot["campaign_id_sha256"],
            "manifest_sha256": snapshot["manifest_sha256"],
            "selector_sha256": snapshot["selector_sha256"],
            "final_entry_sha256": snapshot["final_entry_sha256"],
            "canonical_store_sha256": snapshot[
                "store_shape_sha256"
            ],
            "lock_identity_sha256": _identity_digest(
                *snapshot["lock_identity"]
            ),
            "root_sha256": ZERO_DIGEST,
        }
    )


def _recovery_ready_record(
    facts: Mapping[str, Any],
    components: Mapping[str, bytes],
    resume_grant_sha256: bytes,
    recovery_challenge_sha256: bytes,
) -> dict[str, Any]:
    return report.make_recovery_ready(
        {
            "abi_version": report.RECOVERY_READY_ABI,
            "encoded_bytes": report.RECOVERY_READY_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "pid": os.getpid(),
            "worker_pid": int(facts["worker_pid"]),
            "worker_exit_code_bits": int(facts["worker_exit_code_bits"]),
            "worker_termination_signal": int(
                facts["worker_termination_signal"]
            ),
            "active_worker_count": 0,
            "lock_held": 1,
            "selected_generation": (
                report.RECOVERY_SELECTED_GENERATION
            ),
            "candidate_generation": report.CANDIDATE_GENERATION,
            "segment_count": report.SEGMENT_COUNT,
            "controller_lock_contention_acknowledged": 1,
            "candidate_selector_bytes": report.SELECTOR_BYTES,
            "root_sync_completed": 0,
            "publication_phase_index": (
                report.PUBLICATION_PHASE_SELECTOR_ACTIVE_REPLACE
            ),
            "resume_grant_sha256": resume_grant_sha256,
            "recovery_sha256": components["recovery_sha256"],
            "worker_sha256": components["worker_sha256"],
            "recovery_challenge_sha256": (
                recovery_challenge_sha256
            ),
            "campaign_id_sha256": _hex_digest(
                facts["campaign_id_sha256"],
                "prepared campaign",
            ),
            "selected_manifest_sha256": _hex_digest(
                facts["selected_manifest_sha256"],
                "selected manifest",
            ),
            "selected_selector_sha256": _hex_digest(
                facts["selected_selector_sha256"],
                "selected selector",
            ),
            "candidate_manifest_sha256": _hex_digest(
                facts["candidate_manifest_sha256"],
                "candidate manifest",
            ),
            "candidate_selector_sha256": _hex_digest(
                facts["candidate_selector_sha256"],
                "candidate selector",
            ),
            "prepared_store_sha256": _hex_digest(
                facts["prepared_store_shape_sha256"],
                "prepared store",
            ),
            "lock_identity_sha256": _identity_digest(
                int(facts["lock_device"]),
                int(facts["lock_inode"]),
            ),
            "root_sha256": ZERO_DIGEST,
        }
    )


def _final_audit_record(
    snapshot: Mapping[str, Any],
    prepared_facts: Mapping[str, Any],
    *,
    finalizer_grant_sha256: bytes,
    finalizer_pid: int,
) -> dict[str, Any]:
    return report.make_final_audit(
        {
            "abi_version": report.FINAL_AUDIT_ABI,
            "encoded_bytes": report.FINAL_AUDIT_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "finalizer_pid": finalizer_pid,
            "auditor_pid": os.getpid(),
            "predecessor_generation": (
                report.RECOVERY_SELECTED_GENERATION
            ),
            "final_generation": report.CANDIDATE_GENERATION,
            "segment_count": report.SEGMENT_COUNT,
            "rollforward_count": 1,
            "replace_count": 1,
            "root_sync_count": 1,
            "complete": 1,
            "unknown_object_count": 0,
            "temporary_object_count": 0,
            "total_records": report.TOTAL_RECORDS,
            "total_completed": report.TOTAL_COMPLETED,
            "finalizer_grant_sha256": finalizer_grant_sha256,
            "campaign_id_sha256": snapshot["campaign_id_sha256"],
            "predecessor_selector_sha256": _hex_digest(
                prepared_facts["selected_selector_sha256"],
                "final predecessor selector",
            ),
            "candidate_selector_sha256": _hex_digest(
                prepared_facts["candidate_selector_sha256"],
                "final candidate selector",
            ),
            "final_manifest_sha256": snapshot["manifest_sha256"],
            "final_selector_sha256": snapshot["selector_sha256"],
            "final_store_sha256": snapshot["store_shape_sha256"],
            "root_sha256": ZERO_DIGEST,
        }
    )


def _child_supervisor(arguments: argparse.Namespace) -> int:
    config = _read_private_json(Path(arguments._config))
    _require(
        config.get("schema") == "glacier.w7b-b5/supervisor-config-v1",
        "supervisor config schema changed",
    )
    components = _record_components(config)
    _verify_child_components(
        components,
        arguments.worker,
        arguments.metallib,
    )
    campaign_challenge = _hex_digest(
        config["campaign_challenge_sha256"],
        "campaign challenge",
    )
    supervisor_challenge = _hex_digest(
        config["supervisor_challenge_sha256"],
        "supervisor challenge",
    )
    handle = soak.run_campaign_prefix(
        arguments.worker,
        arguments.metallib,
        arguments._campaign_dir,
        campaign_challenge_sha256=campaign_challenge,
        boundary_challenge_sha256=supervisor_challenge,
    )
    facts = handle.facts
    _selector_wire, _selector, _manifest_wire, manifest = (
        soak._read_selected_campaign(handle.store)
    )
    plan = manifest["plan"]
    _require(
        plan["campaign_challenge_sha256"] == campaign_challenge,
        "supervisor retained campaign challenge changed",
    )
    _write_private_json(
        Path(arguments._handoff),
        {
            "schema": "glacier.w7b-b5/supervisor-pre-ready-v1",
            "pid": os.getpid(),
            "facts": facts,
            "plan_identities": {
                name: plan[name]
                for name in (
                    "campaign_challenge_sha256",
                    "schedule_sha256",
                    "machine_sha256",
                    "backend_sha256",
                    "device_sha256",
                    "placement_sha256",
                )
            },
        },
    )
    ack_path = Path(arguments._ack)
    ack_timeout_millis = int(config["ack_timeout_millis"])
    _require(
        1 <= ack_timeout_millis <= 600_000,
        "supervisor ACK timeout changed",
    )
    deadline = time.monotonic() + ack_timeout_millis / 1000
    while not os.path.lexists(ack_path):
        _require(
            time.monotonic() < deadline,
            "supervisor contention ACK timed out",
        )
        time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
    ack = _read_private_json(ack_path, remove=True)
    _validate_contention_ack(
        ack,
        controller_pid=int(config["controller_pid"]),
        supervisor_pid=os.getpid(),
        worker_pid=int(facts["worker_pid"]),
        lock_device=int(facts["lock_device"]),
        lock_inode=int(facts["lock_inode"]),
        supervisor_challenge_sha256=supervisor_challenge,
    )
    ready = _supervisor_ready_record(
        facts,
        plan,
        components,
        supervisor_challenge,
    )
    encoded = report.encode_supervisor_ready(ready)
    _write_stdout_exact(encoded)
    while True:
        signal.pause()


def _child_audit_six(arguments: argparse.Namespace) -> int:
    config = _read_private_json(Path(arguments._config))
    _require(
        config.get("schema") == "glacier.w7b-b5/audit-six-config-v1",
        "generation-six audit config changed",
    )
    resume_grant = _hex_digest(
        config["resume_grant_sha256"],
        "resume grant",
    )
    verified = soak.verify_retained_store(
        arguments.worker,
        arguments.metallib,
        arguments._campaign_dir,
        expected_forced_process_restart=False,
        require_complete=False,
    )
    _require(
        verified["segments"] == report.SUPERVISOR_GENERATION
        and verified["records"] == report.GENERATION_SIX_RECORDS
        and verified["completed"] == report.GENERATION_SIX_COMPLETED
        and verified["complete"] is False,
        "generation-six offline audit accounting changed",
    )
    with _SharedStoreView(
        Path(arguments._campaign_dir),
        allow_candidate=False,
    ) as view:
        snapshot = view.snapshot(report.SUPERVISOR_GENERATION)
        snapshot["lock_identity"] = view.lock_identity
        record = _generation_six_audit_record(
            snapshot,
            resume_grant_sha256=resume_grant,
        )
        _write_stdout_exact(
            report.encode_generation_six_audit(record)
        )
    return 0


def _child_recovery(arguments: argparse.Namespace) -> int:
    config = _read_private_json(Path(arguments._config))
    _require(
        config.get("schema") == "glacier.w7b-b5/recovery-config-v1",
        "recovery config schema changed",
    )
    components = _record_components(config)
    _verify_child_components(
        components,
        arguments.worker,
        arguments.metallib,
    )
    resume_grant = _hex_digest(
        config["resume_grant_sha256"],
        "resume grant",
    )
    recovery_challenge = _hex_digest(
        config["recovery_challenge_sha256"],
        "recovery challenge",
    )
    prefix_facts = config.get("prefix_facts")
    _require(type(prefix_facts) is dict, "prefix facts changed")
    handle = soak.resume_campaign_to_prepared_final(
        arguments.worker,
        arguments.metallib,
        arguments._campaign_dir,
        resume_grant_sha256=resume_grant,
        expected_prefix_facts=prefix_facts,
        recovery_challenge_sha256=recovery_challenge,
    )
    facts = handle.facts
    _write_private_json(
        Path(arguments._handoff),
        {
            "schema": "glacier.w7b-b5/recovery-pre-ready-v1",
            "pid": os.getpid(),
            "facts": facts,
        },
    )
    ack_path = Path(arguments._ack)
    ack_timeout_millis = int(config["ack_timeout_millis"])
    _require(
        1 <= ack_timeout_millis <= 600_000,
        "recovery ACK timeout changed",
    )
    deadline = time.monotonic() + ack_timeout_millis / 1000
    while not os.path.lexists(ack_path):
        _require(
            time.monotonic() < deadline,
            "recovery contention ACK timed out",
        )
        time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
    ack = _read_private_json(ack_path, remove=True)
    _validate_recovery_contention_ack(
        ack,
        controller_pid=int(config["controller_pid"]),
        recovery_pid=os.getpid(),
        worker_pid=int(facts["worker_pid"]),
        lock_device=int(facts["lock_device"]),
        lock_inode=int(facts["lock_inode"]),
        recovery_challenge_sha256=recovery_challenge,
    )
    ready = _recovery_ready_record(
        facts,
        components,
        resume_grant,
        recovery_challenge,
    )
    encoded = report.encode_recovery_ready(ready)
    _write_stdout_exact(encoded)
    while True:
        signal.pause()


def _child_finalizer(arguments: argparse.Namespace) -> int:
    config = _read_private_json(Path(arguments._config))
    _require(
        config.get("schema") == "glacier.w7b-b5/finalizer-config-v1",
        "finalizer config schema changed",
    )
    prepared_facts = config.get("prepared_facts")
    _require(type(prepared_facts) is dict, "prepared facts changed")
    finalizer_grant = _hex_digest(
        config["finalizer_grant_sha256"],
        "finalizer grant",
    )
    with soak.roll_forward_prepared_final(
        arguments.worker,
        arguments.metallib,
        arguments._campaign_dir,
        finalizer_grant_sha256=finalizer_grant,
        expected_prepared_facts=prepared_facts,
    ) as handle:
        _write_private_json(
            Path(arguments._handoff),
            {
                "schema": "glacier.w7b-b5/finalizer-handoff-v1",
                "facts": handle.facts,
                "pid": os.getpid(),
            },
        )
    return 0


def _child_audit_final(arguments: argparse.Namespace) -> int:
    config = _read_private_json(Path(arguments._config))
    _require(
        config.get("schema") == "glacier.w7b-b5/audit-final-config-v1",
        "final audit config schema changed",
    )
    prepared_facts = config.get("prepared_facts")
    _require(type(prepared_facts) is dict, "final prepared facts changed")
    finalizer_pid = int(config["finalizer_pid"])
    finalizer_grant = _hex_digest(
        config["finalizer_grant_sha256"],
        "finalizer grant",
    )
    verified = soak.verify_retained_store(
        arguments.worker,
        arguments.metallib,
        arguments._campaign_dir,
        expected_forced_process_restart=False,
        require_complete=True,
    )
    _require(
        verified["segments"] == report.SEGMENT_COUNT
        and verified["records"] == report.TOTAL_RECORDS
        and verified["completed"] == report.TOTAL_COMPLETED
        and verified["complete"] is True,
        "final offline audit accounting changed",
    )
    with _SharedStoreView(
        Path(arguments._campaign_dir),
        allow_candidate=False,
    ) as view:
        snapshot = view.snapshot(report.CANDIDATE_GENERATION)
        record = _final_audit_record(
            snapshot,
            prepared_facts,
            finalizer_grant_sha256=finalizer_grant,
            finalizer_pid=finalizer_pid,
        )
        _write_stdout_exact(report.encode_final_audit(record))
    return 0


def _child_verify_report(arguments: argparse.Namespace) -> int:
    encoded = Path(arguments._report).read_bytes()
    decoded = report.verify_report(encoded)
    print(
        json.dumps(
            {
                "schema": PYTHON_VERIFY_SCHEMA,
                "encoded_bytes": len(encoded),
                "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
                "report_sha256": decoded.report_sha256.hex(),
                "verified": True,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def _spawn_role(
    role: str,
    *,
    worker: Path,
    metallib: Path,
    campaign_dir: Path,
    config: Optional[Path] = None,
    handoff: Optional[Path] = None,
    ack: Optional[Path] = None,
    report_path: Optional[Path] = None,
    extra: Sequence[str] = (),
    registry: Optional[_ChildRegistry] = None,
) -> subprocess.Popen[bytes]:
    arguments = [
        "--_role",
        role,
        "--worker",
        str(worker),
        "--metallib",
        str(metallib),
        "--_campaign-dir",
        str(campaign_dir),
    ]
    if config is not None:
        arguments.extend(("--_config", str(config)))
    if handoff is not None:
        arguments.extend(("--_handoff", str(handoff)))
    if ack is not None:
        arguments.extend(("--_ack", str(ack)))
    if report_path is not None:
        arguments.extend(("--_report", str(report_path)))
    arguments.extend(extra)
    process = subprocess.Popen(
        _module_command(*arguments),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        close_fds=True,
    )
    return process if registry is None else registry.add(process)


def _kill_record(
    ready: Mapping[str, Any],
    *,
    supervisor: bool,
    campaign_challenge_sha256: bytes,
    role_challenge_sha256: bytes,
    controller_sha256: bytes,
    component_set_sha256: bytes,
) -> dict[str, Any]:
    common = {
        "flags": report.ALLOWED_FLAGS,
        "pid": int(ready["pid"]),
        "termination_signal": signal.SIGKILL,
        "returncode_bits": report.SIGKILL_RETURNCODE_BITS,
        "stdout_bytes": int(ready["encoded_bytes"]),
        "stderr_bytes": 0,
        "campaign_challenge_sha256": campaign_challenge_sha256,
        "controller_sha256": controller_sha256,
        "lock_identity_sha256": ready["lock_identity_sha256"],
        "component_set_sha256": component_set_sha256,
        "root_sha256": ZERO_DIGEST,
    }
    if supervisor:
        common.update(
            {
                "abi_version": report.SUPERVISOR_KILL_ABI,
                "encoded_bytes": report.SUPERVISOR_KILL_BYTES,
                "supervisor_challenge_sha256": role_challenge_sha256,
                "supervisor_ready_sha256": ready["root_sha256"],
                "supervisor_sha256": ready["supervisor_sha256"],
            }
        )
        return report.make_supervisor_kill(common)
    common.update(
        {
            "abi_version": report.RECOVERY_KILL_ABI,
            "encoded_bytes": report.RECOVERY_KILL_BYTES,
            "resume_grant_sha256": role_challenge_sha256,
            "recovery_ready_sha256": ready["root_sha256"],
            "recovery_sha256": ready["recovery_sha256"],
        }
    )
    return report.make_recovery_kill(common)


def _header_record(
    *,
    plan_identities: Mapping[str, bytes],
    controller_authority_sha256: bytes,
    components: Mapping[str, bytes],
    component_set_sha256: bytes,
    resume_grant_sha256: bytes,
    finalizer_grant_sha256: bytes,
    supervisor_ready: Mapping[str, Any],
    supervisor_kill: Mapping[str, Any],
    generation_six_audit: Mapping[str, Any],
    recovery_ready: Mapping[str, Any],
    recovery_kill: Mapping[str, Any],
    final_audit: Mapping[str, Any],
) -> dict[str, Any]:
    return report.make_header(
        {
            "abi_version": report.REPORT_ABI,
            "encoded_bytes": report.REPORT_BYTES,
            "flags": report.ALLOWED_FLAGS,
            "header_bytes": report.HEADER_BYTES,
            "supervisor_ready_bytes": report.SUPERVISOR_READY_BYTES,
            "supervisor_kill_bytes": report.SUPERVISOR_KILL_BYTES,
            "generation_six_audit_bytes": (
                report.GENERATION_SIX_AUDIT_BYTES
            ),
            "recovery_ready_bytes": report.RECOVERY_READY_BYTES,
            "recovery_kill_bytes": report.RECOVERY_KILL_BYTES,
            "final_audit_bytes": report.FINAL_AUDIT_BYTES,
            "footer_bytes": report.FOOTER_BYTES,
            "segment_count": report.SEGMENT_COUNT,
            "supervisor_generation": report.SUPERVISOR_GENERATION,
            "recovery_selected_generation": (
                report.RECOVERY_SELECTED_GENERATION
            ),
            "candidate_generation": report.CANDIDATE_GENERATION,
            "worker_process_count": report.WORKER_PROCESS_COUNT,
            "total_sigkill_count": report.TOTAL_SIGKILL_COUNT,
            "total_records": report.TOTAL_RECORDS,
            "total_completed": report.TOTAL_COMPLETED,
            "total_cancelled": report.TOTAL_CANCELLED,
            "total_failed": report.TOTAL_FAILED,
            "total_capacity_rejected": (
                report.TOTAL_CAPACITY_REJECTED
            ),
            "total_pin_completions": report.TOTAL_PIN_COMPLETIONS,
            "total_events": report.TOTAL_EVENTS,
            "campaign_challenge_sha256": plan_identities[
                "campaign_challenge_sha256"
            ],
            "schedule_sha256": plan_identities["schedule_sha256"],
            "controller_authority_sha256": (
                controller_authority_sha256
            ),
            "component_set_sha256": component_set_sha256,
            "controller_sha256": components["controller_sha256"],
            "supervisor_sha256": components["supervisor_sha256"],
            "recovery_sha256": components["recovery_sha256"],
            "worker_sha256": components["worker_sha256"],
            "metallib_sha256": components["metallib_sha256"],
            "verifier_sha256": components["verifier_sha256"],
            "machine_sha256": plan_identities["machine_sha256"],
            "backend_sha256": plan_identities["backend_sha256"],
            "device_sha256": plan_identities["device_sha256"],
            "placement_sha256": plan_identities["placement_sha256"],
            "resume_grant_sha256": resume_grant_sha256,
            "finalizer_grant_sha256": finalizer_grant_sha256,
            "supervisor_ready_sha256": supervisor_ready[
                "root_sha256"
            ],
            "supervisor_kill_sha256": supervisor_kill["root_sha256"],
            "generation_six_audit_sha256": generation_six_audit[
                "root_sha256"
            ],
            "recovery_ready_sha256": recovery_ready["root_sha256"],
            "recovery_kill_sha256": recovery_kill["root_sha256"],
            "final_audit_sha256": final_audit["root_sha256"],
            "generation_six_selector_sha256": supervisor_ready[
                "selector_sha256"
            ],
            "candidate_selector_sha256": recovery_ready[
                "candidate_selector_sha256"
            ],
            "final_store_sha256": final_audit["final_store_sha256"],
            "header_sha256": ZERO_DIGEST,
        }
    )


def _write_report_file(path: Path, encoded: bytes) -> None:
    _require(len(encoded) == report.REPORT_BYTES, "report length changed")
    descriptor = os.open(
        path,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            _require(written > 0, "report write made no progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _fsync_directory(path.parent)


def _verify_report_fresh(
    report_path: Path,
    encoded: bytes,
    zig_verifier: Path,
) -> dict[str, Any]:
    expected = report.verify_report(encoded)
    completed = subprocess.run(
        _module_command(
            "--_role",
            "verify-report",
            "--_report",
            str(report_path),
        ),
        check=False,
        capture_output=True,
        timeout=CHILD_TIMEOUT_SECONDS,
    )
    _require(
        completed.returncode == 0 and completed.stderr == b"",
        "fresh Python report verifier failed",
    )
    _require(
        len(completed.stdout) <= 1024
        and completed.stdout.endswith(b"\n")
        and completed.stdout.count(b"\n") == 1,
        "fresh Python verifier output changed",
    )
    try:
        python_receipt = json.loads(completed.stdout)
    except (TypeError, ValueError) as error:
        raise SupervisorRecoveryDeathCampaignError(
            "fresh Python verifier output is not JSON"
        ) from error
    _require(
        python_receipt
        == {
            "schema": PYTHON_VERIFY_SCHEMA,
            "encoded_bytes": report.REPORT_BYTES,
            "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
            "report_sha256": expected.report_sha256.hex(),
            "verified": True,
        },
        "fresh Python verifier receipt changed",
    )
    zig = subprocess.run(
        (str(zig_verifier), str(report_path)),
        check=False,
        capture_output=True,
        timeout=CHILD_TIMEOUT_SECONDS,
    )
    _require(
        zig.returncode == 0
        and zig.stderr == b""
        and len(zig.stdout) <= 512,
        "fresh Zig report verifier failed",
    )
    expected_zig = (
        "wire_verified=true claims_only=true generation=6->12 "
        "recovery_lock_ack=1 claimed_sigkills=2 "
        "claimed_commands=1200 claimed_cpu_oracles=1200 report_sha256="
        + expected.report_sha256.hex()
        + "\n"
    ).encode("ascii")
    _require(zig.stdout == expected_zig, "fresh Zig verifier receipt changed")
    _require(
        report_path.read_bytes() == encoded,
        "report changed during independent verification",
    )
    return python_receipt


def _rename_noreplace(source: Path, target: Path) -> None:
    _require(not os.path.lexists(target), "output directory already exists")
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    target_bytes = os.fsencode(target)
    system = platform.system()
    if system == "Darwin":
        rename = getattr(libc, "renamex_np", None)
        _require(rename is not None, "atomic no-replace rename is unavailable")
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        rename.restype = ctypes.c_int
        result = rename(source_bytes, target_bytes, 0x00000004)
    elif system == "Linux":
        rename = getattr(libc, "renameat2", None)
        _require(rename is not None, "atomic no-replace rename is unavailable")
        rename.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        rename.restype = ctypes.c_int
        result = rename(-100, source_bytes, -100, target_bytes, 1)
    else:
        raise SupervisorRecoveryDeathCampaignError(
            "atomic no-replace rename is unsupported on this host"
        )
    if result != 0:
        error_number = ctypes.get_errno()
        if error_number in (errno.EEXIST, errno.ENOTEMPTY):
            raise SupervisorRecoveryDeathCampaignError(
                "output directory already exists"
            )
        raise OSError(error_number, os.strerror(error_number), str(target))
    _fsync_directory(target.parent)


def _verify_prepared_boundary_read_only(
    campaign_dir: Path,
    facts: Mapping[str, Any],
) -> None:
    with _SharedStoreView(
        campaign_dir,
        allow_candidate=True,
    ) as view:
        snapshot = view.snapshot(report.RECOVERY_SELECTED_GENERATION)
        candidate = soak._read_regular_at(
            view.root_fd,
            soak.SELECTOR_TEMP_NAME,
            campaign.SELECTOR_BYTES,
            expected_device=view.root_identity[0],
            require_private_single_link=True,
        )
        _require(
            candidate
            == bytes.fromhex(str(facts["candidate_selector_wire_hex"]))
            and snapshot["selector_wire"]
            == bytes.fromhex(str(facts["selected_selector_wire_hex"]))
            and snapshot["store_shape_sha256"]
            == _hex_digest(
                facts["prepared_store_shape_sha256"],
                "prepared store shape",
            )
            and view.lock_identity
            == (
                int(facts["lock_device"]),
                int(facts["lock_inode"]),
            ),
            "prepared generation-11/12 boundary changed after death",
        )


def _role_config_path(protocol_dir: Path, name: str) -> Path:
    path = protocol_dir / ("%s.config.json" % name)
    _require(not os.path.lexists(path), "private role config already exists")
    return path


def _role_handoff_path(protocol_dir: Path, name: str) -> Path:
    path = protocol_dir / ("%s.handoff.json" % name)
    _require(not os.path.lexists(path), "private role handoff already exists")
    return path


def _run_native_protocol_inner(
    worker: Path,
    metallib: Path,
    zig_verifier: Path,
    bundle_root: Path,
    protocol_dir: Path,
    registry: _ChildRegistry,
    *,
    ready_timeout: float,
) -> dict[str, Any]:
    campaign_dir = bundle_root / "campaign"
    _require(
        not os.path.lexists(campaign_dir),
        "staged campaign directory already exists",
    )
    components = _component_snapshot(worker, metallib, zig_verifier)
    component_set = report.derive_component_set_sha256(
        components["controller_sha256"],
        components["supervisor_sha256"],
        components["recovery_sha256"],
        components["worker_sha256"],
        components["metallib_sha256"],
        components["verifier_sha256"],
    )
    campaign_challenge = os.urandom(32)
    _require(campaign_challenge != ZERO_DIGEST, "campaign challenge is zero")
    schedule_sha256 = soak._schedule_sha256(
        soak._supervisor_sha256(),
        False,
    )
    supervisor_challenge = report.derive_supervisor_challenge_sha256(
        campaign_challenge,
        schedule_sha256,
        component_set,
    )
    controller_authority = _hash_parts(
        CONTROLLER_AUTHORITY_DOMAIN,
        os.urandom(32),
        components["controller_sha256"],
        campaign_challenge,
        component_set,
    )
    component_config = {
        name: value.hex() for name, value in components.items()
    }

    supervisor_config = _role_config_path(protocol_dir, "supervisor")
    supervisor_handoff_path = _role_handoff_path(
        protocol_dir,
        "supervisor",
    )
    supervisor_ack_path = protocol_dir / "supervisor.ack.json"
    _require(
        not os.path.lexists(supervisor_ack_path),
        "private supervisor ACK already exists",
    )
    _write_private_json(
        supervisor_config,
        {
            "schema": "glacier.w7b-b5/supervisor-config-v1",
            "campaign_challenge_sha256": campaign_challenge,
            "supervisor_challenge_sha256": supervisor_challenge,
            "controller_pid": os.getpid(),
            "ack_timeout_millis": max(
                1,
                min(600_000, int(ready_timeout * 1000)),
            ),
            "components": component_config,
        },
    )
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )
    supervisor_process = _spawn_role(
        "supervisor",
        worker=worker,
        metallib=metallib,
        campaign_dir=campaign_dir,
        config=supervisor_config,
        handoff=supervisor_handoff_path,
        ack=supervisor_ack_path,
        registry=registry,
    )
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )
    supervisor_handoff = _wait_private_json(
        supervisor_handoff_path,
        supervisor_process,
        timeout=ready_timeout,
        remove=True,
    )
    _require(
        supervisor_handoff.get("schema")
        == "glacier.w7b-b5/supervisor-pre-ready-v1"
        and int(supervisor_handoff.get("pid", 0))
        == supervisor_process.pid,
        "supervisor private pre-ready identity changed",
    )
    prefix_facts = supervisor_handoff.get("facts")
    _require(
        type(prefix_facts) is dict
        and int(prefix_facts["worker_pid"]) > 0
        and int(prefix_facts["lock_device"]) >= 0
        and int(prefix_facts["lock_inode"]) > 0
        and _hex_digest(
            prefix_facts["campaign_challenge_sha256"],
            "prefix campaign challenge",
        )
        == campaign_challenge
        and _hex_digest(
            prefix_facts["boundary_challenge_sha256"],
            "prefix boundary challenge",
        )
        == supervisor_challenge,
        "supervisor private pre-ready facts changed",
    )
    plan_identities_raw = supervisor_handoff.get("plan_identities")
    _require(type(plan_identities_raw) is dict, "plan identities changed")
    plan_identities = {
        name: _hex_digest(plan_identities_raw.get(name), "plan.%s" % name)
        for name in (
            "campaign_challenge_sha256",
            "schedule_sha256",
            "machine_sha256",
            "backend_sha256",
            "device_sha256",
            "placement_sha256",
        )
    }
    _require(
        plan_identities["campaign_challenge_sha256"]
        == campaign_challenge
        and plan_identities["schedule_sha256"] == schedule_sha256
        and len(
            {
                plan_identities["machine_sha256"],
                plan_identities["backend_sha256"],
                plan_identities["device_sha256"],
                plan_identities["placement_sha256"],
            }
        )
        == 4,
        "supervisor plan provenance changed",
    )
    _require(
        supervisor_process.poll() is None
        and os.getsid(supervisor_process.pid) == supervisor_process.pid,
        "supervisor exited or lost session isolation before contention",
    )
    _prove_lock_contended(
        campaign_dir / soak.LOCK_NAME,
        int(prefix_facts["lock_device"]),
        int(prefix_facts["lock_inode"]),
    )
    contention_ack = _contention_ack(
        controller_pid=os.getpid(),
        supervisor_pid=supervisor_process.pid,
        worker_pid=int(prefix_facts["worker_pid"]),
        lock_device=int(prefix_facts["lock_device"]),
        lock_inode=int(prefix_facts["lock_inode"]),
        supervisor_challenge_sha256=supervisor_challenge,
    )
    _write_private_json(supervisor_ack_path, contention_ack)
    supervisor_wire = _read_exact_frame(
        supervisor_process,
        report.SUPERVISOR_READY_BYTES,
        timeout=ready_timeout,
        require_blocked=True,
    )
    supervisor_ready = report.decode_supervisor_ready(supervisor_wire)
    _require(
        not os.path.lexists(supervisor_ack_path)
        and supervisor_ready["pid"] == supervisor_process.pid
        and supervisor_ready["worker_pid"]
        == int(prefix_facts["worker_pid"])
        and supervisor_ready["supervisor_challenge_sha256"]
        == supervisor_challenge
        and supervisor_ready["supervisor_sha256"]
        == components["supervisor_sha256"]
        and supervisor_ready["worker_sha256"]
        == components["worker_sha256"]
        and supervisor_ready["metallib_sha256"]
        == components["metallib_sha256"]
        and supervisor_ready["lock_identity_sha256"]
        == _identity_digest(
            int(prefix_facts["lock_device"]),
            int(prefix_facts["lock_inode"]),
        ),
        "supervisor public ready did not bind the observed contention",
    )
    supervisor_ready_for_kill = dict(supervisor_ready)
    supervisor_ready_for_kill["_lock_device"] = int(
        prefix_facts["lock_device"]
    )
    supervisor_ready_for_kill["_lock_inode"] = int(
        prefix_facts["lock_inode"]
    )
    _kill_ready_child(
        supervisor_process,
        supervisor_ready_for_kill,
        supervisor_wire,
        campaign_dir / soak.LOCK_NAME,
    )
    supervisor_kill = _kill_record(
        supervisor_ready,
        supervisor=True,
        campaign_challenge_sha256=campaign_challenge,
        role_challenge_sha256=supervisor_challenge,
        controller_sha256=components["controller_sha256"],
        component_set_sha256=component_set,
    )
    # This grant does not exist until the exact S1 death receipt is sealed.
    resume_grant = report.derive_resume_grant_sha256(
        controller_authority,
        campaign_challenge,
        schedule_sha256,
        component_set,
        supervisor_ready["root_sha256"],
        supervisor_kill["root_sha256"],
        supervisor_ready["selector_sha256"],
        supervisor_ready["canonical_store_sha256"],
    )
    supervisor_config.unlink()
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )

    audit_six_config = _role_config_path(protocol_dir, "audit-six")
    _write_private_json(
        audit_six_config,
        {
            "schema": "glacier.w7b-b5/audit-six-config-v1",
            "resume_grant_sha256": resume_grant,
        },
    )
    audit_six_process = _spawn_role(
        "audit-six",
        worker=worker,
        metallib=metallib,
        campaign_dir=campaign_dir,
        config=audit_six_config,
        registry=registry,
    )
    audit_six_wire = _finish_clean_child(
        audit_six_process,
        report.GENERATION_SIX_AUDIT_BYTES,
        timeout=ready_timeout,
    )
    generation_six_audit = report.decode_generation_six_audit(
        audit_six_wire
    )
    _require(
        generation_six_audit["auditor_pid"] == audit_six_process.pid
        and generation_six_audit["resume_grant_sha256"]
        == resume_grant
        and generation_six_audit["selector_sha256"]
        == supervisor_ready["selector_sha256"]
        and generation_six_audit["canonical_store_sha256"]
        == supervisor_ready["canonical_store_sha256"]
        and generation_six_audit["lock_identity_sha256"]
        == supervisor_ready["lock_identity_sha256"],
        "fresh generation-six audit did not bind the killed boundary",
    )
    audit_six_config.unlink()
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )

    # R1 receives the resume grant only after the grant-bound A1 succeeds.
    recovery_challenge = report.derive_recovery_challenge_sha256(
        resume_grant,
        generation_six_audit["root_sha256"],
    )
    recovery_config = _role_config_path(protocol_dir, "recovery")
    recovery_handoff_path = _role_handoff_path(protocol_dir, "recovery")
    recovery_ack_path = protocol_dir / "recovery.ack.json"
    _require(
        not os.path.lexists(recovery_ack_path),
        "private recovery ACK already exists",
    )
    _write_private_json(
        recovery_config,
        {
            "schema": "glacier.w7b-b5/recovery-config-v1",
            "resume_grant_sha256": resume_grant,
            "recovery_challenge_sha256": recovery_challenge,
            "controller_pid": os.getpid(),
            "ack_timeout_millis": max(
                1,
                min(600_000, int(ready_timeout * 1000)),
            ),
            "prefix_facts": prefix_facts,
            "components": component_config,
        },
    )
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )
    recovery_process = _spawn_role(
        "recovery",
        worker=worker,
        metallib=metallib,
        campaign_dir=campaign_dir,
        config=recovery_config,
        handoff=recovery_handoff_path,
        ack=recovery_ack_path,
        registry=registry,
    )
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )
    recovery_handoff = _wait_private_json(
        recovery_handoff_path,
        recovery_process,
        timeout=ready_timeout,
        remove=True,
    )
    _require(
        recovery_handoff.get("schema")
        == "glacier.w7b-b5/recovery-pre-ready-v1"
        and int(recovery_handoff.get("pid", 0))
        == recovery_process.pid,
        "recovery private pre-ready identity changed",
    )
    prepared_facts = recovery_handoff.get("facts")
    _require(
        type(prepared_facts) is dict
        and int(prepared_facts["worker_pid"]) > 0
        and _hex_digest(
            prepared_facts["campaign_challenge_sha256"],
            "prepared campaign challenge",
        )
        == campaign_challenge
        and _hex_digest(
            prepared_facts["recovery_challenge_sha256"],
            "prepared recovery challenge",
        )
        == recovery_challenge
        and _hex_digest(
            prepared_facts["resume_grant_binding_sha256"],
            "prepared resume-grant receipt",
        )
        == soak.resume_grant_use_sha256(
            resume_grant,
            prefix_facts,
            prepared_facts,
        ),
        "recovery private pre-ready facts changed",
    )
    _prove_lock_contended(
        campaign_dir / soak.LOCK_NAME,
        int(prepared_facts["lock_device"]),
        int(prepared_facts["lock_inode"]),
    )
    _write_private_json(
        recovery_ack_path,
        _recovery_contention_ack(
            controller_pid=os.getpid(),
            recovery_pid=recovery_process.pid,
            worker_pid=int(prepared_facts["worker_pid"]),
            lock_device=int(prepared_facts["lock_device"]),
            lock_inode=int(prepared_facts["lock_inode"]),
            recovery_challenge_sha256=recovery_challenge,
        ),
    )
    recovery_wire = _read_exact_frame(
        recovery_process,
        report.RECOVERY_READY_BYTES,
        timeout=ready_timeout,
        require_blocked=True,
    )
    recovery_ready = report.decode_recovery_ready(recovery_wire)
    _require(
        not os.path.lexists(recovery_ack_path)
        and recovery_ready["pid"] == recovery_process.pid
        and recovery_ready["worker_pid"]
        == int(prepared_facts["worker_pid"])
        and recovery_ready["lock_identity_sha256"]
        == _identity_digest(
            int(prepared_facts["lock_device"]),
            int(prepared_facts["lock_inode"]),
        ),
        "recovery public ready did not bind the observed contention",
    )
    _require(
        recovery_ready["resume_grant_sha256"] == resume_grant
        and recovery_ready["recovery_challenge_sha256"]
        == recovery_challenge
        and recovery_ready["recovery_sha256"]
        == components["recovery_sha256"]
        and recovery_ready["campaign_id_sha256"]
        == supervisor_ready["campaign_id_sha256"]
        and int(prepared_facts["next_publication_phase"])
        == report.PUBLICATION_PHASE_SELECTOR_ACTIVE_REPLACE,
        "recovery ready provenance or publication boundary changed",
    )
    recovery_ready_for_kill = dict(recovery_ready)
    recovery_ready_for_kill["_lock_device"] = int(
        prepared_facts["lock_device"]
    )
    recovery_ready_for_kill["_lock_inode"] = int(
        prepared_facts["lock_inode"]
    )
    _kill_ready_child(
        recovery_process,
        recovery_ready_for_kill,
        recovery_wire,
        campaign_dir / soak.LOCK_NAME,
    )
    recovery_kill = _kill_record(
        recovery_ready,
        supervisor=False,
        campaign_challenge_sha256=campaign_challenge,
        role_challenge_sha256=resume_grant,
        controller_sha256=components["controller_sha256"],
        component_set_sha256=component_set,
    )
    _verify_prepared_boundary_read_only(campaign_dir, prepared_facts)
    # The finalizer grant is derived only after the exact R1 death receipt.
    finalizer_grant = report.derive_finalizer_grant_sha256(
        controller_authority,
        campaign_challenge,
        schedule_sha256,
        component_set,
        resume_grant,
        recovery_ready["root_sha256"],
        recovery_kill["root_sha256"],
        recovery_ready["candidate_selector_sha256"],
        recovery_ready["prepared_store_sha256"],
    )
    recovery_config.unlink()
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )

    finalizer_config = _role_config_path(protocol_dir, "finalizer")
    finalizer_handoff_path = _role_handoff_path(
        protocol_dir,
        "finalizer",
    )
    _write_private_json(
        finalizer_config,
        {
            "schema": "glacier.w7b-b5/finalizer-config-v1",
            "finalizer_grant_sha256": finalizer_grant,
            "prepared_facts": prepared_facts,
        },
    )
    finalizer_process = _spawn_role(
        "finalizer",
        worker=worker,
        metallib=metallib,
        campaign_dir=campaign_dir,
        config=finalizer_config,
        handoff=finalizer_handoff_path,
        registry=registry,
    )
    _require(
        _finish_clean_child(finalizer_process, 0) == b"",
        "finalizer emitted stdout",
    )
    finalizer_handoff = _read_private_json(
        finalizer_handoff_path,
        remove=True,
    )
    finalized_facts = finalizer_handoff.get("facts")
    finalizer_pid = int(finalizer_handoff.get("pid", 0))
    _require(
        finalizer_handoff.get("schema")
        == "glacier.w7b-b5/finalizer-handoff-v1"
        and type(finalized_facts) is dict
        and finalizer_pid == finalizer_process.pid
        and finalized_facts.get("disposition") == "applied"
        and int(finalized_facts.get("generation", -1))
        == report.CANDIDATE_GENERATION
        and _hex_digest(
            finalized_facts["selector_sha256"],
            "finalized selector",
        )
        == recovery_ready["candidate_selector_sha256"]
        and _hex_digest(
            finalized_facts["campaign_id_sha256"],
            "finalized campaign",
        )
        == recovery_ready["campaign_id_sha256"]
        and _hex_digest(
            finalized_facts["finalizer_grant_binding_sha256"],
            "finalizer grant receipt",
        )
        == soak.finalizer_grant_use_sha256(
            finalizer_grant,
            prepared_facts,
            finalized_facts,
        ),
        "fresh finalizer receipt changed",
    )
    finalizer_config.unlink()

    audit_final_config = _role_config_path(protocol_dir, "audit-final")
    _write_private_json(
        audit_final_config,
        {
            "schema": "glacier.w7b-b5/audit-final-config-v1",
            "finalizer_grant_sha256": finalizer_grant,
            "finalizer_pid": finalizer_pid,
            "prepared_facts": prepared_facts,
        },
    )
    audit_final_process = _spawn_role(
        "audit-final",
        worker=worker,
        metallib=metallib,
        campaign_dir=campaign_dir,
        config=audit_final_config,
        registry=registry,
    )
    audit_final_wire = _finish_clean_child(
        audit_final_process,
        report.FINAL_AUDIT_BYTES,
        timeout=ready_timeout,
    )
    final_audit = report.decode_final_audit(audit_final_wire)
    _require(
        final_audit["auditor_pid"] == audit_final_process.pid
        and final_audit["finalizer_pid"] == finalizer_pid
        and final_audit["finalizer_grant_sha256"]
        == finalizer_grant
        and final_audit["final_store_sha256"]
        == _hex_digest(
            finalized_facts["store_shape_sha256"],
            "finalized store",
        ),
        "fresh final audit did not bind the roll-forward",
    )
    audit_final_config.unlink()
    all_role_pids = (
        int(supervisor_ready["pid"]),
        int(supervisor_ready["worker_pid"]),
        int(generation_six_audit["auditor_pid"]),
        int(recovery_ready["pid"]),
        int(recovery_ready["worker_pid"]),
        int(final_audit["finalizer_pid"]),
        int(final_audit["auditor_pid"]),
    )
    _require(
        len(set(all_role_pids)) == len(all_role_pids),
        "the seven process roles do not have fresh distinct PIDs",
    )
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )

    header = _header_record(
        plan_identities=plan_identities,
        controller_authority_sha256=controller_authority,
        components=components,
        component_set_sha256=component_set,
        resume_grant_sha256=resume_grant,
        finalizer_grant_sha256=finalizer_grant,
        supervisor_ready=supervisor_ready,
        supervisor_kill=supervisor_kill,
        generation_six_audit=generation_six_audit,
        recovery_ready=recovery_ready,
        recovery_kill=recovery_kill,
        final_audit=final_audit,
    )
    encoded = report.make_report(
        header,
        supervisor_ready,
        supervisor_kill,
        generation_six_audit,
        recovery_ready,
        recovery_kill,
        final_audit,
    )
    decoded = report.verify_report(encoded)
    report_path = bundle_root / "report.bin"
    _write_report_file(report_path, encoded)
    verifier_receipt = _verify_report_fresh(
        report_path,
        encoded,
        zig_verifier,
    )
    _verify_component_snapshot(
        components,
        worker,
        metallib,
        zig_verifier,
    )
    _require(
        set(path.name for path in bundle_root.iterdir())
        == {"report.bin", "campaign"},
        "retained bundle root is not exact",
    )
    return {
        "schema": RUN_RECEIPT_SCHEMA,
        "encoded_bytes": report.REPORT_BYTES,
        "encoded_sha256": hashlib.sha256(encoded).hexdigest(),
        "report_sha256": decoded.report_sha256.hex(),
        "campaign_id_sha256": supervisor_ready[
            "campaign_id_sha256"
        ].hex(),
        "segment_count": report.SEGMENT_COUNT,
        "metal_commands": report.TOTAL_COMPLETED,
        "cpu_oracles": report.TOTAL_COMPLETED,
        "worker_processes": report.WORKER_PROCESS_COUNT,
        "sigkills": report.TOTAL_SIGKILL_COUNT,
        "python_verified": verifier_receipt["verified"],
        "zig_verified": True,
        "hard_protocol_verified": True,
        "report_claims_only": True,
        "external_build_provenance_verified": False,
        "evidence": False,
        "verified": True,
    }


def _run_native_protocol(
    worker: Path,
    metallib: Path,
    zig_verifier: Path,
    bundle_root: Path,
    protocol_dir: Path,
    *,
    ready_timeout: float,
) -> dict[str, Any]:
    with _ChildRegistry() as registry:
        return _run_native_protocol_inner(
            worker,
            metallib,
            zig_verifier,
            bundle_root,
            protocol_dir,
            registry,
            ready_timeout=ready_timeout,
        )


def run_campaign(
    worker: os.PathLike[str] | str,
    metallib: os.PathLike[str] | str,
    zig_verifier: os.PathLike[str] | str,
    *,
    output_dir: Optional[os.PathLike[str] | str] = None,
    ready_timeout: float = READY_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Run, independently verify, and optionally retain one native report."""
    _require(
        isinstance(ready_timeout, (int, float))
        and not isinstance(ready_timeout, bool)
        and 0 < ready_timeout <= 600,
        "ready timeout is outside the fixed bound",
    )
    worker_path = Path(worker).absolute()
    metallib_path = Path(metallib).absolute()
    verifier_path = Path(zig_verifier).absolute()
    _component_snapshot(worker_path, metallib_path, verifier_path)

    explicit_output = (
        None
        if output_dir is None
        else Path(output_dir).absolute()
    )
    if explicit_output is not None:
        _require(
            not os.path.lexists(explicit_output),
            "output directory already exists",
        )
        parent = explicit_output.parent
        _require(
            parent.is_dir() and not parent.is_symlink(),
            "output parent is not a real directory",
        )
        owned_parent: Optional[tempfile.TemporaryDirectory[str]] = None
    else:
        owned_parent = tempfile.TemporaryDirectory(
            prefix="glacier-w7b-b5-native-"
        )
        parent = Path(owned_parent.name)

    bundle_root = Path(
        tempfile.mkdtemp(
            prefix=".glacier-w7b-b5-bundle-",
            dir=parent,
        )
    )
    os.chmod(bundle_root, 0o700)
    protocol = tempfile.TemporaryDirectory(
        prefix=".glacier-w7b-b5-protocol-",
        dir=parent,
    )
    protocol_dir = Path(protocol.name)
    os.chmod(protocol_dir, 0o700)
    published = False
    try:
        receipt = _run_native_protocol(
            worker_path,
            metallib_path,
            verifier_path,
            bundle_root,
            protocol_dir,
            ready_timeout=float(ready_timeout),
        )
        _require(
            not any(protocol_dir.iterdir()),
            "private protocol records were not removed",
        )
        protocol.cleanup()
        if explicit_output is not None:
            _rename_noreplace(bundle_root, explicit_output)
            published = True
            receipt["retained"] = True
            receipt["output_dir"] = str(explicit_output)
        else:
            receipt["retained"] = False
            receipt["output_dir"] = None
        return receipt
    finally:
        with contextlib.suppress(Exception):
            protocol.cleanup()
        if not published and os.path.lexists(bundle_root):
            shutil.rmtree(bundle_root)
        if owned_parent is not None:
            owned_parent.cleanup()


def _host_frame(
    *,
    phase: int,
    pid: int,
    worker_pid: int,
    lock_device: int,
    lock_inode: int,
    encoded_bytes: int,
) -> bytes:
    _require(
        phase in (1, 2, 3, 4)
        and encoded_bytes in (384, 512)
        and pid > 0
        and worker_pid >= 0,
        "host fixture frame inputs changed",
    )
    header = HOST_MAGIC + struct.pack(
        "<6Q",
        phase,
        pid,
        worker_pid,
        lock_device,
        lock_inode,
        1,
    )
    result = bytearray(header)
    seed = _hash_parts(HOST_FRAME_DOMAIN, header, _u64(encoded_bytes, "host frame"))
    counter = 0
    while len(result) < encoded_bytes:
        result.extend(
            _hash_parts(
                HOST_FRAME_DOMAIN,
                seed,
                _u64(counter, "host frame counter"),
            )
        )
        counter += 1
    return bytes(result[:encoded_bytes])


def _decode_host_frame(
    encoded: bytes,
    *,
    expected_phase: int,
    expected_bytes: int,
) -> dict[str, int]:
    _require(
        isinstance(encoded, bytes)
        and len(encoded) == expected_bytes
        and encoded.startswith(HOST_MAGIC)
        and expected_bytes in (384, 512),
        "host fixture frame geometry changed",
    )
    phase, pid, worker_pid, device, inode, acknowledged = struct.unpack(
        "<6Q",
        encoded[len(HOST_MAGIC) : len(HOST_MAGIC) + 48],
    )
    expected = _host_frame(
        phase=phase,
        pid=pid,
        worker_pid=worker_pid,
        lock_device=device,
        lock_inode=inode,
        encoded_bytes=expected_bytes,
    )
    _require(
        phase == expected_phase
        and acknowledged == 1
        and encoded == expected,
        "host fixture frame content changed",
    )
    return {
        "phase": phase,
        "pid": pid,
        "worker_pid": worker_pid,
        "lock_device": device,
        "lock_inode": inode,
        "encoded_bytes": expected_bytes,
    }


def _write_host_file(
    root: Path,
    name: str,
    data: bytes,
    *,
    exclusive: bool,
) -> None:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    flags |= os.O_EXCL if exclusive else os.O_TRUNC
    descriptor = os.open(root / name, flags, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        _require(
            os.write(descriptor, data) == len(data),
            "host fixture state write changed",
        )
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _host_lock(root: Path, operation: int) -> tuple[int, os.stat_result]:
    descriptor = os.open(
        root / soak.LOCK_NAME,
        os.O_RDWR
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    opened = os.fstat(descriptor)
    _require(
        stat.S_ISREG(opened.st_mode)
        and opened.st_nlink == 1
        and stat.S_IMODE(opened.st_mode) == 0o600,
        "host fixture lock identity changed",
    )
    try:
        fcntl.flock(descriptor, operation | fcntl.LOCK_NB)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor, opened


def _child_host_victim(arguments: argparse.Namespace) -> int:
    config = _read_private_json(Path(arguments._config))
    phase_name = str(arguments._host_phase)
    _require(
        phase_name in ("supervisor", "recovery")
        and config.get("schema")
        == "glacier.w7b-b5/host-victim-config-v1",
        "host victim config changed",
    )
    root = Path(arguments._campaign_dir)
    worker = subprocess.Popen(
        (sys.executable, "-c", "raise SystemExit(0)"),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    worker_pid = worker.pid
    _require(worker.wait(timeout=5.0) == 0, "host fixture worker failed")
    lock_fd, lock_info = _host_lock(root, fcntl.LOCK_EX)
    try:
        if phase_name == "supervisor":
            _write_host_file(
                root,
                HOST_ACTIVE_NAME,
                HOST_GENERATION_SIX,
                exclusive=True,
            )
            phase = 1
            challenge_name = "supervisor_challenge_sha256"
        else:
            _require(
                (root / HOST_ACTIVE_NAME).read_bytes()
                == HOST_GENERATION_SIX,
                "host recovery predecessor changed",
            )
            _write_host_file(
                root,
                HOST_ACTIVE_NAME,
                HOST_GENERATION_ELEVEN,
                exclusive=False,
            )
            _write_host_file(
                root,
                HOST_CANDIDATE_NAME,
                HOST_GENERATION_TWELVE,
                exclusive=True,
            )
            phase = 3
            challenge_name = "recovery_challenge_sha256"
        _fsync_directory(root)
        challenge = _hex_digest(config[challenge_name], challenge_name)
        _write_private_json(
            Path(arguments._handoff),
            {
                "schema": "glacier.w7b-b5/host-pre-ready-v1",
                "role": phase_name,
                "pid": os.getpid(),
                "worker_pid": worker_pid,
                "lock_device": lock_info.st_dev,
                "lock_inode": lock_info.st_ino,
                challenge_name: challenge,
            },
        )
        deadline = time.monotonic() + int(
            config["ack_timeout_millis"]
        ) / 1000
        ack_path = Path(arguments._ack)
        while not os.path.lexists(ack_path):
            _require(
                time.monotonic() < deadline,
                "host victim ACK timed out",
            )
            time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
        ack = _read_private_json(ack_path, remove=True)
        if phase_name == "supervisor":
            _validate_contention_ack(
                ack,
                controller_pid=int(config["controller_pid"]),
                supervisor_pid=os.getpid(),
                worker_pid=worker_pid,
                lock_device=lock_info.st_dev,
                lock_inode=lock_info.st_ino,
                supervisor_challenge_sha256=challenge,
            )
        else:
            _validate_recovery_contention_ack(
                ack,
                controller_pid=int(config["controller_pid"]),
                recovery_pid=os.getpid(),
                worker_pid=worker_pid,
                lock_device=lock_info.st_dev,
                lock_inode=lock_info.st_ino,
                recovery_challenge_sha256=challenge,
            )
        _write_stdout_exact(
            _host_frame(
                phase=phase,
                pid=os.getpid(),
                worker_pid=worker_pid,
                lock_device=lock_info.st_dev,
                lock_inode=lock_info.st_ino,
                encoded_bytes=512,
            )
        )
        while True:
            signal.pause()
    finally:
        os.close(lock_fd)


def _child_host_audit(arguments: argparse.Namespace) -> int:
    phase_name = str(arguments._host_phase)
    _require(
        phase_name in ("six", "final"),
        "host audit phase changed",
    )
    root = Path(arguments._campaign_dir)
    lock_fd, lock_info = _host_lock(root, fcntl.LOCK_SH)
    try:
        if phase_name == "six":
            expected = HOST_GENERATION_SIX
            phase = 2
        else:
            expected = HOST_GENERATION_TWELVE
            phase = 4
        _require(
            (root / HOST_ACTIVE_NAME).read_bytes() == expected
            and (
                phase_name != "final"
                or not os.path.lexists(root / HOST_CANDIDATE_NAME)
            ),
            "host audit state changed",
        )
        _write_stdout_exact(
            _host_frame(
                phase=phase,
                pid=os.getpid(),
                worker_pid=0,
                lock_device=lock_info.st_dev,
                lock_inode=lock_info.st_ino,
                encoded_bytes=384,
            )
        )
    finally:
        os.close(lock_fd)
    return 0


def _child_host_finalizer(arguments: argparse.Namespace) -> int:
    root = Path(arguments._campaign_dir)
    lock_fd, _lock_info = _host_lock(root, fcntl.LOCK_EX)
    try:
        _require(
            (root / HOST_ACTIVE_NAME).read_bytes()
            == HOST_GENERATION_ELEVEN
            and (root / HOST_CANDIDATE_NAME).read_bytes()
            == HOST_GENERATION_TWELVE,
            "host finalizer predecessor changed",
        )
        os.replace(
            root / HOST_CANDIDATE_NAME,
            root / HOST_ACTIVE_NAME,
        )
        _fsync_directory(root)
    finally:
        os.close(lock_fd)
    return 0


def _run_host_victim_boundary(
    *,
    role: str,
    root: Path,
    protocol_dir: Path,
    registry: _ChildRegistry,
    challenge: bytes,
    timeout: float,
    ack_mutator: Optional[Any] = None,
) -> tuple[dict[str, int], int]:
    config = _role_config_path(protocol_dir, "host-" + role)
    handoff_path = _role_handoff_path(protocol_dir, "host-" + role)
    ack_path = protocol_dir / ("host-%s.ack.json" % role)
    challenge_name = (
        "supervisor_challenge_sha256"
        if role == "supervisor"
        else "recovery_challenge_sha256"
    )
    _write_private_json(
        config,
        {
            "schema": "glacier.w7b-b5/host-victim-config-v1",
            "controller_pid": os.getpid(),
            "ack_timeout_millis": max(1, int(timeout * 1000)),
            challenge_name: challenge,
        },
    )
    process = _spawn_role(
        "host-victim",
        worker=_SCRIPT_PATH,
        metallib=_SCRIPT_PATH,
        campaign_dir=root,
        config=config,
        handoff=handoff_path,
        ack=ack_path,
        extra=("--_host-phase", role),
        registry=registry,
    )
    handoff = _wait_private_json(
        handoff_path,
        process,
        timeout=timeout,
        remove=True,
    )
    _require(
        handoff.get("schema") == "glacier.w7b-b5/host-pre-ready-v1"
        and handoff.get("role") == role
        and int(handoff["pid"]) == process.pid
        and _hex_digest(handoff[challenge_name], challenge_name)
        == challenge,
        "host private pre-ready handoff changed",
    )
    device = int(handoff["lock_device"])
    inode = int(handoff["lock_inode"])
    _prove_lock_contended(root / soak.LOCK_NAME, device, inode)
    if role == "supervisor":
        ack = _contention_ack(
            controller_pid=os.getpid(),
            supervisor_pid=process.pid,
            worker_pid=int(handoff["worker_pid"]),
            lock_device=device,
            lock_inode=inode,
            supervisor_challenge_sha256=challenge,
        )
        expected_phase = 1
    else:
        ack = _recovery_contention_ack(
            controller_pid=os.getpid(),
            recovery_pid=process.pid,
            worker_pid=int(handoff["worker_pid"]),
            lock_device=device,
            lock_inode=inode,
            recovery_challenge_sha256=challenge,
        )
        expected_phase = 3
    if ack_mutator is not None:
        ack = ack_mutator(dict(ack))
    _write_private_json(ack_path, ack)
    encoded = _read_exact_frame(
        process,
        512,
        timeout=timeout,
        require_blocked=True,
    )
    ready = _decode_host_frame(
        encoded,
        expected_phase=expected_phase,
        expected_bytes=512,
    )
    ready_for_kill = dict(ready)
    ready_for_kill["_lock_device"] = device
    ready_for_kill["_lock_inode"] = inode
    _kill_ready_child(
        process,
        ready_for_kill,
        encoded,
        root / soak.LOCK_NAME,
    )
    config.unlink()
    return ready, process.returncode


def run_host_protocol_fixture(
    *,
    ready_timeout: float = 5.0,
    _ack_mutator: Optional[Any] = None,
) -> dict[str, Any]:
    """Exercise the real host protocol without producing evidence or output."""
    _require(
        isinstance(ready_timeout, (int, float))
        and not isinstance(ready_timeout, bool)
        and 0 < ready_timeout <= 30,
        "host fixture timeout changed",
    )
    parent_path: Optional[Path] = None
    with tempfile.TemporaryDirectory(
        prefix="glacier-w7b-b5-host-"
    ) as parent_name:
        parent_path = Path(parent_name)
        root = parent_path / "campaign"
        protocol_dir = parent_path / "protocol"
        root.mkdir(mode=0o700)
        protocol_dir.mkdir(mode=0o700)
        lock_fd = os.open(
            root / soak.LOCK_NAME,
            os.O_RDWR | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.fchmod(lock_fd, 0o600)
        os.fsync(lock_fd)
        os.close(lock_fd)
        _fsync_directory(root)
        supervisor_challenge = _hash_parts(
            HOST_FRAME_DOMAIN,
            b"supervisor",
        )
        recovery_challenge = _hash_parts(
            HOST_FRAME_DOMAIN,
            b"recovery",
        )
        with _ChildRegistry() as registry:
            supervisor_ready, supervisor_returncode = (
                _run_host_victim_boundary(
                    role="supervisor",
                    root=root,
                    protocol_dir=protocol_dir,
                    registry=registry,
                    challenge=supervisor_challenge,
                    timeout=float(ready_timeout),
                    ack_mutator=_ack_mutator,
                )
            )
            audit_six = _spawn_role(
                "host-audit",
                worker=_SCRIPT_PATH,
                metallib=_SCRIPT_PATH,
                campaign_dir=root,
                extra=("--_host-phase", "six"),
                registry=registry,
            )
            audit_six_frame = _decode_host_frame(
                _finish_clean_child(audit_six, 384),
                expected_phase=2,
                expected_bytes=384,
            )
            recovery_ready, recovery_returncode = (
                _run_host_victim_boundary(
                    role="recovery",
                    root=root,
                    protocol_dir=protocol_dir,
                    registry=registry,
                    challenge=recovery_challenge,
                    timeout=float(ready_timeout),
                )
            )
            finalizer = _spawn_role(
                "host-finalizer",
                worker=_SCRIPT_PATH,
                metallib=_SCRIPT_PATH,
                campaign_dir=root,
                registry=registry,
            )
            _require(
                _finish_clean_child(finalizer, 0) == b"",
                "host finalizer emitted output",
            )
            audit_final = _spawn_role(
                "host-audit",
                worker=_SCRIPT_PATH,
                metallib=_SCRIPT_PATH,
                campaign_dir=root,
                extra=("--_host-phase", "final"),
                registry=registry,
            )
            audit_final_frame = _decode_host_frame(
                _finish_clean_child(audit_final, 384),
                expected_phase=4,
                expected_bytes=384,
            )
            role_pids = (
                supervisor_ready["pid"],
                supervisor_ready["worker_pid"],
                audit_six_frame["pid"],
                recovery_ready["pid"],
                recovery_ready["worker_pid"],
                finalizer.pid,
                audit_final_frame["pid"],
            )
            _require(
                len(set(role_pids)) == 7
                and supervisor_returncode == -signal.SIGKILL
                and recovery_returncode == -signal.SIGKILL,
                "host fixture process freshness changed",
            )
        _require(
            not any(protocol_dir.iterdir()),
            "host fixture retained private protocol records",
        )
        result = {
            "schema": HOST_RECEIPT_SCHEMA,
            "sigkills": 2,
            "worker_processes": 2,
            "auditor_processes": 2,
            "finalizer_processes": 1,
            "distinct_role_pids": 7,
            "real_processes": True,
            "real_flock": True,
            "real_filesystem_operations": True,
            "gpu_execution": False,
            "report_retained": False,
            "hard_protocol_verified": False,
            "evidence": False,
            "verified": True,
        }
    _require(
        parent_path is not None and not parent_path.exists(),
        "host fixture was not ephemeral",
    )
    return result


def _dispatch_role(arguments: argparse.Namespace) -> int:
    role = arguments._role
    if role == "verify-report":
        _require(arguments._report is not None, "missing report path")
        return _child_verify_report(arguments)
    if role in ("host-victim", "host-audit", "host-finalizer"):
        _require(
            arguments._campaign_dir is not None,
            "missing host campaign directory",
        )
        if role == "host-victim":
            _require(
                arguments._config is not None
                and arguments._handoff is not None
                and arguments._ack is not None
                and arguments._host_phase in ("supervisor", "recovery"),
                "host victim arguments changed",
            )
            return _child_host_victim(arguments)
        if role == "host-audit":
            return _child_host_audit(arguments)
        return _child_host_finalizer(arguments)
    _require(
        arguments.worker is not None
        and arguments.metallib is not None
        and arguments._campaign_dir is not None
        and arguments._config is not None,
        "native child arguments are incomplete",
    )
    if role == "supervisor":
        _require(
            arguments._handoff is not None
            and arguments._ack is not None,
            "supervisor protocol paths are incomplete",
        )
        return _child_supervisor(arguments)
    if role == "audit-six":
        return _child_audit_six(arguments)
    if role == "recovery":
        _require(
            arguments._handoff is not None
            and arguments._ack is not None,
            "recovery protocol paths are incomplete",
        )
        return _child_recovery(arguments)
    if role == "finalizer":
        _require(
            arguments._handoff is not None,
            "finalizer handoff path is missing",
        )
        return _child_finalizer(arguments)
    if role == "audit-final":
        return _child_audit_final(arguments)
    raise SupervisorRecoveryDeathCampaignError("unknown internal role")


def _main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run the fixed native Metal supervisor/recovery death protocol"
        )
    )
    parser.add_argument("--worker")
    parser.add_argument("--metallib")
    parser.add_argument("--zig-verifier")
    parser.add_argument("--output-dir")
    parser.add_argument(
        "--_role",
        choices=_ROLE_CHOICES,
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--_campaign-dir", help=argparse.SUPPRESS)
    parser.add_argument("--_config", help=argparse.SUPPRESS)
    parser.add_argument("--_handoff", help=argparse.SUPPRESS)
    parser.add_argument("--_ack", help=argparse.SUPPRESS)
    parser.add_argument("--_report", help=argparse.SUPPRESS)
    parser.add_argument("--_host-phase", help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    try:
        if arguments._role is not None:
            return _dispatch_role(arguments)
        _require(
            arguments.worker is not None
            and arguments.metallib is not None
            and arguments.zig_verifier is not None,
            "public runner requires --worker, --metallib, and --zig-verifier",
        )
        receipt = run_campaign(
            arguments.worker,
            arguments.metallib,
            arguments.zig_verifier,
            output_dir=arguments.output_dir,
        )
        print(
            json.dumps(
                receipt,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 0
    except (
        SupervisorRecoveryDeathCampaignError,
        soak.NativeMetalSoakError,
        report.SupervisorRecoveryDeathReportError,
        campaign.CampaignManifestError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(_main())
