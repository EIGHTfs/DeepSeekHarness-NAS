---
source: https://help.synology.com/developer-guide/release_notes.html
title: Synology Package Framework 7.2
fetched: 2026-09-11
---

# Synology Package Framework 7.2

## Notes

#### 1. Package Framework

- Implementing a wizard using the Vue.js framework and compile by owner

# Synology Package Framework 7.0

## Breaking Changes

Find more details please refer to breaking changes Breaking Changes In 7.0.

## Notes

#### 1. Package Framework

- Force lower privilege for package

- Force some INFO fields to be neccessary

- Remove package signing

- Remove `run-as system` from privilege

- Change default home path from `target` to `home`

- Change `PACKAGE_ICON.PNG` from 72x72 to 64x64

- Change FHS directory owner according to privilege settings

- Change package log location to `/var/log/packages/[package_name].log` and `/var/log/synopkg.log`

- Consider `prestart` script on bootup

#### 2. Package Center

- Remove keyring

- Remove trust level

#### 3. Commands

- `synopkg start` starts the package with its dependees

- `synopkg install` checks if the package can be installed

## New Features

#### 1. SDK Plugin

- Add `package_install` module

- Add `package_uninstall` module

- Add `package_start` module

- Add `package_stop` module

#### 2. Package Framework

- Add `var` directory for FHS

- Add `tmp` directory for FHS

- Add `home` directory for FHS

- Add `prereplace` script

- Add `postreplace` script

-

Add `install_on_cold_storage` to INFO

-

Add `exclude_model` to INFO

- Add `dsmapppage` to INFO

- Add `use_deprecated_replace_mechanism` to INFO

- Add multiple directories support for `dsmuidir` in INFO

#### 3. Resource Worker

- Add `strong-dependence` to data-share worker for package who needs auto start after encrypted share mounted

- Add `systemd-user-unit` worker

## Enhancements

#### 1. Package Framework

- Restart package after repaired according to its original state

- Cannot continue to install package if spk checksum is incorrect

#### 2. Package Center

- Be able to start a package with its dependees

- Be able to stop a package with its dependers

- Be able to uninstall a package with its dependers

- Be able to repair start-failed package via repair button

- Community sources should have same name / source
