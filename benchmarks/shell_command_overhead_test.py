#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("shell_command_overhead.py")
SPEC = importlib.util.spec_from_file_location("shell_command_overhead", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
shell_command_overhead = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shell_command_overhead)


class ShellCommandOverheadTests(unittest.TestCase):
    def test_write_home_omits_mcp_config_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = pathlib.Path(tmp) / "home"
            shell_command_overhead.write_home(home, "marker-1", 0.0)
            self.assertFalse((home / ".fx/mcp.json").exists())

    def test_write_home_with_mcp_writes_stdio_server_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = pathlib.Path(tmp) / "home"
            shell_command_overhead.write_home(home, "marker-1", 0.0, with_mcp=True)
            mcp_path = home / ".fx/mcp.json"
            self.assertTrue(mcp_path.is_file())
            config = json.loads(mcp_path.read_text())
            self.assertIn("mcpServers", config)
            self.assertEqual(len(config["mcpServers"]), 1)
            server = next(iter(config["mcpServers"].values()))
            self.assertEqual(server["command"], "/bin/true")

    def test_count_bridge_coverage_counts_registrations_and_real_owner_starts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            trace_path = pathlib.Path(tmp) / "trace.log"
            trace_path.write_text(
                "\n".join(
                    [
                        "100 [mcp-call] bridge listening socket=/tmp/fx-mcp-1/s",
                        "101 [mcp-call] bridge closed",
                        "102 [mcp-call] bridge listening socket=/tmp/fx-mcp-2/s",
                        "103 [mcp-call] bridge closed",
                        "104 [mcp-owner] owner started pid=4321",
                        "105 [mcp-owner] owner started without a pid",
                    ]
                )
                + "\n"
            )
            counts = shell_command_overhead.count_bridge_coverage(trace_path)
            self.assertEqual(counts["bridge_registrations"], 2)
            self.assertEqual(counts["mcp_owner_starts"], 1)
            self.assertNotIn("mcp_server_starts", counts)

    def test_count_bridge_coverage_handles_invalid_utf8_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            trace_path = pathlib.Path(tmp) / "trace.log"
            trace_path.write_bytes(
                b"100 [mcp-call] bridge listening socket=/tmp/fx-mcp-1/s\n"
                b"101 [mcp] bad bytes \xff\xfe here\n"
                b"102 [mcp-owner] owner started pid=99\n"
            )
            counts = shell_command_overhead.count_bridge_coverage(trace_path)
            self.assertEqual(counts["bridge_registrations"], 1)
            self.assertEqual(counts["mcp_owner_starts"], 1)

    def test_count_bridge_coverage_missing_file_returns_zeroes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            counts = shell_command_overhead.count_bridge_coverage(pathlib.Path(tmp) / "missing.log")
            self.assertEqual(counts["bridge_registrations"], 0)
            self.assertEqual(counts["mcp_owner_starts"], 0)

    def test_check_bridge_coverage_requires_every_shell_call(self) -> None:
        ok, err = shell_command_overhead.check_bridge_coverage(
            {"bridge_registrations": 101, "mcp_owner_starts": 0},
            100,
        )
        self.assertTrue(ok)
        self.assertIsNone(err)

        ok, err = shell_command_overhead.check_bridge_coverage(
            {"bridge_registrations": 0, "mcp_owner_starts": 0},
            100,
        )
        self.assertFalse(ok)
        self.assertIn("bridge_registrations", err)
        self.assertIn("101", err)
        self.assertIn("0", err)


if __name__ == "__main__":
    unittest.main()
