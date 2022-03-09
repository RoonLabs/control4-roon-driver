#!/bin/bash

set -e


VERSION=`date +"%s"`

rm -Rf build_tmp; mkdir build_tmp
cp -r roon_core_driver/* build_tmp
cp -r shared/* build_tmp
pushd build_tmp
sed -i "s/__VERSION__/$VERSION/" driver.xml 
zip -r ../Roon\ Core.c4z *
popd
cp Roon\ Core.c4z /cygdrive/c/Users/$USER/Documents/Control4/Drivers/

rm -Rf build_tmp; mkdir build_tmp
cp -r roon_zone_driver/* build_tmp
cp -r shared/* build_tmp
pushd build_tmp
sed -i "s/__VERSION__/$VERSION/" driver.xml 
zip -r ../Roon\ Zone.c4z *
popd
cp Roon\ Zone.c4z /cygdrive/c/Users/$USER/Documents/Control4/Drivers/

rm -Rf build_tmp
rm -Rf *.stackdump
