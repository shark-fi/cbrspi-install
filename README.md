sudo apt install minicom

sudo pip install backports.zoneinfo

sudo pip install timezonefinder

sudo pip install netifaces

sudo pip install signalcat

sudo pip3 install --upgrade qcsuper

sudo pip install crcmod

sudo pip install pycrate

git clone https://github.com/shark-fi/cbrspi-install.git

cd cbrspi-install

sudo dpkg -i --force-overwrite cbrspi.deb

sudo rm /usr/local/bin/qscan

sudo ln -s /opt/wlanpi-grafana/qscan/qscan.py /usr/local/bin/qscan
