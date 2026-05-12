# KTC-easy Integration Guide

This guide covers the additional configuration required when using
[klipper-toolchanger-easy (KTC-easy)](https://github.com/jwellman80/klipper-toolchanger-easy)
alongside `eddy_no_register` and the `toolchanger-multi-probe` Klipper patches.

## Why KTC-easy Needs Extra Config

KTC-easy's `INITIALIZE_TOOLCHANGER` sets the active tool in the toolchanger
system but never calls `SET_ACTIVE_TOOL_PROBE`. This means `tool_probe_endstop`
doesn't know which tool probe to use, `get_position_endstop()` returns `0.0`,
and the `z_offset` in `[tool_probe T0]` is completely ignored during Z homing.

KTC-easy also handles Z offset correction differently from stock Klipper — it
uses `_ADJUST_Z_HOME_FOR_TOOL_OFFSET` to apply the tool probe z_offset via
`SET_KINEMATIC_POSITION` after homing, rather than relying on Klipper's native
endstop position system. Both mechanisms must work together correctly.

---

## Required Macro Overrides

Add the following to your `toolchanger-config.cfg`. This file is the correct
place for overrides since KTC-easy loads it last.

### 1. `INITIALIZE_TOOLCHANGER` — Add `SET_ACTIVE_TOOL_PROBE`

This is the most critical fix. Without it, `z_offset` has no effect.

```ini
[gcode_macro INITIALIZE_TOOLCHANGER]
rename_existing: INITIALIZE_TOOLCHANGER_BASE
gcode:
    {% set T = params.T | default(-1) | int %}
    {% if T >= 0 %}
        INITIALIZE_TOOLCHANGER_BASE T={T}
        SET_ACTIVE_TOOL_PROBE T={T}
    {% elif printer.toolchanger.detected_tool_number >= 0 %}
        INITIALIZE_TOOLCHANGER_BASE T={printer.toolchanger.detected_tool_number}
        SET_ACTIVE_TOOL_PROBE T={printer.toolchanger.detected_tool_number}
    {% else %}
        INITIALIZE_TOOLCHANGER_BASE T=0
        SET_ACTIVE_TOOL_PROBE T=0
    {% endif %}
```

**Why:** The `{% else %}` branch defaults to T0 when no `detection_pin` is
configured. If you have `detection_pin` configured this branch is never hit.
The `SET_ACTIVE_TOOL_PROBE T={T}` call is what tells `tool_probe_endstop`
which physical probe to use for Z homing.

### 2. `_ADJUST_Z_HOME_FOR_TOOL_OFFSET` — Ensure correct Z after homing

KTC-easy's readonly version of this macro is correct — but if you have
overridden it during debugging, restore it to the functional version:

```ini
[gcode_macro _ADJUST_Z_HOME_FOR_TOOL_OFFSET]
gcode:
    G90
    G0 Z10 F1000
    {% set tool = printer.toolchanger.tool %}
    {% if tool %}
        {% set tool_z_offset = printer[tool].gcode_z_offset %}
        {% set probe_z_offset = printer.tool_probe_endstop.active_tool_probe_z_offset %}
        SET_KINEMATIC_POSITION Z={10.0+tool_z_offset|float+probe_z_offset|float}
    {% endif %}
```

**Why:** After `G28 Z`, Klipper sets the kinematic Z position to the physical
trigger point (~0.5mm above bed for Opto-tap). This macro corrects that by
setting the kinematic position to account for both the tool's gcode_z_offset
(for multi-tool height differences) and the probe's z_offset (fine tuning).

### 3. Homing rebound — microswitch users

If using microswitches for X/Y homing (not sensorless), set:

```ini
[gcode_macro homing_override_config]
variable_homing_rebound_y: 0
```

KTC-easy's default `homing_rebound_y: 20` moves Y back 20mm after homing,
which can put it out of range of the X endstop depending on your printer geometry.
Setting to `0` leaves Y at max position so X can home correctly.

---

## How z_offset Works With KTC-easy

This is **different** from stock Klipper and causes confusion.

### Stock Klipper (without KTC-easy)
- `z_offset` in `[tool_probe T0]` is used as `position_endstop`
- When probe triggers, Klipper sets `Z = z_offset` directly
- Typical values: `-0.95` to `-1.20` (large negative)

### With KTC-easy
- `get_position_endstop()` returns `0.0` by design
- Klipper sets Z to the physical trigger height (~0.5mm above bed)
- `_ADJUST_Z_HOME_FOR_TOOL_OFFSET` then sets:
  `SET_KINEMATIC_POSITION Z = 10.0 + gcode_z_offset + probe_z_offset`
- `z_offset` is a **fine correction** on top of the physical trigger point
- Typical values: `-0.2` to `+0.2` (small, near zero)

### Finding your z_offset with KTC-easy

1. Set `z_offset = 0.0` in `[tool_probe T0]`
2. Run `G28` then `G1 Z0 F600`
3. Check nozzle position with paper test
4. If nozzle is above bed at Z=0, make z_offset more negative
5. If nozzle is below bed at Z=0 (unlikely), make z_offset more positive
6. Iterate in `0.05mm` steps until Z=0 = nozzle just touching bed

**Note:** Because KTC-easy uses `SET_KINEMATIC_POSITION` to apply the offset,
the value is applied consistently regardless of where the probe physically
triggers. This makes it more repeatable across different homing positions.

---

## PRINT_START Recommendations

### Use `TOOL_BED_MESH_CALIBRATE` instead of `BED_MESH_CALIBRATE`

KTC-easy provides `TOOL_BED_MESH_CALIBRATE` which correctly handles the
kinematic Z position around the bed mesh scan. Use this in your `PRINT_START`:

```gcode
; Instead of:
BED_MESH_CALIBRATE

; Use:
TOOL_BED_MESH_CALIBRATE
```

### Conditional `G28 Z` in your `BED_MESH_CALIBRATE` macro

If you have a custom `BED_MESH_CALIBRATE` macro that unconditionally calls
`G28 Z`, change it to only home Z if not already homed:

```ini
[gcode_macro BED_MESH_CALIBRATE]
rename_existing: BASE_BED_MESH_CALIBRATE
gcode:
    CHECK_HOMED
    BED_MESH_CLEAR
    {% if "z" not in printer.toolhead.homed_axes %}
        M117 Z axis is not homed, homing now...
        G28 Z
    {% endif %}
    BED_MESH_CLEAR
    BASE_BED_MESH_CALIBRATE METHOD=scan ADAPTIVE=1
```

An unconditional `G28 Z` inside `BED_MESH_CALIBRATE` when called from
`TOOL_BED_MESH_CALIBRATE` causes the kinematic Z to be reset to 0, breaking
the first layer height.

---

## Recommended PRINT_START Sequence

```gcode
G28                              ; home all (initializes T0, sets active probe)
QUAD_GANTRY_LEVEL                ; fix gantry sag
CLEAN_NOZZLE Z_OVERRIDE=1.5      ; clean at safe height post-QGL
G28 Z                            ; accurate Z home with clean nozzle
QUAD_GANTRY_LEVEL                ; fine QGL pass
G28 Z                            ; re-home Z after final QGL
TOOL_BED_MESH_CALIBRATE          ; mesh scan with correct Z handling
```

---

## Verifying Everything Works

Run these in sequence and check the outputs:

```
G28
```
Should show: `// toolchanger initialized, active tool T0`

```
DEBUG_PROBE
```
Should show: `active_tool_probe=tool_probe T0 active_z_offset=<your_z_offset>`

Add this temporary macro to verify:
```ini
[gcode_macro DEBUG_PROBE]
gcode:
    {% set tpe = printer.tool_probe_endstop %}
    RESPOND TYPE=command MSG="active_tool_probe={tpe.active_tool_probe} active_z_offset={tpe.active_tool_probe_z_offset}"
```

If `active_tool_probe=None` — `SET_ACTIVE_TOOL_PROBE` is not being called.
Check your `INITIALIZE_TOOLCHANGER` override is in place.

If `active_z_offset=0.0` when you have a non-zero z_offset — check that
`[tool_probe T0]` has `z_offset` set and Klipper has been restarted.

---

## Tool Detection Without `detection_pin`

On a StealthChanger or similar passive shuttle (no fixed carriage wiring),
`detection_pin` cannot be used because the same pin serves as both
`detection_pin` and `[tool_probe]` pin, which causes a pin conflict.

Tool detection works via CAN bus presence instead:
- Tool removed → EBB MCU goes offline → all probes read as triggered
- Tool mounted → EBB MCU comes online → `DETECT_ACTIVE_TOOL_PROBE` identifies T0

The `INITIALIZE_TOOLCHANGER` override above handles this by defaulting to T0
when no tool is detected — which is correct for a single-tool setup.

For multi-tool setups, once you have `detection_pin` working on a fixed
carriage signal line, remove the `{% else %} ... T=0` branch and let
detection handle it automatically.
