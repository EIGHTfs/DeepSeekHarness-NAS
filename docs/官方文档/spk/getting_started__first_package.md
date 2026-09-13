---
source: https://help.synology.com/developer-guide/getting_started/first_package.html
title: Your First Package
fetched: 2026-09-11
---

# Your First Package

> Make sure you have prepared the development environment for your NAS.

## Download the template package

You can download our template package from https://github.com/SynologyOpenSource/ExamplePackages and place the `ExamplePackages/ExamplePackage` directory at `/toolkit/source/ExamplePackage`.

```
/toolkit/
├── build_env/
│   └── ds.${platform}-${version}/
├── pkgscripts-ng/
│   ├── EnvDeploy
│   └── PkgCreate.py
└── source/
    └──ExamplePackage/
        ├── examplePkg.c
        ├── INFO.sh
        ├── Makefile
        ├── PACKAGE_ICON.PNG
        ├── PACKAGE_ICON_256.PNG
        ├── scripts/
        │   ├── postinst
        │   ├── postuninst
        │   ├── postupgrade
        │   ├── postreplace
        │   ├── preinst
        │   ├── preuninst
        │   ├── preupgrade
        │   ├── prereplace
        │   └── start-stop-status
        └── SynoBuildConf/
            ├── depends
            ├── build
            └── install
```

## Configure Build Configs

The steps to build package and pack package are configured under `${project_path}/SynoBuildConf/`. You can see three files:

- **depends**: configure dependencies between projects

- **build**: configure steps to build package

- **install**: configure steps to pack package into `.spk` file

This example will echo some messages by a program written in C language, so it is neccessary to compile program in build stage. We apply `Makefile` in this example to help us doing cross compilation.

We do not concern what you do in `build` configuration so that it can even do nothing. The build system will just chroot into environment then call the corresponding `build`, `install` script according to the commands.

## Configure Properties

The package information and its behavior are controlled by `INFO.sh` which will be translated into `INFO` file in `install`.

```
#!/bin/bash
# INFO.sh
source /pkgscripts/include/pkg_util.sh
package="ExamplePackage"
version="1.0.0000"
os_min_ver="7.0-40000"
displayname="ExamplePackage Package"
description="this is an example package"
arch="$(pkg_get_unified_platform)"
maintainer="Synology Inc."
pkg_dump_info
```

## Configure Lifecycle Behaviour

The package control scripts can be found at `${project_path}/scripts/`. You can control the behaviour in each stage such as calling a `examplePkg` program on package start / stop.

```
#!/bin/sh
# scripts/start-stop-status
case $1 in
    start)
        examplePkg "Start"
        echo "Hello World" > $SYNOPKG_TEMP_LOGFILE
        exit 0
    ;;
    stop)
        examplePkg "Stop"
        echo "Hello World" > $SYNOPKG_TEMP_LOGFILE
        exit 0
    ;;
    status)
        exit 0
    ;;
esac
```

## Write a program and configure its compilation and installation

It is common to bring compiled program into DSM via package. You can just write your program in C and add a Makefile to compile your programs.

```
// examplePkg.c
#include <sys/sysinfo.h>
#include <syslog.h>
#include <stdio.h>
int main(int argc, char** argv) {
    struct sysinfo info;
    int ret;
    ret = sysinfo(&info);
    if (ret != 0) {
        syslog(LOG_SYSLOG, "Failed to get info\n");
        return -1;
    }
    syslog(LOG_SYSLOG, "[ExamplePkg] %s sample package ...", argv[1]);
    syslog(LOG_SYSLOG, "[ExamplePkg] Total RAM: %u\n", (unsigned int) info.totalram);
    syslog(LOG_SYSLOG, "[ExamplePkg] Free RAM: %u\n", (unsigned int) info.freeram);
    return 0;
}
```

```
# Makefile
include /env.mak
EXEC= examplePkg
OBJS= examplePkg.o
all: $(EXEC)
$(EXEC): $(OBJS)
    $(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)
install: $(EXEC)
    mkdir -p $(DESTDIR)/usr/bin/
    install $< $(DESTDIR)/usr/bin/
clean:
    rm -rf *.o $(EXEC)
```

Any additional files (e.g., compiled program, media resources) should be packed into `package.tgz` file inside `.spk`. We provide several script commands to do such operations. In this example, we will pack compiled `examplePkg` executable via `install` build script.

```
#  SynoBuildConf/install (partial)
create_package_tgz() {
    local firewere_version=
    local package_tgz_dir=/tmp/_package_tgz
    local binary_dir=$package_tgz_dir/usr/bin
    rm -rf $package_tgz_dir && mkdir -p $package_tgz_dir
    mkdir -p $binary_dir
    cp -av examplePkg $binary_dir
    make install DESTDIR="$package_tgz_dir"
    pkg_make_package $package_tgz_dir "${PKG_DIR}"
}
```

## Build And Pack The Package

After you have finished preparing the package source code, you can use the following commands to build and pack the package into `.spk` at `/toolkit/result_spk/${package}-${version}/*.spk`.

```
cd /toolkit/pkgscripts-ng/
./PkgCreate.py -v 7.0 -p avoton -c ExamplePackage
```

```
/toolkit/
├── pkgscripts-ng/
├── build_env/
│   └── ds.${platform}-${version}
└── result_spk/
    └── ${package}-${version}/
        └── *.spk
```

## Install And Test The Package

Go to **DSM > Package Center > Manual Install** then select your `.spk` file to do installation.

Once you have installed and started the package, you can see its message on UI and log at `/var/log/messages`.

## Read More

- Synology Toolkit

- Synology Package

- Synology DSM Integration

- Package Examples
