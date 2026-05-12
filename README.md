# eddy_no_register

A shameless use of Claude AI

A Klipper extra and installer that enables **dual probe support** for toolchanger
setups — specifically allowing a per-tool probe (e.g. Opto-tap via
`[tool_probe]`) to own the global Klipper probe slot for Z homing, while a
BTT Eddy Duo or similar eddy current probe handles bed mesh and QGL.

## The Problem

Klipper only allows one global `probe` object. On a toolchanger using
[klipper-toolchanger](https://github.com/jwellman80/klipper-toolchanger-easy):

- `[tool_probe]` needs to own the global `probe` slot for per-tool Z homing
- `[probe_eddy_current]` also tries to claim the global `probe` slot
- Both also register the `probe` pin chip and probe-related G-code commands

This causes startup conflicts that prevent Klipper from loading.

Additionally, mainline Klipper's `[bed_mesh]` and `[quad_gantry_level]` always
use the global `probe` object — there is no way to direct them to a named probe
without modifying Klipper.

## The Solution

This repo provides two components that work together:

### 1. `eddy_no_register` Klipper Extra

A small Klipper module that resolves all startup conflicts between
`[probe_eddy_current]` and `[tool_probe]` by:

- Clearing probe-related G-code commands registered by `probe.py` at config
  load time, before `tool_probe_endstop` tries to register its own
- Evicting the `probe` pin chip registered by `probe.py`
- Suppressing `probe_eddy_current`'s attempt to claim the global probe object
  via a monkey-patch on `printer.add_object`

The Eddy probe remains fully functional for all its own commands:
- `BED_MESH_CALIBRATE METHOD=scan`
- `QUAD_GANTRY_LEVEL METHOD=scan`
- `PROBE_EDDY_CURRENT_CALIBRATE CHIP=<name>`
- `LDC_CALIBRATE_DRIVE_CURRENT CHIP=<name>`

### 2. `toolchanger-multi-probe` Klipper Patches

Three minimal targeted changes to Klipper that add a `probe:` config directive
to `[bed_mesh]` and `[quad_gantry_level]`, allowing them to use a named probe
object directly instead of always falling back to the global `probe` slot.

**Files changed (3 files, ~7 lines total):**
- `klippy/extras/probe.py` — adds `self.probe_name` to `ProbePointsHelper`
- `klippy/extras/quad_gantry_level.py` — reads `probe:` config option
- `klippy/extras/bed_mesh.py` — reads `probe:` config option, uses named probe
  for scan mode detection

Changes are committed to a separate `toolchanger-multi-probe` branch, keeping
mainline Klipper's `master` clean and making future rebases straightforward.

## Requirements

- Klipper (mainline)
- [klipper-toolchanger](https://github.com/jwellman80/klipper-toolchanger-easy)
- BTT Eddy Duo (CAN or USB) or similar `[probe_eddy_current]` probe
- Per-tool probe (e.g. Opto-tap) configured via `[tool_probe]`

## Installation

```bash
git clone https://github.com/BlackStump/eddy_no_register.git ~/eddy_no_register
bash ~/eddy_no_register/install.sh
```

The installer presents a menu:

```
╔══════════════════════════════════════════════════════╗
║       eddy_no_register + toolchanger-multi-probe     ║
║                     Installer                        ║
╚══════════════════════════════════════════════════════╝

  1) Install eddy_no_register only
  2) Install toolchanger-multi-probe Klipper patches only
  3) Install both (recommended)
  4) Uninstall eddy_no_register
  5) Rollback Klipper patches (switch back to master)
  6) Exit
```

**Option 3 (recommended)** installs both components and optionally pushes the
Klipper patches to your own GitHub fork for safe keeping.

The installer is idempotent — running it again detects already-applied patches
and skips them safely.

## Configuration

### printer.cfg

`[eddy_no_register]` must appear **before any includes** so it loads before
`[probe_eddy_current]`:

```ini
# Must be first — before any [include] lines
[eddy_no_register]

[include eddyduot0.cfg]
[include toolhead_t0.cfg]
# ... rest of config
```

### Eddy probe config

```ini
[mcu eddy]
canbus_uuid: YOUR_EDDY_UUID

[probe_eddy_current my_eddy_probe]
sensor_type: ldc1612
i2c_mcu: eddy
i2c_bus: i2c0f
x_offset: 0
y_offset: 0
data_rate: 500
```

### Tool probe config (per tool)

```ini
[tool T0]
tool_number: 0
extruder: extruder
fan: T0_partfan
# detection_pin uses same pin as tool_probe
# detection_pin: ^toolhead0:OPTO_TAP_PIN  # optional, see notes

[tool_probe T0]
pin: ^toolhead0:OPTO_TAP_PIN
tool: 0
z_offset: -0.95
speed: 5.0
samples: 3
samples_result: median
sample_retract_dist: 5.0
samples_tolerance: 0.02
samples_tolerance_retries: 3
```

### Z homing

```ini
[stepper_z]
endstop_pin: probe:z_virtual_endstop
# ... rest of stepper_z config
```

### Bed mesh and QGL using named Eddy probe

```ini
[bed_mesh]
probe: probe_eddy_current my_eddy_probe
mesh_min: 25, 15
mesh_max: 275, 265
horizontal_move_z: 2
probe_count: 9, 9
zero_reference_position: 150, 150

[quad_gantry_level]
probe: probe_eddy_current my_eddy_probe
gantry_corners:
    -97, -43
    388, 380
points:
    25, 5
    25, 265
    275, 265
    275, 5
horizontal_move_z: 2
retries: 5
retry_tolerance: 0.0075
max_adjust: 10
```

## How It Works

### Startup sequence

1. `[eddy_no_register]` loads first (must be before includes in printer.cfg)
2. It clears all probe G-code commands and the probe pin chip at config load time
3. It installs a patch on `printer.add_object` that silently drops any attempt
   by `PrinterEddyProbe` to register as the global `probe` object
4. `[tool_probe]` / `ToolProbeEndstop` loads and claims the global `probe` slot
5. `[probe_eddy_current]` loads — its `add_object('probe')` call is suppressed
6. `[bed_mesh]` and `[quad_gantry_level]` look up `probe_eddy_current my_eddy_probe`
   directly by name, bypassing the global slot entirely

### Tool detection

On a StealthChanger (passive shuttle, no fixed carriage wiring),
`[tool_probe]` handles detection via CAN bus presence:

- Tool removed → EBB MCU goes offline → all probes read as triggered (safe state)
- Tool mounted → EBB MCU comes online → `DETECT_ACTIVE_TOOL_PROBE` identifies
  which tool is present

### Result

| Operation | Probe Used |
|---|---|
| `G28 Z` | `tool_probe T0` (Opto-tap) |
| `QUAD_GANTRY_LEVEL` | `probe_eddy_current my_eddy_probe` (Eddy) |
| `BED_MESH_CALIBRATE` | `probe_eddy_current my_eddy_probe` (Eddy) |
| `BED_MESH_CALIBRATE METHOD=scan` | Eddy scan mode |

## Klipper Updates

Klipper's own files are **not modified directly**. The `eddy_no_register`
extra is a symlink to this repo — Moonraker updates to this repo deploy
automatically.

The Klipper patches live on a separate `toolchanger-multi-probe` branch of
your Klipper fork. To pull upstream Klipper changes into your fork:

```bash
cd ~/klipper
git fetch origin          # fetch upstream (Klipper3d)
git checkout master
git merge origin/master   # update your master
git checkout toolchanger-multi-probe
git rebase master         # rebase patches on top of updated master
sudo systemctl restart klipper
```

If the rebase has conflicts (unlikely given how minimal the patches are),
re-run the installer's option 2 to re-apply patches cleanly.

## Known Limitations

- `detection_pin` in `[tool T0]` cannot use the same pin as `[tool_probe T0]`
  in the current version of klipper-toolchanger — they conflict as separate
  pin consumers. Tool detection works via CAN bus presence instead.
- The Eddy probe cannot be used for Z homing (by design — Opto-tap is more
  reliable for this purpose on a toolchanger).

## Klipper Class Names

The module detects eddy probes by class name. Currently supported:

```python
EDDY_CLASS_NAMES = (
    "EddyCurrentProbe",    # older mainline Klipper
    "PrinterEddyProbe",    # current mainline Klipper
)
```

If a future Klipper update renames the class, add the new name to this tuple
in `eddy_no_register.py` and push to your repo — Moonraker will deploy the
fix automatically.

## License

GNU GPLv3 — same as Klipper.

## KTC-easy Integration

If using [klipper-toolchanger-easy](https://github.com/jwellman80/klipper-toolchanger-easy), see [KTC_EASY_INTEGRATION.md](KTC_Easy_Integration.md) for required macro overrides and configuration differences. 

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for diagnostic commands and common error fixes.
