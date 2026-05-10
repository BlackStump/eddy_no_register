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
# The Eddy probe is still fully functional for:
#   BED_MESH_CALIBRATE METHOD=scan SCAN_MODE=rapid
#   QUAD_GANTRY_LEVEL METHOD=scan
#   PROBE_EDDY_CURRENT_CALIBRATE CHIP=btt_eddy
#   LDC_CALIBRATE_DRIVE_CURRENT CHIP=btt_eddy
#
# Copyright (C) 2025  <your name>
# This file may be distributed under the terms of the GNU GPLv3 license.

import logging

EDDY_CLASS_NAMES = (
    "EddyCurrentProbe",   # probe_eddy_current.py class name in mainline Klipper
)

def load_config(config):
    return EddyNoRegister(config)

class EddyNoRegister:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.printer.register_event_handler(
            "klippy:connect", self._handle_connect)

    def _handle_connect(self):
        # By the time klippy:connect fires, all config sections have been
        # instantiated. probe_eddy_current will have already called
        # printer.add_object("probe", self) in its __init__.
        # We evict it from the object map so tool_probe can take the slot.
        probe = self.printer.lookup_object("probe", default=None)
        if probe is None:
            # Either eddy didn't register (already fixed upstream) or
            # tool_probe was loaded first — nothing to do.
            logging.info(
                "eddy_no_register: no 'probe' object found at connect "
                "— nothing to remove")
            return

        probe_class = type(probe).__name__
        if probe_class not in EDDY_CLASS_NAMES:
            # Something else owns the probe slot (e.g. tool_probe already won,
            # or user has a [probe] section). Leave it alone.
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

        # probe_eddy_current registers Z_OFFSET_APPLY_PROBE in its __init__
        # (before our eviction runs). probe.py also tries to register it
        # when it sees itself as the global probe object. Deregister it now
        # so tool_probe_endstop can register it cleanly.
        # register_command(cmd, None) is the documented Klipper way to remove
        # a gcode command — deletes from both ready and base handler dicts.
        gcode = self.printer.lookup_object("gcode")
        gcode.register_command("Z_OFFSET_APPLY_PROBE", None)
        logging.info(
            "eddy_no_register: unregistered Z_OFFSET_APPLY_PROBE — "
            "tool_probe_endstop can now register it")
