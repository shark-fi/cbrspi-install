#!/bin/bash
# Stream Qualcomm DIAG from the Quectel modem to a SCAT PCAP (+qmdl +text log).
datetime=$(date +"%Y-%m-%d_%H-%M-%S")
filename="scat_${datetime}"
pcap_file="/home/wlanpi/${filename}.pcap"
txt_file="/home/wlanpi/${filename}.txt"
qmdl_file="/home/wlanpi/${filename}.qmdl"

# DIAG (DM) port = Quectel if00 interface; fall back to ttyUSB0.
diag_port=$(ls /dev/serial/by-id/*Quectel*if00* 2>/dev/null | head -1)
diag_port=${diag_port:-/dev/ttyUSB0}

# -L nas,rrc captures control-plane SIGNALING only: RRC (including BCCH/SIB
# broadcast + connection signaling) and NAS. scat's default is "ip,nas,rrc",
# and the "ip" layer is the USER PLANE -- it would also capture subscriber
# traffic (DNS, app data) once a data session is up. Dropping "ip" keeps the
# PCAP to over-the-air signaling, which is what the labs analyze.
scat -t qc -s "$diag_port" -L nas,rrc --qmdl "$qmdl_file" -F "$pcap_file" > "$txt_file"
