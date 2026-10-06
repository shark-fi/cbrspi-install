#!/usr/bin/env bash
# Prepare a fresh WLAN Pi OS DeadEye (26.10 / Trixie) image for the cbrspi
# cellular stack: fix the clock, add the Grafana apt repo, and install
# wlanpi-grafana. Run this FIRST, before install-deadeye.sh.
#
# Why this is a separate step: the 26.10 image ships WITHOUT Grafana (removed
# to keep the image under GitHub's 2 GiB limit), and it has no RTC with a
# wedged time sync -- so apt rejects repo signatures until the clock is set.
# install-deadeye.sh bootstraps the clock too, but the Grafana install has to
# happen before it, so the bootstrap is repeated here.
#
# Run with sudo on the Pi.  Idempotent: safe to re-run.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash $0"; exit 1; }

# The DeadEye image has no RTC and its stock timesyncd is wedged, so a fresh
# boot has a skewed clock. apt then rejects repo signatures ("InRelease is not
# signed / not live until <future>") and every apt call fails. chrony (pulled
# in by install-deadeye.sh) fixes this permanently; bootstrap the clock here
# from an HTTPS Date header first so apt works at all. (TLS still works with a
# ~hours skew, so curl is fine to read the real time.)
if ! timedatectl 2>/dev/null | grep -qi "synchronized: yes"; then
    echo "== bootstrap clock (no RTC; apt signatures need correct time) =="
    REALTIME=$(curl -sI https://www.cloudflare.com 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: *//')
    if [ -n "$REALTIME" ]; then
        date -u -s "$REALTIME" >/dev/null 2>&1 && echo "  clock set to $(date -u)"
    else
        echo "  WARN: could not fetch time; if apt fails on signatures, fix the clock manually"
    fi
fi

echo "== add the Grafana apt repo =="
# The image ships the Grafana signing key at /usr/share/keyrings/grafana.key
# but not the apt source. Use the shipped key if present; otherwise fetch and
# dearmor it into /etc/apt/keyrings.
KEYRING=/usr/share/keyrings/grafana.key
if [ ! -s "$KEYRING" ]; then
    echo "  shipped key missing; fetching from apt.grafana.com"
    install -d /etc/apt/keyrings
    KEYRING=/etc/apt/keyrings/grafana.gpg
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o "$KEYRING"
fi
echo "deb [signed-by=$KEYRING] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
echo "  source: $(cat /etc/apt/sources.list.d/grafana.list)"

echo "== install wlanpi-grafana (pulls grafana) =="
apt-get update -qq
apt-get install -y wlanpi-grafana

echo
echo "Done. Grafana installed. Next:"
echo "  sudo bash install-deadeye.sh        # qscan datastream + dashboard"
echo "  bash install-fpms-deadeye.sh        # FPMS Cellular menu"
