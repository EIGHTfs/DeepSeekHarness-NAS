---
source: https://help.synology.com/developer-guide/synology_package/introduction.html
title: Package Introduction
fetched: 2026-09-11
---

# Package Introduction

In this section, you will learn the layout of synology package (.spk) and the meaning of each file.

```
spk
├── INFO
├── package.tgz
├── scripts
│   ├── postinst
│   ├── postuninst
│   ├── postupgrade
│   ├── preinst
│   ├── preuninst
│   ├── preupgrade
│   └── start-stop-status
├── conf
│   ├── privilege
│   └── resource
├── WIZARD_UIFILES
│   ├── install_uifile
│   └── uninstall_uifile
├── LICENSE
├── PACKAGE_ICON.PNG
└── PACKAGE_ICON_256.PNG
```

# Package Structure

A Synology package contains the following files:

| File/Folder Name(case sensitive) | Required | Description | File/Folder Type | DSM Requirement |
|---|---|---|---|---|
| INFO | O | This file describes the properties of a package. | Properties File | 2.0-0731 |
| package.tgz | O | This is a compressed file containing all the files that should be extracted into the system, such as executable binaries, libraries, or UI files. | TGZ File | 2.0-0731 |
| scripts | O | This folder contains shell scripts which control the lifecycle of a package. | Folder | 2.0-0731 |
| conf | O | This folder contains additional configurations. | Folder | 4.2-3160 |
| WIZARD_UIFILES 7.2.2 | X | This folder contains wizard UI files which are used to guide package user in the installation / uninstallation procedure. | Folder | 7.2.2 |
| LICENSE | X | The file content will show on UI in the installation procedure. It must be less than 1 MB. | Text File | 3.2-1922 |
| PACKAGE_ICON.PNG | O | PNG format image shown in Package CenterFor DSM 6.x, the dimension should be 72 x 72.For DSM 7.0 or above, the image dimension should be 64 x 64. | PNG file | 3.2-1922 |
| PACKAGE_ICON_256.PNG | O | PNG format image shown in Package Center. Its dimension should be 256 x 256. | PNG file | 5.0-4400 |

> To create such package layout, please refer to the Pack Stage for detailed steps.
