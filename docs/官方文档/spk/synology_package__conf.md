---
source: https://help.synology.com/developer-guide/synology_package/conf.html
title: conf
fetched: 2026-09-11
---

# conf

The **conf** folder contains the following files:

| File/Folder Name | Required | Description | File/Folder Type | DSM Requirement |
|---|---|---|---|---|
| PKG_DEPS | X | Define dependency between packages with restrictions of DSM version. | File | 4.2-3160 |
| PKG_CONX | X | Define conflicts between packages with restrictions of DSM version. | File | 4.2-3160 |
| privilege | O | Define file privilege and execution privilege to secure the package. | File | 6.2-5891 |
| resource | X | Define system resources that can be used in the lifecycle of package. | File | 6.2-5941 |

**Since DSM 7.0, all packages are forced to lower the privilege explicitly. The `privilege` must be provided for package to work.**
