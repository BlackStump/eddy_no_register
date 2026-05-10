# eddy_no_register.py
#
# Prevents [probe_eddy_current] from registering itself as the global
# Klipper probe object. This allows klipper-toolchanger's [tool_probe]
# to own the global probe slot instead, enabling per-tool Z probing
# (e.g. Opto-tap) while the Eddy is used separately for QGL and mesh.
#
# Usage — add to printer.cfg:
#   [eddy_no_register]
#
# Copyright (C) 2025  BlackStump
# This file may be distributed under the terms of the GNU GPLv3 license.

import logging

EDDY_CLASS_NAMES = (
    "EddyCurrentProbe",    # older mainline Klipper
    "PrinterEddyProbe",    # current mainline Klipper
)

# All gcode commands registered by probe.py that conflict with tool_probe.
# probe_eddy_current imports probe.py, so these get registered at config
# load time before tool_probe_endstop can register its own versions.
PROBE_GCODE_COMMANDS = (
    "QUERY_PROBE",
    "PROBE",
    "PROBE_CALIBRATE",
    "PROBE_ACCURACY",
    "Z_OFFSET_APPLY_PROBE",
)

def load_config(config):
    return EddyNoRegister(config)

class EddyNoRegister:
    def __init__(self, config):
        self.printer = config.get_printer()

        # Clear all probe.py gcode commands at config load time so
        # tool_probe_endstop can register its own versions cleanly.
        gcode = self.printer.lookup_object("gcode")
        for cmd in PROBE_GCODE_COMMANDS:
            try:
                gcode.register_command(cmd, None)
                logging.info(
                    "eddy_no_register: cleared gcode command %s" % (cmd,))
            except Exception:
                pass  # not yet registered — nothing to clear

        # probe_eddy_current imports probe.py which registers a 'probe' pin
        # chip via pins.register_chip('probe', self). tool_probe_endstop also
        # tries to register the same chip name — duplicate error results.
        # Evict it here so tool_probe_endstop can register cleanly.
        pins = self.printer.lookup_object("pins")
        try:
            if "probe" in pins.chips:
                del pins.chips["probe"]
                del pins.pin_resolvers["probe"]
                logging.info(
                    "eddy_no_register: cleared 'probe' pin chip — "
                    "tool_probe_endstop can register it cleanly")
        except Exception as e:
            logging.info(
                "eddy_no_register: pin chip clear failed: %s" % (e,))

        # probe_eddy_current also registers itself as the 'probe' printer
        # object via add_object. tool_probe will also try to add_object
        # with the same name — duplicate error results.
        # Evict it here at config load time before tool_probe loads.
        objects = self.printer.objects
        probe_obj = objects.get("probe", None)
        if probe_obj is not None:
            probe_class = type(probe_obj).__name__
            if probe_class in EDDY_CLASS_NAMES:
                del objects["probe"]
                logging.info(
                    "eddy_no_register: cleared 'probe' object at config "
                    "load — tool_probe can register as probe")
            else:
                logging.info(
                    "eddy_no_register: 'probe' object is '%s', not an eddy "
                    "probe — leaving it" % (probe_class,))
        else:
            logging.info(
                "eddy_no_register: no 'probe' object at config load "
                "— nothing to clear")
