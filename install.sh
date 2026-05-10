#!/bin/bash
# install.sh — symlinks eddy_no_register.py into Klipper's extras directory.
# Follows the same pattern as klipper-toolchanger's install script.
#
# Usage:
#   bash ~/eddy_no_register/install.sh
#
# To uninstall:
#   rm ~/klipper/klippy/extras/eddy_no_register.py

set -e

REPO_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KLIPPER_EXTRAS="${HOME}/klipper/klippy/extras"
EXTRA_SRC="${REPO_DIR}/klipper/extras/eddy_no_register.py"
EXTRA_DST="${KLIPPER_EXTRAS}/eddy_no_register.py"

echo "=== eddy_no_register installer ==="

# Verify Klipper extras directory exists
if [ ! -d "${KLIPPER_EXTRAS}" ]; then
    echo "ERROR: Klipper extras directory not found at ${KLIPPER_EXTRAS}"
    echo "       Is Klipper installed at ~/klipper?"
    exit 1
fi

# Remove any existing file or symlink at the destination
if [ -e "${EXTRA_DST}" ] || [ -L "${EXTRA_DST}" ]; then
    echo "Removing existing file at ${EXTRA_DST}"
    rm "${EXTRA_DST}"
fi

# Create symlink
ln -s "${EXTRA_SRC}" "${EXTRA_DST}"
echo "Symlinked: ${EXTRA_SRC}"
echo "       -> ${EXTRA_DST}"

# Restart Klipper service if it is running
if systemctl is-active --quiet klipper; then
    echo "Restarting Klipper..."
    sudo systemctl restart klipper
    echo "Klipper restarted."
else
    echo "Klipper service is not running — no restart needed."
fi

echo "=== Installation complete ==="
echo ""
echo "Add the following to your printer.cfg:"
echo ""
echo "  [eddy_no_register]"
echo ""
