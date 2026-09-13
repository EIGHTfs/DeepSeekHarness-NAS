---
source: https://help.synology.com/developer-guide/resource_acquisition/systemd_user_unit.html
title: Systemd User Unit
fetched: 2026-09-11
---

# Systemd User Unit

#### Description

The package framework would copy files at `conf/systemd/pkguser-[customname]` to `home/.config/systemd/user/` on acquired and remove them on released.

> note that user unit cannot be related with normal systemd unit. If you need your package to be related with system service, please refer to start_dep_services

The package should use `synosystemctl start` and `synosystemctl stop` to control user units inside scripts.

#### Extra

If you want to have systemd unit inside the system, you may just put your units at `conf/systemd/pkg-[customname]` **without** the need to use this `systemd-user-unit` worker.

The package framework would copy systemd units to `/usr/local/lib/systemd/system` on acquired and remove them on released.

#### Provider

DSM

#### Since

7.0-40761

#### Timing

`FROM_POSTINST_TO_POSTUNINST`

#### Syntax

```
"systemd-user-unit": {}
```
