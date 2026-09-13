---
source: https://help.synology.com/developer-guide/synology_package/pkgconx.html
title: PKG_CONX
fetched: 2026-09-11
---

## PKG_CONX

The PKG_CONX is similar to **install_conflict_packages** key in **INFO** file, but it additionally defines the restriction according to specific OS versions.

> priority of `PKG_CONX` is higher than `install_conflict_packages` in `INFO`

Each configuration file is defined in standard **.ini** file format with key/value pairs and sections. A section describes a unique name of dependent/conflicting package. Each section contains information about the requirements of package versions and the restriction of OS versions.

``

``

| Key | Availability | Description | Value |
|---|---|---|---|
| pkg_min_ver | DSM4.2 | Minimum version of conflicting package. | Package Version |
| pkg_max_ver | DSM4.2 | Maximum version of conflicting package. | Package Version |
| dsm_min_ver | DSM4.2 - DSM7.1 | Minimum required DSM version. Replaced by os_min_ver since DSM7.2 | X.Y-Z DSM major number, DSM minor number, DSM build number |
| dsm_max_ver | DSM4.2 - DSM7.1 | Maximum required DSM version. Replaced by os_max_ver since DSM7.2 | X.Y-Z DSM major number, DSM minor number, DSM build number |
| os_min_ver | DSM7.2-60112 | Minimum required OS version. | X.Y-Z OS major number, OS minor number, OS build number |
| os_max_ver | DSM7.2-60112 | Maximum required OS version. | X.Y-Z OS major number, OS minor number, OS build number |

```
; Your package conflicts with Package A in any version
[Package A]

; Your package conflicts with Package B version 2 or newer
[Package B]
pkg_min_ver=2

; Your package conflicts with Package C version 2 or older
[Package C]
pkg_max_ver=2

; Your package conflicts with Package D version 2 or newer, but it will be ignored when OS version is smaller than 7.2-60000
[Package D]
os_min_ver=7.2-60000
pkg_min_ver=2

; Your package conflicts with Package E with version 2 or newer but it will be ignored when OS version is bigger than 7.2-60000
[Package E]
os_max_ver=7.2-60000
pkg_min_ver=2
```
