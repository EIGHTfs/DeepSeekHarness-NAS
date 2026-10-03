---
source: https://help.synology.com/developer-guide/resource_acquisition/sysnotify.html
title: System Nofitication
fetched: 2026-09-11
---

# System Nofitication

#### Description

merge / unmerge package notification strings on package start / stop

- `Acquire()`: Merge package notification strings then rebuild string index

- `Release()`: Unmerge package notification strings then rebuild string index

#### Provider

DSM

#### Timing

`FROM_STARTUP_TO_HALT`

#### Environment Variables

None

#### Updatable

No

#### Syntax

```
"sysnotify": {
  "texts_dir": "<related_path_from_target_to_your_app_config_texts_dir>",
  "app_privileges": [
    {
      "app_id": "<app id in app config>",
      "categories": ["<notification category in your notification string>"]
    }
  ]
}
```

``

``

``

``

| Member | Since | Description |
|---|---|---|
| texts_dir | 6.0.1 | the relative path of text dir |
| app_privileges | 7.0-40343 | relationship between category and app id |
| app_id | 7.0-40343 | app id |
| categories | 7.0-40343 | category |

#### Examples

Example-1: apply the specified app privilege config to all categories of notifications

```
"sysnotify": {
  "texts_dir": "ui/texts",
  "app_privileges": [{
    "app_id": "com.company.App1"
  }]
}
```

Example-2: apply the specified app privilege config to some categories of notifications

```
"sysnotify": {
  "texts_dir": "ui/texts",
  "app_privileges": [{
    "app_id": "com.company.App1",
    "categories": ["Admin Area"]
  }]
}
```

Example-3: do not apply any privilege config to some categories of notifications

```
"sysnotify": {
  "texts_dir": "ui/texts",
  "app_privileges": [{
    "categories": ["Guest Area"]
  }]
}
```

#### Notification String Format

- Category: (Required) the category in control panel > notification > rules > categories

- Level: (Required) one of the value in NOTIFICATION_ERROR / NOTIFICATION_WARN / NOTIFICATION_INFO

- Title: (Optional) the event name in control panel > notification > rules > event

- Desktop: (Required) the content of the notification

Example: System Notification

```
Category: Performance Alarm
Level: NOTIFICATION_ERROR
Title: System CPU utilization exceeds the threshold
Desktop: System CPU utilization exceeds the threshold.

The system CPU utilization has reached %VALUE%%, which exceeds the pre-defined value of %THRESHOLD%%.

From %HOSTNAME%
```

Example: Only For Desktop Notification

```
Category: File Station
Level: NOTIFICATION_INFO
Desktop: Copied %FILE% successfully.
```

#### Notification Level

- NOTIFICATION_ERROR: desktop / mail / sms / mobile / cms

- NOTIFICATION_WARN: desktop / mail / mobile / cms

- NOTIFICATION_INFO: desktop / cms

#### Notifcation Target

the mail string can specify the notification target, it has higher priority than category

```
Category: Performance Alarm
Level: NOTIFICATION_WARN
Desktop: there is a performance alram
Target: desktop,mail,sms,mobile,cms

The system has detected a performance issue
```

#### Notification Variable

variables can only be used in `Desktop`

| Variable | Example Value |
|---|---|
| %COMPANY_NAME% | Synology DiskStation |
| %HOSTNAME% | Synology DiskStation |
| %IP_ADDR% | 192.168.1.2 |
| %HTTP_URL% | http://192.168.1.2:5000 |
| %DATE% | 2022-1-1 |
| %TIME% | 09:00 |
| %OSNAME% | DSM |

#### Notification Send Approach

-

usage

```
/usr/syno/bin/synonotify <mail_string_key> <mail_string_custom_variables>
/usr/syno/bin/synodsmnotify <user/group> <mail_string_key> <mail_string_custom_variables>
```

-

example

```
/usr/syno/bin/synonotify CpuFanResume '{"%FANID%": 1,"DESKTOP_NOTIFY_TITLE": "mainmenu:leaf_packagemanage", "DESKTOP_NOTIFY_CLASSNAME": "SYNO.SDS.App.FileStation3.Instance"}'
```
