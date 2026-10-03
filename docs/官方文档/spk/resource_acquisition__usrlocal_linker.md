---
source: https://help.synology.com/developer-guide/resource_acquisition/usrlocal_linker.html
title: /usr/local linker
fetched: 2026-09-11
---

# /usr/local linker

#### Description

Package's executables and library files should be installed to */usr/local*. This worker link / unlink files to ***/usr/local/{bin,lib,etc}*** during package start / stop.

- `Acquire()`: Create symbolic links under */usr/local/{bin,lib,etc}/* that points to files in */var/packages/${package}/target/*.

- Files not found under */var/packages/${package}/target/* will be ignored.

- If the target file already exists in */usr/local/{bin,lib,etc}*, it will be `unlink()` first.

- Failure on any file link results in this worker to abort and triggers rollback.

- `Release()`: Delete the links under */usr/local/{bin,lib,etc}/*.

- Ignore files that are not found.

- Ignore `unlink()` failure.

#### Provider

DSM

#### Timing

`FROM_ENABLE_TO_DISABLE`

#### Environment Variables

None

#### Updatable

No

#### Syntax

```
"usr-local-linker": {
  "bin" ["<relpath>", ...],
  "lib" ["<relpath>", ...],
  "etc" ["<relpath>", ...]
}
```

``

**

``

**

``

**

``

**

| Member | Since | Description |
|---|---|---|
| bin | 6.0-5941 | String array, list of files to be linked under /usr/local/bin/. |
| lib | 6.0-5941 | String array, list of files to be linked under /usr/local/lib/. |
| etc | 6.0-5941 | String array, list of files to be linked under /usr/local/etc/. |
| relpath | 6.0-5941 | String, target file's relative path under /var/packages/${package}/target/. |

#### Example

```
"usr-local-linker": {
  "bin": ["usr/bin/a2p", "usr/bin/perl"],
  "lib": ["lib/perl5"]
}
```

The above specifications generates the following symbolic links for the Perl package:

```
root@DS $ ls -l /usr/local/{bin,lib,etc}
/usr/local/bin/:
total 0
lrwxrwxrwx 1 root root   30 Aug 13 06:32 a2p -> /var/packages/Perl/target/usr/bin/a2p
lrwxrwxrwx 1 root root   31 Aug 13 06:32 perl -> /var/packages/Perl/target/usr/bin/perl

/usr/local/lib/:
total 0
lrwxrwxrwx 1 root root   28 Aug 13 06:32 perl5 -> /var/packages/Perl/target/lib/perl5

/usr/local/etc/:
total 0
```
