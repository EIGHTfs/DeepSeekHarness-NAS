---
source: https://help.synology.com/developer-guide/synology_package/INFO_necessary_fields.html
title: Field Name: package
fetched: 2026-09-11
---

## Field Name: package

- ** Description: **
Package identity. No more than one version of a package can exist at the same time in the end user's DSM; therefore, the identification is unique to identify your package. Besides, Package Center will create a /var/packages/[package identity] folder to put package files.

> Note: This value of the key cannot contain any of these special characters :, /, >, <, | or =.

-

** Value: **
String

-

** Default Value: **
(Empty)

-

** Example: **

```
package="DownloadStation"
```

-

** DSM Requirement: **
2.0-0731

## Field Name: version

-

** Description: **
Package version. End users can identify the package version.

> Note:

> 1. Each version delimiter is only allowed to be . - or _.

> 2. Each version number which is delimited by delimiteris only allowed to be number

> 3. Version value should be in the format of **[feature number]-[build number]**. Build number should be increased on every version and it can be used to distinguish package versions between different DSM major versions.

-

** Value: **
String, major, minor, micro and build numbers should be in the range of 0 - 2^31-1.

-

** Default Value: **
(Empty)

-

** Example: **

```
version="3.6-3263"
version="1.2.3-0001"
```

-

** DSM Requirement: **
2.0-0731

## Field Name: os_min_ver

- ** Description: **
Earliest version of DSM that is required to run the package. The value should be at least `7.0-40000` after DSM 7.0.

- ** Value: **
X.Y-Z DSM major number, DSM minor number, DSM build number

- ** Default Value: **
None

- ** Example: **

```
os_min_ver="7.0-40000"
```

- ** DSM Requirement: **
6.1-14715

## Field Name: description

-

** Description: **
Package Center shows a short description of the package.

-

** Value: **
String

-

** Default Value: **
(Empty)

-

** Example: **

```
description = "Download Station is a web-based download application which allows you to download files from the Internet through BT, FTP, HTTP, NZB, Thunder, FlashGet, QQDL, and eMule, and subscribe to RSS feeds to keep you updated on the hottest or latest BT. It offers the auto unzip service to help you extract compressed files to your Synology NAS whenever files are downloaded. With Download Station, you can download files from multiple file hosting sites, and search for torrent files via system default search engines as well as self-added engines with the BT search function."
```

-

** DSM Requirement: **
2.3-1118

-

** DSM Requirement: **
4.2-3160

## Field Name: arch

-

** Description: **
List the CPU architectures which can be used to install the package.

-

** Value: **
(arch values are separated with a space. Please refer Appendix A: Platform and Arch Value Mapping Table to more information)

-

** Default Value: **
noarch

> Note:

> 1. "noarch" means the package can be installed and work in any platform. For example, the package is written in PHP or shell script.

> 2. Please not pack all binary files with different platforms to one package spk file.

- ** Example: **

```
arch="noarch"
or
arch="x86_64 alpine"
```

- ** DSM Requirement: **
2.0-0731

## Field Name: maintainer

-

** Description: **
Package Center shows the developer of the package.

-

** Value: **
String

-

** Default Value: **
(Empty)

-

** Example: **

```
maintainer="Synology Inc."
```

-

** DSM Requirement: **
2.0-0731
