#!/usr/bin/env bash
# Install the CBRSPI FPMS "Cellular" menu on WLAN Pi OS DeadEye (Trixie).
#
# Unlike Bullseye, DeadEye's FPMS is a dh-virtualenv on Python 3.13
# (/opt/wlanpi-fpms/lib/python3.13/...), and the stock FPMS is newer
# (1.4.23). So this is a PORT, not the Bullseye .deb overlay:
#   * fpms.py here is 1.4.23's own fpms.py with the CBRSPI Cellular menu +
#     ~120 Qscan dispatch functions spliced in (see
#     build-system/splice-cellular-fpms.py to regenerate against a new FPMS).
#   * cellular.py (the 3477-line Qscan app) drops in unchanged -- it is
#     import-compatible with 1.4.23/py3.13.
#   * The NetViews remote-menu hook is included with its one hardcoded
#     python3.9 path patched to python3.13, plus two python3.9 -> python3.13
#     symlinks so NetViews' Bullseye-era path assumptions resolve.
#
# Run ON the Pi as a user with sudo. Re-run after an FPMS package update
# (which would overwrite fpms.py); regenerate fpms.py first if the FPMS
# version changed (the splicer uses anchors, so it usually just works).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/opt/wlanpi-fpms/lib/python3.13/site-packages"
SP=/opt/wlanpi-fpms/lib/python3.13/site-packages
FPMS="$SP/fpms"

[ -d "$SP" ] || { echo "No $SP -- is this DeadEye (FPMS py3.13)?"; exit 1; }

echo ">> backing up current fpms.py -> ~/fpms.py.backup"
cp "$FPMS/fpms.py" "$HOME/fpms.py.backup" 2>/dev/null || true

echo ">> installing spliced fpms.py + cellular.py"
sudo cp "$SRC/fpms/fpms.py" "$FPMS/fpms.py"
sudo cp "$SRC/fpms/modules/apps/cellular.py" "$FPMS/modules/apps/cellular.py"
sudo chmod 644 "$FPMS/fpms.py" "$FPMS/modules/apps/cellular.py"

# cellular.py is PyArmor-obfuscated and imports `pyarmor_runtime_015278` as a
# top-level package, so the runtime must be on sys.path -- i.e. in the FPMS
# venv site-packages (NOT next to cellular.py). Without it FPMS dies at import
# with ModuleNotFoundError: No module named 'pyarmor_runtime_015278'.
echo ">> installing the cellular.py PyArmor runtime into site-packages"
sudo rm -rf "$SP/pyarmor_runtime_015278"
sudo cp -a "$SRC/pyarmor_runtime_015278" "$SP/pyarmor_runtime_015278"

echo ">> installing NetViews hook (DEST_DIR patched to py3.13)"
sudo cp "$SRC/wlanpi_netviews_hook.py" "$SP/wlanpi_netviews_hook.py"
sudo cp "$SRC/wlanpi_netviews_hook.pth" "$SP/wlanpi_netviews_hook.pth"
sudo chmod 644 "$SP/wlanpi_netviews_hook.py" "$SP/wlanpi_netviews_hook.pth"

echo ">> python3.9 -> python3.13 symlinks so NetViews' Bullseye paths resolve"
[ -e /opt/wlanpi-fpms/lib/python3.9 ]  || sudo ln -s python3.13 /opt/wlanpi-fpms/lib/python3.9
[ -e /opt/wlanpi-webui/lib/python3.9 ] || sudo ln -s python3.13 /opt/wlanpi-webui/lib/python3.9

echo ">> restarting FPMS"
sudo systemctl restart wlanpi-fpms

echo ">> done. Check the screen (or NetViews) for the Cellular menu."
echo "   Revert: sudo cp ~/fpms.py.backup $FPMS/fpms.py && sudo rm -f $FPMS/modules/apps/cellular.py && sudo systemctl restart wlanpi-fpms"
