---
source: https://help.synology.com/developer-guide/synology_package/pkgdeps.html
title: PKG_DEPS
fetched: 2026-09-11
---

## PKG_DEPS

The PKG_DEPS is similar to **install_dep_packages** key in **INFO** file, but it additionally defines the restriction according to specific OS versions.

> priority of `PKG_DEPS` is higher than `install_dep_packages` in `INFO`

Each configuration file is defined in standard **.ini** file format with key/value pairs and sections. A section describes a unique name of dependent/conflicting package. Each section contains information about the requirements of package versions and the restriction of OS versions.

``

``

| Key | Availability | Description | Value |
|---|---|---|---|
| pkg_min_ver | DSM4.2 | Minimum version of dependent package. | Package version |
| pkg_max_ver | DSM4.2 | Maximum version of dependent package. | Package version |
| dsm_min_ver | DSM4.2 - DSM7.1 | Minimum required DSM version. Replaced by os_min_ver since DSM7.2 | X.Y-Z DSM major number, DSM minor number, DSM build number |
| dsm_max_ver | DSM4.2 - DSM7.1 | Maximum required DSM version. Replaced by os_max_ver since DSM7.2 | X.Y-Z DSM major number, DSM minor number, DSM build number |
| os_min_ver | DSM7.2-60112 | Minimum required OS version. | X.Y-Z OS major number, OS minor number, OS build number |
| os_max_ver | DSM7.2-60112 | Maximum required OS version. | X.Y-Z OS major number, OS minor number, OS build number |

```
; Your package depends on Package A in any version
[Package A]

; Your package depends on Package B version 2 or newer
[Package B]
pkg_min_ver=2

; Your package depends on Package C with version 2 or older
[Package C]
pkg_max_ver=2

; Your package depends on Package D with version 2 or newer but it will be ignored when OS version is smaller than 7.2-60000
[Package D]
os_min_ver=7.2-60000
pkg_min_ver=2

; Your package depends on Package E with version 2 or newer but it will be ignored when OS version is bigger than 7.2-60000
[Package E]
os_max_ver=7.2-60000
pkg_min_ver=2
```
