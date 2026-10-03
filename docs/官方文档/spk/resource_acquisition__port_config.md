---
source: https://help.synology.com/developer-guide/resource_acquisition/port_config.html
title: Port Config
fetched: 2026-09-11
---

# Port Config

#### Description

Install / uninstall service port config file during package install / uninstall.

For detailed description on what is and how to write a port config file, please refer to Install Package Related Ports Information into DSM.

- `Acquire()`: copy the .sc file to */usr/local/etc/service.d/*

- If the destination file exists, skip file copy.

- `Release()`: remove the .sc file and reload the firewall and portforward.

- `Update()`: update the .sc file and reload firewall and portforward.

#### Timing

`FROM_POSTINST_TO_POSTUNINST`

#### Environment Variables

None

#### Updatable

Yes, please refer to Config Update on how to trigger update.

#### Syntax

```
"port-config": {
    "protocol-file": <protocol_file>
 }
```

``

**

| Member | Since | Description |
|---|---|---|
| protocol_file | 6.0-5936 | .sc file's relative path under /var/package/{$package}/target/ |

#### Example

```
"port-config": {
    "protocol-file": "port_conf/xxdns.sc"
 }
```
