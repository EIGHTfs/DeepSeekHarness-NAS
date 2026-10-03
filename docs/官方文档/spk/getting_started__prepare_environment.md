---
source: https://help.synology.com/developer-guide/getting_started/prepare_environment.html
title: Prepare Environment
fetched: 2026-09-11
---

# Prepare Environment

# Install Toolkit

## Toolkit Installation:

You need to clone the front-end scripts from this link. We will use `/toolkit` as toolkit base in this document from now on.

```
apt-get install git
mkdir -p /toolkit
cd /toolkit
git clone https://github.com/SynologyOpenSource/pkgscripts-ng
```

Then you need to install a few tools to make the built tool work:

```
apt-get install cifs-utils \
    python \
    python-pip \
    python3 \
    python3-pip
```

At this moment, you can find toolkit files as the follows:

```
/toolkit
├── pkgscripts-ng/
│   ├── include/
│   ├── EnvDeploy    (deployment tool for chroot environment)
│   └── PkgCreate.py (build tool for package)
└── build_env/       (directory to store chroot environments)
```

# Deploy Chroot Environment For Different NAS Target

For faster development, we have prepared several build environments of different architectures which contain some pre-built projects whose executable binaries or shared libraries are built in DSM, for example, `zlib`, `libxml2` and so on.

You can use `EnvDeploy` to deploy corresponding environment of your NAS. For example, if there is a NAS in `avoton` architecture, it is possible to use following commands to deploy a environment for `avoton`:

```
cd /toolkit/pkgscripts-ng/
git checkout DSM7.2
./EnvDeploy -v 7.2 -p avoton # for DSM7.2.2
```

It is possible to download environment tarballs manually. You have to put `base_env-{version}.txz`, `ds.{platform}-{version}.dev.txz` and `ds.{platform}-{version}.env.txz` into `toolkit/toolkit_tarballs`.

```
/toolkit
├── pkgscripts-ng/
└── toolkit_tarballs/
    ├── base_env-7.2.txz
    ├── ds.avoton-7.2.dev.txz
    └── ds.avoton-7.2.env.txz
```

```
cd /toolkit/pkgscripts-ng/
./EnvDeploy -v 7.2 -p avoton -D # -D implies no download
```

As mentioned before, the deployed environment contains some pre-built libraries and headers which can be found under **cross gcc sysroot**. Sysroot is the default search path of compiler. If gcc cannot find header or library from the given path, it will then search `sysroot/usr/{lib,include}`.

```
/toolkit
├── pkgscripts-ng/
│   ├── include/
│   ├── EnvDeploy
│   └── PkgCreate.py
└── build_env/
    ├── ds.avoton-7.2/
    └── ds.avoton-6.2/
        └── usr/local/x86_64-pc-linux-gnu/x86_64-pc-linux-gnu/sys-root/
```

## Available Platforms

You can use one of the following commands to show available platforms. If `-v` is not given, available platforms for all versions will be listed.

```
./EnvDeploy -v 7.2 --list
./EnvDeploy -v 7.2 --info platform
```

You may use any toolkit that belong to the same platform family to create spk for all platforms within the same platform family. e.g. you may use the toolkit for braswell to create package runs on all x86_64 compatible platforms. For platform family, please check Platform and Arch Value Mapping Table.

## Update Environment

Use `EnvDeploy` again to update the environment. For example, you can update avoton for DSM 7.2.2 as follows.

```
./EnvDeploy -v 7.2 -p avoton
```

## Remove Environment

To remove a environment, you first need to unmount the `/proc` folder then remove the environment folder. The following commands illustrate how to remove an environment with version 7.2 and platform avoton.

```
umount /toolkit/build_env/ds.avoton-7.2/proc
rm -rf /toolkit/build_env/ds.avoton-7.2
```
