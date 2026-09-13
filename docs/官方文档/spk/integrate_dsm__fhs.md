---
source: https://help.synology.com/developer-guide/integrate_dsm/fhs.html
title: Package Filesystem Hierarchy Standard
fetched: 2026-09-11
---

# Package Filesystem Hierarchy Standard

After the package installed, there will be some directories for package to put their data. There will be **different directories linked for packages who installed on volume partition / system partition**.

```
/var/packages/[package_name]
├── etc     -> /volume[volume_number]/@appconf/[package_name] (move to volume since 7.0-41330, and old path still works)
├── var     -> /volume[volume_number]/@appdata/[package_name]
├── tmp     -> /volume[volume_number]/@apptemp/[package_name]
├── home    -> /volume[volume_number]/@apphome/[package_name]
└── target  -> /volume[volume_number]/@appstore/[package_name]
```

```
/var/packages/[package_name]
├── etc     -> /usr/syno/etc/packages/[package_name]
├── var     -> /usr/local/packages/@appdata/[package_name]
├── tmp     -> /usr/local/packages/@apptemp/[package_name]
├── home    -> /usr/local/packages/@apphome/[package_name]
└── target  -> /usr/local/packages/@appstore/[package_name]
```

> Please refer to install_type in `INFO` for more information about installation on volume / system partition.

****

****

``

****

``

****

``

****
``

``

| Directory | Purpose | Mode | Creation Timing | Remove Timing | Script Variable |
|---|---|---|---|---|---|
| etc | permanant config storage | 0755 | installed / upgraded | none | none |
| var (since 7.0-40314) | permanant data storage | 0755 | installed / upgraded | none | SYNOPKG_PKGVAR |
| tmp (since 7.0-40356) | temporary data storage | 0755 | installed / upgraded | uninstalled / upgrading | SYNOPKG_PKGTMP |
| home (since 7.0-40759) | private storage | 0700 | installed / upgraded | none | SYNOPKG_PKGHOME |
| target | data extracted from package.tgz | 0755 | installed / upgraded | uninstalled / upgrading | SYNOPKG_PKGDEST |

## Directory Owner Rules

- When defaults run-as is package, FHS directories are set to `[packageuser]:[packagegroup]`

- When defaults run-as is root, FHS directories are set to `root:[packagegroup]`

> Please refer to Privilege section for more information about defaults run-as.
