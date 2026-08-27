# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron vs-nand-stats command.

vs-nand-stats reports NAND wear and failure counters.  Three log pages can
back it depending on the drive: 0xC0 on a Hyperscale boot SSD, 0xFB where the
vendor-specific health log exists, and 0xD0 otherwise.  Each renders as a
"<label> : 0x<hex>" text table or as a single top-level JSON key holding a
one-element array of field objects.

The 0xFB variant reports the vendor health log fields followed by the seven
0xD0 derived counters, so its field set is a superset of the 0xD0 one.

Tests in this module verify:
  * The text field table and the JSON field object are both well formed.
  * The JSON top-level key names one of the three supported log pages.
  * The text and JSON field sets and values are identical.
  * The field labels defined for the reported log page are present.
  * --output-format=binary and an unrecognised format are both rejected.
  * The controller and namespace paths report the same fields.
  * Error detection for a non-existent device.
"""

import json

from .micron_test import TestMicron

_COMMAND = "vs-nand-stats"

# One key per log page vs-nand-stats can report.
_JSON_KEYS = (
    "Extended Smart Log Page : 0xC0",
    "Extended Smart Log Page : 0xFB",
    "Extended Smart Log Page : 0xD0",
)

# The seven derived counters the 0xD0 path reports, which the 0xFB path
# appends to the vendor health log fields.
_D0_LABELS = (
    "NAND Writes (Bytes Written)",
    "Program Failure Count",
    "Erase Failures",
    "Bad Block Count",
    "NAND XOR/RAID Recovery Trigger Events",
    "NSZE Change Supported",
    "Number of NSZE Modifications",
)

_REQUIRED_LABELS = {
    "Extended Smart Log Page : 0xD0": _D0_LABELS,
    "Extended Smart Log Page : 0xFB": _D0_LABELS + (
        "Physical Media Units Written - TLC",
        "Physical Media Units Written - SLC",
        "Raw Bad User NAND Block Count",
        "Log Page GUID",
    ),
    "Extended Smart Log Page : 0xC0": (
        "Physical Media Units Written - TLC",
        "Physical Media Units Written - SLC",
        "Bad User NAND Block Count (Raw)",
        "Endurance Estimate",
        "Boot SSD Spec Version",
    ),
}


class TestMicronVsNandStats(TestMicron):
    """Test suite for the micron vs-nand-stats plugin command."""

    def _run_nand_stats(self, device=None, args=""):
        """Run vs-nand-stats, skipping if the drive cannot serve the log."""
        result = self.run_plugin_cmd(_COMMAND, device=device, args=args)
        self.skip_if_result_unsupported(_COMMAND, result)
        self.assertEqual(
            result.returncode, 0,
            f"micron {_COMMAND} failed: rc={result.returncode}, "
            f"stderr={result.stderr!r}",
        )
        return result

    def _nand_stats_json(self, device=None):
        """Return the parsed JSON output of vs-nand-stats."""
        result = self._run_nand_stats(device=device, args="--output-format=json")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            self.fail(
                f"micron {_COMMAND} --output-format=json produced invalid JSON: "
                f"{exc}\nstdout={result.stdout!r}"
            )

    def test_text_field_table(self):
        """Text output is a well-formed '<label> : 0x<hex>' field table."""
        result = self._run_nand_stats()

        self.validate_hex_field_table(result.stdout, _COMMAND)

    def test_json_field_object(self):
        """JSON output holds one known log-page key with a field object."""
        self.validate_hex_table_object(self._nand_stats_json(), _JSON_KEYS, _COMMAND)

    def test_text_and_json_fields_match(self):
        """The text and JSON forms report identical fields and values."""
        text_fields = self.validate_hex_field_table(self._run_nand_stats().stdout, _COMMAND)
        json_fields = self.validate_hex_table_object(
            self._nand_stats_json(), _JSON_KEYS, _COMMAND
        )

        self.assertEqual(
            set(text_fields), set(json_fields),
            f"micron {_COMMAND} text and JSON field sets differ; "
            f"text-only={set(text_fields) - set(json_fields)}, "
            f"JSON-only={set(json_fields) - set(text_fields)}",
        )
        for label, value in json_fields.items():
            self.assertEqual(
                text_fields[label], value,
                f"micron {_COMMAND} field {label!r} differs between text "
                f"({text_fields[label]!r}) and JSON ({value!r})",
            )

    def test_required_labels_present(self):
        """Every field label defined for the reported log page is present."""
        data = self._nand_stats_json()
        key = next(iter(data))
        fields = self.validate_hex_table_object(data, _JSON_KEYS, _COMMAND)

        for label in _REQUIRED_LABELS[key]:
            self.assertIn(
                label, fields,
                f"Expected field {label!r} for log page {key!r}, "
                f"got: {list(fields)}",
            )

    def test_binary_output_format_rejected(self):
        """--output-format=binary is rejected; the command emits text or JSON."""
        result = self.run_plugin_cmd(_COMMAND, args="--output-format=binary")

        self.assertNotEqual(
            result.returncode, 0,
            f"Expected micron {_COMMAND} to reject binary output",
        )
        self.assertIn(
            "Invalid output format", result.stderr,
            f"Expected 'Invalid output format' in stderr, got: {result.stderr!r}",
        )

    def test_invalid_output_format_returns_error(self):
        """An unrecognised --output-format is rejected."""
        result = self.run_plugin_cmd(_COMMAND, args="--output-format=notaformat")

        self.assertNotEqual(
            result.returncode, 0,
            f"Expected micron {_COMMAND} to reject an invalid --output-format",
        )
        self.assertIn(
            "Invalid output format", result.stderr,
            f"Expected 'Invalid output format' in stderr, got: {result.stderr!r}",
        )

    def test_namespace_path_matches_controller(self):
        """The namespace path reports the same fields as the controller path."""
        ctrl_fields = self.validate_hex_table_object(
            self._nand_stats_json(device=self.ctrl), _JSON_KEYS, self.ctrl
        )
        ns_fields = self.validate_hex_table_object(
            self._nand_stats_json(device=self.ns1), _JSON_KEYS, self.ns1
        )

        self.assertEqual(
            set(ctrl_fields), set(ns_fields),
            f"micron {_COMMAND} field set differs between {self.ctrl} and "
            f"{self.ns1}",
        )

    def test_bad_device_returns_error(self):
        """A non-existent device fails with the device path in the message."""
        device = "/dev/nvme-nonexistent-test-device"
        result = self.run_plugin_cmd(_COMMAND, device=device)

        self.assertNotEqual(
            result.returncode, 0,
            "Expected non-zero exit code for a non-existent device",
        )
        self.assertIn(
            device, result.stderr,
            f"Expected {device!r} in stderr, got: {result.stderr!r}",
        )
