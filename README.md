# cbrspi-install

Installation package for the CBRS / Cellular Deep Dive WLAN Pi labs.

Two WLAN Pi OS generations are supported — pick the one your image matches:

| WLAN Pi OS | Debian | Python | Install |
| --- | --- | --- | --- |
| 3.x "Bullseye" (classic) | 11 | 3.9 | `.deb` package — [Bullseye](#bullseye-wlan-pi-os-3x) below |
| 26.10 "DeadEye" and newer | 13 (Trixie) | 3.13 | file-copy scripts — [`deadeye/`](deadeye/) |

Not sure which you have? Run `cat /etc/os-release`: `VERSION_CODENAME=bullseye`
→ Bullseye; `trixie` → DeadEye.

All cbrspi Python (the `qscan` engine, the FPMS Cellular app, the band helpers)
is PyArmor-obfuscated in both the `.deb` and the DeadEye tree.

---

## Bullseye (WLAN Pi OS 3.x)

### Prerequisites

Install the serial console tool and the Python dependencies:

```bash
sudo apt install minicom
sudo pip install timezonefinder netifaces signalcat crcmod pycrate
sudo pip3 install --upgrade qcsuper
```

> `signalcat` is the PyPI name for `scat`; `crcmod` and `pycrate` back the
> QCSuper PCAP capture. `qscan` itself only needs `timezonefinder` and
> `netifaces` (everything else it uses is in the Python 3.9 standard library).

### Install

```bash
git clone https://github.com/shark-fi/cbrspi-install.git
cd cbrspi-install
sudo dpkg -i cbrspi-install.deb
sudo rm -f /usr/local/bin/qscan
sudo ln -s /opt/wlanpi-grafana/qscan/qscan.py /usr/local/bin/qscan
```

If `dpkg` reports missing dependencies, run `sudo apt -f install` and then
re-run the `dpkg -i` line.

Reboot the WLAN Pi and the software is ready.

---

## DeadEye (WLAN Pi OS 26.10 / Trixie)

DeadEye's FPMS is a Python 3.13 virtualenv and its stock packages are newer, so
the install is a set of file-copy scripts in [`deadeye/`](deadeye/) rather than
a `.deb`.

### 1. Set the clock

The DeadEye image has no RTC and its time sync is wedged, so a fresh boot's
clock is hours off — apt then rejects every repo signature ("InRelease … not
live until …"). Set it once from an HTTPS `Date` header:

```bash
sudo date -u -s "$(curl -sI https://www.cloudflare.com | grep -i '^date:' | sed 's/^[Dd]ate: *//')"
```

`install-deadeye.sh` repeats this, and the `chrony` it installs keeps the clock
correct from then on — but the Grafana install in step 2 needs the clock right
first.

### 2. Install Grafana

The 26.10 image ships **without** Grafana (removed to keep the image under
GitHub's 2 GiB file-size limit). The Grafana signing key already ships on the
image, so just add the apt source and install the WLAN Pi Grafana package:

```bash
echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update
sudo apt install -y wlanpi-grafana
```

### 3. Install the cellular stack

```bash
git clone https://github.com/shark-fi/cbrspi-install.git
cd cbrspi-install/deadeye
sudo bash install-deadeye.sh
bash install-fpms-deadeye.sh
```

- **`install-deadeye.sh`** (run with `sudo`) installs the `qscan` datastream +
  dashboard, pulls the Python deps (`chrony`, pyserial, numpy, pandas,
  timezonefinder, …), frees the modem from ModemManager, and allows the stream
  in `wlanpi-core`.
- **`install-fpms-deadeye.sh`** (run as your normal user — it elevates each step
  itself) adds the FPMS "Cellular" menu and the NetViews remote-menu hook.

Reboot the WLAN Pi.

### Using it

- **OLED / NetViews:** the **Cellular** menu → lock a band, then **Cellular
  Survey → Scan & View** shows live LTE/5G cells on screen.
- **Grafana:** top menu → **Data Streams → Scanner LTE/5G → Play**, then open
  the **Scanner LTE/5G** dashboard (serving cell + SINR + band scan).

Re-run the matching script after a `wlanpi-fpms`, `wlanpi-grafana`, or
`wlanpi-core` package update — each overlays files those packages own, and an
update restores the stock versions.
