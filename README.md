# eddy_no_register

A minimal Klipper extra that prevents `[probe_eddy_current]` from registering
as the global Klipper probe object at startup.

## Why

Klipper only allows one global `probe` object. Both `[probe_eddy_current]` and
klipper-toolchanger's `[tool_probe]` try to claim that slot. On a toolchanger
using per-tool probes (e.g. Opto-tap via `[tool_probe]`) alongside a BTT Eddy
Duo for bed mesh and QGL, this causes a startup conflict.

This extra evicts the Eddy from the global slot during `klippy:connect`,
before any hardware communication begins, allowing `[tool_probe]` to register
instead. The Eddy remains fully functional — all its scan, calibration, and
probing commands continue to work by chip name.

## Works with

- BTT Eddy Duo (CAN or USB)
- BTT Eddy (USB)
- Any `[probe_eddy_current]` section in mainline Klipper

## Installation

```bash
# Clone your repo (or this repo) to the Pi
git clone https://github.com/BlackStump/eddy_no_register.git ~/eddy_no_register

# Run the installer
bash ~/eddy_no_register/install.sh
```

Add to `moonraker.conf` for automatic updates:

```ini
[update_manager eddy_no_register]
type: git_repo
path: ~/eddy_no_register
origin: https://github.com/YOURNAME/eddy_no_register.git
primary_branch: main
managed_services: klipper
```

## Configuration

Add a single line to `printer.cfg`:

```ini
[eddy_no_register]
```

### Full example for toolchanger + Eddy Duo + Opto-tap

```ini
# Z homing — owned by tool_probe via klipper-toolchanger
[stepper_z]
endstop_pin: probe:z_virtual_endstop

# Opto-tap on T0 — detection pin + probe pin are the same EBB pin
[tool T0]
tool_number: 0
extruder: extruder
fan: fan
detection_pin: ^toolhead0:OPTO_TAP_PIN
probe: tool_probe T0

[tool_probe T0]
pin: ^toolhead0:OPTO_TAP_PIN
z_offset: 0.0
speed: 5.0
samples: 3
samples_result: median
sample_retract_dist: 2.0
samples_tolerance: 0.02
samples_tolerance_retries: 3

# Eddy Duo on CAN — independent node, used only for QGL and mesh
[mcu eddy]
canbus_uuid: YOUR_EDDY_UUID

[probe_eddy_current btt_eddy]
sensor_type: ldc1612
i2c_mcu: eddy
i2c_bus: i2c0f
x_offset: 0       # set for your mount
y_offset: 0       # set for your mount
data_rate: 500

# This prevents the Eddy from conflicting with tool_probe
[eddy_no_register]
```

Then run QGL and mesh via:

```gcode
QUAD_GANTRY_LEVEL METHOD=scan
BED_MESH_CALIBRATE SCAN_MODE=rapid METHOD=scan
```

## How it works

At `klippy:connect` (after all modules initialise, before any hardware
communication), the extra checks whether the global `probe` object is an Eddy
probe. If it is, it removes it from `printer.objects`, freeing the slot for
`[tool_probe]` to claim during its own connect phase.

The Eddy's G-code commands (`LDC_CALIBRATE_DRIVE_CURRENT`,
`PROBE_EDDY_CURRENT_CALIBRATE`, `BED_MESH_CALIBRATE METHOD=scan`, etc.) are
registered against the chip name, not the global probe slot, so they are
unaffected.

## Klipper updates

Klipper's own files are never modified. Updates to mainline Klipper via
Moonraker will not affect this extra. The only scenario requiring attention
is if mainline Klipper renames the `EddyCurrentProbe` class — in that case,
update the `EDDY_CLASS_NAMES` tuple in `klipper/extras/eddy_no_register.py`
and Moonraker will deploy the fix automatically on next update.

## License

GNU GPLv3 — same as Klipper.
