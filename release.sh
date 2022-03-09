#!/bin/bash

set -e

VERSION="100000010"
MODIFIED=`date '+%m\/%d\/%Y %H:%M'`

rm -Rf bin/release

mkdir -p bin/release/core
cp -r roon_core_driver/* bin/release/core
cp -r shared/* bin/release/core
pushd bin/release/core
sed -i "s/__VERSION__/$VERSION/" driver.xml
sed -i "s/__MODIFIED__/$MODIFIED/" driver.xml
popd

mkdir -p bin/release/zone
cp -r roon_zone_driver/* bin/release/zone
cp -r shared/* bin/release/zone
pushd bin/release/zone
sed -i "s/__VERSION__/$VERSION/" driver.xml
sed -i "s/__MODIFIED__/$MODIFIED/" driver.xml
popd

rm -Rf *.stackdump
