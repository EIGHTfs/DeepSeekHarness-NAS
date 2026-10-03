---
source: https://help.synology.com/developer-guide/integrate_dsm/desktopapp.html
title: Desktop Application
fetched: 2026-09-11
---

# Desktop Application

You can provide a App Config for your package so that the configured application will show on the menu of desktop. It is possible to customize icon, application privilege and target url.

To distinguish different role of users, **one package can even provide more than one application** such as admin application for administrators and normal application for normal users.

In addition, any application can bring its own help documents into desktop by providing a Help Config.

## Steps to setup desktop application

1.

Create a directory inside package.tgz, this directory will be used to store desktop application configs. We name it as `ui` for example here.

2.

Add `dsmuidir` key to your **INFO** or **INFO.sh** whose value is the relative path to the directory you just created on previous step.

```
 dsmuidir="ui"
```

```
 dsmuidir="MyApp1:appui1 MyApp2:appui2"
```

> If you have multiple applications, the second form should be applied. In the example above, `MyApp1` represents an identifier and `appui1` represents a relative path.

> Once the package is installed, DSM will create corresponding soft link at `/usr/syno/synoman/webman/3rdpaty/[identifier]/` linking to the path where your relative path is. When the identifier is not presented in the first form, DSM will use package name as identifier by default.

3.

Create your own App Config and Help Config under the directory specified by `dsmuidir` if necessary.

4.

Add `dsmappname` key to your **INFO** or **INFO.sh** whose value is the unique application name inside App Config. This application will be the target application when open button of package is clicked in package center.

```
dsmappname="com.company.App1"
```
