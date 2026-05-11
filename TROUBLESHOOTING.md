# Troubleshooting Guide

## Diagnostic Commands

### Check eddy_no_register is loading and firing correctly
```bash
grep "eddy_no_register:" /home/pi/printer_data/logs/klippy.log | tail -10
```

**Expected output (all four lines should appear):**
```
eddy_no_register: cleared gcode command QUERY_PROBE
eddy_no_register: cleared gcode command PROBE
eddy_no_register: cleared gcode command PROBE_CALIBRATE
eddy_no_register: cleared gcode command PROBE_ACCURACY
eddy_no_register: cleared gcode command Z_OFFSET_APPLY_PROBE
eddy_no_register: cleared 'probe' pin chip — tool_probe_endstop can register it cleanly
eddy_no_register: installed add_object patch for 'probe'
eddy_no_register: suppressed add_object('probe') from 'PrinterEddyProbe' — slot already held by 'ToolProbeEndstop'
```

### Check for config or startup errors
```bash
grep -E "Config error|configparser.Error|IndentationError" /home/pi/printer_data/logs/klippy.log | tail -10
```

### Check Klipper started cleanly on last restart
```bash
grep -E "eddy_no_register:|error|Error|Start printer" /home/pi/printer_data/logs/klippy.log | tail -20
```

### Check symlink is correct
```bash
ls -la ~/klipper/klippy/extras/eddy_no_register.py
```
Should show `->` pointing to `~/eddy_no_register/eddy_no_register.py`

### Check Klipper patches are applied
```bash
grep -n "probe_name\|config.get.*probe" ~/klipper/klippy/extras/probe.py
grep -n "probe_name\|config.get.*probe" ~/klipper/klippy/extras/quad_gantry_level.py
grep -n "probe_name\|config.get.*probe" ~/klipper/klippy/extras/bed_mesh.py
```

### Check which git branch Klipper is on
```bash
cd ~/klipper && git branch && git log --oneline -3
```

### Check endstop states
Run in Mainsail/Fluidd console:
```
QUERY_ENDSTOPS
DETECT_ACTIVE_TOOL_PROBE
```

### Check Python syntax of patched files
```bash
python3 -m py_compile ~/klipper/klippy/extras/probe.py && echo "ok"
python3 -m py_compile ~/klipper/klippy/extras/quad_gantry_level.py && echo "ok"
python3 -m py_compile ~/klipper/klippy/extras/bed_mesh.py && echo "ok"
```

---

## Common Errors

### `Section 'eddy_no_register' is not a valid config section`

The symlink is missing or broken.

```bash
# Check symlink
ls -la ~/klipper/klippy/extras/eddy_no_register.py

# Reinstall
bash ~/eddy_no_register/install.sh  # option 1 or 3
```

---

### `eddy_no_register: 'probe' is held by 'PrinterEddyProbe', not an eddy probe`

The class name in `EDDY_CLASS_NAMES` doesn't match your Klipper version.

```bash
# Check what class name your Klipper uses
grep -n "^class.*Probe\|^class.*Eddy" ~/klipper/klippy/extras/probe_eddy_current.py
```

Add the class name to `EDDY_CLASS_NAMES` in `eddy_no_register.py`:
```python
EDDY_CLASS_NAMES = (
    "EddyCurrentProbe",    # older mainline Klipper
    "PrinterEddyProbe",    # current mainline Klipper
    "YourNewClassName",    # add here if needed
)
```

---

### `gcode command Z_OFFSET_APPLY_PROBE already registered`

`[eddy_no_register]` is not loading before `[probe_eddy_current]`.
It must be the **first section** in `printer.cfg`, before any `[include]` lines.

```ini
# printer.cfg — eddy_no_register MUST be first
[eddy_no_register]

[include eddyduot0.cfg]   # probe_eddy_current is in here
```

---

### `Printer object 'probe' already created`

Same cause as above — load order issue. Ensure `[eddy_no_register]` is first.

---

### `Duplicate chip name 'probe'`

Same cause — `[eddy_no_register]` loading after `[probe_eddy_current]`.

---

### `Option 'probe' is not valid in section 'quad_gantry_level'`

The Klipper patches are not applied. Check which branch you're on:

```bash
cd ~/klipper && git branch
```

If on `master`, switch to the patched branch:
```bash
git checkout toolchanger-multi-probe
sudo systemctl restart klipper
```

If on `toolchanger-multi-probe` but still erroring, the patches may not have
survived a rebase. Re-apply them:
```bash
bash ~/eddy_no_register/install.sh  # option 2
```

---

### `No trigger on probe after full movement` during QGL or bed mesh

The named probe isn't being found. Check your config uses the full object name:

```ini
# Wrong
[quad_gantry_level]
probe: my_eddy_probe

# Correct — must include the section prefix
[quad_gantry_level]
probe: probe_eddy_current my_eddy_probe
```

---

### `IndentationError: unexpected indent` in probe.py

A patch was applied incorrectly. Check the file:
```bash
python3 -m py_compile ~/klipper/klippy/extras/probe.py
```

Restore from git and re-apply:
```bash
cd ~/klipper
git checkout toolchanger-multi-probe -- klippy/extras/probe.py
# If that doesn't work, rebase:
git rebase master
sudo systemctl restart klipper
```

---

### Tool detection not working / `DETECT_ACTIVE_TOOL_PROBE` always shows triggered

- **Tool removed** → "All probes triggered" is **correct** — EBB MCU offline = safe triggered state
- **Tool mounted** → should show "Found active tool probe: tool_probe T0"

If tool mounted still shows triggered, check the Opto-tap pin polarity:
```bash
grep "tool_probe\|PB6\|opto" ~/printer_data/config/*.cfg | grep -v "#"
```

The `^` prefix enables pullup (normally high, triggers low). Remove `!` if present.

---

### `detection_pin` conflict error

`detection_pin` in `[tool T0]` cannot use the same pin as `[tool_probe T0]`
in the current version of klipper-toolchanger — they conflict as separate pin
consumers. Leave `detection_pin` commented out. Tool detection works via CAN
bus presence detection instead.

---

## Klipper Update Procedure

```bash
# 1. Roll back to mainline
bash ~/eddy_no_register/install.sh   # option 5

# 2. Update Klipper via Fluidd/Mainsail update manager

# 3. Rebase patches onto updated master
cd ~/klipper
git checkout toolchanger-multi-probe
git rebase master

# 4. Push updated branch to your fork
git push myfork toolchanger-multi-probe --force-with-lease

# 5. Restart Klipper
sudo systemctl restart klipper

# 6. Verify
grep "eddy_no_register:" /home/pi/printer_data/logs/klippy.log | tail -5
```

If rebase has conflicts, re-apply patches via installer option 2 instead.

---

## Log File Location

```
/home/pi/printer_data/logs/klippy.log
```

For real-time log monitoring:
```bash
tail -f /home/pi/printer_data/logs/klippy.log | grep -E "eddy_no_register:|error|Error"
```
