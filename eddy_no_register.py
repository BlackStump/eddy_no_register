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

def load_config(config):
    return EddyNoRegister(config)

class EddyNoRegister:
    def __init__(self, config):
        self.printer = config.get_printer()

        # Deregister Z_OFFSET_APPLY_PROBE immediately at config load time
        # before other modules try to register it again. probe_eddy_current
        # registers it in its own __init__ which runs before klippy:connect.
        gcode = self.printer.lookup_object("gcode")
        try:
            gcode.register_command("Z_OFFSET_APPLY_PROBE", None)
            logging.info(
                "eddy_no_register: cleared Z_OFFSET_APPLY_PROBE at config "
                "load — tool_probe_endstop can register it cleanly")
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

        self.printer.register_event_handler(
            "klippy:connect", self._handle_connect)

    def _handle_connect(self):
        probe = self.printer.lookup_object("probe", default=None)
        if probe is None:
            logging.info(
                "eddy_no_register: no 'probe' object found at connect "
                "— nothing to remove")
            return

        probe_class = type(probe).__name__
        if probe_class not in EDDY_CLASS_NAMES:
            logging.info(
                "eddy_no_register: 'probe' is held by '%s', not an eddy "
                "probe — leaving it registered" % (probe_class,))
            return

        # Remove the eddy probe from the global slot.
        # printer.objects is a plain OrderedDict — direct pop is safe here.
        # No hardware communication has happened yet at klippy:connect.
        del self.printer.objects["probe"]
        logging.info(
            "eddy_no_register: removed '%s' from global probe slot — "
            "tool_probe can now register as probe" % (probe_class,))
