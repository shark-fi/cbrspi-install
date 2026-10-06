#!/usr/bin/env bash
# MiFi mode for WLAN Pi OS DeadEye (26.10 / Trixie).
#
# Turns the onboard wlan0 (Broadcom, AP-capable) into a Wi-Fi AP and shares the
# cellular uplink (wwan0) to the clients. NetworkManager leaves wlan0 unmanaged
# on this image (99-wlanpi-unmanaged-wifi.conf, so the scanning tools own the
# radios), so -- unlike a NM shared-AP -- MiFi drives wlan0 directly with
# hostapd + dnsmasq + nftables. This is the Trixie equivalent of the Bullseye
# wlanpi-mifi stack (hostapd on wlan0 + isc-dhcp-server + ufw NAT), with
# dnsmasq replacing isc-dhcp-server and nftables replacing ufw. No reboot.
#
# Usage: mifi-deadeye.sh {on|off|status}   (run with sudo)
set -u

# NOTE: MiFi is an overlay on DeadEye, NOT a stock wlanpi "mode" -- do not write
# /etc/wlanpi-state ("mifi" is not a value stock FPMS recognises and setting it
# stops FPMS from starting). State is tracked by the mifi-hostapd service.
CONF=/etc/wlanpi-mifi-deadeye.conf
RUNDIR=/etc/wlanpi-mifi
IFACE=wlan0
AP_IP=172.16.43.1
AP_CIDR=24
DHCP_LO=172.16.43.100
DHCP_HI=172.16.43.200
NFT_TABLE=mifi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0 $*"; exit 1; }

load_conf() {
    if [ ! -f "$CONF" ]; then
        local mac3 psk
        mac3=$(cat /sys/class/net/$IFACE/address 2>/dev/null | tr -d ':' | tail -c 7 | head -c 6)
        psk=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
        {
            echo "# WLAN Pi DeadEye MiFi AP settings"
            echo "MIFI_SSID=\"wlanpi-mifi-${mac3:-ap}\""
            echo "MIFI_PSK=\"${psk}\""
            echo "MIFI_CHANNEL=6"
            echo "MIFI_COUNTRY=US"
        } > "$CONF"
        chmod 600 "$CONF"
    fi
    # shellcheck disable=SC1090
    . "$CONF"
}

write_confs() {
    mkdir -p "$RUNDIR"
    cat > "$RUNDIR/hostapd.conf" <<EOF
interface=$IFACE
driver=nl80211
ssid=$MIFI_SSID
hw_mode=g
channel=${MIFI_CHANNEL:-6}
country_code=${MIFI_COUNTRY:-US}
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$MIFI_PSK
EOF
    chmod 600 "$RUNDIR/hostapd.conf"
    cat > "$RUNDIR/dnsmasq.conf" <<EOF
interface=$IFACE
bind-interfaces
listen-address=$AP_IP
dhcp-range=$DHCP_LO,$DHCP_HI,255.255.255.0,24h
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
server=1.1.1.1
server=8.8.8.8
EOF
}

# remove the FORWARD accept rules we tagged with comment "$NFT_TABLE"
clear_fwd_rules() {
    local h
    for h in $(nft -a list chain ip filter FORWARD 2>/dev/null | awk "/comment \"$NFT_TABLE\"/{print \$NF}"); do
        nft delete rule ip filter FORWARD handle "$h" 2>/dev/null
    done
}

mifi_on() {
    load_conf
    write_confs
    echo "== MiFi on: $IFACE AP '$MIFI_SSID' @ $AP_IP =="
    # wlan0 is NM-unmanaged; configure it directly.
    ip addr flush dev "$IFACE" 2>/dev/null
    ip addr add "$AP_IP/$AP_CIDR" dev "$IFACE"
    ip link set "$IFACE" up
    sysctl -qw net.ipv4.ip_forward=1
    # NAT the AP subnet out whatever holds the default route (wwan0 when the
    # modem is connected, otherwise eth0/Wi-Fi). Own table so teardown is clean.
    nft delete table ip "$NFT_TABLE" 2>/dev/null
    nft add table ip "$NFT_TABLE"
    nft "add chain ip $NFT_TABLE post { type nat hook postrouting priority 100 ; }"
    nft "add rule ip $NFT_TABLE post ip saddr $AP_IP/$AP_CIDR oifname != \"$IFACE\" masquerade"
    # The image ships an iptables-nft 'ip filter' FORWARD chain with policy drop,
    # so forwarded AP traffic would be dropped. A separate base chain can't
    # override another chain's drop, so insert accept rules INTO FORWARD itself
    # (tagged with a comment so we can remove exactly ours on teardown).
    clear_fwd_rules
    nft insert rule ip filter FORWARD oifname "\"$IFACE\"" ct state related,established accept comment "\"$NFT_TABLE\""
    nft insert rule ip filter FORWARD iifname "\"$IFACE\"" accept comment "\"$NFT_TABLE\""
    systemctl restart mifi-hostapd mifi-dnsmasq
    sleep 2
    if ! systemctl is-active --quiet mifi-hostapd; then
        echo "  FAILED: hostapd did not start"; journalctl -u mifi-hostapd -n 8 --no-pager; return 1
    fi
    echo "  SSID: $MIFI_SSID"
    echo "  PSK:  $MIFI_PSK"
    echo "  AP IP: $AP_IP  (DHCP $DHCP_LO-$DHCP_HI, NAT out the active uplink)"
}

mifi_off() {
    echo "== MiFi off: tearing down the AP, returning $IFACE to scanning =="
    systemctl stop mifi-dnsmasq mifi-hostapd 2>/dev/null
    nft delete table ip "$NFT_TABLE" 2>/dev/null
    clear_fwd_rules
    ip addr flush dev "$IFACE" 2>/dev/null
    ip link set "$IFACE" down 2>/dev/null
    echo "  done"
}

mifi_status() {
    local ha; ha=$(systemctl is-active mifi-hostapd 2>/dev/null)
    echo "state: $([ "$ha" = active ] && echo mifi || echo off)"
    echo "hostapd: $ha   dnsmasq: $(systemctl is-active mifi-dnsmasq 2>/dev/null)"
    ip -4 addr show "$IFACE" 2>/dev/null | grep -q "$AP_IP" && echo "$IFACE has $AP_IP"
    if systemctl is-active --quiet mifi-hostapd && [ -f "$CONF" ]; then
        . "$CONF"; echo "SSID: $MIFI_SSID  PSK: $MIFI_PSK"
        echo "clients: $(iw dev $IFACE station dump 2>/dev/null | grep -c Station)"
    fi
}

case "${1:-}" in
    on)     mifi_on ;;
    off)    mifi_off ;;
    status) mifi_status ;;
    *)      echo "usage: $0 {on|off|status}"; exit 1 ;;
esac
