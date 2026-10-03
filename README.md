# cbrspi-install

Installation package for the CBRS / Cellular Deep Dive WLAN Pi labs.

## Prerequisites

Install the serial console tool and the Python dependencies:

```bash
sudo apt install minicom
sudo pip install timezonefinder netifaces signalcat crcmod pycrate
sudo pip3 install --upgrade qcsuper
```

> `signalcat` is the PyPI name for `scat`; `crcmod` and `pycrate` back the
> QCSuper PCAP capture. `qscan` itself only needs `timezonefinder` and
> `netifaces` (everything else it uses is in the Python 3.9 standard library).

## Install

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
