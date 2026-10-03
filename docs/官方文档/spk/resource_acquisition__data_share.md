---
source: https://help.synology.com/developer-guide/resource_acquisition/data_share.html
title: Data Share
fetched: 2026-09-11
---

# Data Share

#### Description

This worker creates shared folder and set its permission during package startup. The share name can be hard-coded in the specification. The shared folder will not be removed after package uninstallation, since it might delete the user’s personal data as well.

- `Acquire()`: Create shared folder and set its permission.

- If the shared folder already exists, skip share creation and set the permission.

- `Release()`: Does nothing.

#### Provider

DSM

#### Timing

`FROM_ENABLE_TO_POSTUNINST`

#### Environment Variables

None

#### Updatable

No

#### Syntax

```
"data-share": {
  "shares": [{
    "name": "<share-name>",
    "permission": {
      "ro": ["<user-name>", ...],
      "rw": ["<user-name>", ...]
    },
    "once": "<once>"
  }, ...]
}
```

``

``

``

``

``

``

``

| Member | Since | Description |
|---|---|---|
| shares | 6.0-5914 | Object array, array of shares to create |
| name | 6.0-5914 | String, name of the share |
| permission | 6.0-5914 | Json object, permission of the share. (optional) |
| ro | 6.0-5914 | String array，users to be assigned with read-only permission. |
| rw | 6.0-5914 | String array，users to be assigned with read / write permission. |
| once | 6.0-5914 | Boolean, only try to create share on package's first start. (optional, default = false) |

#### Example

The following specification creates a share *music*, and gives the user *AudioStation* read-only permission. Since `once` defaults to `false`, the above procedure is ran every time the package starts.

```
"data-share": {
  "shares": [{
    "name": "music",
    "permission": {
      "ro": ["AudioStation"]
    }
  }]
}
```

> since 7.0-41201, package center will create a symlink under `/var/packages/[package_id]/shares/` named by share folder pointing to share folder path.
