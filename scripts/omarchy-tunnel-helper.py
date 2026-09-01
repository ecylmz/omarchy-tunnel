#!/usr/bin/env python3
"""Bounded process runner and race-safe WireGuard importer.

The QML layer deliberately delegates every external command to this helper so
that child output and wall-clock time are capped independently of nmcli's own
``--wait`` option.  Import is one transaction: the selected inode is opened
with O_NOFOLLOW, copied into a private file, validated there, and that exact
copy is imported and hardened before the temporary directory is removed.
"""

from __future__ import annotations

import argparse
import errno
import os
import pwd
import re
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence


MAX_CONFIG_BYTES = 64 * 1024
MAX_COMMAND_STDOUT = 64 * 1024
MAX_COMMAND_STDERR = 8 * 1024
MAX_PROFILE_ROWS = 256
MAX_PROFILE_LINE = 768
MAX_PROFILE_NAME = 128
MAX_UI_ERROR_BYTES = 512
IMPORT_DEADLINE_SECONDS = 45.0
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
IMPORT_RESULT_RE = re.compile(
    r"^Connection '[^'\r\n]{1,128}' "
    r"\(([0-9a-fA-F-]{36})\) successfully added\.$",
    re.MULTILINE,
)
HOOK_RE = re.compile(
    r"^[ \t]*(?:preup|postup|predown|postdown)[ \t]*=",
    re.IGNORECASE | re.MULTILINE,
)
INTERFACE_RE = re.compile(r"^[ \t]*\[interface\][ \t]*$", re.IGNORECASE | re.MULTILINE)
PEER_RE = re.compile(r"^[ \t]*\[peer\][ \t]*$", re.IGNORECASE | re.MULTILINE)


class HelperError(Exception):
    """A bounded, user-safe failure message."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes
    timed_out: bool = False
    output_limited: bool = False


_active_process: subprocess.Popen[bytes] | None = None


def _terminate_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def _on_signal(_signum: int, _frame: object) -> None:
    process = _active_process
    if process is not None:
        _terminate_group(process)


def _bounded_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    environment["NO_COLOR"] = "1"
    return environment


def run_limited(
    argv: Sequence[str],
    timeout_seconds: float,
    stdout_limit: int,
    stderr_limit: int,
) -> CommandResult:
    """Run argv without a shell, draining but retaining only bounded output."""

    global _active_process

    if not argv or timeout_seconds <= 0 or stdout_limit < 0 or stderr_limit < 0:
        raise HelperError("Invalid bounded command request")

    try:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_bounded_environment(),
            start_new_session=True,
        )
    except (OSError, ValueError) as error:
        message = error.strerror if isinstance(error, OSError) else str(error)
        return CommandResult(127, b"", str(message or "Could not start command").encode()[:stderr_limit])

    _active_process = process
    selector = selectors.DefaultSelector()
    streams = ((process.stdout, stdout_limit), (process.stderr, stderr_limit))
    buffers: dict[int, bytearray] = {}
    limits: dict[int, int] = {}
    for stream, limit in streams:
        assert stream is not None
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ)
        buffers[stream.fileno()] = bytearray()
        limits[stream.fileno()] = limit

    deadline = time.monotonic() + timeout_seconds
    timed_out = False
    output_limited = False

    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                _terminate_group(process)
                break
            for key, _mask in selector.select(min(remaining, 0.1)):
                fd = key.fd
                try:
                    chunk = os.read(fd, 4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer = buffers[fd]
                limit = limits[fd]
                available = max(0, limit - len(buffer))
                buffer.extend(chunk[:available])
                if len(chunk) > available:
                    output_limited = True
                    _terminate_group(process)
                    break
            if output_limited:
                break

        if timed_out or output_limited:
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        returncode = process.wait(timeout=1.0)
    finally:
        selector.close()
        _active_process = None

    stdout_fd = process.stdout.fileno() if process.stdout is not None else -1
    stderr_fd = process.stderr.fileno() if process.stderr is not None else -1
    stdout = bytes(buffers.get(stdout_fd, b""))
    stderr = bytes(buffers.get(stderr_fd, b""))
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()
    if timed_out:
        stderr = b"Operation timed out"
        returncode = 124
    elif output_limited:
        stderr = b"Command output exceeded safety limit"
        returncode = 125
    return CommandResult(returncode, stdout, stderr, timed_out, output_limited)


@dataclass(frozen=True)
class StagedConfig:
    directory: Path
    path: Path
    connection_name: str

    def cleanup(self) -> None:
        shutil.rmtree(self.directory)


def stage_config(selected_path: str) -> StagedConfig:
    """Copy one already-opened regular inode into a mode-0700 directory."""

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        source_fd = os.open(selected_path, flags)
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENXIO):
            raise HelperError("Config rejected: symlinks and special files are not allowed") from None
        raise HelperError("Could not open the selected configuration") from None

    directory: Path | None = None
    try:
        metadata = os.fstat(source_fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise HelperError("Config rejected: only regular files are allowed")
        if metadata.st_size > MAX_CONFIG_BYTES:
            raise HelperError("Config rejected: file exceeds the 64 KiB size limit")

        directory = Path(tempfile.mkdtemp(prefix="omarchy-tunnel-", dir="/tmp"))
        os.chmod(directory, 0o700)
        connection_name = "omt" + secrets.token_hex(6)
        destination = directory / (connection_name + ".conf")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        copied = 0
        try:
            while True:
                chunk = os.read(source_fd, min(8192, MAX_CONFIG_BYTES + 1 - copied))
                if not chunk:
                    break
                copied += len(chunk)
                if copied > MAX_CONFIG_BYTES:
                    raise HelperError("Config rejected: file exceeds the 64 KiB size limit")
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    view = view[written:]
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
        return StagedConfig(directory, destination, connection_name)
    except Exception:
        if directory is not None:
            shutil.rmtree(directory)
        raise
    finally:
        os.close(source_fd)


def validate_staged_config(path: Path) -> None:
    data = path.read_bytes()
    if len(data) > MAX_CONFIG_BYTES:
        raise HelperError("Config rejected: file exceeds the 64 KiB size limit")
    if b"\x00" in data:
        raise HelperError("Config rejected: configuration is not plain text")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise HelperError("Config rejected: configuration must be UTF-8 text") from None
    if HOOK_RE.search(text):
        raise HelperError("Config rejected: PreUp/PostUp/PreDown/PostDown hooks are not allowed")
    if not INTERFACE_RE.search(text):
        raise HelperError("Config rejected: missing [Interface] section")
    if not PEER_RE.search(text):
        raise HelperError("Config rejected: missing [Peer] section")


def _decode_limited(data: bytes, limit: int = MAX_UI_ERROR_BYTES) -> str:
    text = data[:limit].decode("utf-8", "replace")
    text = re.sub(r"\x1b\[[0-9;]*m", "", text).strip()
    if not text:
        return ""
    line = text.splitlines()[-1].strip()
    return line[:240]


def _extract_import_uuid(stdout: bytes) -> str | None:
    text = stdout.decode("utf-8", "replace")
    matches = IMPORT_RESULT_RE.findall(text)
    if len(matches) != 1 or not UUID_RE.fullmatch(matches[0]):
        return None
    return matches[0].lower()


def _split_escaped_colon(line: str) -> list[str]:
    fields: list[str] = []
    current: list[str] = []
    escaped = False
    for character in line:
        if escaped:
            current.append(character)
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(character)
    if escaped:
        current.append("\\")
    fields.append("".join(current))
    return fields


Runner = Callable[[Sequence[str], float, int, int], CommandResult]


def _nmcli(runner: Runner, args: Sequence[str], timeout: float, stdout_limit: int = 8192) -> CommandResult:
    return runner(
        ["nmcli", "--colors", "no", *args],
        max(0.1, timeout),
        stdout_limit,
        MAX_COMMAND_STDERR,
    )


def _discover_named_uuids(runner: Runner, name: str, timeout: float) -> list[str] | None:
    result = _nmcli(
        runner,
        ["--terse", "--escape", "yes", "--fields", "NAME,UUID,TYPE", "connection", "show"],
        timeout,
        MAX_COMMAND_STDOUT,
    )
    if result.returncode != 0:
        return None
    output = result.stdout.decode("utf-8", "replace")
    if len(output) > MAX_COMMAND_STDOUT:
        return None
    matches: list[str] = []
    for index, line in enumerate(output.splitlines()):
        if index >= MAX_PROFILE_ROWS or len(line) > MAX_PROFILE_LINE:
            return None
        fields = _split_escaped_colon(line)
        if len(fields) != 3:
            continue
        profile_name, uuid, profile_type = fields
        if len(profile_name) > MAX_PROFILE_NAME:
            continue
        if profile_name == name and profile_type == "wireguard" and UUID_RE.fullmatch(uuid):
            matches.append(uuid.lower())
    return sorted(set(matches))


def _profile_metadata(runner: Runner, uuid: str, timeout: float) -> tuple[str, str, str, str] | None:
    result = _nmcli(
        runner,
        [
            "--get-values",
            "connection.uuid,connection.type,connection.autoconnect,connection.permissions",
            "connection",
            "show",
            "uuid",
            uuid,
        ],
        timeout,
        2048,
    )
    if result.returncode != 0:
        return None
    lines = result.stdout.decode("utf-8", "replace").splitlines()
    if len(lines) != 4 or any(len(line) > 256 for line in lines):
        return None
    return lines[0].lower(), lines[1], lines[2].lower(), lines[3]


def _is_inactive(runner: Runner, uuid: str, timeout: float) -> bool:
    result = _nmcli(
        runner,
        ["--terse", "--escape", "yes", "--fields", "UUID", "connection", "show", "--active"],
        timeout,
        16 * 1024,
    )
    if result.returncode != 0:
        return False
    lines = result.stdout.decode("utf-8", "replace").splitlines()
    if len(lines) > MAX_PROFILE_ROWS:
        return False
    active = [line.lower() for line in lines if UUID_RE.fullmatch(line)]
    return uuid.lower() not in active


def _verified_wireguard(runner: Runner, uuid: str, timeout: float) -> bool:
    metadata = _profile_metadata(runner, uuid, timeout)
    return metadata is not None and metadata[0] == uuid.lower() and metadata[1] == "wireguard"


def _secure_profile(runner: Runner, uuid: str, username: str, timeout: float) -> bool:
    if not _verified_wireguard(runner, uuid, min(timeout, 3.0)):
        return False
    result = _nmcli(
        runner,
        [
            "--wait",
            "8",
            "connection",
            "modify",
            "uuid",
            uuid,
            "connection.autoconnect",
            "no",
            "connection.permissions",
            "user:" + username,
        ],
        min(timeout, 10.0),
        2048,
    )
    if result.returncode != 0:
        return False
    _nmcli(
        runner,
        ["--wait", "8", "connection", "down", "uuid", uuid],
        min(timeout, 10.0),
        2048,
    )
    metadata = _profile_metadata(runner, uuid, min(timeout, 3.0))
    if metadata is None:
        return False
    expected_permission = "user:" + username
    permission = metadata[3].replace("\\:", ":").rstrip(":;")
    return (
        metadata[0] == uuid.lower()
        and metadata[1] == "wireguard"
        and metadata[2] == "no"
        and permission == expected_permission
        and _is_inactive(runner, uuid, min(timeout, 3.0))
    )


def _recover_profiles(runner: Runner, uuids: Iterable[str], username: str, timeout: float) -> list[str]:
    unresolved: list[str] = []
    deadline = time.monotonic() + max(1.0, timeout)
    for uuid in sorted(set(uuids)):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not UUID_RE.fullmatch(uuid):
            unresolved.append(uuid)
            continue
        if not _verified_wireguard(runner, uuid, min(remaining, 2.0)):
            unresolved.append(uuid)
            continue
        _nmcli(
            runner,
            [
                "--wait",
                "3",
                "connection",
                "modify",
                "uuid",
                uuid,
                "connection.autoconnect",
                "no",
                "connection.permissions",
                "user:" + username,
            ],
            min(max(0.1, deadline - time.monotonic()), 4.0),
            1024,
        )
        _nmcli(
            runner,
            ["--wait", "3", "connection", "down", "uuid", uuid],
            min(max(0.1, deadline - time.monotonic()), 4.0),
            1024,
        )
        deleted = _nmcli(
            runner,
            ["--wait", "3", "connection", "delete", "uuid", uuid],
            min(max(0.1, deadline - time.monotonic()), 4.0),
            1024,
        )
        if deleted.returncode != 0:
            unresolved.append(uuid)
    return unresolved


def import_config(selected_path: str, username: str, runner: Runner = run_limited) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", username) or ":" in username:
        raise HelperError("Could not determine a safe current-user identity")

    staged = stage_config(selected_path)
    imported_uuid: str | None = None
    started = time.monotonic()
    try:
        validate_staged_config(staged.path)
        remaining = IMPORT_DEADLINE_SECONDS - (time.monotonic() - started)
        result = _nmcli(
            runner,
            [
                "--wait",
                "15",
                "connection",
                "import",
                "type",
                "wireguard",
                "file",
                str(staged.path),
            ],
            min(max(0.1, remaining), 18.0),
            8192,
        )
        imported_uuid = _extract_import_uuid(result.stdout)

        if result.returncode != 0:
            candidates = _discover_named_uuids(runner, staged.connection_name, 4.0)
            recovery_targets = list(candidates or [])
            if imported_uuid is not None:
                recovery_targets.append(imported_uuid)
            unresolved = _recover_profiles(runner, recovery_targets, username, 8.0)
            if unresolved:
                raise HelperError("Import failed and cleanup could not be verified for profile " + unresolved[0])
            if candidates is None and imported_uuid is None:
                raise HelperError("Import failed and candidate cleanup could not be verified")
            raise HelperError(_decode_limited(result.stderr or result.stdout) or "WireGuard import failed")
        if imported_uuid is None:
            candidates = _discover_named_uuids(runner, staged.connection_name, 4.0)
            if candidates is None:
                raise HelperError("Imported profile identity was not proven and candidate cleanup could not be verified")
            unresolved = _recover_profiles(runner, candidates, username, 8.0)
            if unresolved:
                raise HelperError("Imported profile identity was not proven; manual cleanup is required for " + unresolved[0])
            raise HelperError("Imported profile identity was not proven; the candidate profile was removed")
        if not _verified_wireguard(runner, imported_uuid, 3.0):
            unresolved = _recover_profiles(runner, [imported_uuid], username, 8.0)
            if unresolved:
                raise HelperError("Imported profile could not be verified; manual cleanup is required for " + unresolved[0])
            raise HelperError("Imported profile could not be verified and was removed")

        remaining = IMPORT_DEADLINE_SECONDS - (time.monotonic() - started)
        if remaining <= 0 or not _secure_profile(runner, imported_uuid, username, remaining):
            unresolved = _recover_profiles(runner, [imported_uuid], username, 8.0)
            if unresolved:
                raise HelperError("Import hardening failed; manual cleanup is required for " + unresolved[0])
            raise HelperError("Import hardening failed; the imported profile was removed")
        return imported_uuid
    finally:
        staged.cleanup()


def _emit_error(message: str) -> None:
    safe = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", str(message))
    data = safe.encode("utf-8", "replace")[:MAX_UI_ERROR_BYTES]
    sys.stderr.buffer.write(data + b"\n")


def _run_mode(arguments: argparse.Namespace) -> int:
    result = run_limited(
        arguments.command,
        arguments.timeout_ms / 1000.0,
        arguments.stdout_limit,
        arguments.stderr_limit,
    )
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


def _import_mode(arguments: argparse.Namespace) -> int:
    try:
        username = pwd.getpwuid(os.getuid()).pw_name
        uuid = import_config(arguments.path, username)
    except HelperError as error:
        _emit_error(str(error))
        return 1
    except Exception:
        _emit_error("WireGuard import failed safely")
        return 1
    sys.stdout.write("OK:" + uuid + "\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    run_parser = subparsers.add_parser("run", add_help=False)
    run_parser.add_argument("--timeout-ms", type=int, required=True)
    run_parser.add_argument("--stdout-limit", type=int, required=True)
    run_parser.add_argument("--stderr-limit", type=int, required=True)
    run_parser.add_argument("command", nargs=argparse.REMAINDER)
    run_parser.set_defaults(handler=_run_mode)

    import_parser = subparsers.add_parser("import", add_help=False)
    import_parser.add_argument("path")
    import_parser.set_defaults(handler=_import_mode)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    arguments = build_parser().parse_args(argv)
    if arguments.mode == "run" and arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if arguments.mode == "run":
        if not arguments.command:
            _emit_error("Missing command")
            return 2
        if not (100 <= arguments.timeout_ms <= 60_000):
            _emit_error("Invalid command timeout")
            return 2
        if not (0 <= arguments.stdout_limit <= MAX_COMMAND_STDOUT):
            _emit_error("Invalid stdout limit")
            return 2
        if not (0 <= arguments.stderr_limit <= MAX_COMMAND_STDERR):
            _emit_error("Invalid stderr limit")
            return 2
    return int(arguments.handler(arguments))


if __name__ == "__main__":
    raise SystemExit(main())
