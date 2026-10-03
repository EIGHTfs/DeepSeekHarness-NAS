---
source: https://developer.fnnas.com/docs/quick-started/test-application/
title: 测试应用
fetched: 2026-09-11
---

# 测试应用

将 `.fpk` 包安装到飞牛 fnOS 测试设备，并验证桌面入口。

---

## 1. 安装应用包​

### 通过应用中心安装​

适用于本地验证。

打开应用中心，进入手动安装入口，并选择 `HelloFnos.fpk`。

手动安装仅用于本地测试，不应作为公开分发方式。

### 使用 appcenter-cli 安装​

适用于脚本化安装或 CI 流程。

在飞牛 fnOS 设备上运行：

```
appcenter-cli install-fpk HelloFnos.fpk
```

包含安装向导的应用包可指定环境变量文件：

```
appcenter-cli install-fpk HelloFnos.fpk --env config.env
```

## 2. 打开应用​

从飞牛 fnOS 桌面打开 **Hello fnOS**。

页面应显示：

```
Hello fnOS 应用正在运行。
```

如果入口无法打开，检查：

- `app/ui/config`：入口 URL 应为 `/cgi/ThirdParty/HelloFnos/index.cgi/`

- `app/ui/index.cgi`：`BASE_PATH` 应指向 `/var/apps/HelloFnos/target/www`

- `app/www/index.html`：目标页面应存在于应用包中

## 3. 开发中重复测试​

修改应用包后：

1. 运行 `fnpack build`

2. 安装新的 `.fpk` 文件

3. 再次打开桌面入口

包含后台服务的应用，还需要检查进程状态、端口和运行日志。可继续阅读 应用架构、Native 应用案例 或 Docker 应用案例。

## 下一步​

继续阅读 发布应用。
