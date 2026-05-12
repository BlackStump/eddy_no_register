#!/bin/bash
# install.sh — eddy_no_register + toolchanger-multi-probe installer
#
# Installs:
#   1. eddy_no_register Klipper extra (symlink)
#   2. toolchanger-multi-probe patches to Klipper (named probe support)
#
# Copyright (C) 2025  BlackStump
# GPLv3 License

set -e

# ── Colours ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Paths ──────────────────────────────────────────────────────────────
REPO_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KLIPPER_DIR="${HOME}/klipper"
KLIPPER_EXTRAS="${KLIPPER_DIR}/klippy/extras"
EXTRA_SRC="${REPO_DIR}/eddy_no_register.py"
EXTRA_DST="${KLIPPER_EXTRAS}/eddy_no_register.py"
BRANCH_NAME="toolchanger-multi-probe"

# ── Helpers ────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" ans
        [[ -z "$ans" || "${ans,,}" == "y" ]]
    else
        read -rp "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" ans
        [[ "${ans,,}" == "y" ]]
    fi
}

check_klipper() {
    if [[ ! -d "${KLIPPER_DIR}" ]]; then
        error "Klipper not found at ${KLIPPER_DIR}"
        exit 1
    fi
    if [[ ! -d "${KLIPPER_EXTRAS}" ]]; then
        error "Klipper extras directory not found at ${KLIPPER_EXTRAS}"
        exit 1
    fi
    success "Klipper found at ${KLIPPER_DIR}"
}

restart_klipper() {
    if systemctl is-active --quiet klipper; then
        info "Restarting Klipper..."
        sudo systemctl restart klipper
        success "Klipper restarted"
    else
        warn "Klipper service not running — skipping restart"
    fi
}

# ── eddy_no_register install ───────────────────────────────────────────
install_eddy_no_register() {
    header "Installing eddy_no_register"

    if [[ ! -f "${EXTRA_SRC}" ]]; then
        error "eddy_no_register.py not found at ${EXTRA_SRC}"
        exit 1
    fi

    # Remove existing symlink or file
    if [[ -e "${EXTRA_DST}" || -L "${EXTRA_DST}" ]]; then
        warn "Removing existing file at ${EXTRA_DST}"
        rm "${EXTRA_DST}"
    fi

    ln -s "${EXTRA_SRC}" "${EXTRA_DST}"
    success "Symlinked: ${EXTRA_SRC}"
    info "        -> ${EXTRA_DST}"

    echo ""
    echo -e "${BOLD}Add the following to your printer.cfg (before any includes):${NC}"
    echo ""
    echo "  [eddy_no_register]"
    echo ""
}

# ── eddy_no_register uninstall ────────────────────────────────────────
uninstall_eddy_no_register() {
    header "Uninstalling eddy_no_register"

    if [[ -e "${EXTRA_DST}" || -L "${EXTRA_DST}" ]]; then
        rm "${EXTRA_DST}"
        success "Removed ${EXTRA_DST}"
    else
        warn "eddy_no_register.py not found at ${EXTRA_DST} — nothing to remove"
    fi

    warn "Remember to remove [eddy_no_register] from your printer.cfg"
}

# ── Check if Klipper file is already patched ───────────────────────────
is_patched() {
    local file="$1"
    local marker="$2"
    grep -q "${marker}" "${file}" 2>/dev/null
}

# ── Apply toolchanger-multi-probe patches ─────────────────────────────
apply_klipper_patches() {
    header "Applying toolchanger-multi-probe Klipper patches"

    local probe_py="${KLIPPER_EXTRAS}/probe.py"
    local qgl_py="${KLIPPER_EXTRAS}/quad_gantry_level.py"
    local bed_mesh_py="${KLIPPER_EXTRAS}/bed_mesh.py"

    # Verify all files exist
    for f in "${probe_py}" "${qgl_py}" "${bed_mesh_py}"; do
        if [[ ! -f "$f" ]]; then
            error "Required file not found: $f"
            exit 1
        fi
    done

    # ── Patch probe.py ────────────────────────────────────────────────
    if is_patched "${probe_py}" "self.probe_name = 'probe'"; then
        warn "probe.py appears already patched — skipping"
    else
        info "Patching probe.py..."
        python3 << EOF
with open('${probe_py}', 'r') as f:
    content = f.read()

# 1. Add self.probe_name = 'probe' at end of ProbePointsHelper.__init__
#    Identified by the pattern before minimum_points to avoid matching
#    the same line in start_probe
old = "        self.manual_results = []\n    def minimum_points"
new = "        self.manual_results = []\n        self.probe_name = 'probe'\n    def minimum_points"
if old not in content:
    raise Exception("probe.py: Could not find __init__ manual_results marker")
content = content.replace(old, new)

# 2. Change probe lookup in start_probe to use self.probe_name
old2 = "        probe = self.printer.lookup_object('probe', None)\n        method = gcmd.get('METHOD'"
new2 = "        probe = self.printer.lookup_object(self.probe_name, None)\n        method = gcmd.get('METHOD'"
if old2 not in content:
    raise Exception("probe.py: Could not find lookup_object probe marker")
content = content.replace(old2, new2)

with open('${probe_py}', 'w') as f:
    f.write(content)
print("probe.py patched")
EOF
        python3 -m py_compile "${probe_py}" || { error "probe.py syntax error after patch"; exit 1; }
        success "probe.py patched and verified"
    fi

    # ── Patch quad_gantry_level.py ────────────────────────────────────
    if is_patched "${qgl_py}" "_probe_name = config.get('probe'"; then
        warn "quad_gantry_level.py appears already patched — skipping"
    else
        info "Patching quad_gantry_level.py..."
        python3 << EOF
with open('${qgl_py}', 'r') as f:
    content = f.read()

old = "        self.probe_helper = probe.ProbePointsHelper(config, self.probe_finalize)\n        if len(self.probe_helper.probe_points) != 4:"
new = "        _probe_name = config.get('probe', 'probe')\n        self.probe_helper = probe.ProbePointsHelper(config, self.probe_finalize)\n        self.probe_helper.probe_name = _probe_name\n        if len(self.probe_helper.probe_points) != 4:"

if old not in content:
    raise Exception("quad_gantry_level.py: Could not find ProbePointsHelper marker")
content = content.replace(old, new)

with open('${qgl_py}', 'w') as f:
    f.write(content)
print("quad_gantry_level.py patched")
EOF
        python3 -m py_compile "${qgl_py}" || { error "quad_gantry_level.py syntax error after patch"; exit 1; }
        success "quad_gantry_level.py patched and verified"
    fi

    # ── Patch bed_mesh.py (ProbePointsHelper + RapidScanHelper) ──────
    # Two separate patches — check each independently
    local bed_mesh_probe_patched=false
    local bed_mesh_rapid_patched=false

    is_patched "${bed_mesh_py}" "_probe_name = config.get('probe'" && bed_mesh_probe_patched=true
    is_patched "${bed_mesh_py}" "rapid_scan_helper.probe_name = self.probe_helper.probe_name" && bed_mesh_rapid_patched=true

    if $bed_mesh_probe_patched && $bed_mesh_rapid_patched; then
        warn "bed_mesh.py appears already patched (both patches) — skipping"
    else
        info "Patching bed_mesh.py..."
        python3 << EOF
with open('${bed_mesh_py}', 'r') as f:
    lines = f.readlines()
    content = ''.join(lines)

# ── Patch 1: ProbePointsHelper named probe ────────────────────────────
probe_patch_marker = "_probe_name = config.get('probe'"
if probe_patch_marker not in content:
    old = "        self.probe_helper = probe.ProbePointsHelper(config, finalize_cb, [])\n        self.probe_helper.use_xy_offsets(True)"
    new = "        _probe_name = config.get('probe', 'probe')\n        self.probe_helper = probe.ProbePointsHelper(config, finalize_cb, [])\n        self.probe_helper.probe_name = _probe_name\n        self.probe_helper.use_xy_offsets(True)"
    if old not in content:
        raise Exception("bed_mesh.py: Could not find ProbePointsHelper marker")
    content = content.replace(old, new)

    old2 = '        pprobe = self.printer.lookup_object("probe", None)\n        if pprobe is not None:\n            probe_name = pprobe.get_status(None).get("name", "")\n            can_scan = probe_name.startswith("probe_eddy_current")'
    new2 = '        pprobe = self.printer.lookup_object(self.probe_helper.probe_name, None)\n        if pprobe is not None:\n            probe_name = pprobe.get_status(None).get("name", "")\n            can_scan = probe_name.startswith("probe_eddy_current")'
    if old2 not in content:
        raise Exception("bed_mesh.py: Could not find start_probe lookup marker")
    content = content.replace(old2, new2)
    print("bed_mesh.py ProbePointsHelper patch applied")
else:
    print("bed_mesh.py ProbePointsHelper patch already present — skipping")

# ── Patch 2: RapidScanHelper named probe ─────────────────────────────
rapid_patch_marker = "rapid_scan_helper.probe_name = self.probe_helper.probe_name"
if rapid_patch_marker not in content:
    lines = content.splitlines(keepends=True)
    out = []
    rapid_scan_init_done = False
    rapid_scan_inst_done = False

    for i, line in enumerate(lines):
        out.append(line)
        # Add probe_name to RapidScanHelper.__init__ after finalize_callback
        if not rapid_scan_init_done and 'self.finalize_callback = finalize_cb' in line:
            next_line = lines[i+1] if i+1 < len(lines) else ''
            if 'perform_rapid_scan' in next_line:
                out.append("        self.probe_name = 'probe'\n")
                rapid_scan_init_done = True
        # Set probe_name on rapid_scan_helper after instantiation
        if not rapid_scan_inst_done and 'self.rapid_scan_helper = RapidScanHelper' in line:
            out.append("        self.rapid_scan_helper.probe_name = self.probe_helper.probe_name\n")
            rapid_scan_inst_done = True

    content = ''.join(out)

    # Replace hardcoded lookup_object("probe") calls in RapidScanHelper
    content = content.replace(
        'pprobe = self.printer.lookup_object("probe")',
        'pprobe = self.printer.lookup_object(self.probe_name)'
    )
    print("bed_mesh.py RapidScanHelper patch applied")
else:
    print("bed_mesh.py RapidScanHelper patch already present — skipping")

with open('${bed_mesh_py}', 'w') as f:
    f.write(content)
EOF
        python3 -m py_compile "${bed_mesh_py}" || { error "bed_mesh.py syntax error after patch"; exit 1; }
        success "bed_mesh.py patched and verified"
    fi

    # Clear pyc cache
    find "${KLIPPER_DIR}/klippy" -name "*.pyc" -delete 2>/dev/null || true
    success "Bytecode cache cleared"
}

# ── Commit patches to git branch ──────────────────────────────────────
commit_klipper_patches() {
    header "Committing patches to git"

    cd "${KLIPPER_DIR}"

    # Check we're in a git repo
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        error "Klipper directory is not a git repository"
        exit 1
    fi

    local current_branch
    current_branch=$(git branch --show-current)

    # Create or switch to toolchanger-multi-probe branch
    if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
        info "Branch ${BRANCH_NAME} already exists"
        if [[ "${current_branch}" != "${BRANCH_NAME}" ]]; then
            info "Switching to ${BRANCH_NAME}..."
            git checkout "${BRANCH_NAME}"
        fi
    else
        info "Creating branch ${BRANCH_NAME}..."
        git checkout -b "${BRANCH_NAME}"
        success "Created branch ${BRANCH_NAME}"
    fi

    # Stage patched files
    git add klippy/extras/probe.py \
            klippy/extras/quad_gantry_level.py \
            klippy/extras/bed_mesh.py

    # Check if there's anything to commit
    if git diff --cached --quiet; then
        warn "No changes to commit — patches already committed"
        return
    fi

    git commit -m "Add named probe support for ProbePointsHelper, RapidScanHelper, bed_mesh, quad_gantry_level

Allows [bed_mesh] and [quad_gantry_level] to specify a named probe via
'probe: <name>' config directive, defaulting to 'probe' for backwards
compatibility. Enables toolchanger setups to use a scan probe (e.g.
probe_eddy_current) for mesh and QGL while a separate probe (e.g.
tool_probe) owns the global probe slot for Z homing.

Patches applied:
- probe.py: ProbePointsHelper.probe_name for named probe lookup
- quad_gantry_level.py: reads 'probe:' config directive
- bed_mesh.py: ProbePointsHelper named probe + RapidScanHelper named
  probe (fixes bed mesh scan using global probe instead of named probe)

Installed by eddy_no_register installer."

    success "Patches committed to branch ${BRANCH_NAME}"
}

# ── Optional GitHub push ───────────────────────────────────────────────
push_to_github() {
    header "Push to GitHub (optional)"

    cd "${KLIPPER_DIR}"

    # List existing remotes
    info "Current git remotes:"
    git remote -v

    echo ""
    read -rp "$(echo -e "${YELLOW}Enter remote name to push to (e.g. myfork), or press Enter to skip: ${NC}")" remote_name

    if [[ -z "${remote_name}" ]]; then
        warn "Skipping GitHub push"
        return
    fi

    # Check if remote exists
    if ! git remote get-url "${remote_name}" > /dev/null 2>&1; then
        read -rp "$(echo -e "${YELLOW}Remote '${remote_name}' not found. Enter GitHub URL (e.g. https://github.com/USER/klipper.git): ${NC}")" remote_url
        if [[ -z "${remote_url}" ]]; then
            warn "No URL provided — skipping push"
            return
        fi
        git remote add "${remote_name}" "${remote_url}"
        success "Added remote '${remote_name}' -> ${remote_url}"
    fi

    info "Pushing ${BRANCH_NAME} to ${remote_name}..."
    info "You will be prompted for GitHub credentials."
    info "Use a Personal Access Token as your password."
    info "(GitHub → Settings → Developer Settings → Personal Access Tokens)"
    echo ""

    if git push "${remote_name}" "${BRANCH_NAME}" --force-with-lease; then
        success "Pushed to ${remote_name}/${BRANCH_NAME}"
        echo ""
        warn "Remember to update moonraker.conf [update_manager klipper]:"
        echo "  origin: $(git remote get-url ${remote_name})"
        echo "  primary_branch: ${BRANCH_NAME}"
    else
        error "Push failed — check your credentials and try again"
    fi
}

# ── Rollback/uninstall Klipper patches ────────────────────────────────
uninstall_klipper_patches() {
    header "Rolling back toolchanger-multi-probe Klipper patches"

    cd "${KLIPPER_DIR}"

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        error "Klipper directory is not a git repository — cannot rollback"
        exit 1
    fi

    local current_branch
    current_branch=$(git branch --show-current)

    if [[ "${current_branch}" == "${BRANCH_NAME}" ]]; then
        info "Switching back to master..."
        git checkout master
        success "Switched to master — patches no longer active"
        warn "Branch ${BRANCH_NAME} still exists. To delete it:"
        warn "  git branch -d ${BRANCH_NAME}"
    else
        warn "Not on ${BRANCH_NAME} branch (currently on ${current_branch})"
        warn "To rollback, manually run: git checkout master"
    fi

    # Clear pyc cache
    find "${KLIPPER_DIR}/klippy" -name "*.pyc" -delete 2>/dev/null || true
}

# ── Main menu ──────────────────────────────────────────────────────────
main_menu() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       eddy_no_register + toolchanger-multi-probe     ║"
    echo "║                     Installer                        ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  1) Install eddy_no_register only"
    echo "  2) Install toolchanger-multi-probe Klipper patches only"
    echo "  3) Install both (recommended)"
    echo "  4) Uninstall eddy_no_register"
    echo "  5) Rollback Klipper patches (switch back to master)"
    echo "  6) Exit"
    echo ""
    read -rp "$(echo -e "${YELLOW}Select option [1-6]: ${NC}")" choice

    case "$choice" in
        1)
            check_klipper
            install_eddy_no_register
            restart_klipper
            success "eddy_no_register installed"
            ;;
        2)
            check_klipper
            apply_klipper_patches
            commit_klipper_patches
            if confirm "Push to GitHub?"; then
                push_to_github
            fi
            restart_klipper
            success "toolchanger-multi-probe patches applied"
            echo ""
            echo -e "${BOLD}Add 'probe: probe_eddy_current <name>' to your${NC}"
            echo -e "${BOLD}[quad_gantry_level] and [bed_mesh] config sections.${NC}"
            ;;
        3)
            check_klipper
            install_eddy_no_register
            apply_klipper_patches
            commit_klipper_patches
            if confirm "Push to GitHub?"; then
                push_to_github
            fi
            restart_klipper
            success "All components installed"
            echo ""
            echo -e "${BOLD}Next steps:${NC}"
            echo "  1. Add '[eddy_no_register]' to printer.cfg (before any includes)"
            echo "  2. Add 'probe: probe_eddy_current <name>' to [quad_gantry_level]"
            echo "  3. Add 'probe: probe_eddy_current <name>' to [bed_mesh]"
            echo "  4. Restart Klipper via Mainsail/Fluidd"
            ;;
        4)
            uninstall_eddy_no_register
            restart_klipper
            ;;
        5)
            uninstall_klipper_patches
            restart_klipper
            ;;
        6)
            exit 0
            ;;
        *)
            error "Invalid option"
            main_menu
            ;;
    esac
}

main_menu
