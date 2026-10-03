---
source: https://help.synology.com/developer-guide/integrate_dsm/config.html
title: Application Config
fetched: 2026-09-11
---

# Application Config

To integrate desktop applications into DSM, you have to provide a `config` file in JSON format under the directory specified by `dsmuidir` in `INFO`.

```
{
    ".url": {
        "com.company.App1": {
            "type": "url",
            "icon": "images/app_{0}.png",
            "title": "Test App1",
            "desc": "Description",
            "url": "http://www.yahoo.com",
            "allUsers": true,
            "preloadTexts": [
                "app_tree:index_title",
                "app_tree:node_1"
            ]
        },
        "com.company.App2": {
            "type": "url",
            "icon": "images/app2_{0}.png",
            "title": "Test App2",
            "desc": "Description 2",
            "url": "http://www.synology.com",
            "allUsers": true
        }
    }
}
```

****

********

****
****
****
``
``
``
``
``
``
``
****

****

****

``
****

| Property | Required | Description |
|---|---|---|
| com.company.App1 com.company.App2 | O | In “.url”, each object should have a unique property name. |
| type | O | When you click the menu item, the address you use to connect to the DSM management UI will be shown in the right frame of the management UI. However, you can customize the address as you wish. The “type” value can be "url". "url" means when you click the application icon, the URL will be opened in a pop-up window. You can follow the descriptions below to set up your customized URL. |
| icon | O | “icon” indicates the icon for the application. It is a template string. The “{0}” can be replaced by “16”, “24”, “32”, “48”, “64”, “72”, “256” depending on the resolution of the icon. The icon must be saved under /usr/syno/synoman/webman/3rdparty/xxx/ where xxx is the directory name of your package. For example, if you create a directory named "images" and put the icon image file “icon.png” in it, the full path for the icon would be: /usr/syno/synoman/webman/3rdparty/xxx/images/icon_16.png /usr/syno/synoman/webman/3rdparty/xxx/images/icon_24.png /usr/syno/synoman/webman/3rdparty/xxx/images/icon_32.png /usr/syno/synoman/webman/3rdparty/xxx/images/icon_48.png /usr/syno/synoman/webman/3rdparty/xxx/images/icon_64.png /usr/syno/synoman/webman/3rdparty/xxx/images/icon_72.png /usr/syno/synoman/webman/3rdparty/xxx/images/icon_256.png The icon value should also be set as "images/icon_{0}.png" |
| title | O | “title” represents the application name that will be displayed in the main menu. |
| desc | X | “desc” displays more details about this application upon mouse-over. |
| url | O | The following is an example of value setting for your URL of the application: “url”: http://www.synology.com/ “url”: “3rdparty/xxx/index.html” |
| allUsers | X | This key determines whether or not the menu items can be seen by users when they log in with an admin account. If you would like to have all users see the menu items, please set the key value as below: "allUsers": true The default setting is that only the admin can find the application. |
| preloadTexts | X | The specified i18n section:key strings will be loaded even when application ui is not opened. This is necessary when corresponding strings are used to send desktop notifications. |

> Text fields support i18n value.
