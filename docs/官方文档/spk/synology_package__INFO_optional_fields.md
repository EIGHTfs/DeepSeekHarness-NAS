---
source: https://help.synology.com/developer-guide/synology_package/INFO_optional_fields.html
title: Field Name: displayname
fetched: 2026-09-11
---

## Field Name: displayname

- ** Description: **
Package Center shows the name of the package.

> Note: If **displayname** key is empty, Package Center will display the value of **package** key.

- ** Value: **
String

- ** Default Value: **
The value of **package** key

- ** Example: **
None

- ** DSM Requirement: **
2.3-1118

## Field Name: displayname_[ DSM language]

- **Description**:
Package Center shows the name in the DSM language set by the end-user.
DSM supports the following languages:

- enu (English)

- cht (Traditional Chinese)

- chs (Simplified Chinese)

- krn (Korean)

- ger (German)

- fre (French)

- ita (Italian)

- spn (Spanish)

- jpn (Japanese)

- dan (Danish)

- nor (Norwegian)

- sve (Swedish)

- nld (Dutch)

- rus (Russian)

- plk (Polish)

- ptb (Brazilian Portuguese)

- ptg (European Portuguese)

- hun (Hungarian)

- trk (Turkish)

- csy (Czech)

- **Value**:
String

- **Default Value**:
package name

-

**Example**:

```
displayname_enu="Hello World"
displayname_cht="你好"
```

-

**DSM Requirement**:
2.3-1118

## Field Name: description_[ DSM language]

-

**Description**:
Package Center shows a short description in the DSM language set by the end-user.

DSM supports the following languages:

- enu (English)

- cht (Traditional Chinese)

- chs (Simplified Chinese)

- krn (Korean)

- ger (German)

- fre (French)

- ita (Italian)

- spn (Spanish)

- jpn (Japanese)

- dan (Danish)

- nor (Norwegian)

- sve (Swedish)

- nld (Dutch)

- rus (Russian)

- plk (Polish)

- ptb (Brazilian Portuguese)

- ptg (European Portuguese)

- hun (Hungarian)

- trk (Turkish)

- csy (Czech)

-

**Value**:
String

- **Default Value**:
description

- **Example**:

```
description_enu="Hello World"
description_cht="你好"
```

- **DSM Requirement**:
2.3-1118

## Field Name: maintainer_url

- **Description**:
If a package has a developer webpage, Package Center will show a link to let the user open it.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:

```
maintainer_url="http://www.synology.com"
```

- **DSM Requirement**:
4.2-3160

## Field Name: distributor

- **Description**:
Package Center shows the publisher of the package.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:

```
distributor="Synology Inc."
```

- **DSM Requirement**:
4.2-3160

## Field Name: distributor_url

- **Description**:
If a package is installed and has a distributer webpage, Package Center will show a link to let the user open it.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:

```
distributor_url ="http://www.synology.com/enu/apps/3rd-party_application_integration.php"
```

- **DSM Requirement**:
4.2-3160

## Field Name: support_url

-

**Description**:
Package Center shows a support link to allow users to seek technical support when needed.

-

**Value**:
String

-

**Default Value**:
(Empty)

-

**Example**:

```
support_url="https://myds.synology.com/support/support_form.php".
```

## Field Name: support_center

- **Description**:
If set to “yes,” Package Center displays a link to make the end user launch Synology Support Center Application when your package is installed.

> Note: If set to “yes,” the **report_url** link won’t show in Package Center.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:
None

- **DSM Requirement**:
5.0-4458

## Field Name: model

- **Description**:
List of models on which packages can be installed in spesific models. It is organized by Synology string, architecture and model name.

- **Value**:
(models are separated with a space, e.g. synology_88f6281_209, synology_cedarview_rs812rp+, synology_x86_411+II, synology_bromolow_3612xs, synology_cedarview_rs812rp+, …)

- **Default Value**:
(Empty)

- **Example**:

```
model="synology_bromolow_3612xs synology_cedarview_rs812rp+".
```

- **DSM Requirement**:
4.0-2219

## Field Name: exclude_arch

- **Description**:
List the CPU architectures where the package can't be used to install the package.

> Note: Be careful to use this **exclude_arch** field. If the package has different **exclude_arch** value in the different versions, the end user can install the package in the specific version without some arch values of **exclude_arch**.

- **Value**:
(arch values are separated with a space. Please refer Appendix A: Platform and Arch Value Mapping Table to more information)

- **Default Value**:
(Empty)

- **Example**:
None

- **DSM Requirement**:
6.0

- **Example**:

```
exclude_arch="bromolow cedarview".
```

## Field Name: checksum

- **Description**:
Contains MD5 string to verify the package.tgz.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:
None

- **DSM Requirement**:
3.2-1922

## Field Name: adminport

- **Description**:
A package listens to a specific port to display its own UI.
If the package is defined by a port, a link will be opened when the package is started.

> Note: **adminprotocol**, **adminport**and **adminurl** keys are combined to **adminprotocol**://ip:**adminport**/**adminurl** link

- **Value**:
0~65536

- **Default Value**:
80

- **Example**:

```
adminport="9002"
```

- **DSM Requirement**:
2.0-0731

## Field Name: adminurl

- **Description**:
If a package is installed and has a webpage, a link will be opened when the package is started.

> Note: **adminprotocol**, **adminport**and **adminurl** keys are combined to **adminprotocol**://ip:**adminport**/**adminurl** link

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:

```
adminurl="web"
```

- **DSM Requirement**:
2.3-1118

## Field Name: adminprotocol

- **Description**:
A package uses a specific protocol to display its own UI. If a package is installed and has a webpage, a protocol will be opened when the package is started.

> Note: **adminprotocol**, **adminport**and **adminurl** keys are combined to **adminprotocol**://ip:**adminport**/**adminurl** link

- **Value**:
http / https
(Separated with a space)

- **Default Value**:
http

- **Example**:

```
adminprotocol="http"
```

- **DSM Requirement**:
3.2-1922

## Field Name: dsmuidir

- **Description**:
DSM UI folder name in package.tgz. The UI folder of the package in **/var/packges/[packge name]/target/[dsmuidir]** will be automatically linked to the DSM UI folder in **/usr/syno/synoman/webman/3rdparty/[linkname]** to show your package's shortcut in DSM.

> Note:

> 1. If only one path is provided, the path will be the relative path to dsmuidir in package target and the link name will be package name.

> 2. If multiple key:value pairs are provided, the key will be the name of link and the value will be the relative path to dsmuidir in package target.

> 3. Please refer Integrate Your package into DSM for more information.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:

```
dsmuidir="ui"
dsmuidir="MyLinkName1:ui/app1 MyLinkName2:ui/app2"
```

- **DSM Requirement**:
3.2-1922 for single value
7.0-40731 for multiple values

## Field Name: dsmappname

- **Description**:
The value of each individual application will be equal to the unique property name in DSM’s config file so as to be integrated into Synology DiskStation.

> Note: Please refer Config in Integrate Your package into DSM chapter for more information.

- **Value**:
(Separated with a space)

- **Default Value**:
(Empty)

- **Example**:

```
dsmappname="SYNO.SDS.PhotoStation SYNO.SDS.PersonalPhotoStation"
```

- **DSM Requirement**:
3.2-1922

## Field Name: dsmapppage

- **Description**:
The application page to open when click on package open button (should be used with **dsmappname** key)

- **Value**:
Page name

> Note: page name corresponds to PageListAppWindow's fn value when calling SYNO.SDS.AppLaunch

- **Default Value**:
(Empty)

- **Example**:

```
dsmappname="SYNO.SDS.AdminCenter.Application"
dsmapppage="SYNO.SDS.AdminCenter.FileService.Main"
```

- **DSM Requirement**:
7.0-40332

## Field Name: dsmapplaunchname

- **Description**:
The value will be used to launch desktop app, and it has higher priority than dsmappname.

- **Value**:
App name

- **Default Value**:
same as `dsmappname`

- **Example**:

```
dsmapplaunchname="SYNO.SDS.AdminCenter.Application"
```

- **DSM Requirement**:
7.0-40796

## Field Name: checkport

- **Description**:
Check if there is any conflict between the **adminport** and the ports which are reserved or are listening on DSM except web-service ports (e.g. 80, 443) and DSM ports (e.g. 5000, 5001).

- **Value**:
"yes"/"no"

- **Default Value**:
"yes"

- **Example**:
None

- **DSM Requirement**:
3.2-1922

## Field Name: startable

- **Description**:
When no program in the package provides the end-user with the options to enable or disable its function. This key is set to "no" and the end-user cannot start or stop the package in Package Center.

> Note: Deprecated after 6.1-14907, use *ctl_stop* instead.
> If “startable” is set to “no”, **start-stop-status** script which runs in bootup or shotdown is still required.

- **Value**:
"yes"/"no"

- **Default Value**:
"yes"

- **Example**:
None

- **DSM Requirement**:
3.2-1922

## Field Name: ctl_stop

- **Description**:
When no program in the package provides the end-user with the options to enable or disable its function. This key is set to "no" and the end-user cannot start or stop the package in Package Center.

> Note: If “ctl_stop” is set to “no”, **start-stop-status** script which runs in bootup or shotdown is still required.

- **Value**:
"yes"/"no"

- **Default Value**:
"yes"

- **Example**:
None

- **DSM Requirement**:
6.1-14907

## Field Name: ctl_uninstall

- **Description**:
If this key is set to "no", the end-user cannot uninstall the package in Package Center.

- **Value**:
"yes"/"no"

- **Default Value**:
"yes"

- **Example**:
None

- **DSM Requirement**:
6.1-14907

## Field Name: precheckstartstop

- **Description**:
If set to "yes", let start-stop-status with prestart or prestop argument run before start or stop the package. Please refer to start-stop-status in scripts for more information.

- **Value**:
"yes"/"no"

- **Default Value**:
"yes"

- **Example**:
None

- **DSM Requirement**:
6.0

## Field Name: helpurl

- **Description**:
If a package is installed and has a "help" webpage, Package Center will display a hyperlink to the user.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:

```
helpurl="https://www.synology.com/en-global/knowledgebase"
```

- **DSM Requirement**:
3.2-1922

## Field Name: beta

- **Description**:
If this package is considered the beta version, the beta information will be shown in Package Center.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:
None

- **DSM Requirement**:
6.0

## Field Name: report_url

- **Description**:
If a package is a beta version and has a "report" webpage, Package Center will display a hyperlink. If this package is considered the beta version, the beta information will be also be shown in Package Center.

- **Value**:
String

- **Default Value**:
(Empty)

- **Example**:
None

- **DSM Requirement**:
3.2-1922

## Field Name: install_reboot

- **Description**:
Reboot DiskStation after installing or upgrading the package.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:
None

- **DSM Requirement**:
3.2-1922

## Field Name: install_dep_packages

- **Description**:
Before a package is installed or upgraded, these packages must be installed first.
In addition, the order of starting or stopping packages is also dependent on it. The format consists of a package name. If more than one dependent packages are required, the package name of the package(s) will be separated with a colon, e.g. **install_dep_packages="packageA"**. If a specific version range is required, package name will be followed by one of the special characters =, <, >, >=, <= and package version which is composed by number and periods, e.g. **install_dep_packages="packageA>2.2.2:packageB"**.

> Note: **>=** and **<=** operator only supported in DSM 4.2 or newer. Don’t use **<=** and **>=** if a package can be installed in DSM 4.1 or older because it cannot be compared correctly. Instead, the package version should be set lower or higher.

- **Value**:
Package names

> Note: Each package name is separated with a colon.

- **Default Value**:
(Empty)

- **Example**:

```
install_dep_packages="packageA"
or
install_dep_packages="packageA>2.2.2:packageB"
```

- **DSM Requirement**:
3.2-1922

## Field Name: install_conflict_packages

- **Description**:
Before your package is installed or upgraded, these conflict packages cannot be installed. The format consists of a package name, e.g. **install_conflict_packages="packageA"**. If more than one conflict packages are required with the format, the name of the package(s) will be separated with a colon, e.g. **install_conflict_packages="packageA:packageB"**. If a specific version range is required, package name will be followed by one of the special characters =, <, >, >=, <= and package version which is composed by number and periods, e.g. **install_conflict_packages="packageA>2.2.2:packageB"**.

> Note: **>=** and **<=** operator only supported in DSM 4.2 or newer. Do not use **<=** and **>=** if a package can be installed in DSM 4.1 because it can’t be compared correctly. Instead, the package version should be set lower or higher.

- **Value**:
Package names

> Note: Each package name is separated with a colon.

- **Default Value**:
(Empty)

- **Example**:

```
install_conflict_packages="packageA:packageB"
or
install_conflict_packages="packageA>2.2.2:packageB"
```

- **DSM Requirement**:
4.1-2851

## Field Name: install_break_packages

- **Description**:
After your package is installed or upgraded, these to-be-broken packages will be stopped and remain broken during the existence of your package. The format consists of a package name, e.g. **install_break_packages="packageA"**. If more than one to-be-broken packages are required with the format, the name of the package(s) will be separated with a colon, e.g. **install_break_packages="packageA:packageB"**. If a specific version range is required, package name will be followed by one of the special characters =, <, >, >=, <= and package version which is composed by number and periods, e.g. **install_break_packages="packageA>2.2.2:packageB"**.

- **Value**:
Package names

> Note: Each package name is separated with a colon.

- **Default Value**:
(Empty)

- **Example**:

```
install_break_packages="packageA:packageB"
or
install_break_packages="packageA>2.2.2:packageB"
```

- **DSM Requirement**:
6.1-15117

## Field Name: install_replace_packages

- **Description**:
After your package is installed or upgraded, these to-be-replaced packages will be removed. The format consists of a package name, e.g. **install_replace_packages="packageA"**. If more than one to-be-replaced packages are required with the format, the name of the package(s) will be separated with a colon, e.g. **install_replace_packages="packageA:packageB"**. If a specific version range is required, package name will be followed by one of the special characters =, <, >, >=, <= and package version which is composed by number and periods, e.g. **install_replace_packages="packageA>2.2.2:packageB"**.

- **Value**:
Package names

> Note: Each package name is separated with a colon.

- **Default Value**:
(Empty)

- **Example**:

```
install_replace_packages="packageA:packageB"
or
install_replace_packages="packageA>2.2.2:packageB"
```

- **DSM Requirement**:
6.1-15117

## Field Name: install_dep_services

- **Description**:
Before the package is installed or upgraded, these services must be started or enabled by the end-user.

- **Value**:

DSM 4.2 or older: apache-web, mysql, php_disable_safe_exec_dir

DSM 4.3: apache-web, mysql, php_disable_safe_exec_dir, ssh

DSM 5.0 ~ DSM 5.2: apache-web, php_disable_safe_exec_dir, ssh, pgsql

DSM 6.0: ssh, pgsql

DSM 7.0: ssh-shell, pgsql, network.target, network-online.target, nginx.service, avahi.service, atalk.service, crond.service, nfs-server.service

> Note: Each service is separated with a space.

- **Default Value**:
(Empty)

- **Example**:

```
install_dep_services="apache-web ssh"
```

- **DSM Requirement**:
3.2-1922

## Field Name: start_dep_services

- **Description**:
Before the package is started, these services must be started or enabled by the end-user. If startable is set to “no”, this value is ignored.

- **Value**:

DSM 4.2 or older: apache-web, mysql, php_disable_safe_exec_dir

DSM 4.3: apache-web, mysql, php_disable_safe_exec_dir, ssh

DSM 5.0 ~ DSM 5.2: apache-web, php_disable_safe_exec_dir, ssh, pgsql

DSM 6.0: ssh, pgsql

DSM 7.0: ssh-shell, pgsql, network.target, network-online.target, nginx.service, avahi.service, atalk.service, crond.service, nfs-server.service

> Note: Each service is separated with a space.

- **Default Value**:
(Empty)

- **Example**:

```
install_dep_services="apache-web ssh"
```

- **DSM Requirement**:
3.2-1922

## Field Name: extractsize

- **Description**:
This value indicates the minimal space to install a package. It will be used to prompt the user if there is enough free space to install it.

> Note:

> 1. In DSM 5.2 or order, the size based on byte unit.

> 2. In DSM 6.0 or newer, the size based on kilobyte unit.

- **Value**:
Size unit

- **Default Value**:
The byte size of SPK file of package

- **Example**:

```
extractsize="253796"
```

- **DSM Requirement**:
4.0-2166

## Field Name: support_conf_folder

- **Description**:
In DSM 5.2 or order, if you want to use some special configuration files within a "**conf**" folder, this value must be set to "**yes**". More details are given in the "**conf**" section. Howerver, in DSM 6.0 or newer, you don't need to define it anymore.

> Note: Deprecated in DSM 6.0

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
support_conf_folder="yes"
```

- **DSM Requirement**:
4.2-3160 ~ 5.2

## Field Name: install_type

- **Description**:
If set to “system”/"system_hidden", your package will be installed in the root file system, **/usr/local/packages/@appstore/**, even if there is no volume.

> Note:

> 1. Be careful when setting this, as it may result in the DiskStation crashing if your package runs out of the space in the root file system.

- **Value**:
"system"

- **Default Value**:
(Empty)

- **Example**:

```
install_type="system"
```

- **DSM Requirement**:
5.0-4458

## Field Name: silent_install

- **Description**:
If set to “yes”, your package is allowed to be installed without the package wizard in the background. This allows CMS (Central Management System) to distribute package installation to other NAS connected.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
silent_install="yes"
```

- **DSM Requirement**:
5.0-4458

## Field Name: silent_upgrade

- **Description**:
If set to “yes”, your package is allowed to be upgraded without the package wizard in the background. End user cannot modify any information for upgrading. This allows not only your package to be upgraded automatically but also for CMS (Central Management System) to distribute package upgrades to other NAS connected.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
silent_upgrade="yes"
```

- **DSM Requirement**:
5.0-4458

## Field Name: silent_uninstall

- **Description**:
If set to “yes”, your package is allowed to be uninstalled without the package wizard in the background. This allows CMS (Central Management System) to distribute package uninstallation to other NAS connected.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
silent_uninstall="yes"
```

- **DSM Requirement**:
5.0-4458

## Field Name: auto_upgrade_from

- **Description**:
It is set to a version of your package. If your package is set to **silent_upgrade="yes"** and the value is set, Package Center only upgrades your package automatically from the installed package with the version or the newer version. However, if the end user install a older version than it, Package Center won't upgrade it automatically and the user must upgrade it by themself.

- **Value**:
(a package version)

- **Default Value**:
(Empty string)

- **Example**:

```
auto_upgrade_from="2.0"
```

-

**DSM Requirement**:
5.2-5565

## Field Name: offline_install

- **Description**:
If set to "yes", after the package is published in synology server, it won't be shown in the package list of Package Center from Synology server. However, the user can install the package manually.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
offline_install="yes"
```

- **DSM Requirement**:
DSM 6.0

## Field Name: thirdparty

- **Description**:
If set to “yes”, your package is a third-party package and isn't developed by Synology. In Package Center, third-pary pacakges will be shown in another part.

> Note: It's not used in DSM 5.0 or newer.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
thirdparty="yes"
```

- **DSM Requirement**:
4.0~4.3

## Field Name: os_max_ver

- ** Description: **
Maximum version of DSM that is capable to run the package.

- ** Value: **
X.Y-Z DSM major number, DSM minor number, DSM build number

- ** Default Value: **
None

- ** Example: **

```
os_max_ver="6.1-14715"
```

- ** DSM Requirement: **
6.1-14715

## Field Name: support_move

- ** Description: **
If set to "yes", the package can be moved to a different volume after installation.

- ** Value: **
"yes"/"no"

- ** Default Value: **
"no"

- ** Example: **

```
support_move="yes"
```

- ** DSM Requirement: **
6.2-22306

## Field Name: exclude_model

- **Description**:
List the model names where the package can't be used to install the package.

> Note: Be careful to use this **exclude_model** field. If the package has different **exclude_model** value in the different versions, the end user can install the package in the specific version without some model values of **exclude_model**.

- **Value**:
model values are separated with a space.

- **Default Value**:
(Empty)

- **Example**:

```
exclude_model="synology_cedarview_713+ synology_kvmx64_virtualdsm"
```

- **DSM Requirement**:
7.0-40329

## Field Name: use_deprecated_replace_mechanism

- **Description**:
if set to "yes", replacee will be uninstalled after replacer installed, and prereplace / postreplace scripts will not be executed. Otherwise, replacee will be uninstalled before replacer installed, and prereplace / postreplace will be executed.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
install_replace_packages="packageA"
use_deprecated_replace_mechanism="yes"
```

- **DSM Requirement**:
7.0-40340

## Field Name: install_on_cold_storage

- **Description**:
if set to "yes", this package can be installed on cold storage, which has very large space for data storage.

- **Value**:
"yes"/"no"

- **Default Value**:
"no"

- **Example**:

```
install_on_cold_storage="yes"
```

- **DSM Requirement**:
7.0-40726
