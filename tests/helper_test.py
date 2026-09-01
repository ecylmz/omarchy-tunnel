#!/usr/bin/env python3

import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock


HELPER_PATH = Path(__file__).resolve().parents[1] / "scripts" / "omarchy-tunnel-helper.py"
SPEC = importlib.util.spec_from_file_location("omarchy_tunnel_helper", HELPER_PATH)
helper = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)

UUID = "11111111-1111-4111-8111-111111111111"
VALID_CONFIG = b"[Interface]\nPrivateKey = test\n[Peer]\nPublicKey = peer\n"


class FakeNmcli:
    def __init__(self, import_output=True, discovery_error=False):
        self.import_output = import_output
        self.discovery_error = discovery_error
        self.name = ""
        self.hardened = False
        self.down = False
        self.deleted = False
        self.calls = []

    def __call__(self, argv, _timeout, _stdout_limit, _stderr_limit):
        args = list(argv)
        self.calls.append(args)
        if "import" in args:
            self.name = Path(args[-1]).stem
            output = (
                f"Connection '{self.name}' ({UUID}) successfully added.\n".encode()
                if self.import_output
                else b"unexpected success text\n"
            )
            return helper.CommandResult(0, output, b"")
        if "--get-values" in args:
            if self.deleted:
                return helper.CommandResult(10, b"", b"not found")
            autoconnect = "no" if self.hardened else "yes"
            permissions = "user:alice" if self.hardened else ""
            output = f"{UUID}\nwireguard\n{autoconnect}\n{permissions}\n".encode()
            return helper.CommandResult(0, output, b"")
        if "modify" in args:
            self.hardened = True
            return helper.CommandResult(0, b"", b"")
        if "down" in args:
            self.down = True
            return helper.CommandResult(0, b"", b"")
        if "delete" in args:
            self.deleted = True
            return helper.CommandResult(0, b"", b"")
        if "--fields" in args:
            field = args[args.index("--fields") + 1]
            if field == "NAME,UUID,TYPE":
                if self.discovery_error:
                    return helper.CommandResult(124, b"", b"Operation timed out")
                output = b"" if self.deleted else f"{self.name}:{UUID}:wireguard\n".encode()
                return helper.CommandResult(0, output, b"")
            if field == "UUID":
                output = b"" if self.down or self.deleted else (UUID + "\n").encode()
                return helper.CommandResult(0, output, b"")
        raise AssertionError("Unexpected nmcli invocation: " + repr(args))


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, name, data=VALID_CONFIG):
        path = self.root / name
        path.write_bytes(data)
        return path

    def test_stages_private_bounded_regular_copy(self):
        source = self.write("source.conf")
        staged = helper.stage_config(str(source))
        try:
            self.assertEqual(staged.path.read_bytes(), VALID_CONFIG)
            self.assertTrue(stat.S_ISREG(staged.path.stat().st_mode))
            self.assertEqual(stat.S_IMODE(staged.directory.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(staged.path.stat().st_mode), 0o600)
            self.assertLessEqual(len(staged.connection_name), 15)
        finally:
            staged.cleanup()
        self.assertFalse(staged.directory.exists())

    def test_rejects_symlink_fifo_and_oversized_file(self):
        source = self.write("real.conf")
        symlink = self.root / "link.conf"
        symlink.symlink_to(source)
        with self.assertRaisesRegex(helper.HelperError, "symlinks"):
            helper.stage_config(str(symlink))

        fifo = self.root / "pipe.conf"
        os.mkfifo(fifo)
        with self.assertRaisesRegex(helper.HelperError, "regular files"):
            helper.stage_config(str(fifo))

        oversized = self.write("large.conf", b"x" * (helper.MAX_CONFIG_BYTES + 1))
        with self.assertRaisesRegex(helper.HelperError, "64 KiB"):
            helper.stage_config(str(oversized))

    def test_path_replacement_does_not_change_opened_content(self):
        source = self.write("selected.conf", VALID_CONFIG)
        replacement = self.write("replacement.conf", b"[Interface]\nPostUp = bad\n[Peer]\n")
        real_read = helper.os.read
        swapped = False

        def swap_then_read(fd, size):
            nonlocal swapped
            if not swapped:
                swapped = True
                os.replace(replacement, source)
            return real_read(fd, size)

        with mock.patch.object(helper.os, "read", side_effect=swap_then_read):
            staged = helper.stage_config(str(source))
        try:
            self.assertEqual(staged.path.read_bytes(), VALID_CONFIG)
            helper.validate_staged_config(staged.path)
        finally:
            staged.cleanup()

    def test_validator_rejects_hooks_and_malformed_text(self):
        hooks = self.write("hooks.conf", b"[Interface]\n PostUp = curl bad\n[Peer]\n")
        with self.assertRaisesRegex(helper.HelperError, "hooks"):
            helper.validate_staged_config(hooks)
        missing_peer = self.write("missing.conf", b"[Interface]\nPrivateKey=x\n")
        with self.assertRaisesRegex(helper.HelperError, r"missing \[Peer\]"):
            helper.validate_staged_config(missing_peer)
        binary = self.write("binary.conf", b"[Interface]\x00\n[Peer]\n")
        with self.assertRaisesRegex(helper.HelperError, "plain text"):
            helper.validate_staged_config(binary)

    def test_import_uses_exact_uuid_and_verifies_hardening(self):
        source = self.write("valid.conf")
        fake = FakeNmcli()
        result = helper.import_config(str(source), "alice", fake)
        self.assertEqual(result, UUID)
        self.assertTrue(fake.hardened)
        self.assertTrue(fake.down)
        self.assertFalse(fake.deleted)
        modify = next(call for call in fake.calls if "modify" in call)
        self.assertIn("uuid", modify)
        self.assertIn(UUID, modify)
        self.assertFalse(any("NAME,UUID,TYPE" in call for call in fake.calls))
        first_modify = fake.calls.index(modify)
        self.assertTrue(any("--get-values" in call for call in fake.calls[:first_modify]))

    def test_unproven_identity_is_recovered_by_private_import_name(self):
        source = self.write("valid.conf")
        fake = FakeNmcli(import_output=False)
        with self.assertRaisesRegex(helper.HelperError, "identity was not proven"):
            helper.import_config(str(source), "alice", fake)
        self.assertTrue(fake.hardened)
        self.assertTrue(fake.down)
        self.assertTrue(fake.deleted)

    def test_unproven_identity_never_claims_cleanup_when_discovery_fails(self):
        source = self.write("valid.conf")
        fake = FakeNmcli(import_output=False, discovery_error=True)
        with self.assertRaisesRegex(helper.HelperError, "cleanup could not be verified"):
            helper.import_config(str(source), "alice", fake)
        self.assertFalse(fake.deleted)

    def test_private_copy_is_removed_after_validation_failure(self):
        source = self.write("hooks.conf", b"[Interface]\nPostUp = bad\n[Peer]\n")
        real_mkdtemp = helper.tempfile.mkdtemp
        created = []

        def tracked_mkdtemp(*args, **kwargs):
            kwargs["dir"] = self.root
            path = real_mkdtemp(*args, **kwargs)
            created.append(Path(path))
            return path

        with mock.patch.object(helper.tempfile, "mkdtemp", side_effect=tracked_mkdtemp):
            with self.assertRaisesRegex(helper.HelperError, "hooks"):
                helper.import_config(str(source), "alice", FakeNmcli())
        self.assertEqual(len(created), 1)
        self.assertFalse(created[0].exists())

    def test_import_uuid_parser_rejects_ambiguous_output(self):
        line = f"Connection 'omt123' ({UUID}) successfully added.\n".encode()
        self.assertEqual(helper._extract_import_uuid(line), UUID)
        self.assertIsNone(helper._extract_import_uuid(line + line))
        self.assertIsNone(helper._extract_import_uuid(b"success without identity\n"))

    def test_bounded_runner_enforces_output_and_deadline(self):
        oversized = helper.run_limited(
            [sys.executable, "-c", "print('x' * 4096)"], 2.0, 64, 64
        )
        self.assertEqual(oversized.returncode, 125)
        self.assertLessEqual(len(oversized.stdout), 64)

        stalled = helper.run_limited(
            [sys.executable, "-c", "import time; time.sleep(2)"], 0.1, 64, 64
        )
        self.assertEqual(stalled.returncode, 124)
        self.assertTrue(stalled.timed_out)


if __name__ == "__main__":
    unittest.main()
