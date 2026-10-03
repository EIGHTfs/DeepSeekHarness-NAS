---
source: https://help.synology.com/developer-guide/resource_acquisition/resources.html
title: Resource
fetched: 2026-09-11
---

# Resource

Packages can obtain system resources even in lower privilege identity if they apply this mechanism.

## Steps to setup resource config

1.

Find out the resources you want from Resource List

2.

Check if the corresponding Timing of selected resource is satisfied.

3.

Create a file at `conf/resource` with prefered configuration.

```
{
    "data-share": {
        "shares": [
            {
                "name": "MyShareFolderName",
                "permission": {
                    "ro": ["MyUserName"]
                }
            }
        ]
    }
}
```

> The instance handling the resource request is called `worker`.
