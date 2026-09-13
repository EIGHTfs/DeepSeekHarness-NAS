---
source: https://help.synology.com/developer-guide/resource_acquisition/php_ini.html
title: PHP INI
fetched: 2026-09-11
---

# PHP INI

#### Description

Packages can carry custom php.ini and fpm.conf files. This worker installs / uninstalls these config files during package start / stop.

- `Acquire()`: Copy the php.ini and fpm.conf files to */usr/local/etc/php56/conf.d/* and */usr/local/etc/php56/fpm.d/*. Then reload php56-fpm.

- *php.ini* / *fpm.conf* files should have .ini / .conf extension, otherwise it will be ignored

- Files will be prefixed by ${package}.

- Existing files will be `unlink()` first.

- Failure on any file copy results in this worker to abort and triggers rollback.

- `Release()`: Delete previously created links

- Ignore files that are not found.

- Ignore `unlink()` failure.

#### Provider

PHP5.6

#### Timing

`FROM_ENABLE_TO_DISABLE`

#### Environment Variables

None

#### Updatable

No

#### Syntax

```
"php": {
     "php-ini": [{
         "relpath": "<ini-relpath>",
     }, ...],
     "fpm-conf": [{
         "relpath": "<conf-relpath>",
     }, ...]
 }
```

``

``

``

**

| Member | Since | Description |
|---|---|---|
| php-ini | PHP5.6-5.6.17-0020 | Object array, list of php.ini files to install. |
| fpm-conf | PHP5.6-5.6.17-0020 | Object array, list of fpm.conf files to install. |
| relpath | PHP5.6-5.6.17-0020 | Target file's relative path under /var/packages/${package}/target/. |

#### Example

```
{
    "php": {
        "php-ini": [{
            "relpath": "synology_added/etc/php/conf.d/test_1.ini"
        }, {
            "relpath": "synology_added/etc/php/conf.d/test_2.ini"
        }, {
            "relpath": "synology_added/etc/php/conf.d/test_3.ini"
        }],
        "fpm-conf": [{
            "relpath": "synology_added/etc/php/fpm.d/test_1.conf"
        }, {
            "relpath": "synology_added/etc/php/fpm.d/test_2.conf"
        }, {
            "relpath": "synology_added/etc/php/fpm.d/test_3.conf"
        }]
    }
}
```
