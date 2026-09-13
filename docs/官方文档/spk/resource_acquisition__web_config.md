---
source: https://help.synology.com/developer-guide/resource_acquisition/web_config.html
title: Web Config (since DSM7.2)
fetched: 2026-09-11
---

# Web Config (since DSM7.2)

### Description

This worker handles the Nginx static config.

- Make the registered nginx static config take effect at its desired time.

- The required resources can be registered synchronously, including port and 80/443 alias. It can be declared separately without additionally specifying config.

**FROM_POSTINST_TO_PREUNINST**

- `Acquire()`: copies all registered configs under `/var/packages/${package}/target/` to the corresponding nginx available folder and create a config link with a timing of disable to the corresponding nginx enable folder.

- `Release()`: removes all available configs and enable links.

**FROM_STARTUP_TO_HALT**

- `Acquire()`

- removes the enable config link whose timing is **disable** from the corresponding nginx folder

- creates the config link whose timing is **enable** to the corresponding nginx folder

- `Release()`

- removes the enable config link with a timing of **enable** from the corresponding nginx folder

- create the config link with a timing of **disable** to the corresponding nginx folder

### Note

- When creating an enable link, it will first lock and test the nginx config to avoid race conditions and to ensure that it does not conflict with the enabled config.

- Acquire will end immediately if any failures occur during the process. Release will finish as much as possible even if errors occur during the process.

- If a config registers enable and disable the timing at the same time, the config will create an enable link after the Package is installed and delete the enable link when the Package is removed. Package enable/disable will not operate the link.

- When the configuration is copied to the available folder, its name will be hash calculated, and the corresponding prefix and suffix will be added. There is no need to worry about collisions with other or your own configurations. The converted configuration name will be {prefix of type}.{package}-hash({path}).conf.

- Worker will not reload nginx, if you need to reload nginx service, please following the instructions below:

- if there is a config with timing as **enable**, package owner needs to marked `instuninst_restart_services = nginx.service` in INFO

- if there is a config with timing as **disable**, package owner needs to marked `instuninst_restart_services = nginx.service` `startstop_restart_services = nginx.service` in INFO

- Registering port resources is limited to allowing nginx framework to assist in reserving and confirming the use of the port number. The package still needs to write a port config worker to register the port number.

### Provider

DSM

### Timing

`FROM_POSTINST_TO_PREUNINST`
`FROM_STARTUP_TO_HALT`

### Environment Variables

None

### Updatable

No

### Syntax

```
"web-config": {
  "nginx-static-config": {
  "enable": [{
    "type": "<config type>",
    "relpath": "<config relpath>",
    "ports": [{
    "port": <config port used>",
    "protocol": <config port protocol used>",
    "schema": <config port schema used>",
    }],
    "alias": ["<config alias used>"]
  }],
  "disable": [{
    "type": "<config type>",
    "relpath": "<config relpath>",
    "ports": [{
    "port": <config port used>",
    "protocol": <config port protocol used>",
    "schema": <config port schema used>",
    }],
    "alias": ["<config alias used>"]
  }]
  }
}
```

#### nginx-static-config

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

| Member | Since | Description |
|---|---|---|
| nginx-static-config | 7.0-40120 | List the nginx static config to be used by the package |
| enable | 7.0-40120 | List the nginx static config to be applied when the package is enabled |
| disable | 7.0-40120 | List nginx static config to be applied when the package is disabled |
| type | 7.0-40120 | The type of config to be placed determines its include position in nginx config. Currently supports dsm, www, http, server, x-accel, main |
| relpath | 7.0-40120 | The relative path of the config to be placed under /var/packages/${package}/target/ |
| port | 7.1-42446 | Declare the port number used |
| protocol | 7.1-42446 | Declare the port number protocol used, can be filled in tcp/udb/both |
| schema | 7.1-42446 | Declare the port number schema used, http/https can be filled |
| alias | 7.1-42446 | The 80/443 alias used for the declaration |

- type

| Name | Since | Description |
|---|---|---|
| dsm | 7.0-40120 | Valid for DSM Server block and DSM custom domain block (5000/5001) |
| www | 7.0-40120 | Valid for Default server block (80/443) |
| http | 7.0-40120 | Valid for HTTP context |
| server | 7.0-40120 | Independent server block |
| x-accel | 7.0-40120 | Valid for DSM Server block, DSM custom domain block and Default server block, used to place x-accel settings |
| main | 7.0-40227 | Valid for HTTP Context. It can place independent stream block, mail block or other settings that do not belong to HTTP Context |

### Example

```
{
  "web-config": {
    "nginx-static-config": {
      "enable": [{
        "type": "www",
        "relpath": "synology_added/enable",
        "alias": [
          "www-test"
        ]
      },
      {
        "type": "http",
        "relpath": "synology_added/install"
      },
      {
        "type": "server",
        "relpath": "synology_added/enable",
        "ports": [{
          "port": 50400,
          "protocol": "tcp",
          "schema": "http"
        }]
      },
      {
        "ports": [{
          "port": 50455,
          "protocol": "tcp",
          "schema": "http"
        }],
        "alias": [
          "unique-test"
        ]
      }],
      "disable": [{
        "type": "x-accel",
        "relpath": "synology_added/disable"
      },
      {
        "type": "http",
        "relpath": "synology_added/install"
      },
      {
        "type": "dsm",
        "relpath": "synology_added/disable"
      }]
    }
  }
}
```
