# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Base class for OCP plugin tests."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

from plugin_test import TestPlugin


class TestOCP(TestPlugin):
    """Base class for OCP plugin tests.

    Provides the plugin_name and any OCP-specific helpers.
    """

    plugin_name = "ocp"
