---
source: https://help.synology.com/developer-guide/compile_applications/manual.html
title: Compile Applications
fetched: 2026-09-11
---

# Compile Applications

The Synology NAS employs embedded SoC or x86-based CPUs, implementing several platforms -- such as ARM and x86 -- on a variety of Synology NAS models. In order to run 3rd-party applications on the Synology NAS, it is necessary to compile applications into an executable format for the corresponding platform.

This information will help you determine which DSM tool chain (please refer to the “Download DSM Tool Chain” section) to download for each model.

Please refer to What kind of CPU does my NAS have for a complete model list.

To compile an application for the Synology NAS, a compiler that runs on Linux PC is required in order to generate an executable file for the Synology NAS. This compiling procedure is called *cross-compiling*, and the set of compiling tools (compiler, linker, etc) used to compile the application is called a *tool chain.*
