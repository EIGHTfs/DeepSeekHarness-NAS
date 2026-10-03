---
source: https://help.synology.com/developer-guide/resource_acquisition/index_db.html
title: Index DB
fetched: 2026-09-11
---

# Index DB

#### Description

Index / unindex package help and app index during package start / stop.

For detailed description on package app index and help index, please refer to Integegrate Help Document into DSM Help.

- `Acquire()`: Index package help and app content.

- `Release()`: Un-index package help and app content.

#### Provider

DSM

#### Timing

`FROM_ENABLE_TO_DISABLE`

#### Environment Variables

None

#### Updatable

No

#### Syntax

```
"indexdb": {
    "app-index"  : {
        "conf-relpath": "<conf relpath>",
        "db-relpath": "<app db relpath>"
    },
    "help-index": {
        "conf-relpath": "<conf relpath>",
        "db-relpath": "<help db relpath>"
    }
}
```

``

``

``

**

``

**

| Member | Since | Description |
|---|---|---|
| app-index | 6.0-5924 | Object, app index info. |
| help-index | 6.0-5924 | Object, help index info. |
| conf-relpath | 6.0-5924 | String, config file's relative path under /var/packages/${package}/target/. |
| db-relpath | 6.0-5924 | String, db folder's relative path under /var/packages/${package}/target/. |

#### Example

```
"indexdb": {
    "app-index"  : {
        "conf-relpath": "app/index.conf",
        "db-relpath": "indexdb/appindexdb"
    },
    "help-index": {
        "conf-relpath": "app/helptoc.conf",
        "db-relpath": "indexdb/helpindexdb"
    }
}
```
