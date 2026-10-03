---
source: https://help.synology.com/developer-guide/integrate_dsm/dsm_help.html
title: Application Help
fetched: 2026-09-11
---

# Application Help

To integrate help documents into DSM Help, please follow these steps:

1> Provide a `helptoc.conf` describing your help document structure and put it under the directory specified by `dsmuidir` in `INFO`.

```
{
    "app": "SYNO.App.TestAppInstance",
    "title": "app_tree:index_title",
    "content": "testapp_index.html",
    "toc": [
        {
            "title": "app_tree:node_1",
            "content": "testapp_node1.html",
            "nodes": [
                {
                    "title": "app_tree:node_1_child",
                    "content": "testapp_node1_child.html"
                }
            ]
        }, {
            "title": "app_tree:node_2",
            "content": "testapp_node2.html"
        }
    ]
}
```

Details of `helptoc.conf` are stated below:

| Property | Description |
|---|---|
| app | the application instance. |
| title | the text being displayed. |
| content | the path to your help document. |
| toc | the child nodes of root. (use empty array if your application doesn't have one) |
| nodes | the child nodes of toc node. |

> Text fields support i18n value.

2> Create directories and files according to your `helptoc.conf`.

```
ui (specified by dsmuidir in INFO)
├── helptoc.conf
├── help
│   ├── enu
│   │    └── testapp_index.html
│   └── cht
│        └── testapp_index.html
└── texts
    ├── enu
    │    └── strings
    └── cht
         └── strings
```

3> Write each help document in the following `HTML` format so that the UI style can be consistent with others.

```
<!DOCTYPE html>
<html class="img-no-display">
    <head>
        <meta charset="UTF-8" />
        <meta http-equiv="X-UA-Compatible" content="IE=edge,chrome=1">
        <link href="../../../../help/help.css" rel="stylesheet" type="text/css">
        <link href="../../../../help/scrollbar/flexcroll.css" rel="stylesheet" type="text/css">
        <script type="text/javascript" src="../../../../help/scrollbar/flexcroll.js"></script>
        <script type="text/javascript" src="../../../../help/scrollbar/initFlexcroll.js"></script>
    </head>
    <body>
        This is my help document content
    </body>
</html>
```
