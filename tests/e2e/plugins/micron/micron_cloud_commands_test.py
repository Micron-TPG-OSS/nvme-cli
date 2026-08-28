# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron cloud SSD commands.

vs-cloud-log, vs-device-waf and cloud-boot-SSD-version all report data from
the vendor cloud health log, and all three are reachable only on a drive
whose customer ID in the vendor-specific identify data marks it as a cloud
SSD; otherwise they print "<command> option is not supported for specified
drive".  vs-cloud-log is additionally gated on the drive model derived from
the PCI device ID, and prints "Unsupported drive model for <command>" when
that gate rejects the drive.

vs-cloud-log renders the log as a field table in normal or JSON form.
vs-device-waf and cloud-boot-SSD-version each derive a single value from it
and print one line of text, declaring no output formats at all, so a format
flag changes nothing rather than being rejected.

On unsupported drives, the gating contract is the primary thing under test.

Tests in this module verify:
  * The exact gate message and a non-zero exit status when a gate rejects
    the drive.
  * The field table of vs-cloud-log in both text and JSON form.
  * The single-line output of vs-device-waf and cloud-boot-SSD-version.
  * --output-format handling for each group.
  * Error detection for a non-existent device.
"""

import re

from .micron_test import TestMicron

_CLOUD_LOG = "vs-cloud-log"
_DEVICE_WAF = "vs-device-waf"
_BOOT_VERSION = "cloud-boot-SSD-version"

# The top-level JSON key vs-cloud-log emits.
_JSON_KEYS = ("OCP Hyperscale Cloud Health Log: 0xC0",)

# The model gate message ends in "command", which vs-cloud-log misspells, so
# only the prefix up to the command name is matched.
_UNSUPPORTED_MODEL_MSG = f"Unsupported drive model for {_CLOUD_LOG}"
_UNSUPPORTED_DRIVE_MSG = "{command} option is not supported for specified drive"

_WAF_RE = re.compile(r"^Write Amplification Factor \d+$")
_BOOT_VERSION_RE = re.compile(r"^HyperScale Boot Version Spec\.[0-9a-f]+\.[0-9a-f]+$")


class TestMicronCloudCommands(TestMicron):
    """Test suite for the micron cloud SSD commands."""

    def _check_customer_id_gate(self, command):
        """A cloud command must name itself and fail when the customer ID differs."""
        self.check_unsupported_drive_fails(
            command, _UNSUPPORTED_DRIVE_MSG.format(command=command)
        )

    def _check_output_format_ignored(self, command):
        """A command declaring no output formats must ignore --output-format."""
        baseline = self.run_plugin_cmd(command)
        for value in ("binary", "notaformat"):
            result = self.run_plugin_cmd(command, args=f"--output-format={value}")

            self.assertNotIn(
                "Invalid output format", result.stderr + result.stdout,
                f"micron {command} does not validate --output-format, but "
                f"rejected {value!r}",
            )
            self.assertEqual(
                result.stdout, baseline.stdout,
                f"micron {command} output changed for --output-format={value}: "
                f"{result.stdout!r} != {baseline.stdout!r}",
            )

    def test_cloud_log_model_gate(self):
        """vs-cloud-log reports and fails when the drive model is gated out."""
        self.check_unsupported_drive_fails(_CLOUD_LOG, _UNSUPPORTED_MODEL_MSG)

    def test_cloud_log_customer_id_gate(self):
        """vs-cloud-log fails on its customer-ID branch.

        Reachable only on a drive that passes the model gate first.
        """
        self._check_customer_id_gate(_CLOUD_LOG)

    def test_device_waf_customer_id_gate(self):
        """vs-device-waf fails on its customer-ID branch."""
        self._check_customer_id_gate(_DEVICE_WAF)

    def test_cloud_boot_ssd_version_customer_id_gate(self):
        """cloud-boot-SSD-version fails on its customer-ID branch."""
        self._check_customer_id_gate(_BOOT_VERSION)

    def test_cloud_log_text_field_table(self):
        """vs-cloud-log prints a well-formed '<label> : 0x<hex>' table."""
        self.check_hex_fields_table(_CLOUD_LOG)

    def test_cloud_log_json_field_object(self):
        """vs-cloud-log reports the cloud health log as one JSON key."""
        self.check_hex_fields_json(_CLOUD_LOG, _JSON_KEYS)

    def test_device_waf_prints_factor(self):
        """vs-device-waf prints a single 'Write Amplification Factor <N>' line."""
        result = self.run_supported_cmd(_DEVICE_WAF)

        self.assertRegex(
            result.stdout.strip(), _WAF_RE,
            f"Unexpected vs-device-waf output: {result.stdout!r}",
        )

    def test_cloud_boot_ssd_version_prints_spec(self):
        """cloud-boot-SSD-version prints 'HyperScale Boot Version Spec.<x>.<y>'."""
        result = self.run_supported_cmd(_BOOT_VERSION)

        self.assertRegex(
            result.stdout.strip(), _BOOT_VERSION_RE,
            f"Unexpected cloud-boot-SSD-version output: {result.stdout!r}",
        )

    def test_cloud_log_binary_output_format_rejected(self):
        """vs-cloud-log rejects --output-format=binary.

        The format check precedes both gates, so it runs on any drive.
        """
        self.check_output_format_rejected(_CLOUD_LOG, "binary")

    def test_cloud_log_invalid_output_format_returns_error(self):
        """vs-cloud-log rejects an unrecognised --output-format."""
        self.check_output_format_rejected(_CLOUD_LOG, "notaformat")

    def test_device_waf_ignores_output_format(self):
        """vs-device-waf prints the same text whatever --output-format is given."""
        self._check_output_format_ignored(_DEVICE_WAF)

    def test_cloud_boot_ssd_version_ignores_output_format(self):
        """cloud-boot-SSD-version ignores --output-format entirely."""
        self._check_output_format_ignored(_BOOT_VERSION)

    def test_cloud_log_bad_device_returns_error(self):
        """vs-cloud-log fails and names a non-existent device."""
        self.check_bad_device_name(_CLOUD_LOG)

    def test_device_waf_bad_device_returns_error(self):
        """vs-device-waf fails and names a non-existent device."""
        self.check_bad_device_name(_DEVICE_WAF)

    def test_cloud_boot_ssd_version_bad_device_returns_error(self):
        """cloud-boot-SSD-version fails and names a non-existent device."""
        self.check_bad_device_name(_BOOT_VERSION)
