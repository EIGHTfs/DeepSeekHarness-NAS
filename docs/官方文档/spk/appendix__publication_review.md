---
source: https://help.synology.com/developer-guide/appendix/publication_review.html
title: Package Review
fetched: 2026-09-11
---

# Package Review

We are excited that you are creating packages for the Synology DSM and want to help you understand our guidelines so you can be confident your package will get through the review process quickly.

| Review Item | Review Guideline |
|---|---|
| INFO: required field | Ensure required fields in INFO exists |
| INFO: deprecated field | Ensure deprecated fields in INFO does not exist (from DSM7.0) |
| Lower priviledge | The package should be run with non-privileged user (from DSM7.0) |
| Package installation | The package should be installed successfully |
| Package start | The package should be started successfully |
| Package stop | The package should be stopped successfully |
| Package upgrade | The package should be upgraded successfully |
| Package uninstall | The package should be uninstalled successfully |
| Offline installation | The package should be able to be installed offline |
| Network activity during installation | There should not be any abnormal connection during installation |
| Security advisor scan | The package should not cause any security advisor issue |
| Antivirus essential scan | The package should pass the virus scanning |
| Clean up/file leftover | Files belong to package should be removed after uninstallation |
| Clean up/process leftover | Process belong to package should be stopped after uninstallation |
| Port-config | Register port numbers used by services of package |
| Port conflict | Registered port should not conflict with other services |
| Error log | There should not be any error log left on system |
| Apparmor log | There should not be any deny log from apparmor |
| Coredump file | There should not be any coredump file left on system |
| Ad-hoc test | Check any other abnormal behavior |
