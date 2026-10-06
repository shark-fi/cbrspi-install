#!/usr/bin/env bash
# CBRSPI cellular datastream for WLAN Pi OS DeadEye (26.10 / Trixie / py3.13).
# Layers onto an installed wlanpi-grafana as a new "qscan" datastream.
# Run with sudo on the Pi from the unpacked cbrspi-deadeye dir.
set -euo pipefail

GRAF=/opt/wlanpi-grafana
[ -d "$GRAF" ] || { echo "wlanpi-grafana not installed; run: sudo apt install wlanpi-grafana"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

# The Pi has no RTC and the stock timesyncd is wedged, so a fresh boot has a
# skewed clock. apt then rejects repo signatures ("InRelease is not signed /
# not live until <future>") and the whole install fails at the first update.
# chrony (installed below) fixes this permanently; bootstrap the clock here from
# an HTTPS Date header first so apt works at all. (TLS still works with a ~hours
# skew, so curl is fine to read the real time.)
if ! timedatectl 2>/dev/null | grep -qi "synchronized: yes"; then
    echo "== bootstrap clock (no RTC; apt signatures need correct time) =="
    REALTIME=$(curl -sI https://www.cloudflare.com 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: *//')
    if [ -n "$REALTIME" ]; then
        date -u -s "$REALTIME" >/dev/null 2>&1 && echo "  clock set to $(date -u)"
    else
        echo "  WARN: could not fetch time; if apt fails on signatures, fix the clock manually"
    fi
fi

echo "== dependencies (apt first, PEP 668 keeps pip off the system env) =="
apt-get update -qq
# available from Debian Trixie. chrony: the stock image's systemd-timesyncd
# wedges (never polls) and DHCP often hands out a non-NTP server, so the Pi's
# clock drifts -- a skewed clock then breaks apt signature verification. chrony
# replaces timesyncd, steps large offsets, and handles the RTC-less Pi.
apt-get install -y python3-serial python3-numpy python3-pandas python3-netifaces minicom chrony
# core deps not in apt -> pip into the system env (PEP 668). Required for the
# cellular Grafana stream; abort if these fail.
pip install --break-system-packages --no-input timezonefinder crcmod pycrate

# optional: SCAT + QCSuper power the PCAP labs, not the Grafana stream. They are
# heavier and can fail to build; don't let that abort the streaming install.
set +e
pip install --break-system-packages --no-input qcsuper \
    'git+https://github.com/shark-fi/scat@master'
[ $? -eq 0 ] && echo "  scat/qcsuper installed" || echo "  WARN: scat/qcsuper not installed (PCAP labs only; streaming unaffected)"
set -e

echo "== free the modem from ModemManager =="
# ModemManager claims the Quectel AT/QMI ports (/dev/ttyUSB2 etc), so qscan
# cannot open them and QMI_WWAN connect labs would fail. CBRSPI disables it;
# connectivity is done via QMI_WWAN instead. Reversible: systemctl enable --now ModemManager
if systemctl is-enabled ModemManager >/dev/null 2>&1 || systemctl is-active ModemManager >/dev/null 2>&1; then
    systemctl disable --now ModemManager || true
    echo "  ModemManager disabled"
else
    echo "  ModemManager already inactive"
fi

echo "== install the qscan datastream files =="
install -d "$GRAF/qscan"
# qscan.py, band helpers, and the stream script
cp -a "$HERE/opt/wlanpi-grafana/qscan/." "$GRAF/qscan/"
chmod +x "$GRAF/qscan/"*.sh "$GRAF/qscan/"*.py 2>/dev/null || true

# convenience symlink used interactively (a wrapper, NOT a bare symlink, so an
# obfuscated qscan.py can still find its pyarmor runtime via sys.path[0])
cat > /usr/local/bin/qscan <<'WRAP'
#!/bin/bash
exec python3 /opt/wlanpi-grafana/qscan/qscan.py "$@"
WRAP
chmod +x /usr/local/bin/qscan

echo "== install the QMI-WWAN connection manager (simcom-cm) =="
# Data-connection labs bring up wwan0 over QMI with the simcom-cm userspace
# manager (symlinked as `qmiwwan`). Unlike Bullseye, DeadEye needs NO
# out-of-tree kernel modules: the stock Trixie kernel's in-tree qmi_wwan +
# option drivers already bind the modem (cdc-wdm0 + wwan0). So this installs
# only the userspace manager + its udhcpc dispatcher script.
install -d "$GRAF/QMI-WWAN/Goonline"
cp -a "$HERE/opt/wlanpi-grafana/QMI-WWAN/Goonline/." "$GRAF/QMI-WWAN/Goonline/"
chmod +x "$GRAF/QMI-WWAN/Goonline/simcom-cm"
# simcom-cm runs `busybox udhcpc -s /usr/share/udhcpc/default.script` to apply
# the lease on wwan0, so that script must be in place (busybox + net-tools are
# already on the image).
install -d /usr/share/udhcpc
install -m 0755 "$HERE/opt/wlanpi-grafana/QMI-WWAN/Goonline/default.script" /usr/share/udhcpc/default.script
ln -sf "$GRAF/QMI-WWAN/Goonline/simcom-cm" /usr/local/bin/qmiwwan
echo "  qmiwwan ready -- connect with:  sudo qmiwwan -s <APN>"

echo "== dashboard =="
# provisioning silently rejects dashboards with a non-null "id"; strip it.
python3 -c "import json,sys; d=json.load(open('$HERE/var/lib/grafana/dashboards/qscan.json')); d['id']=None; json.dump(d, open('/var/lib/grafana/dashboards/qscan.json','w'))"
chown grafana:grafana /var/lib/grafana/dashboards/qscan.json 2>/dev/null || true

echo "== service =="
install -m 0644 "$HERE/lib/systemd/system/wlanpi-grafana-qscan.service" /usr/lib/systemd/system/wlanpi-grafana-qscan.service
# SCAT PCAP capture service -- started on demand from the FPMS "Scan to PCAP"
# menu (left disabled, not auto-started), runs qscan-scat.sh against the modem
# DIAG port. Needs scat (installed above) + pandas.
install -m 0644 "$HERE/lib/systemd/system/wlanpi-scat.service" /usr/lib/systemd/system/wlanpi-scat.service
systemctl daemon-reload
systemctl enable grafana-server >/dev/null 2>&1 || true
systemctl restart grafana-server

echo "== allow the cellular stream in wlanpi-core =="
# The WebUI "Data Streams > Scanner LTE/5G > Play" and the FPMS Scan-to-PCAP
# menu do not run systemctl directly -- they ask wlanpi-core, which gates
# service start/stop against a hardcoded allowed_services list. That list
# ships without our cellular units, so Play is refused with "Could not start
# Grafana Scanner LTE/5G data stream". Insert the units if absent, then
# restart core. Idempotent; re-run after a wlanpi-core package update.
CORE_SS=/opt/wlanpi-core/lib/python3.13/site-packages/wlanpi_core/services/system_service.py
if [ -f "$CORE_SS" ]; then
    python3 - "$CORE_SS" <<'PY' || echo "  WARN: core allowlist patch failed; WebUI Play may be refused"
import sys
path = sys.argv[1]
want = ["wlanpi-grafana-qscan", "wlanpi-scat"]
src = open(path).read()
missing = [s for s in want if f'"{s}"' not in src]
if not missing:
    print("  core allowlist already has the cellular units"); sys.exit(0)
marker = "allowed_services = [\n"
i = src.find(marker)
if i == -1:
    sys.stderr.write("  WARN: allowed_services list not found; core not patched\n"); sys.exit(0)
j = i + len(marker)
open(path, "w").write(src[:j] + "".join(f'    "{s}",\n' for s in missing) + src[j:])
print("  added to core allowlist: " + ", ".join(missing))
PY
    systemctl restart wlanpi-core || true
else
    echo "  WARN: wlanpi-core system_service.py not found; WebUI Play may be refused"
fi

# wait for Grafana to answer, then pre-provision the service-account token so
# the first stream start does not race a still-starting Grafana into 401s.
echo "  waiting for grafana-server..."
for _ in $(seq 1 60); do
    code=$(curl -s --insecure -o /dev/null -w "%{http_code}" https://127.0.0.1:3000/app/grafana/api/health || true)
    [ "$code" = "200" ] && break
    sleep 1
done
/opt/wlanpi-grafana/check-token.sh || echo "  (token will be created on first stream start)"

# The qscan stream is started on demand from the Grafana Data Streams menu
# (Play), exactly like scanner/health/wipry -- left disabled, not auto-started.

echo
echo "Done. Next:"
echo "  1) lock the modem to a band, e.g.:  qscan -b48        (CBRS)  or  qscan -n78"
echo "  2) open Grafana, dashboard 'Cellular LTE/5G'"
echo "  3) top menu > Data Streams > Cellular LTE/5G > Play  (starts wlanpi-grafana-qscan)"
echo "  Serving cell + SINR appear on the same dashboard (AT+QENG, no extra stream)."
