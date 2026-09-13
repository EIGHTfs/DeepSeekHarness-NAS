---
source: https://help.synology.com/developer-guide/synology_package/INFO.html
title: INFO
fetched: 2026-09-11
---

# INFO

This file describes the properties of a package

## INFO Field Format:

Each property is defined as key/value pair separated by an equals sign

```
key=value
```

## INFO Field List:

You can define properties according to the requirements:

- Necessary Fields

- Optional Fields

```
thirdparty="yes"
maintainer="mycompany"
description="mydescription"
distributor="mycompany"
package="mypackagename"
silent_install="yes"
silent_uninstall="yes"
silent_upgrade="yes"
os_min_ver="7.0-40000"
version="0.0.1-0001"
arch="noarch"
```

## How to write an INFO File

Instead of writing the INFO file manually, you can use the helper functions in Package Toolkit to generate some fields programmatically.
Please refer to INFO.sh for more information.
