---
source: https://help.synology.com/developer-guide/privilege/privilege_config.html
title: Privilege Config
fetched: 2026-09-11
---

## Privilege Config

To make your package work, there must exist `conf/privilege` inside your package. It controls security related behaviours in entire package lifecycle.

```
{
  "defaults":{
    "run-as": "package"
  },
  "username": "myusername",
  "groupname": "mygroupname",
  "tool": [{
    "relpath": "bin/mytool",
    "user": "package",
    "group": "package",
    "permission": "0700"
  }]
}
```

#### defaults (required)

Controls default settings for entire privilege file. It can only be set as value below.

``
``

| run-as | behaviour on file | behaviour on script |
|---|---|---|
| package | chown -hR "${package}:${package}" | set resuid as [username] |

``
``

| run-as | behaviour on file | behaviour on script |
|---|---|---|
| root | chown -hR "root:root" | set resuid as root |

#### username / groupname (optional) (since 6.0-5940)

Specify which name will be the user name and group name. If not specified, the package name will be the default value.

#### ctrl-script (optional)

Control the identity to run scripts.

```
"ctrl-script": [{
  "action": "start",
  "run-as": "package"
}]
```

``

``````````````````````

``

| Member | Since | Description |
|---|---|---|
| action | 6.0-5891 | one of preinst, postinst, preuninst, postuninst, preupgrade, postupgrade, start, stop, status, prestart, prestop |
| run-as | 6.0-5891 | see the description above |

#### executable (optional)

Specify the identity to **chown** on installed for specific file.

```
"executable": [{
  "relpath": "bin/mybin",
  "run-as": "package"
}]
```

``

``

``

| Member | Since | Description |
|---|---|---|
| relpath | 6.0-5891 | relative path under /var/packages/[package_name]/target |
| run-as | 6.0-5891 | see the description above |

#### tool (optional)

Specify the identity to **chown** and **chmod** on installed for specific file.

If you want, you can even set file capabilities.

```
"tool": [{
  "relpath": "bin/mytool",
  "user": "package",
  "group": "package",
  "permission": "0700"
}]
```

``

**

``

``

``

| Member | Since | Description |
|---|---|---|
| relpath | 6.0-5891 | String, the file's relative path under /var/packages/${package}/target/. |
| user | 6.0-5891 | String, file's owner user, must be "package". |
| group | 6.0-5891 | String, file's owner group, must be "package" |
| permission | 6.0-5891 | 4 digit number to set file permission, for example: 4750 |

```
"tool": [{
  "relpath": "bin/mytool",
  "user": "package",
  "group": "package",
  "capabilities": "cap_chown,cap_net_raw",
  "permission": "0700"
}]
```

``

``

| Member | Since | Description |
|---|---|---|
| capabilities | 7.0-40656 | capabilities string without any +-=eip symbol. the value can be viewed HERE |

## Package User / Group Visibility On UI

Package users and groups will not appear on most UI settings, but there are some exceptions:

- [x] Application privilege permission viewer

- [x] FTP chroot user selector

- [x] File Station

- [x] Change owner

- [x] Shared Links Manager -> Enable secure sharing

- [o] Control Panel > Shared Folder > Edit > Permission > System internal user

- [o] ACL editor
