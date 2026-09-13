---
source: https://help.synology.com/developer-guide/privilege/preface.html
title: Privilege
fetched: 2026-09-11
---

# Privilege

**DSM 7.0, packages are forced to lower the privilege by applying privilege mechanism explicitly.**

To reduce security risks, package should run as an user rather than `root`. Package can apply such mechanism by providing a configuration file named `pivilege`:

With the configuration, package developer is capable to

-

Control default user / group name of process in `scripts`

-

Control permission of files in `package.tgz`

-

Control file capabilities in `package.tgz`

-

Control if special system resources are accessible

To overcome the limitation that normal user cannot be used to do privileged operations, we provide a way for package to request system resources. Please refer to Resource for more information.

## Setup privilege configuration

Just create a file at `conf/privilege` with prefered configuration.

```
{
    "defaults": {
        "run-as": "package"
    }
}
```
