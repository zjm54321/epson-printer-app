#!/usr/bin/env bash
set -euo pipefail
# Build-container only: package maintainer scripts must not launch services.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends avahi-daemon dbus
rm /usr/sbin/policy-rc.d
groupadd --gid 584792 printer
useradd --uid 584792 --gid 584792 --home-dir /tmp --no-create-home --shell /usr/sbin/nologin printer
chmod 0755 /usr/local/bin/epson-discovery-entrypoint
mkdir -p /discovery-source/{manifests,licenses} /usr/share/epson-discovery
dpkg-query -W -f='${Package}\t${Version}\t${source:Package}\t${source:Version}\n' \
  > /discovery-source/manifests/discovery-packages.tsv
cp /discovery-source/manifests/discovery-packages.tsv /usr/share/epson-discovery/
while IFS=$'\t' read -r package _; do
  if [[ -f /usr/share/doc/$package/copyright ]]; then
    mkdir -p "/discovery-source/licenses/$package" "/usr/share/licenses/epson-discovery/$package"
    cp -L "/usr/share/doc/$package/copyright" "/discovery-source/licenses/$package/copyright"
    cp -L "/usr/share/doc/$package/copyright" "/usr/share/licenses/epson-discovery/$package/copyright"
  fi
done < /discovery-source/manifests/discovery-packages.tsv
find / -xdev -type f -perm /6000 -exec chmod a-s {} +
getcap -r / 2>/dev/null | while read -r path _; do setcap -r "$path"; done
rm -rf /var/lib/apt/lists/*
