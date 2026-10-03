---
source: https://help.synology.com/developer-guide/toolkit/toolkit.html
title: Synology Toolkit
fetched: 2026-09-11
---

# Synology Toolkit

In this section, we will explain the workflow of Package Toolkit. If you want to build a Synology Package without using Package Toolkit, you must:

- Prepare a cross compile tool chain

- Prepare a build environment

- Prepare metadata

- Compile source code

- Pack the package

Creating a package manually can be very complex for most developers, so we recommended using the Package Toolkit to make the package creation process easier.

```
/toolkit/
├── build_env/
│   └── ds.${platform}-${version}/
└── pkgscripts-ng/
    ├── EnvDeploy
    └── PkgCreate.py
```

## Create Package Workflow:

There are two stages in the `PkgCreate.py` package creation process:

- **Build Stage**: compile your project and all dependent projects in the correct order.

- **Pack Stage**: pack your project into an `.spk` file

To create your `.spk` file with PkgCreate.py properly, you need to provide additional configuration files and build scripts to describe how to build your project. These files are put in a folder named “**SynoBuildConf**” under your project.

- `SynoBuildConf/depends`: defines the dependency of your project. For further details, please refer to Build Stage

- `SynoBuildConf/build`: specifies PkgCreate.py on how to compile your project. For further details, please refer to Build Stage

- `SynoBuildConf/install`: specifies PkgCreate.py on how to pack your SPK file. For further details, please refer to Pack Stage

- `SynoBuildConf/install-dev`: similar to SynoBuildConf/install, but this will pack your `.spk` file in chroot environment rather than general DSM system. For further details, please refer to Compile Open Source Project: nmap.
