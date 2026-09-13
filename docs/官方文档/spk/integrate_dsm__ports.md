---
source: https://help.synology.com/developer-guide/integrate_dsm/ports.html
title: Port
fetched: 2026-09-11
---

# Port

If your package service uses specific ports for communication (e.g. Surveillance Station uses ports 19997/udp for source port and 19998/udp for destination port), you should prepare a service configuration file for this package to describe which ports will be used. After that, once the user creates firewall rules or port forwarding rules from the built-in application, your package service will also be listed for selection.

## Service Configure File Name

The file name should follow the naming convention **[package_name].sc** (ex: **SurveillanceStation.sc**). **[package_name]** should be the package name that is specified by the key "**package**" in the **INFO** file, and **sc** means Service Configure file.

## Configure Format Template

Please see the following example:

```
[service_name]
title="English title"
desc="English description"
port_forward="yes" or "no"
src.ports="ports/protocols"
dst.ports="ports/protocols"

[service_name2]
…
```

## Section/Key Descriptions

Please see the following statements for the strings and keys:

**

*

*

**

**

**

**

**

| Section/Key | Description | Value | Default Value | DSM Requirement |
|---|---|---|---|---|
| service_name | Required Usually a package only has one unique service name. If your package needs more than one port description, you can define service_name2, service_name3, … Note: service_name cannot be empty and can only include characters “a~z”, “A~Z”, “0~9”, “-”, “\”, “.” | Unique service name | N/A | 4.0-2206 |
| title | Required English title which will be shown on field Protocol at firewall build-in selection menu. | English title | N/A | 4.0-2206 |
| desc | Required English description which will be shown on field Applications at firewall build-in selection menu. | English description | N/A | 4.0-2206 |
| port_forward | Optional If set to “yes,” your package service related ports will be listed when users set port forwarding rule from build-in applications. Otherwise they will not be listed. | “yes” or “no” | “no” | 4.0-2206 |
| src.ports | Optional If your package service has specified source ports, you can set them in this key. The value should contain at least the port numbers, and a default protocol that is tcp + udp. Ex: 6000,7000:8000/tcp,udp means source ports are 6000, 7000 to 8000, all ports are tcp + udp. | ports/protocols ports: 1~65535 (separated by ‘,’ and use ‘:’ to represent port range) protocols: tcp,udp (separated by ‘,’) | ports: N/A protocols: tcp,udp | 4.0-2206 |
| dst.ports | Required Each service should have destination ports. The value should contain at least the port numbers, and a default protocol that is tcp + udp. Ex: 6000,7000:8000/tcp,udp means destination ports are 6000, 7000 to 8000, all ports are tcp + udp. | ports/protocols ports: 1~65535 (separated by ‘,’ and use ‘:’ to represent port range) protocols: tcp,udp (separated by ‘,’) | ports: N/A protocols: tcp,udp | 4.0-2206 |

Please see the following example (SurveillanceStation.sc):

```
[ss_findhostd_port]
title="Search Surveillance Station"
desc="Surveillance Station"
port_forward="yes"
src.ports="19997/udp"
dst.ports="19998/udp"
```

After the service configuration file is ready, add the following content to the resource specification file. Please refer to Port Config for more detail.

```
"port-config": {
    "protocol-file": "port_conf/xxdns.sc"
 }
```

# Check port conflict

Before trying to change a port number, you would need to check if the port number was already in use.

## How to check if the port number was in use

Assume the package named DhcpServer and the port-config DhcpServer.sc contains:

```
[dhcp_udp]
title="DHCP Server"
title_key="DHCP Server"
desc="DHCP Server"
desc_key="DHCP Server"
port_forward="no"
dst.ports="67,68/udp"
```

Please run the following instructions to check if the port is in use while you are trying to change the port number from `67` to `667`

```
servicetool --conf-port-conflict-check  --tcp 667
```

The output would look like this:

```
root@dev:~# servicetool --conf-port-conflict-check  --tcp 667
IsConflict: false       Port: 667       Protocol: tcp   ServiceName: (null)
root@dev:~#
```

The return code does not indicate port occupation, you need to parse the standard output to extract the *IsConflict* value.

If the IsConflict value is *false*, you can use that port number safely.
