# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Base class for Micron plugin tests."""

import re

from ..plugin_test import TestPlugin

# The micron plugin gates most commands on the drive model, and sometimes on
# a customer ID in the vendor-specific identify data, so a command can be
# unreachable on an otherwise healthy Micron drive.  When a command fails
# due to an unsupported drive model, the test needs to be skipped.  The
# exit status can't be used to determine this behavior, so detection is by
# message rather than return code.
_UNSUPPORTED_DRIVE_PATTERNS = (
    "Unsupported drive model",
    "not supported for specified drive",
)

_INVALID_LOG_PAGE = "Invalid Log Page"

# Log pages per command that generate Invalid Log Page message if not supported.
_COMMAND_LOG_PAGES = {
    "vs-smart-ext-log": (0xE1, 0xD0),
    "vs-smart-add-log": (0xC0, 0xFB),
    "vs-nand-stats": (0xD0, 0xFB),
    "vs-fw-activate-history": (0xC2,),
    "latency-stats": (0xD0,),
    "latency-logs": (0xD1,),
    "vs-cloud-log": (0xC0,),
    "vs-work-load-log": (0xC5,),
    "vs-vendor-telemetry-log": (0xC6,),
}

# Log ID key pattern for extracting the supported log page IDs
_LID_KEY_RE = re.compile(r'"lid_0x([0-9a-fA-F]+) *"')

# Distinguishes "not probed yet" from a probe that found no Supported Log Pages
# log, since the latter caches as None.
_NOT_PROBED = object()

# generic_structure_parser() renders every field as "0x<hex>", except version
# fields such as "DSSD Spec Version", which are dotted hex ("2.5.0.0").
_FIELD_VALUE_RE = re.compile(
    r"^(?:0x[0-9a-fA-F]+|[0-9a-fA-F]+(?:\.[0-9a-fA-F]+)+)$"
)


class TestMicron(TestPlugin):
    """Base class for Micron plugin tests.

    Provides the plugin_name and any Micron-specific helpers.
    """

    plugin_name = "micron"

    # Shared by every subclass: (command, args) -> unsupported reason or None.
    _support_cache = {}

    # Shared by every subclass: the drive's supported log page IDs, or None
    # when the Supported Log Pages log could not be read.
    _log_pages = _NOT_PROBED

    @staticmethod
    def _extract_error_message(output, pattern):
        """Find the first error message matching the pattern and return the message.

        If the message is formatted as JSON, just the message string is returned
        without the surrounding JSON formatting.
        """
        line = next(line for line in output.splitlines() if pattern in line)
        # A JSON-mode line is '"error":"<message>",'; keep just the message so
        # the reason reads the same whichever output format was used.
        return line.strip().strip(',').strip('"').removeprefix('error":"')

    @staticmethod
    def _lid_list(lids):
        """Format log page IDs for a message, e.g. '0xD0 or 0xFB'."""
        return " or ".join(f"0x{lid:02X}" for lid in lids)

    def supported_log_pages(self):
        """Return the log page IDs the drive advertises.

        Read from the Supported Log Pages log.  Returns None when that log
        cannot be read.  If no supported logs are listed, returns an empty set.
        """
        if TestMicron._log_pages is _NOT_PROBED:
            result = self.run_cmd(
                f"{self.nvme_bin} {self.command('log supported-pages')} "
                f"{self.ctrl} --output-format=json"
            )
            TestMicron._log_pages = frozenset(
                int(lid, 16) for lid in _LID_KEY_RE.findall(result.stdout)
            ) if result.returncode == 0 else None
        return TestMicron._log_pages

    def _log_page_unsupported_reason(self, command, result):
        """Return a reason if the tested log pages are not supported by this drive.

        A return value of None indicates that either no log page errors were
        detected, or that the log pages should be supported and any errors are
        valid failures and should not be skipped.
        """
        if _INVALID_LOG_PAGE not in result.stderr + result.stdout:
            return None

        lids = _COMMAND_LOG_PAGES.get(command)
        if lids is None:
            return None

        supported = self.supported_log_pages()
        if supported is None or supported.intersection(lids):
            return None

        return f"drive does not support log page {self._lid_list(lids)}"

    def _unsupported_reason(self, command, result):
        """Return the reason this drive cannot run command, else None.

        Both streams are searched: in normal mode the message goes to stderr,
        while in JSON mode it is reported as a JSON object on stdout.
        """
        output = result.stderr + result.stdout
        for pattern in _UNSUPPORTED_DRIVE_PATTERNS:
            if pattern in output:
                return self._extract_error_message(output, pattern)
        return self._log_page_unsupported_reason(command, result)

    def _probe_unsupported_reason(self, command, args=""):
        """Test whether the command is supported on this drive. Return reason if unsupported.

        If no cached results exist for the command, runs it and caches the result.
        Returns the unsupported reason, or None when the command is usable.
        """
        key = (command, args)
        if key not in TestMicron._support_cache:
            result = self.run_plugin_cmd(command, args=args)
            TestMicron._support_cache[key] = self._unsupported_reason(command, result)
        return TestMicron._support_cache[key]


    def skip_unless_command_supported(self, command, args=""):
        """Skip the test if the command is not supported on this drive.

        Pre-runs the command to verify support on the current drive.
        If the command is not supported, the test is skipped.  The result
        is cached for future checks on the same command.
        """
        reason = self._probe_unsupported_reason(command, args=args)
        if reason:
            self.skipTest(f"micron {command} unsupported on this drive: {reason}")

    def skip_if_result_unsupported(self, command, result):
        """Skip the current test if the result reports an unsupported drive."""

        reason = self._unsupported_reason(command, result)
        if reason:
            self.skipTest(f"micron {command} unsupported on this drive: {reason}")

    def validate_hex_field_table(self, stdout, context=""):
        """Parse and validate print_log() style text output.

        The shared field-table path emits one "%-40s : %-4s" line per field,
        optionally preceded by a header line with no " : " separator (for
        example "SMART Extended Log:0xE1").  Returns {label: value}.
        """
        where = f" ({context})" if context else ""
        fields = {}
        for line in stdout.splitlines():
            if " : " not in line:
                continue
            label, _, value = line.partition(" : ")
            label, value = label.strip(), value.strip()
            self.assertRegex(
                value, _FIELD_VALUE_RE,
                f"Field {label!r} value is not hex or dotted hex{where}: "
                f"{value!r}",
            )
            self.assertNotIn(
                label, fields,
                f"Duplicate field label {label!r} in output{where}",
            )
            fields[label] = value
        self.assertGreater(
            len(fields), 0,
            f"Expected at least one 'label : value' field line{where}, "
            f"got: {stdout!r}",
        )
        return fields

    def validate_hex_table_object(self, data, allowed_keys, context=""):
        """Validate print_log() style JSON output and return its field object.

        The JSON form is a single top-level key (which varies with the log page
        the drive supports) mapping to a one-element array of field objects.
        """
        where = f" ({context})" if context else ""
        self.assertEqual(
            len(data), 1,
            f"Expected exactly one top-level JSON key{where}, "
            f"got: {list(data.keys())}",
        )
        key = next(iter(data))
        self.assertIn(
            key, allowed_keys,
            f"Unexpected top-level JSON key {key!r}{where}, "
            f"expected one of: {list(allowed_keys)}",
        )

        log_pages = data[key]
        self.assertIsInstance(
            log_pages, list,
            f"Expected {key!r} to hold an array{where}, got: {type(log_pages)}",
        )
        self.assertEqual(
            len(log_pages), 1,
            f"Expected exactly one entry under {key!r}{where}, "
            f"got {len(log_pages)}",
        )

        fields = log_pages[0]
        self.assertIsInstance(
            fields, dict,
            f"Expected an object under {key!r}{where}, got: {type(fields)}",
        )
        self.assertGreater(
            len(fields), 0, f"Expected at least one field under {key!r}{where}",
        )
        for label, value in fields.items():
            self.assertRegex(
                value, _FIELD_VALUE_RE,
                f"Field {label!r} value is not hex or dotted hex{where}: "
                f"{value!r}",
            )
        return fields
