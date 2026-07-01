# SPDX-License-Identifier: GPL-2.0-or-later
#
# Plugin test suites — each is gated by both a meson option and the plugin
# being present in selected_plugins.

if get_option('micron-tests') and 'micron' in selected_plugins
    subdir('micron')
endif

if get_option('ocp-tests') and 'ocp' in selected_plugins
    subdir('ocp')
endif
