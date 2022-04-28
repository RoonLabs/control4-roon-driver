# Roon x Control4: Development Guide

Note that Roon Labs has no current plans to do additional development work on this driver.  We're able to answer
specific questions about the driver design or RoonAPI, and could merge pull requests, but that is about the limit.

## Dev Cycle

The `build.sh` in this directory builds packages that can be loaded directly into composer.

Note: `build.sh` does not encrypt the packages--that must be done using C4's IDE.

There are two drivers for Roon:

- `roon_core_driver` - Represents a Roon Core
- `roon_zone_driver` - Represents one Zone in Roon

Typically, during development, I will run `build.sh` in a minimized terminal like this:

    $ while true; do ./build.sh; sleep 2; done

And let it continuously produce `.zip` files in the background. 

When I want to pull my changes into Control:4, I go over to composer, right-click either a Roon Zone or the Roon Core and select "Update Driver".

Note: you need to update the driver once per zone if there are multiple zones.

Then once the drivers are updated, Use File -> Refresh Navigators to force the C4 apps to reflect the changes. This step can sometimes be skipped. You'll learn when by trial+error.

## Release Process

1. Bump the version number in release.sh

2. Run release.sh
./release.sh

3. release.sh copies output to bin/release/core and bin/release/zone, for each of these:
   open the driver project in the Control4 DriverEditor IDE
   build the project by selecting project -> build
   close the project

4. The DriverEditor IDE from step 3 will create a "Roon Core.c4z" and "Roon Zone.c4z" file in Documents\Control4\Drivers

5. See file `'Roon x Control_4.docx'` for instructions on using the driver with a Control4 system and Roon

## Roon APIs

The best public documentation for the Roon API that these drivers interact with is the documentation included with the
Node client library here: https://github.com/RoonLabs/node-roon-api

