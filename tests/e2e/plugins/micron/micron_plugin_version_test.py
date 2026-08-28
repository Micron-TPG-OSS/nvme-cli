# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Tests for the micron plugin-version and cloud-SSD-plugin-version commands.

Both commands print a static version string built from the plugin's version
macros and perform no device I/O.  They are registered with .no_device = true,
so they run without a device argument and ignore one if given.

Tests in this module verify:
  * The exact version string and a zero exit status for both commands.
  * The cloud SSD version is the major.minor prefix of the plugin version,
    since both are built from the same version macros.
  * A device argument is accepted and does not change the output.
  * The --help usage line advertises no <device> operand.
  * JSON output wraps the same string in a "result" object.
"""

import re

from ..plugin_test import NO_DEVICE
from .micron_test import TestMicron

_PLUGIN_VERSION = "plugin-version"
_CLOUD_VERSION = "cloud-SSD-plugin-version"

_PLUGIN_VERSION_RE = re.compile(r"^nvme-cli Micron plugin version: (\d+)\.(\d+)\.(\d+)$")
_CLOUD_VERSION_RE = re.compile(r"^nvme-cli Micron cloud SSD plugin version: (\d+)\.(\d+)$")


class TestMicronPluginVersion(TestMicron):
    """Test suite for the micron plugin version commands."""

    def _run_version(self, command, device=NO_DEVICE, args=""):
        """Run a version command with no device argument by default."""
        return self.run_plugin_cmd_check(command, device=device, args=args)

    def _check_device_argument_ignored(self, command):
        """A device argument must not change the command's output."""
        without = self._run_version(command).stdout
        with_device = self._run_version(command, device=self.ctrl).stdout

        self.assertEqual(
            with_device, without,
            f"micron {command} output changed when a device was supplied: "
            f"{with_device!r} != {without!r}",
        )

    def _check_help_omits_device(self, command):
        """--help must advertise no <device> operand."""
        result = self.run_plugin_cmd(command, device=NO_DEVICE, args="--help")
        output = result.stdout + result.stderr

        self.assertRegex(
            output, rf"Usage: nvme micron {command} \[OPTIONS\]",
            f"Expected a device-free usage line for {command}, got: {output!r}",
        )
        self.assertNotIn(
            "<device>", output,
            f"micron {command} usage should not take a device: {output!r}",
        )

    def _check_json_wraps_text(self, command):
        """JSON output must report the text output under a "result" key."""
        text = self._run_version(command).stdout.strip()
        result = self._run_version(command, args="--output-format=json")
        data = self.parse_json_output(
            result.stdout, f"micron {command} --output-format=json"
        )

        self.assertEqual(
            data, {"result": text},
            f"Expected {{'result': {text!r}}}, got: {data!r}",
        )

    def test_plugin_version_string(self):
        """plugin-version prints 'nvme-cli Micron plugin version: <x>.<y>.<z>'."""
        result = self._run_version(_PLUGIN_VERSION)

        self.assertRegex(
            result.stdout.strip(), _PLUGIN_VERSION_RE,
            f"Unexpected plugin-version output: {result.stdout!r}",
        )

    def test_cloud_plugin_version_string(self):
        """cloud-SSD-plugin-version prints its own version line."""
        result = self._run_version(_CLOUD_VERSION)

        self.assertRegex(
            result.stdout.strip(), _CLOUD_VERSION_RE,
            f"Unexpected cloud-SSD-plugin-version output: {result.stdout!r}",
        )

    def test_cloud_version_matches_plugin_version_prefix(self):
        """The cloud SSD version is the major.minor prefix of the plugin version."""
        plugin = _PLUGIN_VERSION_RE.match(
            self._run_version(_PLUGIN_VERSION).stdout.strip()
        )
        cloud = _CLOUD_VERSION_RE.match(
            self._run_version(_CLOUD_VERSION).stdout.strip()
        )
        self.assertIsNotNone(plugin)
        self.assertIsNotNone(cloud)

        self.assertEqual(
            cloud.group(1, 2), plugin.group(1, 2),
            f"cloud SSD version {cloud.group(0)!r} does not share the "
            f"major.minor of {plugin.group(0)!r}",
        )

    def test_plugin_version_ignores_device_argument(self):
        """plugin-version accepts a device argument without using it."""
        self._check_device_argument_ignored(_PLUGIN_VERSION)

    def test_cloud_plugin_version_ignores_device_argument(self):
        """cloud-SSD-plugin-version accepts a device argument without using it."""
        self._check_device_argument_ignored(_CLOUD_VERSION)

    def test_plugin_version_help_omits_device_operand(self):
        """plugin-version --help shows no <device> operand."""
        self._check_help_omits_device(_PLUGIN_VERSION)

    def test_cloud_plugin_version_help_omits_device_operand(self):
        """cloud-SSD-plugin-version --help shows no <device> operand."""
        self._check_help_omits_device(_CLOUD_VERSION)

    def test_plugin_version_json_output(self):
        """plugin-version JSON output wraps the text output in "result"."""
        self._check_json_wraps_text(_PLUGIN_VERSION)

    def test_cloud_plugin_version_json_output(self):
        """cloud-SSD-plugin-version JSON output wraps the text output in "result"."""
        self._check_json_wraps_text(_CLOUD_VERSION)
