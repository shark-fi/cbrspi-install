#!/bin/bash
# Stream cellular ("qscan") + satellite ("satellite") line protocol to Grafana
# Live channel "piscat" for the CBRSPI dashboards.
#
# We push with our OWN curl loop instead of the shared to-grafana.sh: that
# script has no --max-time, so a single hung Grafana Live push fills the pipe
# and blocks qscan on stdout write -- the stream then silently stalls (qscan
# alive but idle, no data) until restarted. --max-time caps any hang so the
# pipeline keeps moving.
#
# -gbands is intentionally omitted (its modem band query can crash qscan).
# The trailing ns timestamp is stripped so Grafana 13 Live stamps arrival time.

GRAFANA_URL="https://localhost:3000/app/grafana/api/live/push/piscat"

# Retry check-token until a valid token exists (grafana may still be starting).
for _ in $(seq 1 30); do
    /opt/wlanpi-grafana/check-token.sh || true
    set -a; source /etc/environment 2>/dev/null; set +a
    [ "${#GRAFANA_TOKEN}" -ge 40 ] && break
    sleep 2
done

push_to_live() {
    while IFS= read -r line; do
        curl -s --insecure --max-time 5 \
            -X POST -H "Authorization: Bearer $GRAFANA_TOKEN" \
            -d "$line" "$GRAFANA_URL" >/dev/null 2>&1
    done
}

QSCAN=/opt/wlanpi-grafana/qscan/qscan.py
while true; do
    python3 "$QSCAN" -cs -gs --gbands \
        | python3 /opt/wlanpi-grafana/qscan/scan-aggregator.py \
        | grep --line-buffered -E '^(qscan|scell|satellite|bands-conf|scan_proto|scan_carrier|scan_summary)' \
        | sed -u -E 's/ [0-9]{16,19}$//; s/=None/=0/g' \
        | push_to_live
    sleep 3   # never tight-loop if qscan exits
done
