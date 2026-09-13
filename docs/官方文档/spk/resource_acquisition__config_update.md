---
source: https://help.synology.com/developer-guide/resource_acquisition/config_update.html
title: Resource Update
fetched: 2026-09-11
---

# Resource Update

Some workers support update operation outside of worker timings. */usr/syno/sbin/synopkgheler* should be used to accomplish this job. Below are the steps to update the resource:

1. Update the file at `/var/packages/[package_name]/conf/resource`

2. Execute the command `/usr/syno/sbin/synopkghelper update [package_name] [resource_id]` to trigger updating procedure.

For example, suppose a package allows the user to edit its listening port and needs to update correponding network settings:

1. User submits new port to the application

2. The application updates the file at `/var/packages/[package_name]/conf/resource`

3. The application executes the command `/usr/syno/sbin/synopkghelper update ${package} port-config`, then the `port-config` worker will read the config and reload network settings.

NOTE Not all resource support update operation, please refer to the *Updatable* section of each resource.
