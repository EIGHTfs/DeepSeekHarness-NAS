---
source: https://help.synology.com/developer-guide/examples/compile_docker_package.html
title: Compile Docker Package - Gitlab
fetched: 2026-09-11
---

# Compile Docker Package - Gitlab

This chapter will show how to compile a docker package by using a well known version control opensource - Gitlab.

To create a Gitlab docker container, you only need to depends on Docker package and fill in docker worker configuration and the worker will do the reset for you.

As mentioned before, you have to create **SynoBuildConf/build**, **SynoBuildConf/install** and **SynoBuildConf/depends** for packing spk. However, since docker package will pull images or build image on the DSM, We don't need to build any code while packing the spk.

## Project Layout:

```
docker-gitlab
├── conf
│   ├── privilege
│   └── resource
├── INFO.sh
├── scripts
│   ├── postinst
│   ├── postuninst
│   ├── postupgrade
│   ├── preinst
│   ├── preuninst
│   ├── preupgrade
│   ├── script_customized
│   └── start-stop-status
├── SynoBuildConf
│   ├── build
│   ├── depends
│   └── install
└── ui
    ├── config.png
    ├── Gitlab_120.png
    ├── Gitlab_16.png
    ├── Gitlab_24.png
    ├── Gitlab_256.png
    ├── Gitlab_32.png
    ├── Gitlab_48.png
    ├── Gitlab_64.png
    └── Gitlab_72.png
```

## INFO.sh:

We will use INFO.sh to generate the INFO file. The following is the **INFO.sh** file for this example. For more details of each key's purpose, please see INFO.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

package="wordpress_sample"

. "/pkgscripts-ng/include/pkg_util.sh"
version="12.9.0-1"
os_min_ver="7.0-40337"
install_dep_packages="Docker>=18.09.0-1017"
maintainer="Gitlab"
thirdparty="yes"
arch="avoton"
adminurl="wordpress"
dsmuidir="ui"
displayname="Gitlab"
package_icon="`/pkgscripts-ng/include/base64.php ${ICON_PATH}`"

[ "$(caller)" != "0 NULL" ] && return 0
pkg_dump_info
```

## SynoBuildConf/depends:

The following is the **depends** file for this example.

```
[default]
all="7.0"
```

## SynoBuildConf/build:

The following is the **build** file for this example. Since WordPress is depends on PHP, there is nothing to do in **build**.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

case ${MakeClean} in
    [Yy][Ee][Ss])
        make clean
        ;;
esac

case ${CleanOnly} in
    [Yy][Ee][Ss])
        return
        ;;
esac

make ${MAKE_FLAGS}
```

## SynoBuildConf/install:

The following is the **install** file for this example.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

# set include projects to install into this package
INST_DIR="/tmp/_Gitlab"      # temp folder for dsm files
PKG_DIR="/tmp/_Gitlab_pkg"   # temp folder for package files
PKG_DEST="/image/packages"

# prepare install and package dir
for dir in $INST_DIR $PKG_DIR; do
        rm -rf "$dir"
done
for dir in $INST_DIR $PKG_DIR $PKG_DEST; do
        mkdir -p "$dir" # use default mask
done

[ -d $INST_DIR/ui ] || install -d $INST_DIR/ui
cp -a ui/* $INST_DIR/ui

[ -d $PKG_DIR ] || install -d $PKG_DIR
[ -d $PKG_DIR/scripts ] || install -d $PKG_DIR/scripts
cp -a conf $PKG_DIR
cp -a scripts/* $PKG_DIR/scripts
chmod 755 $PKG_DIR/scripts/*

./INFO.sh > INFO

install -c -m 644 INFO $PKG_DIR

. "/pkgscripts-ng/include/pkg_util.sh"
pkg_make_package $INST_DIR $PKG_DIR
pkg_make_spk $PKG_DIR $PKG_DEST
```

## UI config:

UI config is placed in `ui` folder.

```
{
    ".url": {
        "SYNO.SDS.GitLab": {
            "allUsers": true,
            "desc": "Docker-GitLab",
            "icon": "images/Docker_GitLab_SynoCommunity-{0}.png",
            "port": "@PORT@",
            "protocol": "http",
            "texts": "texts",
            "title": "GitLab",
            "type": "url",
            "url": "/"
        }
    }
}
```

## Scripts:

The following are spk scripts for installing docker Gitlab spk into DSM.

- preinst: There is nothing to do for `preinst` in this example. You can customize your own `preinst` script to fit your circumstances.

```
#!/bin/sh

exit 0
```

- postinst: In `postinst` stage, we set up port in ui/config after user specify in install wizard.

```
#!/bin/sh
PKG_NAME="Gitlab"
PORT_CONFIG_FILE="/var/packages/$PKG_NAME/etc/port_config"

port=""
if [ ! -z "$wizard_http_port" ]; then
    # new install
    port="$wizard_http_port"
elif [ -f "$PORT_CONFIG_FILE" ]; then
    # upgrade
    port=$(get_key_value "$PORT_CONFIG_FILE" port)
fi

echo "port=$port" > $PORT_CONFIG_FILE

if [ -f "$SYNOPKG_PKGDEST/app/config" ]; then
    sed -i "s/@PORT@/$port/g" "$SYNOPKG_PKGDEST/ui/config"
fi

exit 0
```

- preuninst: There is nothing to do in `preuninst` in this example. You can customize your own `preuninst` script to fit your circumstances.

```
#!/bin/sh

exit 0
```

- postuninst: In `postuninst` stage, we remove gitlab port configuration file.

```
#!/bin/sh
PKG_NAME="Gitlab"
PORT_CONFIG_FILE="/var/packages/$PKG_NAME/etc/port_config"

if [ "$SYNOPKG_PKG_STATUS" = "UNINSTALL" ]; then
    rm -f "$PORT_CONFIG_FILE"
fi

exit 0
```

- preupgrade: There is nothing to do in `preupgrade` in this example. You can customize your own `preupgrade` script for upgrade purpose.

```
#!/bin/sh

exit 0
```

- postupgrade: There is noting to do in `postupgrade` in this example. You can customize your own `postupgade` script for upgrade purpose.

```
#!/bin/sh

exit 0
```

- start-stop-status: For `start-stop-status` in this example. You could call docker_inspect to see if your container is running.

```
#!/bin/bash
GITLAB_NAME="GitLab"
DOCKER_INSPECT="/usr/local/bin/docker_inspect"

case "$1" in
    start)
        ;;
    stop)
        ;;
    status)
        "$DOCKER_INSPECT" "$GITLAB_NAME" | grep -q "\"Status\": \"running\"," || exit 1
        ;;
    log)
        echo ""
        ;;
    *)
        echo "Usage: $0 {start|stop|status}" >&2
        exit 1
        ;;
esac
exit 0
```

## Privilege:

The following is the **privilege** file under `conf` directory. The **privilege** file is configuration for specifying the installation and run time privilege.
The detail of privilege will be elaborated under privilge section.

```
{
    "defaults": {
        "run-as": "package"
    },
    "username": "Gitlab"
}
`
```

## Worker:

The following is the **resource** file under `conf` directory. The **resource** file are configurations for calling workers. In this example, since docker package only need docker worker to prepare container for them, we write docker worker configuration for setting up Gitlab container. For more details, please see docker worker.

```
{
    "docker": {
        "services": [{
            "service": "gitlab",
            "image": "gitlab/gitlab-ce",
            "container_name": "GitLab",
            "tag": "12.9.0-ce.0",
            "restart": "always",
            "shares": [{
                "host_dir": "gitlab/data",
                "mount_point": "/var/opt/gitlab"
            }, {
                "host_dir": "gitlab/logs",
                "mount_point": "/var/log/gitlab"
            }, {
                "host_dir": "gitlab/config",
                "mount_point": "/etc/gitlab"
            }],
            "ports": [{
                "host_port": "{{wizard_http_port}}",
                "container_port": "80",
                "protocol": "tcp"
            }, {
                "host_port": "{{wizard_https_port}}",
                "container_port": "443",
                "protocol": "tcp"
            }, {
                "host_port": "{{wizard_ssh_port}}",
                "container_port": "22",
                "protocol": "tcp"
            }]
        }]
    }
}
```

## Build and Create Package

Run the following command to build your source code into package.

```
/toolkit/pkgscripts-ng/PkgCreate.py -p avoton -c docker-gitlab
```

After the build process, you can check the result in `/toolkit/result_spk`.

## Verify the Result

If the building process was successful, you will see that the .spk file has been placed under result_spk folder.
To test the spk file, you can use manual install in Package Center to install your package.
