---
source: https://help.synology.com/developer-guide/compile_applications/compile_open_source_projects.html
title: Compile Open Source Projects
fetched: 2026-09-11
---

# Compile Open Source Projects

To compile an application on most open source projects, you will be asked to execute the following three steps:

1. `configure`

2. `make`

3. `make install`

The configure script basically consists of many lines which are used to check details about the machine on where the software is going to be installed. The script will check for a lot of dependencies on your system. When you run the configure script, you will see a lot of output on the screen, each being some sort of question with a respective yes/no reply. If there are any major requirements missing on your system, the configure script will exit and you will not be able to proceed with the installation until you meet all the requirements. In most cases, compile applications on some particular target machines will require you to modify the configure script manually to provide the correct values.

When running the configure script to configure software packages for cross-compiling, you will need to specify the `CC`, `LD`, `RANLIB`, `CFLAGS`, `LDFLAGS`, `host`, `target`, and `build`, etc. All these values can be found in `/env32.mak` or `/env64.mak` in your chroot environment. Some examples are given below.

For Intel X86-compatible platform in DSM 7.0:

```
    env CC=/usr/local/x86_64-pc-linux-gnu/bin/x86_64-pc-linux-gnu-wrap-gcc \
    LD=/usr/local/x86_64-pc-linux-gnu/bin/x86_64-pc-linux-gnu-ld \
    RANLIB=/usr/local/x86_64-pc-linux-gnu/bin/x86_64-pc-linux-gnu-ranlib \
    CFLAGS="-DSYNOPLAT_F_X86_64 -O2 -include /usr/syno/include/platformconfig.h -DSYNO_ENVIRONMENT -DBUILD_ARCH=64 -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -g -DSDK_VER_MIN_REQUIRED=600" \
./configure \
    --host=i686-pc-linux-gnu \
    --target=i686-pc-linux-gnu \
    --build=i686-pc-linux \
    --prefix=/usr/local
```
