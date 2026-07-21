# SPDX-License-Identifier: GPL-2.0-or-later
#
# This file is part of nvme-cli.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
"""
NVMe Telemetry Log Testcase :-

    Exercises the transfer-size controls (--xfer-len / --xfer-mdts) added to
    'nvme telemetry-log', verifying that:
      - the default (no flag) still produces a valid log,
      - an explicit --xfer-len assembles a log with the same size and layout,
      - --xfer-mdts assembles a log with the same size and layout,
      - force-4k clamps the transfer but assembles the same size and layout,
      - invalid / conflicting options are rejected.

    The transfer-size controls only change how the log is chunked over
    successive Get Log Page commands; they must not change the size or the
    layout descriptors of the assembled log.  They are NOT expected to yield
    byte-identical content: the default host-generate path regenerates a fresh
    telemetry log on every invocation (the Generation Number in the header
    increments each call), and the telemetry data areas capture live
    controller state that changes between reads.  The tests therefore compare
    the stable header invariants (total size, log page identifier, and the
    Data Area Last Block boundaries) rather than raw bytes.

    All cases hit the device configured in tests/config.json.
"""

import os
import struct

from nvme_test import TestNVMe, to_decimal

# NVMe Telemetry Host-Initiated log page identifier (Figure: Get Log Page).
NVME_LOG_LID_TELEMETRY_HOST = 0x07


class TestNVMeTelemetryLogCmd(TestNVMe):

    """
    Represents NVMe Telemetry Log test.
    """

    def setUp(self):
        """ Pre Section for TestNVMeTelemetryLogCmd. """
        super().setUp()
        # Host-Initiated telemetry is optional; LPA bit 3 (0x08) in Identify
        # Controller advertises support.  Skip cleanly when unsupported so the
        # device I/O based cases don't fail on drives that lack telemetry.
        lpa = to_decimal(self.get_id_ctrl_field_value("lpa"))
        if not (lpa & (1 << 3)):
            self.skipTest("Host-Initiated telemetry log (LPA bit 3) not supported")
        self.setup_log_dir(self.__class__.__name__)
        self.output_file = os.path.join(self.test_log_dir, "telemetry.bin")

    def tearDown(self):
        """ Post Section: remove generated files and call super's destructor. """
        super().tearDown()

    def _telemetry_cmd(self, out_file, *extra_args, set_options=None):
        """ Build a telemetry-log command string.
            - set_options: optional string passed to a leading --set-options.
        """
        prefix = f"{self.nvme_bin}"
        if set_options:
            prefix += f" --set-options {set_options}"
        args = " ".join(extra_args)
        return f"{prefix} telemetry-log {self.ctrl} " \
               f"--output-file={out_file} {args}".strip()

    def _run_ok(self, out_file, *extra_args, set_options=None):
        """ Run telemetry-log expecting success and a non-empty output file. """
        cmd = self._telemetry_cmd(out_file, *extra_args, set_options=set_options)
        self.assertEqual(self.exec_cmd(cmd), 0,
                         f"ERROR : telemetry-log failed: {cmd}")
        self.assertTrue(os.path.exists(out_file) and os.path.getsize(out_file) > 0,
                        f"ERROR : empty telemetry output for: {cmd}")

    def _run_fail(self, out_file, *extra_args):
        """ Run telemetry-log expecting a nonzero exit (validation failure). """
        cmd = self._telemetry_cmd(out_file, *extra_args)
        self.assertNotEqual(self.exec_cmd(cmd), 0,
                            f"ERROR : telemetry-log unexpectedly succeeded: {cmd}")

    def _read(self, path):
        with open(path, "rb") as f:
            return f.read()

    def _layout(self, path):
        """ Parse the stable layout descriptors from a telemetry log header.

            Returns a tuple that must be invariant across transfer-size
            options for a given controller: the total assembled size, the
            log page identifier, and the Data Area Last Block boundaries
            (dalb1..dalb4).  These describe the shape of the log; the data
            area payload itself is volatile and deliberately excluded.

            Layout of struct nvme_telemetry_log:
              off 0      lpi   (u8)   log page identifier
              off 11..12 dalb1 (le16)
              off 13..14 dalb2 (le16)
              off 15..16 dalb3 (le16)
              off 18..21 dalb4 (le32)
        """
        data = self._read(path)
        self.assertGreaterEqual(len(data), 22,
                                f"ERROR : telemetry log too short to parse header: {path}")
        lpi = data[0]
        dalb1, dalb2, dalb3 = struct.unpack_from("<HHH", data, 11)
        dalb4 = struct.unpack_from("<I", data, 18)[0]
        return (len(data), lpi, dalb1, dalb2, dalb3, dalb4)

    def _assert_same_layout(self, base, alt, what):
        """ Assert two logs share size and layout descriptors (not content). """
        base_layout = self._layout(base)
        alt_layout = self._layout(alt)
        self.assertEqual(base_layout[1], NVME_LOG_LID_TELEMETRY_HOST,
                         f"ERROR : unexpected log page identifier in {base}")
        self.assertEqual(base_layout, alt_layout,
                         f"ERROR : {what} changed the telemetry log size/layout "
                         f"(default={base_layout}, alt={alt_layout})")

    def test_default(self):
        """ Baseline: default transfer produces a valid, non-empty log. """
        self._run_ok(self.output_file)
        size, lpi = self._layout(self.output_file)[:2]
        self.assertEqual(lpi, NVME_LOG_LID_TELEMETRY_HOST,
                         "ERROR : default log is not a Telemetry Host log page")
        self.assertGreater(size, 0, "ERROR : default telemetry log is empty")

    def test_xfer_len_matches_default(self):
        """ Explicit --xfer-len assembles a log of the same size and layout. """
        base = self.output_file
        alt = os.path.join(self.test_log_dir, "telemetry_xfer.bin")
        self._run_ok(base)
        self._run_ok(alt, "--xfer-len=8192")
        self._assert_same_layout(base, alt, "--xfer-len")

    def test_xfer_mdts_matches_default(self):
        """ --xfer-mdts assembles a log of the same size and layout. """
        base = self.output_file
        alt = os.path.join(self.test_log_dir, "telemetry_mdts.bin")
        self._run_ok(base)
        self._run_ok(alt, "--xfer-mdts")
        self._assert_same_layout(base, alt, "--xfer-mdts")

    def test_force_4k_override(self):
        """ force-4k clamps the transfer but assembles the same size and layout. """
        base = self.output_file
        alt = os.path.join(self.test_log_dir, "telemetry_4k.bin")
        self._run_ok(base)
        self._run_ok(alt, "--xfer-mdts", set_options="force-4k=1")
        self._assert_same_layout(base, alt, "force-4k")

    def test_xfer_len_not_multiple_of_4096(self):
        """ A --xfer-len that is not a multiple of 4096 is rejected. """
        self._run_fail(self.output_file, "--xfer-len=4097")

    def test_mutual_exclusion(self):
        """ --xfer-len and --xfer-mdts together are rejected. """
        self._run_fail(self.output_file, "--xfer-len=8192", "--xfer-mdts")
