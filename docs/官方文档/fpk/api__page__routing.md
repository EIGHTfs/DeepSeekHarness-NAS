---
source: https://developer.fnnas.com/api/page/routing/
title: 页面路由
fetched: 2026-09-11
---

# 页面路由

应用可以通过 JS SDK 打开宿主系统页面或外部地址，例如打开文件、查看文件详情、进入文件管理器、打开应用设置页或跳转 URL。

注意

打开文件、文件管理器或文件详情前，应用应确保目标路径来自授权范围，并按需要检查当前用户权限。页面路由只负责打开页面，不会替应用完成文件授权或权限判断。

## API 清单​

这些方法都在前端调用。JS SDK 的通用使用方式见 调用方式。

``````````````````````````````

| 接口 | 类型 | Scope | 系统版本要求 | App 版本要求 |
|---|---|---|---|---|
| openFile | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| showFileDetails | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| openFileManager | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| openAppSetting | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |
| openURL | 前端 JS SDK | 无 | 1.2.0401 | 1.34.0 |

## 打开文件​

调用 `openFile` 可以让宿主系统打开指定文件，具体打开方式与文件管理中的一致。

方法：

```
openFile(path: string): Promise<void | null>
```

示例：

```
await sdk.openFile('/vol1/1000/demo.pdf');
```

## 查看文件详情​

调用 `showFileDetails` 可以打开文件详情页。用户可以在详情页查看文件元数据，也可以查看或调整权限。

方法：

```
showFileDetails(paths: string[], options?: object): Promise<void | null>
```

示例：

```
await sdk.showFileDetails(['/vol1/1000/photos/1.jpg']);
```

## 打开文件管理器​

调用 `openFileManager` 可以打开文件管理器，并定位到指定路径。

方法：

```
openFileManager(path: string): Promise<void | null>
```

示例：

```
await sdk.openFileManager('/vol1/1000');
```

## 打开应用设置页​

调用 `openAppSetting` 可以打开当前应用的设置页。

方法：

```
openAppSetting(): Promise<void | null>
```

示例：

```
await sdk.openAppSetting();
```

## 打开 URL​

调用 `openURL` 可以打开外部地址。在 Web 宿主中，它遵循浏览器 `window.open` 的行为；在移动 WebView 宿主中，它会使用系统浏览器打开 URL。

备注

`openURL` 在不同宿主中的表现可能不同。需要保持返回路径或刷新状态时，应用应自行设计回到原页面后的处理逻辑。

方法：

```
openURL(url: string, target?: string, features?: string): Promise<void | null>
```

示例：

```
await sdk.openURL('https://example.com', '_blank');
```

## 本页要点​

- 页面路由能力都在前端 JS SDK 中调用。

- 打开文件、文件管理器或文件详情前，应用应确保目标路径来自授权范围，并按需要检查当前用户权限。

- `showFileDetails` 可用于查看文件元数据，也可进入权限调整入口。

- `openURL` 在不同宿主中的表现可能不同，Web 宿主遵循 `window.open`，移动 WebView 宿主通常会打开系统浏览器。
