---
source: https://developer.fnnas.com/api/authorization/file-acl/
title: 文件权限检查
fetched: 2026-09-11
---

# 文件权限检查

注意

应用拿到授权目录或文件后，不要直接把内容提供给所有用户。授权会让应用用户具备访问目标路径的 ACL 权限；返回文件列表、预览内容或执行写入操作前，还需要用当前使用用户的 `uid` 检查目标路径权限。

## API 清单​

前端 JS SDK 和后端 API 的通用请求方式见 调用方式。

````````

| 接口 | 类型 | Scope | 系统版本要求 | App 版本要求 |
|---|---|---|---|---|
| trim.file.checkUserACL | 后端 API | trim.file.userAcl | 1.2.0401 | 1.34.0 |

## 使用步骤​

1. 先通过 应用共享授权路径 或 用户个人授权路径 获取应用可访问的目录。

2. 后端准备返回内容前，调用 `trim.file.checkUserACL` 检查当前用户对目标路径的权限。

3. 只返回 `readable: true` 的内容；涉及写入或删除时，再检查 `writable` 或 `deletable`。

## API 方法​

```
trim.file.checkUserACL
```

## 请求​

```
{
  "reqId": "string",
  "req": "trim.file.checkUserACL",
  "appName": "string",
  "data": {
    "uid": 1000,
    "path": "/vol1/1000/data/test.txt"
  }
}
```

需要一次检查多个路径时，`path` 可以传数组：

```
{
  "reqId": "string",
  "req": "trim.file.checkUserACL",
  "appName": "string",
  "data": {
    "uid": 1000,
    "path": [
      "/vol1/1000/data/test.txt",
      "/vol1/1000/data/demo"
    ]
  }
}
```

请求字段：

````

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| uid | number | 是 | 要检查权限的用户 UID |
| path | string/string[] | 是 | 要检查的文件或目录路径，不能为空 |

## 成功响应​

```
{
  "reqId": "string",
  "code": 0,
  "msg": "",
  "data": [
    {
      "path": "/vol1/1000/data/test.txt",
      "readable": true,
      "writable": false,
      "deletable": false
    }
  ]
}
```

响应字段：

````````

| 字段 | 类型 | 说明 |
|---|---|---|
| path | string | 被检查路径 |
| readable | boolean | 当前用户是否可读 |
| writable | boolean | 当前用户是否可写 |
| deletable | boolean | 当前用户是否可删除 |

备注

如果路径不存在，或应用无权读取路径状态，该路径会返回默认权限结果：`readable`、`writable`、`deletable` 均为 `false`。

## 本页要点​

- 文件权限检查用于判断当前使用用户是否能访问某个路径，不用于授权应用。

- 返回文件列表、预览、写入或删除前，建议按当前用户 `uid` 检查权限。

- `path` 可以传单个路径，也可以传路径数组。

- 路径不存在或应用无权读取路径状态时，会返回 `readable/writable/deletable` 均为 `false`。
