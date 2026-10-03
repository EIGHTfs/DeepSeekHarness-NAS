---
source: https://help.synology.com/developer-guide/resource_acquisition/maria_db_10.html
title: Maria DB 10
fetched: 2026-09-11
---

# Maria DB 10

#### Description

This worker register on the following timings:

-

`PREINST/PREUNINST`
It checks the resource specification from user / wizard to avoid failure on another timing.

-

`POSTINST/POSTUNINST`
It performs several stages when package intents to do so:

- `POSTINST` (install & upgrade)

- **migrate-db**: migrate db from mariadb5 to mariadb10, usually used on upgrade

- **create-db**: create database

- **grant-user**: create user

- **drop-db-inst**: drop old database, usually used on db migration

- `POSTUNINST` (uninstall) (do not run during update)

- **drop-db-uninst**: drop database

- **drop-user-uninst**: delete user, if multiple packages share same user, this option should not be applied

If worker fails on any stage, worker framework would rollback the performed operations.

#### Provider

MariaDB10 package

#### Timing

`FROM_PREINST_TO_PREUNINST`

`FROM_POSTINST_TO_POSTUNINST`

#### Environment Variables

None

#### Updatable

No

#### Syntax

```
"mariadb10-db": {
    "admin-account-m10": "<db account>",
    "admin-pw-m10": "<db password>",
    "admin-account-m5": "<m5 db account>",
    "admin-pw-m5": "<m5 db password>",
    "migrate-db": {
        "flag": true | false,
        "m5-db-name": "<db name>",
        "m10-db-name": "<db name>",
        "db-collision": "replace" | "error"
    },
    "create-db": {
        "flag": true | false,
        "db-name": "<db name>",
        "db-collision": "replace" | "skip" | "error"
    },
    "grant-user": {
        "flag": true | false,
        "db-name": "<db name>",
        "user-name": "<db username>",
        "host": "<db host>",
        "user-pw": "<db password>"
    },
    "drop-db-inst": {
        "flag": true | false,
        "ver": "m5" | "m10",
        "db-name": "<db name>"
    },
    "drop-db-uninst": true | false,
    "drop-user-uninst": true | false
}
```

All fields are not necessary, but if you enable some stages then you have to fillup some fields. (e.g., enable `create-db` stage, then you have to provide `admin-account-m10` and `admin-pw-m10`)

``

``

``

``

``
``

``

``

``

``****

``
``

``

``

``

``
``

``

``

``

``

``
``

``

``

``

``

| Member(L1) | Member(L2) | Since | Description |
|---|---|---|---|
| admin-account-m10 | - | 10.0.30-0005 | MariaDB10 account id which has full access permission(root) |
| admin-pw-m10 | - | 10.0.30-0005 | MariaDB10 account password which has full access permission(root) |
| admin-account-m5 | - | 10.0.30-0005 | MariaDB account id which has full access permission(root) |
| admin-pw-m5 | - | 10.0.30-0005 | MariaDB account password which has full access permission(root) |
| migrate-db | flag | 10.0.30-0005 | whether to run the stage |
|  | m5-db-name | 10.0.30-0005 | migration source db name of MariaDB |
|  | m10-db-name | 10.0.30-0005 | migration destination db name of MariaDB10 |
|  | db-collision | 10.0.30-0005 | DB Collision Strategy on import，do not provide skip |
| create-db | flag | 10.0.30-0005 | whether to run the stage |
|  | db-name | 10.0.30-0005 | db name to create on MariaDB10 |
|  | db-collision | 10.0.30-0005 | DB Collision Strategy on create db |
| grant-user | flag | 10.0.30-0005 | whether to run the stage |
|  | db-name | 10.0.30-0005 | target db name to grant for user |
|  | user-name | 10.0.30-0005 | create and grant user name |
|  | host | 10.0.30-0005 | user host (default = localhost) |
|  | user-pw | 10.0.30-0005 | user password |
| drop-db-inst | flag | 10.0.30-0005 | whether to run the stage |
|  | ver | 10.0.30-0005 | target mariadb version (m5 / m10) |
|  | db-name | 10.0.30-0005 | db name to drop |
| drop-db-uninst | - | 10.0.30-0005 | whether to run the stage |
| drop-user-uninst | - | 10.0.30-0005 | whether to run the stage |

`DB Collision Strategy`: when there are same db names as provided from `migrate-db` & `create-db`, it can solve the conflict by one of the following strategies:

1. **replace**

drop exist db and replace it using new db

2. **error**

do not do anything and just report error, which might cause installation failure

3. **skip**

do not do anything and continue to execute as usual

#### Example

```
"mariadb10-db": {
    "admin-account-m10": "root",
    "admin-pw-m10": "password!@#123432",
    "admin-account-m5": "",
    "admin-pw-m5": "",
    "migrate-db": {
        "flag": false,
        "m5-db-name": "",
        "m10-db-name": "",
        "db-collision": ""
    },
    "create-db": {
        "flag": true,
        "db-name": "myservice",
        "db-collision": "error"
    },
    "grant-user": {
        "flag": true,
        "db-name": "myservice",
        "user-name" : "myservice_dbuser",
        "host" : "localhost",
        "user-pw"    : "password!@#123432asd123123"
    },
    "drop-db-inst": {
        "flag": false,
        "ver": "",
        "db-name": ""
    },
    "drop-db-uninst": true,
    "drop-user-uninst": false
}
```
