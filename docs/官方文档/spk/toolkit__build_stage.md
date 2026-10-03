---
source: https://help.synology.com/developer-guide/toolkit/build_stage.html
title: Build Stage:
fetched: 2026-09-11
---

# Build Stage:

In the Build Stage, `PkgCreate.py` will compile the project and its dependent projects. Please note that in this stage, `PkgCreate.py` depends on two build scripts (`SynoBuildConf/build` and `SynoBuildConf/depends`) to get the necessary information.

```
PkgCreate.py -v ${version} -p ${platform} ${project} # build project in specific platform version
```

```
/toolkit/
├── build_env/
│   └── ds.${platform}-${version}/
├── pkgscripts-ng/
│   ├── EnvDeploy
│   └── PkgCreate.py
└── source/
    └──${project}/
        └── SynoBuildConf/
            ├── depends
            ├── build
            └── install
```

## Build Stage Workflow:

1. Based on your `SynoBuildConf/depend`, `PkgCreate.py` will locate the target DSM version from [default] section.

2. `PkgCreate.py` will resolve the projects you depend on.

3. Your project and the dependent projects which are placed under `/toolkit/source` will be hard-linked to `/toolkit/build_env/ds.${platform}/source`.

4. Their `SynoBuildConf/build` will be executed in order according to their dependency based on each `SynoBuildConf/depend`.

5. If your project is needed by other project for cross compiling, you may add `SynoBuildConf/install-dev` script. `install-dev` script will install cross compiled product into platform chroot.

> Note: `SynoBuildConf/build` is executed under chroot environment **/toolkit/build_env/ds.${platform}**.

## SynoBuildConf/depends

`PkgCreate.py` will resolve your dependency according to this configuration file.
You need to specify your project dependency and the build environment of your project in this file. For example:

```
[BuildDependent]
# each line here is a dependent project

[ReferenceOnly]
# each line here is a project for reference only but no need to be built

[default]
all="7.2.2"   # toolkit environment version of specific platform. (all platform use 7.2.2 toolkit environment)
```

There are three fields in `SynoBuildConf/depends`:

- **BuildDependent**: Describes other projects which are dependent on this project. For further details about this field, please refer to Compile Open Source Project: nmap.

- **ReferenceOnly**: Describes other projects which are referred by this project, without the build process.

- **default**: Describes the toolkit environment. This section is a necessary field. It indicates each platform to build against some DSM version and the key "**all**" means all platform use this version by default.

You can use `ProjDepends.py` script to see whether the dependency order of your projects is correct. Option `-x0` will traverse all dependent projects of **${project}**.

```
cd /toolkit/pkgscripts-ng
./ProjDepends.py -x0 ${project}
```

If your application contains more than one project, put them in `/toolkit/source` and edit `SynoBuildConf` accordingly for each of them. For advanced usage, you may refer to Compile Open Source Project and References.

## SynoBuildConf/build

`SynoBuildConf/build` is a shell script that tells `PkgCreate.py` how to compile your project. The current working directory of this shell script is located in `/source/${project}` under chroot environment.

All pre-built binaries, headers, and libraries are under **cross compiler sysroot** in chroot environment. Since sysroot is the default search path of cross compiler, you do not need to provide `-I` or `-L` to `CFLAGS` or `LDFLAGS`.

### Variables:

You can also find most of them in `/toolkit/build_env/ds.${platform}-${version}/{env.mak,env32/64.mak}`. They can be used in `SynoBuildConf/build`:

- **CC**: path of gcc cross compiler.

- **CXX**: path of g++ cross compiler.

- **LD**: path of cross compiler linker.

- **CFLAGS**: global cflags includes.

- **AR**: path of cross compiler ar.

- **NM**: path of cross compiler nm.

- **STRIP**: path of cross compiler strip.

- **RANLIB**: path of cross compiler ranlib.

- **OBJDUMP**: path of cross compiler objdump.

- **LDFLAGS**: global ldflags includes.

- **ConfigOpt**: options for configure.

- **ARCH**: processor architecture.

- **SYNO_PLATFORM**: Synology platform.

- **DSM_SHLIB_MAJOR**: major number of DSM (integer).

- **DSM_SHLIB_MINOR**: minor number of DSM (integer).

- **DSM_SHLIB_NUM**: build number of DSM (integer).

- **ToolChainSysRoot**: cross compiler sysroot path.

- **SysRootPrefix**: cross compiler sysroot concat with prefix /usr.

- **SysRootInclude**: cross compiler sysroot concat with include_dir /usr/include.

- **SysRootLib**: cross compiler sysroot concat with lib_dir /usr/lib.

```
# SynoBuildConf/build

case ${MakeClean} in
       [Yy][Ee][Ss])
               make distclean
               ;;
esac

make ${MAKE_FLAGS}
```

The above example calls the `make` command and compiles your project according to your **Makefile** located in `/source/${project}`.

Synology toolkit environment has included selected prebuild projects. You can enter the chroot and use following commands to check if needed header or project is provided by toolkit.

```
## inner chroot
dpkg -l  # list all dpkg projects.
dpkg -L {project dev} # list project install files
dpkg -S {header/library pattern} # search header/library pattern.
```

For example, the project needs `zlib.h` and `libz.so` in the build stage. Use following command to check if zlib and its component are installed in chroot.

```
chroot /tookit/build_env/ds.avoton-7.0/
## inner chroot
>> dpkg -l | grep zlib
ii  zlib-1.x-avoton-dev        7.0-7274       all             Synology build-time library

>> dpkg -L zlib-1.x-avoton-dev
/.
/usr
/usr/local
/usr/local/x86_64-pc-linux-gnu
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.so
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.a
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/pkgconfig
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/pkgconfig/zlib.pc
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.so.1
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.so.1.2.8
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/include
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/include/zconf.h
/usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/include/zlib.h

>> dpkg -S zlib.so
zlib-1.x-avoton-dev: /usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.so
zlib-1.x-avoton-dev: /usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.so.1.2.8
zlib-1.x-avoton-dev: /usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/usr/lib/libz.so.1
```

Some open source projects require to use other projects' cross compiled product while building their own . For example, `python` needs `libffi` and `zlib` while configure, we need to provide those two project before build `python`. You can install the cross compiled product into the destination you want in build script. Please refer to Compile Open Source Project: nmap for more information.

## Makefile

The following example shows a `Makefile`. Most of the content contains typical makefile rules. Note that when writing your project `Makefile`, you can utilize pre-defined variables in `/env.mak`.

```
## You can use CC CFALGS LD LDFLAGS CXX CXXFLAGS AR RANLIB READELF STRIP after include env.mak
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

For more detailed descriptions about makefile, please refer to the article here.
