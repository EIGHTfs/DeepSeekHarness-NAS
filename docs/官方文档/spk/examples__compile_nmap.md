---
source: https://help.synology.com/developer-guide/examples/compile_nmap.html
title: Compile Open Source Project: nmap
fetched: 2026-09-11
---

# Compile Open Source Project: nmap

This chapter will show you how to build an open source project for your DSM system using Package Toolkit.

The open source project that we are going to build in this example is **nmap**, a network scanning program. We will use **avoton** as our build environment platform.

If you wish to compile an open source project manually,
please refer to Appendix B: Compile Open Source Project Manually.

You have to create the SynoBuildConf/build, SynoBuildConf/install, and SynoBuildConf/depends before using Package Toolkit.

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

## Preparation:

You can download the projects by following commands:

```
git clone https://github.com/SynologyOpenSource/ExamplePackages.git
cp -a ExamplePackages/libpcap /toolkit/source
cp -a ExamplePackages/nmap /toolkit/source
```

Our nmap & libpcap source code come from here:

```
wget https://nmap.org/dist/nmap-7.91.tar.bz2
wget http://www.tcpdump.org/release/libpcap-1.9.1.tar.gz
```

## Project Layout:

After you download the source code, your toolkit layout should look like the following figure.

```
/toolkit/
├── build_env/
│   └── ds.${platform}-${version}/
│       └── /usr/syno/
│           ├── bin
│           ├── include
│           └── lib
├── pkgscripts-ng/
└── source/
    ├──nmap/
    │   ├── nmap related source code
    │   ├── SynoBuildConf/
    │   |   ├── build
    │   |   ├── depends
    │   |   └── install
    |   └── synology
    │       ├── PACKAGE_ICON.PNG
    │       ├── PACKAGE_ICON_256.PNG
    │       ├── INFO.sh
    │       ├── conf/
    │       |   ├── privilege
    │       |   └── resource
    │       └── scripts/
    └──libpcap/
        ├── libpcap related source code
        ├── Makefile
        └── SynoBuildConf/
            ├── build
            ├── depends
            ├── install-dev
            └── install
```

The file, **install-dev**, is a special file which we will be covered in the following section.

## SynoBuildConf/depends:

The SynoBuildConf/depends for nmap is slightly different from the previous example.
Since nmap depends on libpcap, we have to add the value to the BuildDependent field,
so that the PkgCreate.py can resolve the dependency and compile the project in the correct order.

The **depends** file for nmap is as follows.

```
[BuildDependent]
libpcap

[default]
all="7.0"
```

However, the SynoBuildConf/depends for libpcap is the same as the Hello World Example.

```
[BuildDependent]

[default]
all="7.0"
```

## SynoBuildConf/build:

The SynoBuildConf/build script is also different from the previous one.

Here you will have to pass several environment variables to configure, so that nmap can be compiled properly

- CC

- CXX

- LD

- AR

- STRIP

- RANLIB

- NM

- CFLAGS

- CXXFLAGS

- LDFLAGS

Since nmap will be compiled with many features by default, we will need to disable some of them to make it clean.
The following list contains the features that will be disabled:

- ndiff

- zenmap

- nping

- ncat

- nmap-update

- liblua

> Note: If you are interested in some of the above features and you want to enable them,
> just change the `--without-${feature}` into `--with-${feature}`.

The following is the SynoBuildConf/build for nmap

```
#!/bin/sh
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

PKG_NAME=nmap
INST_DIR=/tmp/_${PKG_NAME}

case ${MakeClean} in
    [Yy][Ee][Ss])
        make distclean
        ;;
esac

LDFLAGS+=$(shell pkg-config --libs libnl libnl-genl)

env CC="${CC}" CXX="${CXX}" LD="${LD}" AR=${AR} STRIP=${STRIP} RANLIB=${RANLIB} NM=${NM} \
    CFLAGS="${CFLAGS}" CXXFLAGS="$CXXFLAGS $CFLAGS" \
    LDFLAGS="${LDFLAGS} -ldbus-1" \
    ./configure ${ConfigOpt} \
    --prefix=${INST_DIR} \
    --without-ndiff \
    --without-zenmap \
    --without-nping \
    --without-ncat \
    --without-nmap-update \
    --without-liblua \
    --with-libpcap=/usr/local

make ${MAKE_FLAGS}
```

In this example,`--with-libpcap` is assigned with value `/usr/local`. We need to install libpcap's cross compiled product into "/usr/local" so that nmap's configure can retrieve libpcap correctly.

The following is the SynoBuildConf/build for libpcap.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

case ${MakeClean} in
    [Yy][Ee][Ss])
        make distclean
        ;;
esac

case ${CleanOnly} in
    [Yy][Ee][Ss])
        return
        ;;
esac

# prefix with /usr/local, all files will be installed into /usr/local
env CC="${CC}" CXX="${CXX}" LD="${LD}" AR=${AR} STRIP=${STRIP} RANLIB=${RANLIB} NM=${NM} \
    CFLAGS="${CFLAGS} -Os" CXXFLAGS="${CXXFLAGS}" LDFLAGS="${LDFLAGS}" \
    ./configure ${ConfigOpt} \
    --with-pcap=linux --prefix=/usr/local

make ${MAKE_FLAGS}

make install
```

The above script will install libpcap related files into `/usr/local/` in chroot environment. After installing libpcap, nmap can find libpcap's cross compiled products in `/usr/local`.

Synology toolkit provides `libpcap` in chroot.

```
> dpkg -l | grep libpcap
ii  libpcap-avoton-dev                  7.0-7274     all        Synology build-time library
```

nmap can use chroot's libpcap by using `${SysRootPrefix}` variable.

```
--with-libpcap=${SysRootPrefix}
```

## SynoBuildConf/install

Instead of copying the binary to the destination folder, most big projects will use `make install` to install the binaries and libraries.
Since we have used the `--prefix` flag when configuring the nmap project,
we can just execute **make install** and it will install the nmap related files to the folder specified by `--prefix`.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

PKG_NAME="nmap"
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

SetupPackageFiles() {
    make install
    synology/INFO.sh > INFO
    cp INFO "${PKG_DIR}"
    cp -r synology/conf/ "${PKG_DIR}"
    cp -r synology/scripts/ "${PKG_DIR}"
    cp synology/PACKAGE_ICON{,_256}.PNG "${PKG_DIR}"
}

MakePackage() {
    source /pkgscripts-ng/include/pkg_util.sh
    pkg_make_package $INST_DIR $PKG_DIR
    pkg_make_spk $PKG_DIR $PKG_DEST
}

main() {
    PrepareDirs
    SetupPackageFiles
    MakePackage
}

main "$@"
```

## conf/resource

```
{
    "usr-local-linker": {
        "bin": ["bin/nmap"]
    }
}
```

## conf/privilege

```
{
    "defaults": {
        "run-as": "package"
    }
}
```

## INFO.sh

As mentioned before, we will use INFO.sh to generate the INFO file.

```
#!/bin/sh
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

. /pkgscripts-ng/include/pkg_util.sh
package="nmap"
version="7.91-1001"
os_min_ver="7.0-40850"
displayname="nmap"
arch="$(pkg_get_platform) "
maintainer="Synology Inc."
description="This package will install nmap in your DSM system."
[ "$(caller)" != "0 NULL" ] && return 0
pkg_dump_info
```

> Note: Remember to set the executable bit of INFO.sh file.

## Build and Create Package:

Lastly, run the following commands to compile the source code and build the package.

```
/toolkit/pkgscripts-ng/PkgCreate.py -p avoton -x0 -c nmap
```

After the build process, you can check the result in `/toolkit/result_spk`.

## Verify the Result

If the packing process was successful, you will see an spk file placed in the result_spk folder. To test the spk file, You can use manual install from Package Center then connect to DSM via ssh to try `nmap -v -A localhost` command.

If you failed to install the package, it is possible to find out the error logs at `/var/log/messages`.

## References

- Toolkit

- Package Format

- Privilege

- Resource
