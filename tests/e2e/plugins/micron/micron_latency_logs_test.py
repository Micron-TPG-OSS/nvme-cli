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

    def _logs_stdout(self):
        """Return latency-logs stdout, skipping if the log is not supported."""
        return self.run_supported_cmd(_COMMAND).stdout

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
        """latency-logs fails when the device does not exist."""
        self.check_bad_device_name(_COMMAND)

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
        result = self.run_supported_cmd(_COMMAND, device=self.ns1)

        rows = self._logs_rows(result.stdout)
        self.assertEqual(
            len(rows), _ENTRY_COUNT,
            f"Expected {_ENTRY_COUNT} CSV rows for {self.ns1}, "
            f"got {len(rows)}: {rows!r}",
        )
