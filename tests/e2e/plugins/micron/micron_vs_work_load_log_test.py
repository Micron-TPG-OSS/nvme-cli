# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron vs-work-load-log command.

vs-work-load-log reports the drive's workload log.  The command is gated on
the drive model derived from the PCI device ID and prints "Unsupported drive
model for vs-work-load-log command" on any other drive, so the gating
contract is tested alongside the output and the output assertions skip on a
drive that cannot reach them.

The log renders through the shared field-table path: one
"<label> : 0x<hex>" line per field in text mode, or a single top-level key
holding a one-element array of field objects in JSON mode.  The command
declares normal|json and rejects any other format.

Tests in this module verify:
  * The gate message and a non-zero exit status when the model is gated out.
  * The text field table and the JSON field object are both well formed.
  * --output-format=binary and an unrecognised format are both rejected.
  * Error detection for a non-existent device.
"""

from .micron_test import TestMicron

_COMMAND = "vs-work-load-log"

# The top-level JSON key the command emits.
_JSON_KEYS = ("Micron Workload Log:0xC5",)

_UNSUPPORTED_MODEL_MSG = f"Unsupported drive model for {_COMMAND} command"


class TestMicronVsWorkLoadLog(TestMicron):
    """Test suite for the micron vs-work-load-log command."""

    def test_model_gate(self):
        """The command reports and fails when the drive model is gated out."""
        self.check_unsupported_drive_fails(_COMMAND, _UNSUPPORTED_MODEL_MSG)

    def test_text_field_table(self):
        """Text output is a well-formed '<label> : 0x<hex>' field table."""
        self.check_hex_fields_table(_COMMAND)

    def test_json_field_object(self):
        """JSON output reports the workload log as one top-level key."""
        self.check_hex_fields_json(_COMMAND, _JSON_KEYS)

    def test_binary_output_format_rejected(self):
        """--output-format=binary is rejected.

        The format check precedes the model gate, so it runs on any drive.
        """
        self.check_output_format_rejected(_COMMAND, "binary")

    def test_invalid_output_format_returns_error(self):
        """An unrecognised --output-format is rejected."""
        self.check_output_format_rejected(_COMMAND, "notaformat")

    def test_bad_device_returns_error(self):
        """The command fails and names a non-existent device."""
        self.check_bad_device_name(_COMMAND)
