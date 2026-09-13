---
source: https://help.synology.com/developer-guide/integrate_dsm/i18n.html
title: Application Internationalization
fetched: 2026-09-11
---

# Application Internationalization

The desktop application can have i18n text referenced by config, help, etc.

```
ui (specified by dsmuidir in INFO)
└── texts
   ├── enu
   │    └── strings
   └── cht
        └── strings
```

You have to create directories according to supported languages then create a file named `strings` inside each language directory.

- [dsmuidir]/texts/enu/strings

```
  [app_tree]
  index_title="This is a title"
  node_1="This is node1"
  [app_tab]
  tab1="This is tab1"
  tab2="This is tab2"
```

- [dsmuidir]/texts/cht/strings

```
  [app_tree]
  index_title="這是標題"
  node_1="這是節點1"
  [app_tab]
  tab1="這是標籤1"
  tab2="這是標籤2"
```

When you want to use these texts, just reference them in `section:key` format (one value can only be one i18n string)

```
"title": "app_tree:node_1"
```

> I18N strings are loaded only when application opened on desktop after DSM 7.0. If the strings are used as desktop notifications, those strings should be specified in `preloadTexts` of application config.
