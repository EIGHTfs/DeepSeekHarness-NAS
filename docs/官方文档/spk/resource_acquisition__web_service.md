---
source: https://help.synology.com/developer-guide/resource_acquisition/web_service.html
title: Web Service (since DSM7.0)
fetched: 2026-09-11
---

# Web Service (since DSM7.0)

### Description

When in install/remove package stage, worker will update/remove service and default portal setting.

When in start/stop package stage, worker will start/stop service setting.

**FROM_PREINST_TO_PREUNINST**

- `Acquire()`: sync information in user specified `/var/package/${package}/target/*.json` into user setting, do **migrate** and setup **portal** and **service** which user specify in **resource** file

- `Release()`: remove user's setting

**FROM_ENABLE_TO_DISABLE**

- `Acquire()`: copy `*.json` and `.mustache` under `/var/packages/${package}/target/` into `/usr/syno/etc/www/app.d/` and enable **service** setting.

- `Release()`: remove files which copied into `/usr/syno/etc/www/app.d/` and disable **service** setting

### Provider

WebStation

### Timing

`FROM_PREINST_TO_PREUNINST`
`FROM_ENABLE_TO_DISABLE`

### Lower privilege

According to package center privilege policy, web package will get a confined privilege during installation and run time. In order to setup environment for web package, webservice worker provide a mechanism called `pkg_dir_prepare` to assist web package creating website root directory and setting corresponding owner, group. The detail of pkg_dir_prepare will be elaborate in pkg_dir_prepare section.

### Environment Variables

None

### Updatable

No

### Syntax

```
"webservice":{
    "services": [{
        service setting 1
    },{
        service setting 2
    }...],
    "portals": [{
        default portal setting 1
    },{
        default portal setting 2
    }],
    "migrate": {
        Migration data
    },
    "pkg_dir_prepare": [{
        package directory prepare settings
    }]
}
```

``

``

``

``

| Key | Since | Type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| services | 3.0.0-0214 | Array | true | false | N/A | List services which are wanted to be registered |
| portals | 3.0.0-0214 | Array | false | true | Empty array | List default portal for services (Unnecessary) |
| migrate | 3.0.0-0214 | Object | false | true | Empty object | Migrate information (Unnecessary) |
| pkg_dir_prepare | 3.0.0-0256 | Array | true | false | Empty array | Setting specification of website root under web_package |

Framework will use default value when field is not **required** and doesn't exist or is null.

#### services

Web services which are going to register, allow multiple web services to register. For more detail please see Web Service

#### portals

Default portal which are going to register for access portal of services and will craete UI Shortcut. Devided into `server portal` and `alias portal`.

** Important: Default server portal is not allowed registered as name base portal, since you may not be able to lookup FQDN's correct IP from client side.**

Example:

```
Alias Portal
{
    "service": "wordpress",
    "name": "wordpress",
    "app": "SYNO.SDS.WordPress",
    "type": "alias",
    "alias": "wordpress"
}
Server Portal
{
    "service": "wordpress",
    "name": "wordpress",
    "app": "SYNO.SDS.WordPress",
    "type": "server",
    "http_port": [9000],
    "https_port": [9001]
}
```

``

**

********

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| service | 3.0.0-0214 | string | true | false | N/A | portal service name that portal link, corresponding to service field in service that is about to register |
| name | 3.0.0-0214 | string | true | false | N/A | portal name |
| display_name | 3.0.0-0302 | string | false | true | same as name | the title of web UI portal shortcut |
| app | 3.0.0-0214 | string | false | true | empty string | pacakge's UI App name |
| type | 3.0.0-0214 | string | true | false | N/A | portal's type, could be alias or server |
| alias | 3.0.0-0214 | string | true (if type is alias) | false | N/A | alias name |
| http_port | 3.0.0-0214 | int array | false | false | empty array (if type is server) | Http port setting for server portal, only 1 port allowed. There should be at least http_port or https_port or both. |
| https_port | 3.0.0-0214 | int array | false | false | empty array (if type is server) | Https port setting for server portal, only 1 port allowed. There should be at least http_port or https_port or both. |

#### migrate

Migrate assist package migration from older version ( < DSM7.0 ) to newer version. Supporting two kinds of migrate setting - `root` and `vhost`.

**root**

```
"root": [{
    "old": "wordpress",
    "new": "wordpress"
}]
```

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| root | 3.0.0-0214 | array | false | true | empty array | Migrate web package from web share folder to web_packages share folder. |
| old | 3.0.0-0214 | string | true | false | N/A | name of old package which in web share folder. |
| new | 3.0.0-0214 | string | true | false | N/A | name of new package which in web_packages share folder. |

**vhost**

```
"vhost": [{
    "root": "wordpress",
    "service": "wordpress"
}]
```

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| vhost | 3.0.0-0222 | array | false | true | empty array | Migrate virtualhost, which pointing to old package, to service portal. |
| root | 3.0.0-0222 | string | true | false | N/A | name of old pacakge which in web share folder. |
| service | 3.0.0-0222 | string | true | false | N/A | new package's service name |

#### pkg_dir_prepare

Webservice worker will set up website root directory under `web_packages` according to the information web package specified in worker config. The worker will remove the `target` directory under web_package between preuninst and postuninst. Make sure to **backup** your website root in preuninst script during upgrade.

pkg_dir_prepare example:

```
"pkg_dir_prepare": [{
    "source": "/var/package/WordPress/target/src",
    "target": "wordpress",
    "mode": "0755",
    "group": "http",
    "user": "WordPress"
}]
```

````````

``````````````

``

``

``

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| source | 3.0.0-0256 | string | false | true | N/A | Your web package source code directory. Mostly it will be under package target path (/var/package/$PKG_NAME/target/). Webservice worker will move your source directory to target directory and set owner group according to your user:group specification. Note that you should specify a full path in source field. |
| target | 3.0.0-0256 | string | true | false | N/A | Your website root directory. target directory wil be created under web_packages directory. Webservice worker will move source directory to target and setted with corresponding owner group according to your user:group specification. You sould only specify a relative path based on web_packages. Note that when source field is not specified, webservice worker will only create target directory and set owner group for target directory. |
| mode | 3.0.0-0256 | string | true | false | N/A | target directory access mode e.g. "0755", "0644" ... etc. |
| group | 3.0.0-0256 | string | true | false | N/A | Name of target directory group ownership. |
| user | 3.0.0-0256 | string | true | false | N/A | Name of target directory user ownership. |

### Web Service

Package could register to WebStation via WebStation webapi or Package Worker.

- Web Service support following types

- static service

- static web pages web services

- nginx_php service

- web service that useing Nginx as HTTP server and PHP as scripts, e.g. phpMyAdmin

- Will generate PHP Profile after service registered. You can modify it in WebStation -> Script Language Settings -> PHP.

- apache_php service

- web service that using Apache as HTTP server adn PHP as scripts, e.g. WordPress

- Will gengerate PHP Profile after service registerd. You can modify it in WebStation -> Script Language Settings -> PHP.

- reverse_proxy service

- web service depending on reverse proxy, e.g. Docker-GitLab

#### common field

````

````````

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| service | 3.0.0-0214 | string | true | false | N/A | service name |
| display_name | 3.0.0-0214 | string | true | false | N/A | service display name |
| display_name_i18n | 3.0.0-0214 | string | false | true | null | service displayed in different language (optional) |
| support_alias | 3.0.0-0214 | bool | false | false | true | Whether support alias portal, downgrade is not allowed |
| support_server | 3.0.0-0214 | bool | false | false | true | Whether suport server portal, downgrade is not allowed |
| icon | 3.0.0-0214 | string | false | true | null | icon path, relative path from package's target. Resolution should replaced in {0}. For now, we only support png format. Will use default icon if this field is empty. |
| type | 3.0.0-0214 | string | true | false | N/A | service type |
| php | 3.0.0-0214 | object | true | false | N/A | php-fpm setting including profile_name, backend, open_basedir, extensions, ... etc. The detail will be shown as following section. |

#### Detail of php profile

``

``

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| profile_name | 3.0.0-0214 | string | true | false | N/A | Name of default php profile, user may not modify this field. |
| profile_desc | 3.0.0-0214 | string | true | false | N/A | Description of php profile |
| backend | 3.0.0-0214 | int | true | false | N/A | php version, 3 for PHP5.6, 4 for PHP7.0, 5 for PHP7.1, 6 for PHP7.2 and 7 for PHP7.3, user may not modify this field |
| open_basedir | 3.0.0-0214 | string | false | true | empty string | default php open_basedir，user may modify this field. |
| extensions | 3.0.0-0214 | string array | false | true | empty array | default switched on php extension, user may not switch of these php extension; however, they may switch on others |
| php_settings | 3.0.0-0214 | object | false | true | empty object | key value pairs, define php ini setting, user may modify this field. |
| user | 3.0.0-0256 | string | true | false | N/A | Name of user with privilege while php-fpm accessing your website. Note that the value of user should be the same as pkg_dir_prepare user in order to access your website correctly. |
| group | 3.0.0-0256 | string | true | false | N/A | Name of group with privilege while php-fpm accessing your website. Note that the value of group should be the same as pkg_dir_prepare group in order to access your website correctly. |

#### static service

When type is static, system will serve your pacakge with nginx.

````

****``

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| root | 3.0.0-0214 | string | true | false | N/A | service working directory, will be treated as absolute path if start with /, otherwise, relative path to web_pacakges |
| index | 3.0.0-0214 | string array | false | true | ["index.html", "index.html"] | static service's index file. note use default value if null in this field |
| custom_rule | 3.0.0-0214 | object | false | true | empty object | Support customized routing rule. For more detail, please see Custom rule |

static service worker setting example:

```
{
        "service": "static",
        "display_name": "static service",
        "support_alias": true,
        "support_server": true,
        "type": "static",
        "root": "static_dir",
        "icon": "ui/Wordpress_{0}.png"
    }
```

#### nginx_php service

When type is nginx_php, system will serve your package with nginx. The php file will be executed by php-fpm. Php-fpm default behavior can be defined in field `php

````

****``

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| root | 3.0.0-0214 | string | true | false | N/A | service working directory, will be treated as absolute path if start with /, otherwise, relative path to web_pacakges |
| index | 3.0.0-0214 | string array | false | true | ["index.htm", "index.html", "index.php"] | nginx service's index file. note use default value if null in this field. |
| custom_rule | 3.0.0-0214 | object | false | true | empty object | Support customized routing rule. For more detail, please see Custom rule |
| connect_timeout | 3.0.0-0214 | int | false | false | 60 | timeout setting for connecting php-fpm, in units of second |
| read_timeout | 3.0.0-0214 | int | false | false | 60 | timeout setting for getting response from php-fpm, in units of second |
| send_timeout | 3.0.0-0214 | int | false | false | 60 | timeout setting for sending request to php-fpm, in units of second |
| php | 3.0.0-0214 | object | true | false | N/A | define default php profile |

nginx_php service worker setting example:

```
{
        "service": "wordpress",
        "display_name": "WordPress",
        "support_alias": true,
        "support_server": true,
        "type": "nginx_php",
        "root": "wordpress",
        "icon": "ui/Wordpress_{0}.png",
        "php": {
            "profile_name": "WordPress Profile",
            "profile_desc": "PHP Profile for WordPress",
            "backend": 6,
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
                "mysql.default_port": "3307",
                "mysqli.default_port": "3307"
            }
        },
        "connect_timeout": 60,
        "read_timeout": 3600,
        "send_timeout": 60
    }
```

#### apache_php service

When type is apache_php, nginx will pass request to apache server. The php file will be executed by php-fpm. Php-fpm default behavior can be defined in field `php`. Compare to nginx_php, apache_php with additional filed `backend` to specify apache version

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| backend | 3.0.0-0214 | int | true | false | N/A | 1 (Apache2.2) or 2 (Apache2.4) |
| intercept_errors | 3.0.0-0284 | bool | false | false | true | true (on) or false (off) |

apache_php service worker setting example:

```
{
        "service": "wordpress",
        "display_name": "WordPress",
        "support_alias": true,
        "support_server": true,
        "type": "apache_php",
        "root": "wordpress",
        "backend": 2,
        "icon": "ui/Wordpress_{0}.png",
        "php": {
            "profile_name": "WordPress Profile",
            "profile_desc": "PHP Profile for WordPress",
            "backend": 6,
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
                "mysql.default_port": "3307",
                "mysqli.default_port": "3307"
            }
        },
        "intercept_errors": false,
        "connect_timeout": 60,
        "read_timeout": 3600,
        "send_timeout": 60
    }
```

#### reverse_proxy service

When type is reverse_proxy, nginx will proxy request to target services

``

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| proxy_target | 3.0.0-0214 | string | true | false | N/A | Proxy target, support http, https, and unix. This value will be filled in nginx proxy_pass URL. For more detail please see proxy_pass |
| proxy_headers | 3.0.0-0214 | array | false | true | empty array | define proxy relay header value pair list |
| proxy_intercept_errors | 3.0.0-0284 | bool | false | false | false | specify whether letting nginx return error page for your packages if there's an error occur. Default is setting to false |
| proxy_http_version | 3.0.0-0214 | int | false | false | 1 | proxy http version, support 1.0 (0), 1.1 (1) |
| custom_rule | 3.0.0-0214 | object | false | true | empty object | define specific routing rule, should be compatible with support_alias and support_server setting. For more detail please see custom rule |
| connect_timeout | 3.0.0-0214 | int | false | false | 60 | timeout setting for connecting proxy target, in units of second |
| read_timeout | 3.0.0-0214 | int | false | false | 60 | timeout setting for getting response from proxy target, in units of second |
| send_timeout | 3.0.0-0214 | int | false | false | 60 | timeout setting for sending request to php-fpm, in units of second |

You could define proxy header to modify proxy behavior, e.g. modify host or turn on websocket. If need support of websocket, you should specify Upgrade and Connection header as shown below:

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| name | 3.0.0-0214 | string | true | false | N/A | header name |
| value | 3.0.0-0214 | string | true | false | N/A | header value |

reverse_proxy service worker setting example:

```
{
        "service": "gitlab",
        "display_name": "Git Lab",
        "support_alias": true,
        "support_server": true,
        "type": "reverse_proxy",
        "icon": "ui/gitlab_{0}.png",
        "proxy_target": "http://gitlab:30000",
        "proxy_headers": [{
            "name": "host",
            "value": "gitlab"
        },{
            "name": "Upgrade",
            "value": "$http_upgrade"
        },{
            "name": "Connection",
            "value": "$connection_upgrade"
        }]
        "connect_timeout": 60,
        "read_timeout": 3600,
        "send_timeout": 60
    }
```

#### Custom Rule

- You could modify config via custom_rule field in json key value format. Json key is target name, json value is target config's mustache file path。

- You can reference `nginx_service_template.mustache`, `apache22_service_template.mustache` and `apache24_service_template.mustache` under `/var/packages/WebStation/target/misc` for routing rule that you can modify.

- Field {{ \@json key\@ }} in mustache template will be replaced by files specified in custom_rule

- You should consider the compatibility between `server` and `alias`, and could use {{#alias}} to seperate these two different routing rules.

Custom rule example:

```
"custom_rule": {
    "global_rule": "/var/packages/WordPress/target/misc/nginx_global.mustache",
    "fastcgi_rule": "/var/packages/WordPress/target/misc/nginx_fastcgi.mustache",
    "proxy_rule": "/var/packages/WordPress/target/misc/nginx_proxy.mustache",
    "apache_rule": "/var/packages/WordPress/target/misc/apache.mustache"
}
```

#### Custom rule type

| key | affect target | affect service type | effect |
|---|---|---|---|
| global_rule | Nginx | all | modify service's request behavior |
| fastcgi_rule | Nginx | nginx_php | modify behavior of request passed to php-fpm |
| proxy_rule | Nginx | reverse_proxy | modify behavior of request passed to proxy target |
| apache_rule | Apache2.2 or Apache2.4 (depends on apache backend) | apache_php | modify apache behavior |
