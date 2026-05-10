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

        # probe_eddy_current calls printer.add_object('probe', self) in its
        # __init__ AFTER tool_probe_endstop has already claimed the slot.
        # Monkey-patch add_object to silently drop any attempt to register
        # 'probe' if the slot is already taken by a non-eddy object.
        # The patch is permanent but harmless — it only suppresses duplicates
        # for the 'probe' key from eddy class instances.
        original_add_object = self.printer.__class__.add_object

        def patched_add_object(printer_self, name, obj):
            if name == "probe" and name in printer_self.objects:
                existing_class = type(printer_self.objects[name]).__name__
                new_class = type(obj).__name__
                if new_class in EDDY_CLASS_NAMES:
                    logging.info(
                        "eddy_no_register: suppressed add_object('probe') "
                        "from '%s' — slot already held by '%s'"
                        % (new_class, existing_class))
                    return
            original_add_object(printer_self, name, obj)

        self.printer.__class__.add_object = patched_add_object
        logging.info(
            "eddy_no_register: installed add_object patch for 'probe'")
