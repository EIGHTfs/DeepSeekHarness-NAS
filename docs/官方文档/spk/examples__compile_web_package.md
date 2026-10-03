---
source: https://help.synology.com/developer-guide/examples/compile_web_package.html
title: Compile Web Package - WordPress
fetched: 2026-09-11
---

# Compile Web Package - WordPress

This chapter will use well known open source project - WordPress as an example to show you how to build a php based web package integrating with DSM Packages -- WebStation, MariaDB and Apache server.

WordPress is the largest self-hosted blogging Open Source Project that have been used by millions of websites. All it need is a PHP web server and a database, then you can build your own blogging website. In this example, we will use WebStation and Apache as web server to host WordPress, and use MariaDB as database. Once the website was setted up, you could modify web server configurations for WordPress via WebStation UI.

As mentioned before, you have to create **SynoBuildConf/build**, **SynoBuildConf/install**, **SynoBuildConf/depends** and WordPress source project before creating spk. However, since WordPress depends on PHP, we don't have to compile any source code.

## Preparation:

First you need to download WordPress from official website and unarchive it into your spk source project. In this example, we put it under **src** as shown in Project Layout.

Secondly, before installing your WordPress spk, you need to download the dependant packages such as WebStation, MariaDB, PHP7.2 and Apache2.2 in DSM from Package Center. Noted that we use PHP7.2 and Apache2.2 in this example, you can choose whatever you want in considering your circumstances.

Third, according to instructions from WordPress official website, you have to setup DB information for WordPress. For more details, please see WordPress - how to install wordpress.

## Project Layout:

```
/toolkit/source/wordpress_sample
├── PACKAGE_ICON.PNG
├── PACKAGE_ICON_256.PNG
├── conf
│   ├── privilege
│   └── resource
├── INFO.sh
├── Makefile
├── scripts
│   ├── postinst
│   ├── postuninst
│   ├── postupgrade
│   ├── preinst
│   ├── preuninst
│   ├── preupgrade
│   ├── script_customized
│   └── start-stop-status
├── src
│   └── wordpress
│       └── wp-admin
├── SynoBuildConf
│   ├── build
│   ├── depends
│   └── install
└── ui
    ├── Wordpress_120.png
    ├── Wordpress_16.png
    ├── Wordpress_24.png
    ├── Wordpress_256.png
    ├── Wordpress_32.png
    ├── Wordpress_48.png
    ├── Wordpress_64.png
    └── Wordpress_72.png
```

## INFO.sh (this file should have executable permission: chmod +x INFO.sh):

As metioned before, we will use INFO.sh to generate the INFO file. The following is the **INFO.sh** file for this example. For more details of each key's purpose, please see INFO.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

package="wordpress_sample"

. "/pkgscripts-ng/include/pkg_util.sh"
version="5.5.1-1001"
os_min_ver="7.0-40337"
startstop_restart_services="nginx.service"
instuninst_restart_services="nginx.service"
install_dep_packages="WebStation>=3.0.0-0226:MariaDB10:PHP7.3>=7.3.16-0150:Apache2.2>=2.2.34-0104"
install_provide_packages="WEBSTATION_SERVICE"
maintainer="WordPress"
thirdparty="yes"
silent_upgrade="yes"
arch="noarch"
adminprotocol="http"
adminport="80"
adminurl="wordpress"
dsmuidir="ui"

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

The following is the **install** file for this example. In this example, we install our package with the help of **Makefile**.

```
#!/bin/bash
# Copyright (c) 2000-2022 Synology Inc. All rights reserved.

# set include projects to install into this package
INST_DIR="/tmp/_WordPress"      # temp folder for dsm files
PKG_DIR="/tmp/_WordPress_pkg"   # temp folder for package files
PKG_DEST="/image/packages"

# prepare install and package dir
for dir in $INST_DIR $PKG_DIR; do
    rm -rf "$dir"
done
for dir in $INST_DIR $PKG_DIR $PKG_DEST; do
    mkdir -p "$dir" # use default mask
done

make INSTALLDIR=$INST_DIR install
make PACKAGEDIR=$PKG_DIR package

. "/pkgscripts-ng/include/pkg_util.sh"
pkg_make_package $INST_DIR $PKG_DIR
pkg_make_spk $PKG_DIR $PKG_DEST
```

## Makefile:

The following is the **Makefile** file for this example.
**Watch out the indent must be tab instead of space**.

```
WORDPRESSDIR=src
WORDPRESS_INSTALL_DIR=$(INSTALLDIR)/$(WORDPRESSDIR)

all clean:

.PHONY:

install:
    [ -d $(INSTALLDIR) ] || install -d $(INSTALLDIR)
    [ -d $(WORDPRESS_INSTALL_DIR) ] || install -d $(WORDPRESS_INSTALL_DIR)
    cp -a $(WORDPRESSDIR)/* $(WORDPRESS_INSTALL_DIR)

    [ -d $(INSTALLDIR)/ui ] || install -d $(INSTALLDIR)/ui
    cp -a ui/* $(INSTALLDIR)/ui

    # change owner to nobody user/group on DS
    chown -R http:http $(WORDPRESS_INSTALL_DIR)

INFO: INFO.sh
    env UISTRING_PATH=$(STRING_DIR) ./INFO.sh > INFO

package: INFO
    [ -d $(PACKAGEDIR) ] || install -d $(PACKAGEDIR)
    [ -d $(PACKAGEDIR)/scripts ] || install -d $(PACKAGEDIR)/scripts
    cp -a scripts/* $(PACKAGEDIR)/scripts
    chmod 755 $(PACKAGEDIR)/scripts/*

    cp -a PACKAGE_ICON.PNG $(PACKAGEDIR)
    cp -a PACKAGE_ICON_256.PNG $(PACKAGEDIR)
    cp -a conf $(PACKAGEDIR)
    install -c -m 644 INFO $(PACKAGEDIR)

clean:
```

## Scripts (these files should have executable permission):

The following are spk scripts for installing WordPress spk into DSM.

- preinst: There is nothing to do for `preinst` in this example. You can customize your own `preinst` script to fit your circumstances.

```
#!/bin/sh

exit 0
```

- postinst: In `postinst` stage, we move the source project into "/var/services/web_packages" since it's Web Station's working directory.

```
#!/bin/sh
WEBSITE_ROOT="/var/services/web_packages/wordpress"

chown -R WordPress:http "$WEBSITE_ROOT/*"

exit 0
```

- preuninst: There is nothing to do in `preuninst` in this example. You can customize your own `preuninst` script to fit your circumstances.

```
#!/bin/sh

exit 0
```

- postuninst: In `postuninst` stage, we remove source project from "/var/services/web_packages".

```
#!/bin/sh

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

- start-stop-status: There is nothing to do in `start-stop-status` in this example. You can customize your own `start-stop-status` script by following the template.

```
#!/bin/sh

case "$1" in
    start)
            exit 0
            ;;

    stop)
            exit 0
            ;;

    status)
            exit 0
            ;;

    *)
            exit 1
            ;;
esac
```

## Privilege:

The following is the **privilege** file under `conf` directory. The **privilege** file is configuration for specifying the installation and run time privilege.
The detail of privilege will be elaborated under privilge section.

```
{
    "defaults": {
        "run-as": "package"
    },
    "username": "WordPress",
    "join-groupname": "http"
}
`
```

## Worker:

The following is the **resource** file under `conf` directory. The **resource** file are configurations for calling workers. In this example, since we would like to integrate WordPress with WebStation, we will call WebStation's worker to run specific setup during installation. For more details, please see webservice.

```
{
    "webservice": {
        "services": [{
            "service": "wordpress",
            "display_name": "WordPress",
            "support_alias": true,
            "support_server": true,
            "type": "apache_php",
            "root": "wordpress",
            "backend": 1,
            "icon": "ui/Wordpress_{0}.png",
            "php": {
                "profile_name": "WordPress Profile",
                "profile_desc": "PHP Profile for WordPress",
                "backend": 7,
                "open_basedir": "/var/services/web_packages/wordpress:/tmp:/var/services/tmp",
                "extensions": [
                    "mysql",
                    "mysqli",
                    "pdo_mysql",
                    "curl",
                    "gd",
                    "iconv"
                ],
                "php_settings": {
                    "mysql.default_socket": "/run/mysqld/mysqld10.sock",
                    "mysqli.default_socket": "mysqli.default_socket",
                    "pdo_mysql.default_socket": "/run/mysqld/mysqld10.sock",
                    "display_errors": "1",
                    "error_reporting": "E_ALL",
                    "log_errors": "true"
                },
                "user": "WordPress",
                "group": "http"
            },
            "connect_timeout": 60,
            "read_timeout": 3600,
            "send_timeout": 60
        }],
        "portals": [{
            "service": "wordpress",
            "type": "alias",
            "name": "wordpress",
            "alias": "wordpress",
            "app": "SYNO.SDS.WordPress"
        }],
        "pkg_dir_prepare": [{
            "source": "/var/packages/WordPress/target/src/wordpress",
            "target": "wordpress",
            "mode": "0755",
            "user": "WordPress",
            "group": "http"
        }]
    }
}
```

## Build and Create Package

Run the following command to build your source code into package.

```
/toolkit/pkgscripts-ng/PkgCreate.py -p avoton -c wordpress_sample
```

After the build process, you can check the result in `/toolkit/result_spk`.

## Verify the Result

If the building process was successful, you will see that the .spk file has been placed under result_spk folder.
To test the spk file, you can use manual install in Package Center to install your package.

## WordPress Installation Note

- user need to create database manually first (by using phpmyadmin or something else)

- database address should be set to `localhost:/run/mysqld/mysqld10.sock` if you are using db root user

-

if you see error pages from nginx, you might need to disable nginx error intercept manually:

1.

find out the nginx conf of wordpress

```
root@nas:/etc/nginx/conf.d# grep -R 'wordpress' .
./.service.6522c657-36cf-4165-84ab-f9e271a712eb.60d1dcff-5b7f-4908-8890-fcfc19b333c8.conf:location ^~ /wordpress/ {
./.service.6522c657-36cf-4165-84ab-f9e271a712eb.60d1dcff-5b7f-4908-8890-fcfc19b333c8.conf:    location ^~ /wordpress/ {
./www.webservice_portal_6522c657-36cf-4165-84ab-f9e271a712eb.conf:location = /wordpress {
./www.webservice_portal_6522c657-36cf-4165-84ab-f9e271a712eb.conf:location ~ ^/wordpress/ {
```

```
root@nas:/etc/nginx/conf.d# cat .service.6522c657-36cf-4165-84ab-f9e271a712eb.60d1dcff-5b7f-4908-8890-fcfc19b333c8.conf
location ^~ /wordpress/ {
 include conf.d/.webstation.error_page.default.conf*;
 location ^~ /wordpress/ {
     proxy_connect_timeout 60s;
     proxy_read_timeout 3600s;
     proxy_send_timeout 60s;
     proxy_pass  http://localhost:914;
     proxy_set_header X-Forwarded-By $server_addr;
     proxy_set_header X-Real-IP $remote_addr;
     proxy_set_header X-Forwarded-Proto $scheme;
     proxy_set_header X-Forwarded-Port $server_port;
     proxy_set_header Host $http_host;
     proxy_set_header Upgrade $http_upgrade;
     proxy_http_version 1.1;
     proxy_intercept_errors on;
 }
}
```

2.

modify `proxy_intercept_errors` from on to off in wordpress nginx conf

3. run `systemctl reload nginx` then you can see original error page from wordpress now
