# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron latency-logs command.

The command reports data gathered by the drive's latency-monitoring feature,
read from a vendor-specific log page that a drive may not implement.

latency-logs reads the log page and prints the fixed-size ring of the most
recent slow commands as comma-separated values, one row per entry, preceded
by a column-name header.

The command ignores --output-format, always generating CSV output.

Tests in this module verify:
  * Error handling for a non-existent device.
  * The CSV header text, entry count and per-row column count.
  * Equivalent output for the controller and namespace device paths.
"""

import json

from .micron_test import TestMicron

_COMMAND = "latency-logs"

_CSV_HEADER = (
    "Timestamp, Latency, CmdTag, Opcode, Fuse, Psdt, Cid, Nsid, "
    "Slba_L, Slba_H, Nlb, DEAC, PRINFO, FUA, LR"
)
_COLUMNS = tuple(name.strip() for name in _CSV_HEADER.split(","))
_ENTRY_COUNT = 16


class TestMicronLatencyLogs(TestMicron):
    """Test suite for the micron latency-logs command."""

    def _run_logs(self, device=None, args=""):
        """Run latency-logs and return the CompletedProcess result."""
        return self.run_plugin_cmd(_COMMAND, device=device, args=args)

    def _logs_stdout(self, args=""):
        """Return latency-logs stdout, skipping if log page is not supported.

        The support probe always runs without a format flag: with -o json the
        failure is reported as a JSON object on stdout instead of a message on
        stderr, which the unsupported-reason matcher cannot see.
        """
        self.skip_unless_command_supported(_COMMAND)
        return self.run_plugin_cmd_check(_COMMAND, args=args).stdout

    def _logs_rows(self, stdout):
        """Return the non-empty CSV rows that follow the header."""
        lines = [line.strip() for line in stdout.splitlines()]
        self.assertIn(
            _CSV_HEADER, lines,
            f"Expected CSV header {_CSV_HEADER!r} in stdout, "
            f"got: {stdout!r}",
        )
        start = lines.index(_CSV_HEADER) + 1
        return [line for line in lines[start:] if line]

    def test_bad_device_returns_error(self):
        """latency-logs fails when the device does not exist.

        Only the device name is asserted because the OS strerror text appended
        to it differs between Windows and Linux.
        """
        device = "/dev/nvme-nonexistent-test-device"
        result = self._run_logs(device=device)

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for a non-existent device",
        )
        self.assertIn(
            device, result.stderr,
            f"Expected {device!r} in stderr, got: {result.stderr!r}",
        )

    def test_prints_csv_header(self):
        """latency-logs prints the fixed CSV column header."""
        stdout = self._logs_stdout()

        self.assertIn(
            _CSV_HEADER, stdout,
            f"Expected CSV header {_CSV_HEADER!r} in stdout, "
            f"got: {stdout!r}",
        )

    def test_has_one_row_per_entry(self):
        """latency-logs prints one row per entry in the fixed-size log."""
        rows = self._logs_rows(self._logs_stdout())

        self.assertEqual(
            len(rows), _ENTRY_COUNT,
            f"Expected {_ENTRY_COUNT} CSV rows, got {len(rows)}: {rows!r}",
        )

    def test_rows_match_header_column_count(self):
        """Every latency-logs row holds one decimal value per header column."""
        rows = self._logs_rows(self._logs_stdout())

        for row in rows:
            values = row.split(",")
            self.assertEqual(
                len(values), len(_COLUMNS),
                f"Expected {len(_COLUMNS)} columns to match the header "
                f"{_COLUMNS!r}, got {len(values)} in row: {row!r}",
            )
            for column, value in zip(_COLUMNS, values):
                self.assertRegex(
                    value, r"^\d+$",
                    f"Column {column!r} is not an unsigned decimal value in "
                    f"row {row!r}: {value!r}",
                )

    def test_namespace_device_produces_same_row_count(self):
        """latency-logs accepts a namespace path and reports the same rows.

        A namespace path resolves to its parent controller, so the log page
        read and its output are identical.
        """
        result = self._run_logs(device=self.ns1)
        self.skip_if_result_unsupported(_COMMAND, result)
        self.assertEqual(
            result.returncode, 0,
            f"latency-logs failed for {self.ns1}: rc={result.returncode}, "
            f"stderr={result.stderr!r}",
        )

        rows = self._logs_rows(result.stdout)
        self.assertEqual(
            len(rows), _ENTRY_COUNT,
            f"Expected {_ENTRY_COUNT} CSV rows for {self.ns1}, "
            f"got {len(rows)}: {rows!r}",
        )
