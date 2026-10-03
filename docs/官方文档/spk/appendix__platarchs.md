---
source: https://help.synology.com/developer-guide/appendix/platarchs.html
title: Appendix A: Platform and Arch Value Mapping Table
fetched: 2026-09-11
---

# Appendix A: Platform and Arch Value Mapping Table

The architecture of the NAS is developed upon various platforms on which your package is designed and needs to be addressed in the **INFO** file in the package.

In the below table, you will find the string value corresponding to the platform in question. For example, if the platform of your NAS is Marvell ARMADA 370, armada370, the value that should to be provided as a pair of the arch key is `armada370`.

Please check the platforms of the NAS to be supported and refer to the table below for their corresponding string values:

| Arch Family | Member platforms |
|---|---|
| noarch | (all platforms) |
| x86_64 | apollolake, avoton, braswell, broadwell, broadwellnk, broadwellntb, broadwellntbap, bromolow, cedarview, coffeelake, denverton, geminilake, grantley, kvmx64, purley, skylaked, v1000 |
| i686 | evansport |
| armv7 | alpine, alpine4k |
| armv5 | 628x |
| armv8 | rtd1296, armada37xx, rtd1619, rtd1619b |

Supported platform value list:

- alpine

- alpine4k

- apollolake

- armada370

- armada375

- armada37xx

- armada38x

- armadaxp

- avoton

- braswell

- broadwell

- broadwellnk

- broadwellntb

- broadwellntbap

- bromolow

- cedarview

- coffeelake

- comcerto2k

- denverton

- evansport

- geminilake

- grantley

- kvmx64

- monaco

- purley

- rtd1296

- rtd1619

- rtd1619b

- skylaked

- v1000

You can check the "Package Arch" field in the CPU list to find out which arch does your NAS belong to.
