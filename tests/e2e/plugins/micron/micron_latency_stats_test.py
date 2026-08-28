# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron latency-stats command.

The command reports data gathered by the drive's latency-monitoring feature,
read from a vendor-specific log page.  Not all drives implement the log.

latency-stats prints a histogram of command completion times: a header
naming the command class it covers (All|Read|Write|Trim, selected with -c),
the log's major and minor revision, and one row per latency bucket 
with the bucket's range and the number of commands that fell into it.
The bucket ranges are fixed by the plugin, not reported by the drive.

The command ignores --output-format, always generating text output.

Tests in this module verify:
  * Error handling for a non-existent device.
  * Rejection of an unrecognised -c value, and that the rejection happens
    before the log page is read.
  * The header naming for each -c value and for the default.
  * The revision lines, bucket table header, bucket count and the exact
    bucket ranges.
  * Equivalent output for the controller and namespace device paths.
"""

import re

from .micron_test import TestMicron

_COMMAND = "latency-stats"

# "Micron IO %s Command Latency Statistics" with cmd_str per -c value.
_HEADER = "Micron IO {} Command Latency Statistics"
_COMMAND_CLASSES = (("all", "All"), ("read", "Read"), ("write", "Write"),
                    ("trim", "Trim"))
_DEFAULT_COMMAND_CLASS = "All"

_TABLE_HEADER = "Bucket    Start     End        Command Count"
_MAJOR_REVISION = "Major Revision"
_MINOR_REVISION = "Minor Revision"

_BOGUS_COMMAND = "bogus"
_INVALID_COMMAND_MSG = (
    f"Invalid command option {_BOGUS_COMMAND} to display latency stats"
)

# Messages emitted only once a log read has been attempted; the -c value is
# validated before that point, so neither may appear for a bogus -c value.
_LOG_READ_MSGS = (
    "Unable to retrieve latency stats log for the drive",
    "Invalid Log Page",
)

# The bucket boundaries are hard-coded in the plugin's thresholds[] table, so
# they are the same on every drive.  The last bucket's end is printed as "INF".
_LATENCY_BUCKETS = (
    ("0us", "50us"), ("50us", "100us"), ("100us", "150us"),
    ("150us", "200us"), ("200us", "300us"), ("300us", "400us"),
    ("400us", "500us"), ("500us", "600us"), ("600us", "700us"),
    ("700us", "800us"), ("800us", "900us"), ("900us", "1000us"),
    ("1ms", "5ms"), ("5ms", "10ms"), ("10ms", "20ms"), ("20ms", "50ms"),
    ("50ms", "100ms"), ("100ms", "200ms"), ("200ms", "300ms"),
    ("300ms", "400ms"), ("400ms", "500ms"), ("500ms", "600ms"),
    ("600ms", "700ms"), ("700ms", "800ms"), ("800ms", "900ms"),
    ("900ms", "1000ms"), ("1s", "2s"), ("2s", "3s"), ("3s", "4s"),
    ("4s", "5s"), ("5s", "8s"), ("8s", "INF"),
)

# "%2d   %8s    %8s    %8"PRIu64"" -- bucket, start, end, command count.
_BUCKET_ROW_RE = re.compile(
    r"^\s*(\d+)\s+(\d+(?:us|ms|s))\s+(\d+(?:us|ms|s)|INF)\s+(\d+)$"
)


class TestMicronLatencyStats(TestMicron):
    """Test suite for the micron latency-stats command."""

    def _run_stats(self, device=None, args=""):
        """Run latency-stats and return the CompletedProcess result."""
        return self.run_plugin_cmd(_COMMAND, device=device, args=args)

    def _stats_stdout(self, args=""):
        """Return latency-stats stdout, skipping if the log is not supported."""
        return self.run_supported_cmd(_COMMAND, args=args).stdout

    def _bucket_rows(self, stdout):
        """Return the (bucket, start, end, count) tuples from the stats table."""
        rows = [m.groups() for m in
                (_BUCKET_ROW_RE.match(line) for line in stdout.splitlines())
                if m]
        self.assertTrue(
            rows,
            f"Expected latency bucket rows in stdout, got: {stdout!r}",
        )
        return rows

    def test_bad_device_returns_error(self):
        """latency-stats fails when the device does not exist."""
        self.check_bad_device_name(_COMMAND)

    def test_invalid_command_option_returns_error(self):
        """latency-stats rejects a -c value outside all|read|write|trim."""
        result = self._run_stats(args=f"-c {_BOGUS_COMMAND}")

        self.assertNotEqual(
            result.returncode, 0,
            f"Expected non-zero exit code for '-c {_BOGUS_COMMAND}'",
        )
        self.assertIn(
            _INVALID_COMMAND_MSG, result.stderr,
            f"Expected {_INVALID_COMMAND_MSG!r} in stderr, "
            f"got: {result.stderr!r}",
        )

    def test_invalid_command_option_checked_before_log_read(self):
        """latency-stats validates -c before reading the latency stats log.

        The check precedes the log read, so the error is the same on a drive
        that does not implement the log page -- no log-read diagnostic appears.
        """
        result = self._run_stats(args=f"-c {_BOGUS_COMMAND}")

        for message in _LOG_READ_MSGS:
            self.assertNotIn(
                message, result.stderr,
                f"Expected no log-read diagnostic for an invalid -c value, "
                f"but stderr contains {message!r}: {result.stderr!r}",
            )
        self.assertEqual(
            result.stdout, "",
            f"Expected no stdout for an invalid -c value, "
            f"got: {result.stdout!r}",
        )

    def test_header_names_selected_command_class(self):
        """latency-stats names the command class selected by -c in its header."""
        for option, name in _COMMAND_CLASSES:
            stdout = self._stats_stdout(args=f"-c {option}")
            expected = _HEADER.format(name)
            self.assertIn(
                expected, stdout,
                f"Expected header {expected!r} for '-c {option}', "
                f"got: {stdout!r}",
            )

    def test_default_command_class_is_all(self):
        """latency-stats reports the All command class when -c is omitted."""
        stdout = self._stats_stdout()
        expected = _HEADER.format(_DEFAULT_COMMAND_CLASS)

        self.assertIn(
            expected, stdout,
            f"Expected header {expected!r} with no -c option, got: {stdout!r}",
        )

    def test_reports_log_revision(self):
        """latency-stats reports the log's major and minor revision numbers."""
        stdout = self._stats_stdout()

        for label in (_MAJOR_REVISION, _MINOR_REVISION):
            self.assertRegex(
                stdout, re.compile(rf"^{label}\s*:\s*-?\d+$", re.MULTILINE),
                f"Expected '{label} : <N>' line, got: {stdout!r}",
            )

    def test_prints_bucket_table_header(self):
        """latency-stats labels the bucket table columns."""
        stdout = self._stats_stdout()

        self.assertIn(
            _TABLE_HEADER, stdout,
            f"Expected table header {_TABLE_HEADER!r} in stdout, "
            f"got: {stdout!r}",
        )

    def test_has_one_row_per_bucket(self):
        """latency-stats prints exactly one row per latency bucket."""
        rows = self._bucket_rows(self._stats_stdout())

        self.assertEqual(
            len(rows), len(_LATENCY_BUCKETS),
            f"Expected {len(_LATENCY_BUCKETS)} bucket rows, got {len(rows)}: "
            f"{rows!r}",
        )

    def test_bucket_ranges_match_plugin_thresholds(self):
        """latency-stats prints the fixed bucket ranges in order, 1-based."""
        rows = self._bucket_rows(self._stats_stdout())
        ranges = [(int(bucket), start, end) for bucket, start, end, _ in rows]
        expected = [(i + 1, start, end)
                    for i, (start, end) in enumerate(_LATENCY_BUCKETS)]

        self.assertEqual(
            ranges, expected,
            f"Bucket ranges differ from the plugin thresholds table:\n"
            f"  got:      {ranges!r}\n"
            f"  expected: {expected!r}",
        )

    def test_namespace_device_produces_same_header(self):
        """latency-stats accepts a namespace path and reports the same header.

        A namespace path resolves to its parent controller, so the log page
        read and its output are identical.
        """
        result = self.run_supported_cmd(_COMMAND, device=self.ns1)

        expected = _HEADER.format(_DEFAULT_COMMAND_CLASS)
        self.assertIn(
            expected, result.stdout,
            f"Expected header {expected!r} for {self.ns1}, "
            f"got: {result.stdout!r}",
        )
