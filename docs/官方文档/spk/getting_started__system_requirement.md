---
source: https://help.synology.com/developer-guide/getting_started/system_requirement.html
title: System Requirements
fetched: 2026-09-11
---

# System Requirements

## Toolkit Requirements

- **64bit** generic linux environment with root permission (e.g., Ubuntu 18.04 LTS)

- bash (>= 4.1.5)

- python (>= 2.7.3)

Please **DO NOT install toolkit on Synology NAS** as your development environment. NAS is specialized for storage, and not for generic developing purpose. Instead, you can install `Docker` package on NAS then setup a generic linux container to install the toolkit.

## Runtime Requirements

- If your package is for DSM6 then you should have a DSM6 NAS.

- If your package is for DSM7 then you should have a DSM7 NAS.

> Package for DSM6 is not compatible with DSM7

## Install Development Token (For collaborative partners only)

If you are developing a package with root privilege, you are not able to install that package unless it is signed by synology. To deal with this security restriction, we provide a development token to bypass the signing restriction.

1. Open your DSM web UI, go to Support Center > Support Services.

2. Press "Generate Logs" button and you will get a file named `debug.dat`.

3. Send the `debug.dat` to Synology.

4. The Synology will sign a token and send it to you.

5. Put the development token to `/var/packages/syno_dev_token` on the NAS where the `debug.dat` generated.

If everything works fine, your unsigned package will be accepted for installation. If not, you would receive the error message:

- Failed to install. The package should run with a lower privilege level. Please contact the package developer to modify the privilege settings.

If you believe you are doing it correct and the problem persists, please contact us for help.

The development token is only valid for the NAS generating the `debug.dat`. Installing the token to another NAS does not make the bypass work.
