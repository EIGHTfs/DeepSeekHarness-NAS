---
source: https://help.synology.com/developer-guide/resource_acquisition/timing.html
title: Resource Timing
fetched: 2026-09-11
---

# Resource Timing

Every worker acquires resources at certain timings and holds it during an interval. For example, */usr/local linker* holds the resource during the interval `FROM_ENABLE_TO_DISABLE`, which means it acquires resource at `WHEN_ENABLE` and releases it at `WHEN_DISABLE`. The timings are listed and explained below:

``
**

``
**

``
``****

``
**

``
**

``
**

``
``****

``
**

| timing | descrioption | when Failure |
|---|---|---|
| WHEN_PREINST | before preinst | abort installation, rollback, show alert message on UI |
| WHEN_POSTINST | before postinst | finish installation, show alert message on UI |
| WHEN_ENABLE | before WHEN_STARTUP, won't process during bootup | abort startup, rollback, show alert message on UI |
| WHEN_STARTUP | before start | abort startup, rollback, show alert message on UI |
| WHEN_PREUNINST | after preuninst | finish uninstallation, show alert message on UI |
| WHEN_POSTUNINST | before postuninst | finish uninstallation, show alert message on UI |
| WHEN_DISABLE | after WHEN_HALT, won't process during shutdown | ignore |
| WHEN_HALT | after stop | ignore |

NOTE To let the package itself decide whether uninstallation should continue or not, `WHEN_PREUNINST` is processed after the `preuninst` script.
