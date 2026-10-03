---
source: https://help.synology.com/developer-guide/compile_applications/download_dsm_tool_chain.html
title: Download DSM Tool Chain
fetched: 2026-09-11
---

# Download DSM Tool Chain

To download the DSM tool chain, please go to Synology Archive.

You would need to know what your target platform is to download the corresponding tool chain. Here is the platform list

If you are not sure about which tool chain you need, please execute the following command on your Synology NAS.

```
DiskStation> uname -a
Linux DiskStation 4.4.59+ #24922 SMP PREEMPT Mon Aug 19 12:13:37 CST 2019 x86_64 GNU/Linux synology_apollolake_718+
DiskStation>
```

The output "synology_apollolake_718+" tells you which tool chain is appropriate. For example, apollolake means you need the tool chain for "Intel x86 Linux 4.4.59 (Apollolake)" on the Synology Archive.

After you download the DSM tool chain, extract it to where you want it on your computer. For the following instructions we will extract to **/usr/local/** as an example. You can extract the tool chain by using the following command:

```
# tar xJf apollolake-gcc493_glibc220_linaro_x86_64-GPL.txz -C /usr/local/
```

Please make sure the tool chain is located in the directory **/usr/local** on your computer to ensure proper integration.
