---
source: https://help.synology.com/developer-guide/synology_package/package_tgz/package_tgz.html
title: package.tgz
fetched: 2026-09-11
---

# package.tgz

The **package.tgz** is a compressed file (tgz / xz) containing all the files you would need when bringing up your applications such as:

- executable files

- library files

- UI files

- configuration files

> You can use pkg_make_package function to create the **package.tgz** instead of packing it manually.

Once the package is installed, your package.tgz will be extracted to `/volume?/@appstore/[your_pkg_name]/` or `/usr/local/packages/@appstore/[your_pkg_name]/` folder (depending on the *install_type* in INFO).
In the meantime, there will be a soft link at `/var/packages/[your_pkg_name]/target` pointing to the assigned folder.

In addition to the `target` directory, system will also create other directories for package to store its data for different purposes. Detailed information can be found HERE.
