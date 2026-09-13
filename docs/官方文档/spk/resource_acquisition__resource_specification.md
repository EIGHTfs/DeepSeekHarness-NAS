---
source: https://help.synology.com/developer-guide/resource_acquisition/resource_specification.html
title: Resource Config
fetched: 2026-09-11
---

# Resource Config

It defines the system resource that is neccesary for this package to work.

```
{
  "<resource-id>": {
    <specification>
  }
}
```

For example, you can apply */usr/local linker*:

```
{
  "usr-local-linker": {
    "lib": ["lib/foo"],
    "bin": ["bin/foo"],
    "etc": ["etc/foo"],
  }
}
```

From this example, the `usr-local-linker` represents the resource id and its value represents the file to be linked.
