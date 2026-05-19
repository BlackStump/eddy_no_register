# eddy_no_register.py
#
# Prevents [probe_eddy_current] from registering itself as the global
# Klipper probe object. This allows klipper-toolchanger's [tool_probe]
# to own the global probe slot instead, enabling per-tool Z probing
# (e.g. Opto-tap) while the Eddy is used separately for QGL and mesh.
#
# Usage — add to printer.cfg:
# [eddy_no_register]
#
# Copyright (C) 2025 BlackStump
# This file may be distributed under the terms of the GNU GPLv3 license.

import logging

EDDY_CLASS_NAMES = (
    "EddyCurrentProbe",   # older mainline Klipper
    "PrinterEddyProbe",   # current mainline Klipper
)

def load_config(config):
    return EddyNoRegister(config)

class EddyNoRegister:
    def __init__(self, config):
        self.printer = config.get_printer()
        # Register at BOTH connect and ready.
        # connect: evicts Eddy before tool_probe connects (single-tool case)
        # ready:   re-checks after all tools have resolved (multi-tool case)
        self.printer.register_event_handler(
            "klippy:connect", self._handle_connect)
        self.printer.register_event_handler(
            "klippy:ready", self._handle_ready)

    def _evict_eddy(self, phase):
        probe = self.printer.lookup_object("probe", default=None)
        if probe is None:
            logging.info(
                "eddy_no_register [%s]: no 'probe' object found "
                "— nothing to remove" % phase)
            return False

        probe_class = type(probe).__name__
        if probe_class not in EDDY_CLASS_NAMES:
            logging.info(
                "eddy_no_register [%s]: 'probe' is held by '%s', not an eddy "
                "probe — leaving it registered" % (phase, probe_class))
            return False

        del self.printer.objects["probe"]
        logging.info(
            "eddy_no_register [%s]: removed '%s' from global probe slot — "
            "tool_probe can now register as probe" % (phase, probe_class))

        gcode = self.printer.lookup_object("gcode")
        try:
            gcode.register_command("Z_OFFSET_APPLY_PROBE", None)
            logging.info(
                "eddy_no_register [%s]: unregistered Z_OFFSET_APPLY_PROBE"
                % phase)
        except Exception:
            pass  # may already be gone or not registered yet

        return True

    def _handle_connect(self):
        self._evict_eddy("connect")

    def _handle_ready(self):
        # At klippy:ready, all tools have resolved their active probe.
        # If Eddy somehow re-claimed the slot, evict it again.
        evicted = self._evict_eddy("ready")
        if evicted:
            # After ready, tool_probe won't re-register itself automatically.
            # We need to find the active tool's tool_probe and install it.
            self._install_active_tool_probe()

    def _install_active_tool_probe(self):
        # Ask toolchanger for the active tool, then register its tool_probe
        # as the global probe object so homing works correctly.
        toolchanger = self.printer.lookup_object("toolchanger", default=None)
        if toolchanger is None:
            logging.info(
                "eddy_no_register: no toolchanger found, "
                "cannot restore tool_probe after ready-phase eviction")
            return

        active_tool = None
        try:
            active_tool = toolchanger.get_selected_tool()
        except Exception:
            pass

        if active_tool is None:
            # No tool selected — try T0 as fallback
            active_tool = self.printer.lookup_object("tool 0", default=None)

        if active_tool is None:
            logging.info(
                "eddy_no_register: no active tool found at ready phase")
            return

        tool_probe_name = "tool_probe %s" % (
            getattr(active_tool, 'tool_number', 0),)
        tool_probe = self.printer.lookup_object(tool_probe_name, default=None)

        if tool_probe is None:
            logging.info(
                "eddy_no_register: could not find '%s'" % tool_probe_name)
            return

        self.printer.objects["probe"] = tool_probe
        logging.info(
            "eddy_no_register [ready]: installed '%s' as global probe"
            % tool_probe_name)
