---
source: https://help.synology.com/developer-guide/synology_package/show_massage.html
title: Show Messages to Users
fetched: 2026-09-11
---

# Show Messages to Users

## Show Message as Script Result

If you want to send a prompt users with **messages after they installed, upgraded, uninstalled, started, or stopped a package**, you can use the `$SYNOPKG_TEMP_LOGFILE` variable in related scripts. For example:

```
echo "Hello World!!" > $SYNOPKG_TEMP_LOGFILE
```

If you want to prompt users according to their language, you can use `$SYNOPKG_DSM_LANGUAGE` variable for language abbreviation as shown in the example below:

```
case $SYNOPKG_DSM_LANGUAGE in
        chs)
            echo "简体中文" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        cht)
            echo "繁體中文" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        csy)
            echo "Český" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        dan)
            echo "Dansk" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        enu)
            echo "English" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        fre)
            echo "Français" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        ger)
            echo "Deutsch" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        hun)
            echo "Magyar" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        ita)
            echo "Italiano" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        jpn)
            echo "日本語" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        krn)
            echo "한국어" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        nld)
            echo "Nederlands" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        nor)
            echo "Norsk" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        plk)
            echo "Polski" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        ptb)
            echo "Português do Brasil" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        ptg)
            echo "Português Europeu" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        rus)
            echo "Русский" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        spn)
            echo "Español" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        sve)
            echo "Svenska" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        trk)
            echo "Türkçe" > $SYNOPKG_TEMP_LOGFILE 
        ;;
        *)
            echo "English" > $SYNOPKG_TEMP_LOGFILE 
        ;;
    esac
```

> Please refer to "scripts" and "Script Environment Variables" sections for more information.

## Show Message as Desktop Notification

It is possible to use `/usr/syno/bin/synodsmnotify` executable to **send desktop notifications to users**. The notification title / message must be an I18N string.

```
/usr/syno/bin/synodsmnotify -c [app_id] [user_or_group] [i18n_string_for_title] [i18n_string_for_msg]
```

```
/usr/syno/bin/synodsmnotify -c com.company.App1 admin MyPackage:app_tree:index_title MyPackage:app_tree:node_1
```

```
/usr/syno/bin/synodsmnotify -c com.company.App1 @administrators MyPackage:app_tree:index_title MyPackage:app_tree:node_1
```

> Notification title and message here should be in the format of `[package_id]:[i18n_section]:[i18n_key]` where `package_id` is the `package` value in package `INFO` file. I18N string example can be found in I18N page. Remember to specify desktop notification strings to `preloadTexts` field in application config.
