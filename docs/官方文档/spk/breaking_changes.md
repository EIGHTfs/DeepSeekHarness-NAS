---
source: https://help.synology.com/developer-guide/breaking_changes.html
title: Breaking Changes in 7.0
fetched: 2026-09-11
---

# Breaking Changes in 7.0

In DSM7.0 , there’re some breaking changes in package framework、Package Center and commands. Also see Release Notes.

## Package Framework Changes

#### 1. Force lower privilege for package

All packages should provide `conf/privilege` with `package` in `run-as` explicitly. Any privileged operation should be accomplished via resource worker.

#### 2. Force some INFO fields to be neccessary

Any package should have `package`, `version`, `os_min_ver`, `description`, `arch` and `maintainer` fields. Futhermore, the value of `os_min_ver` should be at least `7.0-40000` or you cannot install the package correctly.

#### 3. Remove package signing mechanism

Packages are no longer able to do signing in packing stage.

#### 4. Remove `run-as system` from privilege

Packages will not be able to use run-as system in `conf/privilege`. Instead, all packages should run as `package`.

#### 5. Change default home path from `target` to `home`

The home directory of package is changed from `/var/packages/[package_name]/target` to `/var/packages/[package_name]/home` and its mode will be 0700.

#### 6. Change `PACKAGE_ICON.PNG` from 72x72 to 64x64

Package should have PACKAGE_ICON.PNG in 64x64 above 7.0.

#### 7. Change FHS directory owner according to privilege settings

FHS directories such as `target` will have new privilege settings according to `conf/privilege`.

#### 8. Change package log location to `/var/log/packages/[package_name].log` and `/var/log/synopkg.log`

Package operation log is still at `/var/log/synopkg.log` but control script log will be at `/var/log/packages/[package_name].log`. Besides, when you are developing a package, you should always pay attention to the content of `/var/log/messages` to check if there are any warning or error.

#### 9. Consider `prestart` script on bootup

The `prestart` script will run on bootup to check if a package can be started.

## Package Center Changes

#### 1. Remove keyring && Remove trust level

User are no longer be able to add / remove keyrings on package center since we have deprecated the codesign mechanism of spk. Similarly, there will be no trust level settings for user to choose. Any non-synology package will get alert on installation.

## Command Changes

#### 1. `synopkg start` starts a package with its dependees

If A depends on B, run `synopkg start A` will also start B when B is not started.

#### 2. `synopkg install` checks if package can be installed

The `synopkg install` command will have same constraints as UI installation.
