# Synology Package Developer Guide（官方文档存档）

> 本目录由 `scripts/fetch-official-docs.py` 自动抓取，**请勿手工编辑**。
> 重新抓取：`python3 scripts/fetch-official-docs.py`

- 来源站点：https://help.synology.com/developer-guide
- 抓取时间：2026-09-11 01:46:18
- 成功页面：80

## 页面索引

| 原文路径 | 本地文件 | 标题 |
|----------|----------|------|
| `appendix/platarchs.html` | `appendix__platarchs.md` | Appendix A: Platform and Arch Value Mapping Table |
| `appendix/publication_review.html` | `appendix__publication_review.md` | Package Review |
| `appendix/ui_framework/application.html` | `appendix__ui_framework__application.md` | Appliation |
| `appendix/ui_framework/button.html` | `appendix__ui_framework__button.md` | Button |
| `appendix/ui_framework/checkbox.html` | `appendix__ui_framework__checkbox.md` | Checkbox |
| `appendix/ui_framework/form.html` | `appendix__ui_framework__form.md` | Form |
| `appendix/ui_framework/input.html` | `appendix__ui_framework__input.md` | Input |
| `appendix/ui_framework/radio.html` | `appendix__ui_framework__radio.md` | Radio |
| `appendix/ui_framework/rich_text.html` | `appendix__ui_framework__rich_text.md` | Rich Text |
| `appendix/ui_framework/select.html` | `appendix__ui_framework__select.md` | Select Input API |
| `appendix/ui_framework/ui_framework.html` | `appendix__ui_framework__ui_framework.md` | Components List |
| `breaking_changes.html` | `breaking_changes.md` | Breaking Changes in 7.0 |
| `compile_applications/compile.html` | `compile_applications__compile.md` | Compile |
| `compile_applications/compile_open_source_projects.html` | `compile_applications__compile_open_source_projects.md` | Compile Open Source Projects |
| `compile_applications/download_dsm_tool_chain.html` | `compile_applications__download_dsm_tool_chain.md` | Download DSM Tool Chain |
| `compile_applications/manual.html` | `compile_applications__manual.md` | Compile Applications |
| `examples/compile_docker_package.html` | `examples__compile_docker_package.md` | Compile Docker Package - Gitlab |
| `examples/compile_nmap.html` | `examples__compile_nmap.md` | Compile Open Source Project: nmap |
| `examples/compile_tmux.html` | `examples__compile_tmux.md` | Compile Open Source Project |
| `examples/compile_web_package.html` | `examples__compile_web_package.md` | Compile Web Package - WordPress |
| `examples/examples.html` | `examples__examples.md` | Package Examples |
| `getting_started/first_package.html` | `getting_started__first_package.md` | Your First Package |
| `getting_started/gettingstarted.html` | `getting_started__gettingstarted.md` | Getting Started |
| `getting_started/prepare_environment.html` | `getting_started__prepare_environment.md` | Prepare Environment |
| `getting_started/system_requirement.html` | `getting_started__system_requirement.md` | System Requirements |
| `integrate_dsm/config.html` | `integrate_dsm__config.md` | Application Config |
| `integrate_dsm/desktopapp.html` | `integrate_dsm__desktopapp.md` | Desktop Application |
| `integrate_dsm/dsm_help.html` | `integrate_dsm__dsm_help.md` | Application Help |
| `integrate_dsm/fhs.html` | `integrate_dsm__fhs.md` | Package Filesystem Hierarchy Standard |
| `integrate_dsm/i18n.html` | `integrate_dsm__i18n.md` | Application Internationalization |
| `integrate_dsm/integration.html` | `integrate_dsm__integration.md` | Synology DSM Integration |
| `integrate_dsm/ports.html` | `integrate_dsm__ports.md` | Port |
| `integrate_dsm/resource_monitor.html` | `integrate_dsm__resource_monitor.md` | Monitor |
| `integrate_dsm/web_authentication.html` | `integrate_dsm__web_authentication.md` | Application Authentication |
| `privilege/preface.html` | `privilege__preface.md` | Privilege |
| `privilege/privilege_config.html` | `privilege__privilege_config.md` | Privilege Config |
| `publish_package/get_start.html` | `publish_package__get_start.md` | Get Started with Publishing |
| `publish_package/publish.html` | `publish_package__publish.md` | Publish Synology Packages |
| `publish_package/repond_to_user_issue.html` | `publish_package__repond_to_user_issue.md` | Responding to User Issues |
| `publish_package/summit_package_for_approval.html` | `publish_package__summit_package_for_approval.md` | Submitting the Package for Approval |
| `release_notes.html` | `release_notes.md` | Synology Package Framework 7.2 |
| `resource_acquisition/apache22.html` | `resource_acquisition__apache22.md` | Apache 2.2 Config |
| `resource_acquisition/available_workers.html` | `resource_acquisition__available_workers.md` | Available Workers |
| `resource_acquisition/config_update.html` | `resource_acquisition__config_update.md` | Resource Update |
| `resource_acquisition/data_share.html` | `resource_acquisition__data_share.md` | Data Share |
| `resource_acquisition/docker-project.html` | `resource_acquisition__docker-project.md` | Docker Project Worker |
| `resource_acquisition/docker.html` | `resource_acquisition__docker.md` | Docker (since DSM7.0) |
| `resource_acquisition/index_db.html` | `resource_acquisition__index_db.md` | Index DB |
| `resource_acquisition/maria_db_10.html` | `resource_acquisition__maria_db_10.md` | Maria DB 10 |
| `resource_acquisition/php_ini.html` | `resource_acquisition__php_ini.md` | PHP INI |
| `resource_acquisition/port_config.html` | `resource_acquisition__port_config.md` | Port Config |
| `resource_acquisition/resource_specification.html` | `resource_acquisition__resource_specification.md` | Resource Config |
| `resource_acquisition/resources.html` | `resource_acquisition__resources.md` | Resource |
| `resource_acquisition/syslog_config.html` | `resource_acquisition__syslog_config.md` | Syslog Config |
| `resource_acquisition/sysnotify.html` | `resource_acquisition__sysnotify.md` | System Nofitication |
| `resource_acquisition/systemd_user_unit.html` | `resource_acquisition__systemd_user_unit.md` | Systemd User Unit |
| `resource_acquisition/timing.html` | `resource_acquisition__timing.md` | Resource Timing |
| `resource_acquisition/usrlocal_linker.html` | `resource_acquisition__usrlocal_linker.md` | /usr/local linker |
| `resource_acquisition/web_config.html` | `resource_acquisition__web_config.md` | Web Config (since DSM7.2) |
| `resource_acquisition/web_service.html` | `resource_acquisition__web_service.md` | Web Service (since DSM7.0) |
| `synology_package/INFO.html` | `synology_package__INFO.md` | INFO |
| `synology_package/INFO_necessary_fields.html` | `synology_package__INFO_necessary_fields.md` | Field Name: package |
| `synology_package/INFO_optional_fields.html` | `synology_package__INFO_optional_fields.md` | Field Name: displayname |
| `synology_package/conf.html` | `synology_package__conf.md` | conf |
| `synology_package/introduction.html` | `synology_package__introduction.md` | Package Introduction |
| `synology_package/license.html` | `synology_package__license.md` | License |
| `synology_package/package_tgz/launch_app.html` | `synology_package__package_tgz__launch_app.md` | Launch an App |
| `synology_package/package_tgz/package_tgz.html` | `synology_package__package_tgz__package_tgz.md` | package.tgz |
| `synology_package/pkgconx.html` | `synology_package__pkgconx.md` | PKG_CONX |
| `synology_package/pkgdeps.html` | `synology_package__pkgdeps.md` | PKG_DEPS |
| `synology_package/script_env_var.html` | `synology_package__script_env_var.md` | Script Environment Variables |
| `synology_package/scripts.html` | `synology_package__scripts.md` | scripts |
| `synology_package/show_massage.html` | `synology_package__show_massage.md` | Show Messages to Users |
| `synology_package/wizard/WIZARD_UIFILES_v2.html` | `synology_package__wizard__WIZARD_UIFILES_v2.md` | WIZARD_UIFILES [7.2.2] |
| `synology_package/wizard/intro.html` | `synology_package__wizard__intro.md` | Wizard UI Files |
| `toolkit/build_stage.html` | `toolkit__build_stage.md` | Build Stage: |
| `toolkit/pack_stage.html` | `toolkit__pack_stage.md` | Pack Stage: |
| `toolkit/references.html` | `toolkit__references.md` | References |
| `toolkit/sign_package.html` | `toolkit__sign_package.md` | Sign Package (only for DSM6.X) |
| `toolkit/toolkit.html` | `toolkit__toolkit.md` | Synology Toolkit |
