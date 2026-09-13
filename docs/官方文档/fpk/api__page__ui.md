---
source: https://developer.fnnas.com/api/page/ui/
title: 页面交互
fetched: 2026-09-11
---

# 页面交互

应用可以通过 JS SDK 更新页面标题、设置离开提示、关闭当前页面，也可以让页面跟随宿主语言、主题变化。

页面初始化时读取语言、主题和系统版本，见 平台配置。`$on` 监听主题或语言变化时，只支持 Web 宿主环境，不支持移动端 App 内嵌页面，也不支持独立浏览器页面。

注意

`$on` 只支持 Web 宿主环境，也就是 `sdk.isWeb === true` 且 `sdk.isStandaloneWeb === false`。移动端 App 内嵌页面和独立浏览器页面不要展示依赖 `$on` 的调试入口或功能入口。

## API 清单​

这些方法都在前端调用。JS SDK 的通用使用方式见 调用方式。

``````````````````````````````

| 接口 | 类型 | Scope | 系统版本要求 | App 版本要求 |
|---|---|---|---|---|
| setTitle | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| $on('os/theme') | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| $on('os/language') | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| setExitPageTips | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| close | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |

## 设置页面标题​

应用需要根据当前页面内容更新窗口标题时，可以调用 `setTitle`。

方法：

```
setTitle(title: string): Promise<void | null>
```

示例：

```
await sdk.setTitle('任务详情');
```

## 监听主题变化​

如果应用需要在用户切换浅色模式或暗黑模式后立即更新界面，可以监听 `os/theme`。

页面初始化时，先通过 getPlatformConfig 获取当前主题；如果当前页面运行在 Web 宿主环境中，再监听后续主题变化。

`$on` 只支持 Web 宿主环境。移动端 App 内嵌页面和独立浏览器页面不支持该事件监听。

方法：

```
$on(event: 'os/theme', callback: (theme: 'dark' | 'light') => void): Promise<void>
```

完整示例：

```
const config = await sdk.getPlatformConfig();

applyTheme(config.theme);

if (sdk.isWeb === true && sdk.isStandaloneWeb === false) {
  await sdk.$on('os/theme', (theme) => {
    applyTheme(theme);
  });
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
}
```

## 监听界面语言变化​

如果应用需要在用户切换界面语言后立即更新文案，可以监听 `os/language`。

页面初始化时，先通过 getPlatformConfig 获取当前界面语言；如果当前页面运行在 Web 宿主环境中，再监听后续语言变化。

`$on` 只支持 Web 宿主环境。移动端 App 内嵌页面和独立浏览器页面不支持该事件监听。

方法：

```
$on(event: 'os/language', callback: (language: string) => void): Promise<void>
```

完整示例：

```
const config = await sdk.getPlatformConfig();

applyLanguage(config.language);

if (sdk.isWeb === true && sdk.isStandaloneWeb === false) {
  await sdk.$on('os/language', (language) => {
    applyLanguage(language);
  });
}

function applyLanguage(language) {
  document.documentElement.lang = language;
}
```

## 关闭当前应用页面​

调用 `close` 可以关闭当前应用页面。

方法：

```
close(): Promise<void | null>
```

示例：

```
await sdk.close();
```

## 设置离开页面提示​

当页面存在未保存内容时，可以调用 `setExitPageTips` 设置离开确认提示。保存完成后，再调用不带参数的 `setExitPageTips()` 清除提示。

方法：

```
setExitPageTips(params?: { title?: string; content?: string }): Promise<void | null>
```

设置离开提示：

```
await sdk.setExitPageTips({
  title: 'Leave this page?',
  content: 'Unsaved changes may be lost.',
});
```

清除离开提示：

```
await sdk.setExitPageTips();
```

## 本页要点​

- 页面交互能力都在前端 JS SDK 中调用。

- 初始化时读取当前语言、主题和系统版本，见 平台配置。

- `$on('os/theme')` 和 `$on('os/language')` 只支持 Web 宿主环境。

- 有未保存内容时用 `setExitPageTips` 设置离开提示，保存后调用不带参数的 `setExitPageTips()` 清除提示。

- `close` 关闭的是当前应用页面。
