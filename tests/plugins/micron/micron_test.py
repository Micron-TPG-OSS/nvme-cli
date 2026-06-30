# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Micron Technology, Inc.
#
#   Author: Broc Going <broc.going@micron.com>
#
"""Base class for Micron plugin tests."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

from plugin_test import TestPlugin


class TestMicron(TestPlugin):
    """Base class for Micron plugin tests.

    Provides the plugin_name and any Micron-specific helpers.
    """

    plugin_name = "micron"
