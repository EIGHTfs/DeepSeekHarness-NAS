---
source: https://developer.fnnas.com/api/authorization/path-convert/
title: 路径转换
fetched: 2026-09-11
---

# 路径转换

提示

应用页面不要直接展示 `/vol1/...` 这类内部路径。调用 `trim.file.convertPath` 可以把内部路径转换成用户更容易理解的展示路径。

例如，传入内部路径：

```
/vol1/1000/photo
```

可以得到：

```
存储空间1/admin 的文件/photo
```

## API 清单​

前端 JS SDK 和后端 API 的通用请求方式见 调用方式。

````````

| 接口 | 类型 | Scope | 系统版本要求 | App 版本要求 |
|---|---|---|---|---|
| trim.file.convertPath | 后端 API | trim.file.path | 1.2.0401 | 1.34.0 |

## API 方法​

```
trim.file.convertPath
```

## 请求​

```
{
  "reqId": "string",
  "req": "trim.file.convertPath",
  "appName": "string",
  "data": {
    "path": [
      "/vol1/1000/photo",
      "/vol1/1000/demo.pdf"
    ],
    "language": "zh-CN"
  }
}
```

请求字段：

````````

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| path | string/string[] | 是 | 要转换的原始路径。可以传单个路径，也可以传路径数组 |
| language | string | 是 | 展示语言，例如 zh-CN、en-US |

注意

`language` 必须传入。应用应按当前界面语言传值，避免用户看到不一致的路径展示文案。

## 成功响应​

```
{
  "reqId": "string",
  "code": 0,
  "msg": "",
  "data": {
    "status": 0,
    "result": [
      {
        "path": "/vol1/1000/photo",
        "semanticPath": "存储空间1/admin 的文件/photo"
      },
      {
        "path": "/vol1/1000/demo.pdf",
        "semanticPath": "存储空间1/admin 的文件/demo.pdf"
      }
    ]
  }
}
```

响应字段：

``````````

| 字段 | 类型 | 说明 |
|---|---|---|
| status | number | 转换状态，0 表示成功 |
| result | object[] | 转换结果列表 |
| result[].path | string | 原始路径 |
| result[].semanticPath | string | 转换后的语义化路径 |

## 本页要点​

- 页面展示路径时，不建议直接显示 `/vol1/...` 内部路径。

- `trim.file.convertPath` 用于把内部路径转换成用户能理解的语义化路径。

- `path` 支持单个路径或路径数组。

- `language` 必须传入，用于决定返回路径的展示语言。
