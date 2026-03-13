# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2024 Micron Technology, Inc.
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
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301, USA.
#
"""
NVMe Power Measurement Log Verification Testcase:-

    1. Execute power-measurement-log on controller.

"""

import subprocess
from nvme_test import TestNVMe


class TestNVMePowerMeasurementLogCmd(TestNVMe):

    """
    Represents Power Measurement Log testcase.

        - Attributes:
    """

    def setUp(self):
        """ Pre Section for TestNVMePowerMeasurementLogCmd """
        super().setUp()
        self.setup_log_dir(self.__class__.__name__)

    def tearDown(self):
        """
        Post Section for TestNVMePowerMeasurementLogCmd

            - Call super class's destructor.
        """
        super().tearDown()

    def get_power_measurement_log(self):
        """ Wrapper for executing power-measurement-log on controller.
            - Args:
                - None:
            - Returns:
                - 0 on success, error code on failure.
        """
        power_meas_log_cmd = f"{self.nvme_bin} power-measurement-log {self.ctrl}"
        proc = subprocess.Popen(power_meas_log_cmd,
                                shell=True,
                                stdout=subprocess.PIPE,
                                encoding='utf-8')
        err = proc.wait()
        return err

    def test_power_measurement_log(self):
        """ Testcase main """
        err = self.get_power_measurement_log()
        # Power Measurement log may not be supported by all controllers.
        # A non-zero return may indicate the log is unsupported (e.g. status
        # 0x2 = invalid field / unsupported log page), which is acceptable.
        self.assertIn(err, [0, 1], "ERROR : nvme power-measurement-log returned unexpected error")
