#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential autoconf automake autopoint libtool autotools-dev pkg-config \
  git curl xz-utils python3 gettext sharutils perl patch \
  libavahi-client-dev libavahi-common-dev libavahi-compat-libdnssd-dev libdbus-1-dev \
  libgnutls28-dev libjpeg-dev libpng-dev libusb-1.0-0-dev zlib1g-dev libpam0g-dev \
  libfontconfig1-dev libfreetype6-dev libpaper-dev liblcms2-dev libpoppler-cpp-dev \
  libtiff-dev libexif-dev libqpdf-dev poppler-utils \
  foomatic-db-engine=4.0.13-6
pkg-config --atleast-version=11 libqpdf
test "$(dpkg-query -W -f='${Version}' foomatic-db-engine)" = 4.0.13-6
mkdir -p /corresponding-source/manifests
dpkg-query -W -f='${Package}\t${Version}\t${source:Package}\t${source:Version}\n' \
  > /corresponding-source/manifests/build-packages.tsv
