# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron vs-temperature-stats command.

The vs-temperature-stats command reads the NVMe SMART log page and prints
the current composite temperature along with any active per-sensor
temperatures.  Output is human-readable text by default, or JSON when a
JSON format flag is supplied.

Temperature sensors are reported sparsely: only sensors with a non-zero
reading appear, so gaps between sensor indices are possible.

Tests in this module verify:
  * Text output (default and explicit --output-format=normal).
  * JSON output for the --output-format=json flag, including that temperatures
    are formatted with a Celsius suffix.
  * One sensor entry per active sensor and none for inactive sensors, in
    both text and JSON output.
  * Error detection for a non-existent device and an invalid output format.
"""

from .micron_test import TestMicron

_COMMAND = "vs-temperature-stats"


class TestMicronVsTemperatureStats(TestMicron):
    """Test suite for the micron vs-temperature-stats plugin command."""

    def _active_sensor_indices(self):
        """Return the 1-based indices of active temperature sensors from nvme log smart.

        Sensors are reported sparsely, so the returned indices may have gaps.
        """
        result = self.run_cmd(
            f"{self.nvme_bin} log smart {self.ctrl} --output-format=json"
        )
        self.assertEqual(result.returncode, 0,
                         f"nvme log smart failed: {result.stderr}")
        data = self.parse_json_output(result.stdout, "nvme log smart")
        return [i for i in range(1, 9) if f"temperature_sensor_{i}" in data]

    def test_bad_device_returns_error(self):
        """vs-temperature-stats fails when the device does not exist."""
        self.check_bad_device_name(_COMMAND)

    def test_invalid_output_format_returns_error(self):
        """An unrecognised --output-format value is rejected."""
        self.check_output_format_rejected(_COMMAND, "notaformat")

    def test_default_output_is_text(self):
        """vs-temperature-stats produces human-readable text output by default."""
        result = self.run_plugin_cmd_check(_COMMAND)

        self.assertIn(
            "Micron temperature information", result.stdout,
            f"Expected header line in stdout, got: {result.stdout!r}",
        )
        self.assertIn(
            "Current Composite Temperature", result.stdout,
            f"Expected composite temperature label in stdout, got: {result.stdout!r}",
        )

    def test_output_format_normal_flag(self):
        """vs-temperature-stats produces text output when --output-format=normal is passed."""
        result = self.run_plugin_cmd_check(
            _COMMAND, args="--output-format=normal"
        )

        self.assertIn(
            "Micron temperature information", result.stdout,
            f"Expected header line in stdout, got: {result.stdout!r}",
        )
        self.assertIn(
            "Current Composite Temperature", result.stdout,
            f"Expected composite temperature label in stdout, got: {result.stdout!r}",
        )

    def test_output_format_json_flag_produces_valid_json(self):
        """vs-temperature-stats produces valid JSON when --output-format=json is passed."""
        data = self.run_supported_cmd_json(_COMMAND)

        self.assertIn(
            "Micron temperature information", data,
            f"Expected top-level key 'Micron temperature information' in JSON, "
            f"got keys: {list(data.keys())}",
        )
        log_pages = data["Micron temperature information"]
        self.assertIsInstance(log_pages, list)
        self.assertGreater(len(log_pages), 0)

        stats = log_pages[0]
        self.assertIn(
            "Current Composite Temperature", stats,
            f"Expected 'Current Composite Temperature' in stats object, got keys: {list(stats.keys())}",
        )

    def test_json_temperature_value_has_celsius_suffix(self):
        """vs-temperature-stats JSON output formats temperatures as '<N> C'."""
        data = self.run_supported_cmd_json(_COMMAND)
        temp_str = data["Micron temperature information"][0]["Current Composite Temperature"]

        self.assertRegex(
            temp_str, r"^\d+ C$",
            f"Expected temperature formatted as '<N> C', got: {temp_str!r}",
        )

    def test_text_temperature_value_has_celsius_suffix(self):
        """vs-temperature-stats text output formats temperatures as '<N> C'."""
        result = self.run_plugin_cmd_check(_COMMAND)

        self.assertRegex(
            result.stdout, r"Current Composite Temperature\s*:\s*\d+ C",
            f"Expected 'Current Composite Temperature : <N> C' in stdout, "
            f"got: {result.stdout!r}",
        )

    def test_json_sensor_entries_match_smart_log_count(self):
        """vs-temperature-stats JSON output contains exactly one entry per active sensor.

        Cross-checks the reported sensors against nvme smart-log: a
        "Temperature Sensor #N" key must appear for each active sensor and for
        no inactive one.
        """
        active = self._active_sensor_indices()

        data = self.run_supported_cmd_json(_COMMAND)
        stats = data["Micron temperature information"][0]

        for i in active:
            key = f"Temperature Sensor #{i}"
            self.assertIn(
                key, stats,
                f"Expected '{key}' in vs-temperature-stats JSON output, "
                f"got keys: {list(stats.keys())}",
            )
            self.assertRegex(
                stats[key], r"^\d+ C$",
                f"Expected '{key}' formatted as '<N> C', got: {stats[key]!r}",
            )

        # No inactive sensor should appear.
        for i in range(1, 9):
            if i in active:
                continue
            self.assertNotIn(
                f"Temperature Sensor #{i}", stats,
                f"Unexpected sensor key for inactive sensor #{i} in JSON output: "
                f"{list(stats.keys())}",
            )

    def test_text_sensor_entries_match_smart_log_count(self):
        """vs-temperature-stats text output contains exactly one line per active sensor.

        Cross-checks the reported sensors against nvme smart-log: a
        "Temperature Sensor #N" line must appear for each active sensor and for
        no inactive one.
        """
        active = self._active_sensor_indices()

        result = self.run_plugin_cmd_check(_COMMAND)

        for i in active:
            self.assertRegex(
                result.stdout, rf"Temperature Sensor #{i}\s*:\s*\d+ C",
                f"Expected 'Temperature Sensor #{i} : <N> C' in stdout, "
                f"got: {result.stdout!r}",
            )

        # No inactive sensor should appear.
        for i in range(1, 9):
            if i in active:
                continue
            self.assertNotRegex(
                result.stdout, rf"Temperature Sensor #{i}\s*:",
                f"Unexpected sensor line for inactive sensor #{i} in stdout: "
                f"{result.stdout!r}",
            )
