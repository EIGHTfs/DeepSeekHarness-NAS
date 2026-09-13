---
source: https://help.synology.com/developer-guide/synology_package/scripts.html
title: scripts
fetched: 2026-09-11
---

# scripts

This folder contains shell scripts controlling the lifecycle of a package.

``

``

| Script Name | Required | Description |
|---|---|---|
| preinst | O | It can be used to check conditions before installation but not to make side effects onto the system. Package installation will be aborted for non-zero returned value. |
| postinst | O | It can be used to prepare environment for package after installed. Package status will become corrupted for non-zero returned value. |
| preuninst | O | It can be used to check conditions before uninstallation but not to make side effects onto the system. Package uninstallation will be aborted for non-zero returned value. |
| postuninst | O | It can be used to cleanup environment for package after uninstalled. |
| preupgrade | O | It can be used to check conditions before upgrade but not to make side effects onto the system. Package upgrade will be aborted for non-zero returned value. |
| postupgrade | O | It can be used to prepare environment for package after upgraded. Package status will become corrupted for non-zero returned value. |
| prereplace | X | It can be used to do data migration when install_replace_packages is defined in INFO for package replacement. Package replacement will be aborted for non-zero returned value. |
| postreplace | X | It can be used to do data migration when install_replace_packages is defined in INFO for package replacement. Package replacement will be aborted for non-zero returned value. |
| start-stop-status | O | It can be used to control package lifecycle. |

The simplest implemenation of script is just doing nothing:

```
#!/bin/sh

exit 0
```

> Please refer to Script Messages for mechanism to show messages to users.

## start-stop-status

```
#!/bin/sh

case "$1" in
    start)
        ;;
    stop)
        ;;
    status)
        ;;
esac

exit 0
```

This script is used to start, stop a package and detect running status. DSM would call this script with different parameters in different scenario:

-

**start**: When a user runs the package or the system is turning on, the package should do its start operation.

-

**stop**: When a user stops the package or the system is turning off, the package should do its stop operation.

-

**status**: When the package status is being checked, the following exit codes should be returned according to its status:

```
 0: package is running.
 1: program of package is dead and /var/run pid file exists.
 2: program of package is dead and /var/lock lock file exists
 3: package is not running
 4: package status is unknown
 150: package is broken and should be reinstalled.
```

-

**prestart**: If precheckstartstop in `INFO` is set to `yes`, the package could check if it is allowed to be started.

> Note: It will also run before starting a package at booting up after DSM 7.0.

-

**prestop**: If precheckstartstop in `INFO` is set to `yes`, the package could check if it is allowed to be stopped.

> Note: It won't run before stopping a package at shutting down.

## Execution Order

### Installation

1. prereplace

2. preinst

3. postinst

4. postreplace

5. start-stop-status with prestart argument if end user chooses to start it immediately

6. start-stop-status with start argument if end user chooses to start it immediately

### Upgrade

1. start-stop-status with prestop argument if it has been started (old)

2. start-stop-status with stop argument if it has been started (old)

3. preupgrade (new)

4. preuninst (old)

5. postuninst (old)

6. prereplace (new)

7. preinst (new)

8. postinst (new)

9. postreplace (new)

10. postupgrade (new)

11. start-stop-status with prestart argument if it was started before being upgraded (new)

12. start-stop-status with start argument if it was started before being upgraded (new)

### Uninstallation

1. start-stop-status with prestop argument if it has been started

2. start-stop-status with stop argument if it has been started

3. preuninst

4. postuninst

### Start

1. start-stop-status with prestart argument

2. start-stop-status with start argument

### Stop

1. start-stop-status with prestop argument

2. start-stop-status with stop argument
