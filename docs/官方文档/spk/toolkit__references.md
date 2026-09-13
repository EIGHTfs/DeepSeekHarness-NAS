---
source: https://help.synology.com/developer-guide/toolkit/references.html
title: References
fetched: 2026-09-11
---

# References

This section illustrates advanced types of usage for the Package Toolkit.

## PkgCreate.py Command Option List

The following table lists some of the PkgCreate.py commands.

``

********

| Option Name | Option Purpose |
|---|---|
| (default) | Run build stage only which include link and compile source code. It's the same as -U option. |
| -p | Specify the platform you want to pack your project. |
| -x | Build dependent project level. Each project is built according to their own SynoBuildConf/build (e.g., -x0, -x1) |
| -c | Run both build stage and pack stage which include link source code, compile source code, pack package and sign the final spk. |
| -U | Run build stage only which includes link and compile source code. |
| -l | Run build stage only, but will only link your source code. |
| -L | Run build stage only, but will compile your source code only. |
| -I | Run pack stage only, which will pack and sign your spk. |
| --no-sign | Tells PkgCreat.py not to sign your spk file. for example, PkgCreat.py -I --no-sign ${project} |
| -z | Run all platforms concurrently. |
| -J | Compile your project with -J make command options. |
| -S | Disable silent make. |

The following table shows the relationship between command options in different stages.
You can choose the proper options based on your needs. Option `-c` is enough for most cases.

| Stage | Action | (default) | -l | -L | -U | -I --no-sign | -I | -c |
|---|---|---|---|---|---|---|---|---|
| Build Stage | Link Source code | Yes | Yes | No | Yes | No | No | Yes |
| Build Stage | Compile Source code | Yes | No | Yes | Yes | No | No | Yes |
| Pack Stage | Pack Package | No | No | No | No | Yes | Yes | Yes |
| Pack Stage | Sign Package | No | No | No | No | No | Yes | Yes |

## Platform-Specific Dependency

Platform-specific dependency means you can have several dependent projects for different platforms by appending "**:${platform}**" to the following sections: **BuildDependent** and **ReferenceOnly**. The following example shows 816x and aramda370 projects that are on libbar-1.0.

```
# SynoBuildConf/depends

[BuildDependent]
libfoo-1.0

[BuildDependent:816x,armada370]  
libfoo-1.0
libbar-1.0

[default]
all="7.0"
```

## Collect the SPK File in Your Own Way

By default, **PkgCreate.py** will move the SPK file to **/toolkit/result_spk** according to **/toolkit/build_env/ds.${platform}-${version}/source/${project}/INFO.** You can have your own collect operation by adding a hook, **SynoBuildConf/collect**. **SynoBuildConf/collect** can be any executable shell script (so remember to chmod +x) and **PkgCreate.py** will pass the following environment variables to it:

- **SPK_SRC_DIR**: Source folder of target SPK file.

- **SPK_DST_DIR**: Default destination folder to put SPK file.

- **SPK_VERSION**: Version of package (according to INFO).

The current working directory of **SynoBuildConf/collect** is **/source/${project}** will be under chroot environment.
