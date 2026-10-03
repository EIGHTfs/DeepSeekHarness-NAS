---
source: https://help.synology.com/developer-guide/examples/compile_tmux.html
title: Compile Open Source Project
fetched: 2026-09-11
---

# Compile Open Source Project

This chapter will show you how to build an open source project for your DSM system using Package Toolkit.
If you wish to compile the open source project manually,
please refer to Appendix B: Compile Open Source Project Manually.

You have to create SynoBuildConf/build, SynoBuildConf/install, and SynoBuildConf/depends before using Package Toolkit.

Unlike the previous example, compiling an application on most open source projects may require executing the following three steps:

1. `configure`

2. `make`

3. `make install`

The configure script consists of many lines which are used to check some details about the machine where the software is going to be installed.
This script will also check a lot of dependencies on your system.
When you run the configure script, you will see a lot of output on the screen, each being some sort of question with a respective yes/no as a reply.
If any of the major requirements are missing on your system, the configure script will exit and you will not be able to proceed with the installation until you meet the required conditions.
In most cases, compile applications on some particular target machines will require you to modify the configure script manually to provide the correct values.

When running the configure script to configure software packages for cross-compiling,
you will need to specify the `CC`, `LD`, `RANLIB`, `CFLAGS`, `LDFLAGS`, `host`, `target`, and `build`.

In this chapter, we will use **platform avoton** as our example.

## Preparation:

First download the tmux source code from the official github site
or you can download **example tmux package project** from this link.

> Note: The archive file you've downloaded from the above links is different from the official tmux source code.
> We have added the necessary build scripts.

## Project Layout:

```
tmux/
    ├── tmux related source code
    ├── SynoBuildConf/
    |   ├── build
    |   ├── depends
    |   └── install
    └── synology
        ├── conf/
        ├── scripts/
        └── INFO.sh
```

## SynoBuildConf/depends:

The following is the **depends** file for this example. There is nothing special about the **depends** file.

```
[default]
all="7.0"
```

## SynoBuildConf/build:

The build script is slightly different from the previous one.
Here you will have to pass the following environment variables to configure:

- CC

- AR

- CFLAGS

- LDFLAGS

In addition, since tmux is dependent on ncurses, you will need to use `pkg-config` to resolve the necessary header files and libraries for tmux.

The following is an example of SynoBuildConf/build:

```
#!/bin/sh
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

case ${MakeClean} in
    [Yy][Ee][Ss])
        make distclean
        ;;
esac

NCURSES_INCS="$(pkg-config ncurses --cflags)"
NCURSES_LIBS="$(pkg-config ncurses --libs)"

CFLAGS="${CFLAGS} ${NCURSES_INCS}"
LDFLAGS="${LDFLAGS} ${NCURSES_LIBS}"

autoreconf -if

env CC="${CC}" AR="${AR}" CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" \
./configure ${ConfigOpt}

make ${MAKE_FLAGS}
```

## SynoBuildConf/install

Instead of copying the binary to the destination folder, most big projects will use `make install` to install the binaries and libraries.
You can pass the DESTDIR environment variable to specify where you want to install the binaries and libraries.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

PKG_NAME="tmux"
INST_DIR="/tmp/_${PKG_NAME}"
PKG_DIR="/tmp/_${PKG_NAME}_pkg"
PKG_DEST="/image/packages"

PrepareDirs() {
    for dir in $INST_DIR $PKG_DIR; do
        rm -rf "$dir"
    done
    for dir in $INST_DIR $PKG_DIR $PKG_DEST; do
        mkdir -p "$dir"
    done
}

InstallTmux() {
    DESTDIR="${INST_DIR}" make install
}

GenerateINFO() {
    synology/INFO.sh > INFO
    cp INFO "${PKG_DIR}"
}

InstallSynologyConfig(){
    cp -r synology/scripts/ "${PKG_DIR}"
    cp -r synology/conf/ "${PKG_DIR}"
    cp synology/PACKAGE_ICON{,_256}.PNG "${PKG_DIR}"
}

MakePackage() {
    source /pkgscripts/include/pkg_util.sh
    pkg_make_package $INST_DIR $PKG_DIR
    pkg_make_spk $PKG_DIR $PKG_DEST
}

main() {
    PrepareDirs
    InstallTmux
    GenerateINFO
    InstallSynologyConfig
    MakePackage
}

main "$@"
```

## INFO.sh

As mentioned before, we will use INFO.sh to generate the INFO file.

```
#!/bin/sh
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.
. /pkgscripts/include/pkg_util.sh
package="tmux"
version="1.9.1-1001"
os_min_ver="7.0-40850"
displayname="tmux"
arch="$(pkg_get_platform) "
maintainer="Synology Inc."
description="Tmux package for Synology DSM."
support_url="https://github.com/tmux/tmux"
thirdparty="yes"
startable="no"
silent_install="yes"
silent_upgrade="yes"
silent_uninstall="yes"
[ "$(caller)" != "0 NULL" ] && return 0
pkg_dump_info
```

> Note: Remember to set the executable bit of INFO.sh file.

## Build and Create Package:

Run the following commands to compile the source code and build the package.

```
/toolkit/pkgscripts-ng/PkgCreate.py -p avoton -c tmux
```

After the build process, you can check the result in `/toolkit/result_spk`.

## Verify the Result

If the building process was successful, you will see that the .spk file has been placed under result_spk folder. To test the spk file, You can use manual install from Package Center then connect to DSM via ssh to try `tmux` command.

If you failed to install the package, it is possible to find out the error logs at `/var/log/messages`.

## References

- Toolkit

- Package Format

- Privilege

- Resource
