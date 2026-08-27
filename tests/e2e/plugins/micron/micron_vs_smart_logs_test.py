# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron vs-smart-ext-log and vs-smart-add-log commands.

Both commands read a vendor SMART log page and render it through the shared
field-table path (generic_structure_parser): one "<label> : 0x<hex>" line per
field in text mode, or a single top-level key holding a one-element array of
field objects in JSON mode.  Which log page is read depends on the drive
model, so the top-level JSON key varies between drives.

vs-smart-ext-log prints a header line naming the log page in text mode;
vs-smart-add-log prints none.

Tests in this module verify:
  * The text field table and the JSON field object are both well formed.
  * The JSON top-level key is one the plugin can emit for that command.
  * The text and JSON field sets and values are identical.
  * The log-page specific field labels are present.
  * vs-smart-ext-log's text header equals its JSON top-level key, and
    vs-smart-add-log emits no header.
  * --output-format=binary and an unrecognised format are both rejected.
  * The controller and namespace paths report the same fields.
  * Error detection for a non-existent device.
"""

import json

from .micron_test import TestMicron

_EXT_LOG = "vs-smart-ext-log"
_ADD_LOG = "vs-smart-add-log"

# Top-level JSON keys each command can emit, one per supported log page.
_JSON_KEYS = {
    _EXT_LOG: (
        "SMART Extended Log:0xE1",
        "SMART Extended Log:0xD0",
    ),
    _ADD_LOG: (
        "OCP DataCenter SMART Health Log: 0xC0",
        "OCP SMART Cloud Health Log: 0xC0",
        "Extended Smart Log Page : 0xFB",
    ),
}

# Labels that must appear for a given log page, taken from its field table in
# micron-nvme.c.  Log pages absent from this map are not asserted against.
_REQUIRED_LABELS = {
    "SMART Extended Log:0xE1": (
        "Grown Bad Block Count",
        "Per Block Max Erase Count",
        "Power On Minutes",
        "Total Erase Count",
        "User Block Max Erase Count",
    ),
    "SMART Extended Log:0xD0": (
        "Version",
        "Grown Bad Block Count",
        "Total Erase Count",
        "Erase Fail Count",
    ),
    "OCP DataCenter SMART Health Log: 0xC0": (
        "Physical Media Units Written",
        "Physical Media Units Read",
        "Raw Bad User NAND Block Count",
        "Log Page Version",
        "Log Page GUID",
    ),
    "OCP SMART Cloud Health Log: 0xC0": (
        "Physical Media Units Written",
        "Physical Media Units Read",
        "Raw Bad User NAND Block Count",
        "NUSE",
        "Log Page Version",
        "Log Page GUID",
    ),
    "Extended Smart Log Page : 0xFB": (
        "Physical Media Units Written - TLC",
        "Physical Media Units Written - SLC",
        "Raw Bad User NAND Block Count",
        "Log Page Version",
    ),
}


class TestMicronVsSmartLogs(TestMicron):
    """Test suite for the micron vendor SMART log commands."""

    def _run(self, command, device=None, args=""):
        """Run a SMART log command, skipping if the drive cannot serve it."""
        result = self.run_plugin_cmd(command, device=device, args=args)
        self.skip_if_result_unsupported(command, result)
        self.assertEqual(
            result.returncode, 0,
            f"micron {command} failed: rc={result.returncode}, "
            f"stderr={result.stderr!r}",
        )
        return result

    def _json_data(self, command, device=None):
        """Return the parsed JSON output of a SMART log command."""
        result = self._run(command, device=device, args="--output-format=json")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            self.fail(
                f"micron {command} --output-format=json produced invalid JSON: "
                f"{exc}\nstdout={result.stdout!r}"
            )

    def _json_fields(self, command, device=None):
        """Return the field object from JSON output, validating its shape."""
        return self.validate_hex_table_object(
            self._json_data(command, device=device), _JSON_KEYS[command], command
        )

    def _check_text_field_table(self, command):
        """Text output must be a well-formed field table."""
        self.validate_hex_field_table(self._run(command).stdout, command)

    def _check_text_and_json_match(self, command):
        """The text and JSON forms must report identical fields and values."""
        text_fields = self.validate_hex_field_table(self._run(command).stdout, command)
        json_fields = self._json_fields(command)

        self.assertEqual(
            set(text_fields), set(json_fields),
            f"micron {command} text and JSON field sets differ; "
            f"text-only={set(text_fields) - set(json_fields)}, "
            f"JSON-only={set(json_fields) - set(text_fields)}",
        )
        for label, value in json_fields.items():
            self.assertEqual(
                text_fields[label], value,
                f"micron {command} field {label!r} differs between text "
                f"({text_fields[label]!r}) and JSON ({value!r})",
            )

    def _check_required_labels(self, command):
        """Every label defined for the reported log page must be present."""
        data = self._json_data(command)
        key = next(iter(data))
        fields = self.validate_hex_table_object(data, _JSON_KEYS[command], command)

        for label in _REQUIRED_LABELS[key]:
            self.assertIn(
                label, fields,
                f"Expected field {label!r} for log page {key!r}, "
                f"got: {list(fields)}",
            )

    def _check_output_format_rejected(self, command, value):
        """An --output-format the command does not implement must be rejected."""
        result = self.run_plugin_cmd(command, args=f"--output-format={value}")

        self.assertNotEqual(
            result.returncode, 0,
            f"Expected micron {command} to reject --output-format={value}",
        )
        self.assertIn(
            "Invalid output format", result.stderr,
            f"Expected 'Invalid output format' in stderr, got: {result.stderr!r}",
        )

    def _check_namespace_matches_controller(self, command):
        """The namespace path must report the same fields as the controller."""
        ctrl_fields = self._json_fields(command, device=self.ctrl)
        ns_fields = self._json_fields(command, device=self.ns1)

        self.assertEqual(
            set(ctrl_fields), set(ns_fields),
            f"micron {command} field set differs between {self.ctrl} and "
            f"{self.ns1}",
        )

    def _check_bad_device(self, command):
        """A non-existent device must fail and name the device."""
        device = "/dev/nvme-nonexistent-test-device"
        result = self.run_plugin_cmd(command, device=device)

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for a non-existent device",
        )
        self.assertIn(
            device, result.stderr,
            f"Expected {device!r} in stderr, got: {result.stderr!r}",
        )

    def test_ext_log_text_field_table(self):
        """vs-smart-ext-log prints a well-formed '<label> : 0x<hex>' table."""
        self._check_text_field_table(_EXT_LOG)

    def test_add_log_text_field_table(self):
        """vs-smart-add-log prints a well-formed '<label> : 0x<hex>' table."""
        self._check_text_field_table(_ADD_LOG)

    def test_ext_log_json_field_object(self):
        """vs-smart-ext-log JSON holds one known log-page key and its fields."""
        self._json_fields(_EXT_LOG)

    def test_add_log_json_field_object(self):
        """vs-smart-add-log JSON holds one known log-page key and its fields."""
        self._json_fields(_ADD_LOG)

    def test_ext_log_text_and_json_fields_match(self):
        """vs-smart-ext-log reports identical fields in text and JSON."""
        self._check_text_and_json_match(_EXT_LOG)

    def test_add_log_text_and_json_fields_match(self):
        """vs-smart-add-log reports identical fields in text and JSON."""
        self._check_text_and_json_match(_ADD_LOG)

    def test_ext_log_required_labels_present(self):
        """vs-smart-ext-log reports every label its log page defines."""
        self._check_required_labels(_EXT_LOG)

    def test_add_log_required_labels_present(self):
        """vs-smart-add-log reports every label its log page defines."""
        self._check_required_labels(_ADD_LOG)

    def test_ext_log_text_header_matches_json_key(self):
        """vs-smart-ext-log's first line names the log page it read."""
        stdout = self._run(_EXT_LOG).stdout
        key = next(iter(self._json_data(_EXT_LOG)))

        self.assertEqual(
            stdout.splitlines()[0].strip(), key,
            f"Expected {key!r} as the first line of vs-smart-ext-log output, "
            f"got: {stdout!r}",
        )

    def test_add_log_text_has_no_header(self):
        """vs-smart-add-log output starts with a field line, not a header."""
        stdout = self._run(_ADD_LOG).stdout
        first = next(line for line in stdout.splitlines() if line.strip())

        self.assertIn(
            " : ", first,
            f"Expected vs-smart-add-log to start with a field line, "
            f"got: {first!r}",
        )

    def test_ext_log_binary_output_format_rejected(self):
        """vs-smart-ext-log rejects --output-format=binary."""
        self._check_output_format_rejected(_EXT_LOG, "binary")

    def test_add_log_binary_output_format_rejected(self):
        """vs-smart-add-log rejects --output-format=binary."""
        self._check_output_format_rejected(_ADD_LOG, "binary")

    def test_ext_log_invalid_output_format_returns_error(self):
        """vs-smart-ext-log rejects an unrecognised --output-format."""
        self._check_output_format_rejected(_EXT_LOG, "notaformat")

    def test_add_log_invalid_output_format_returns_error(self):
        """vs-smart-add-log rejects an unrecognised --output-format."""
        self._check_output_format_rejected(_ADD_LOG, "notaformat")

    def test_ext_log_namespace_path_matches_controller(self):
        """vs-smart-ext-log reports the same fields for both device paths."""
        self._check_namespace_matches_controller(_EXT_LOG)

    def test_add_log_namespace_path_matches_controller(self):
        """vs-smart-add-log reports the same fields for both device paths."""
        self._check_namespace_matches_controller(_ADD_LOG)

    def test_ext_log_bad_device_returns_error(self):
        """vs-smart-ext-log fails and names a non-existent device."""
        self._check_bad_device(_EXT_LOG)

    def test_add_log_bad_device_returns_error(self):
        """vs-smart-add-log fails and names a non-existent device."""
        self._check_bad_device(_ADD_LOG)
