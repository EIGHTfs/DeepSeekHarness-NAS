---
source: https://help.synology.com/developer-guide/integrate_dsm/resource_monitor.html
title: Monitor
fetched: 2026-09-11
---

# Monitor

The DSM manages resource by slices or processes. It requires the information "who owns this process". For packages, they should tell DSM which daemon belongs to them.

All you have to do is to fill the `Slice` field in your systemd unit with `[package_name].slice`. Here is an example field from units for MyPackage:

```
...
[Service]
Slice=MyPackage.slice
...
```

If the field is properly set, you should be able to see your package shown on the resource monitor.
