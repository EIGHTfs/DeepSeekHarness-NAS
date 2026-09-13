---
source: https://help.synology.com/developer-guide/synology_package/wizard/WIZARD_UIFILES_v2.html
title: WIZARD_UIFILES [7.2.2]
fetched: 2026-09-11
---

# WIZARD_UIFILES [7.2.2]

**install_uifile**, **upgrade_uifile**, and **uninstall_uifile** are files which describe UI components in JSON format. They are stored in the “**WIZARD_UIFILES**” folder. During the installation, upgrading, and un-installation processes, these UI components will appear in the wizard. Once these components are selected, their keys will be set in the script environment variables with true, false, or text values.

These files can be regarded as user settings or used to control the flow of script execution.

- **install_uifile**: Describes UI components for the installation process. During the process of the **preinst ** and **postinst** scripts, these component keys and values can be found in the environment variables.

- **upgrade_uifile**: Describes UI components for the upgrade process. During the process of the **preupgrade**, **postupgrade**, **preuninst**, **postuninst**, **preinst** and **postinst** scripts, these component keys and values can be found in the environment variables.

- **uninstall_uifile**: Describes UI components for the un-installation process. During the process of the **preuninst** and **postuninst** scripts, these component keys and values can be found in the environment variables.

If you would like to run a script to generate the wizard dynamically, you can add **install_uifile.sh**, **upgrade_uifile.sh** and **uninstall_uifile.sh** files, they are run before installing, upgrading, and uninstalling a package respectively to generate UI components in JSON format and write to **SYNOPKG_TEMP_LOGFILE**. Script environment variables in these scripts are available in these scripts. Please refer to "Script Environment Variables" for more information.

If you would like to localize the descriptions of UI components, you can add a language abbreviation suffix to the file “**install_uifile_[DSM language]**,”** “upgrade_uifile_[DSM language]**”, “**uninstall_uifile_[DSM language]**”, “**install_uifile_[DSM language]**.sh,”** “upgrade_uifile_[DSM language]**.sh” or “**uninstall_uifile_[DSM language]**.sh” in this folder. For example, in order to perform installation in Traditional Chinese, **[DSM language]** should be replaced with “**cht**” as follows: “**install_uifile_cht**”.

You can download our template package from https://github.com/SynologyOpenSource/ExamplePackages and place the `ExamplePackages/ExamplePackage` directory at `/toolkit/source/ExamplePackage`.

```
└── WIZARD_UIFILES
    ├── create_install_uifile.sh
    ├── create_uninstall_uifile.sh
    ├── create_upgrade_uifile.sh
    ├── Makefile
    ├── package.json
    ├── pnpm-lock.yaml
    ├── src
    │   ├── remove-entry.js
    │   ├── remove-setting.vue
    ├── uifile_setting.sh
    └── webpack.config.js
```

In DSM 7.2.2, we have introduced a new way to create wizard UI files. This new method involves using a render function to generate the wizard UI file. The render function is a Vue.js Framework structured function. Before starting, developers should be familiar with the basic concepts of the Vue.js Framework to create wizard UI files more efficiently.

## UI Framework related documents

In our DSM 7.2.2, the default Vue.js version is 2.7.14. This means that our wizard UI files are built based on Vue.js 2.7.14. Developers can refer to the official Vue2 documentation to learn about the basic concepts of Vue.js.

### Basic knowledge

- Vue2 Official Document

- Webpack

- NPM

- PNPM

> Note:

> 1. You can refer to the WIZARD_UIFILES folder in ExamplePackage to learn how to create wizard UI files.

Example of the file in JSON format:

```
[{
    "custom_render_fn": "/* render function */", // needed compiled by webpack
    "custom_render_name": "remove_setting" // render name
}]
```

## Package.json

- package.json

```
{
    "name": "WIZARD_UIFILES",
    "private": true,
    "version": "1.0.0",
    "description": "",
    "main": "webpack.config.js",
    "scripts": {
        "build": "webpack --mode production",
        "dev": "webpack --watch --progress --mode development"
    },
    "keywords": [],
    "author": "",
    "license": "ISC",
    "devDependencies": {
        "@babel/core": "7.18.6",
        "babel-loader": "8.0.6",
        "terser-webpack-plugin": "5.3.10",
        "vue": "2.7.14",
        "vue-loader": "15.10.1",
        "vue-template-compiler": "2.7.14",
        "webpack": "5.91.0",
        "webpack-cli": "5.1.4"
    }
}
```

- install the dependencies

```
pnpm install
```

## Webpack settings

```
const path = require('path');
const fs = require('fs');
const webpack = require('webpack');
const VueLoaderPlugin = require('vue-loader/lib/plugin');
const STRING_PATH = '/source/uistring/webstation';
const { getString } = require('/source/synopkgutils/string.js');

/**
 * Retrive the strings from the uistring folder, for example retrieve the wizard strings with following entries:
 ['wizard', 'remove_setting_title']
 ['wizard', 'remove_setting_desc']

 */
const stringsEntries = [
    ['wizard', 'remove_setting_title'],
    ['wizard', 'remove_setting_desc']
];

function resolve (dir) {
    return path.join(__dirname, dir)
}

async function traverseStringPath() {
    const texts = {};
    fs.readdirSync(STRING_PATH).forEach(dir => {
        const lang = path.basename(dir);
        const langStringFile = `${STRING_PATH}/${lang}/strings`;
        texts[lang] = {};
        for (const [section, key] of stringsEntries) {
            texts[lang][section] = texts[lang][section] ?? {};
            texts[lang][section][key] = getString(langStringFile, section, key);
        }
    });
    return texts;
}

module.exports = async (env, argv) => {
    const isDevelopment = argv.mode === 'development';
    return {
        mode: isDevelopment ? 'development' : 'production',
        devtool: isDevelopment ? 'inline-source-map' : false,
        module: {
            rules: [
                {
                    test: /\.vue$/,
                    loader: 'vue-loader'
                },
                {
                    exclude: /node_modules/,
                    test: /\.js$/,
                    use: {
                        loader: 'babel-loader',
                        options: {
                            rootMode: 'upward'
                        }
                    }
                },
            ]
        },
        resolve: {
            extensions: ['.js', '.vue', '.json'],
        },
        entry: {
            /* puts your package entry here */
            remove_entry: './src/remove-entry.js',
        },
        output: {
            library: {
                name: 'SYNO.SDS.PkgManApp.Custom.JsonpLoader.load',
                type: 'jsonp',
            },
            path: resolve('dist'),
            filename: '[name].bundle.js'
        },
        plugins: [
            new VueLoaderPlugin(),
            new webpack.DefinePlugin({
                __STRINGS__: JSON.stringify(await traverseStringPath())
            }),
        ],
        externalsType: 'window',
        externals: {
            'vue': 'Vue',
        },
        watchOptions: {
            poll: true,
        },
    };
}
```

## Start writing your own wizard layout

Before writing, you need to understand the basic concepts of Vue.js. To use the wizard layout, we must follow a few guidelines:

The entry file must return an object in the format `{ name: 'your_render_function_name', render: YourRenderFunction }`.

The Vue.js file must contain a pkg-center-step-content component.

Use the composite method to call the functions provided by the package center.

### Functions provided by the package center

`SYNO.SDS.PkgManApp.Custom.useHook.props` is used to obtain the props that will be provided by the package center.

`SYNO.SDS.PkgManApp.Custom.useHook(props)` is used to obtain the functions provided by the package center, which are as follows:

```
{
    getNext: () => String, // Get the ID of the next step
    checkState: () => void, // Update the wizard footer information based on the current information, e.g.: enable/disable the previous step button
}
```

In your Vue.js file, please use the setup function to obtain the functions provided by the package center and return the following variables:

```
{
    getNext,
    checkState,
    headline,
    getValues,
}
```

| Property | Description | Value |
|---|---|---|
| getNext | Get the ID of the next step | () => String |
| checkState | Update the wizard footer information based on the current information | () => void |
| headline | Display the wizard title | String |
| getValues | The package center will use this function to obtain the data set by the wizard | () => Object[] |

- remove-entry.js

```
import RemoveSetting from './remove-setting.vue';

export default {
    name: 'remove_setting', // your render function name
    render: RemoveSetting,
};
```

- remove-setting.vue

To create the corresponding form layout, you can refer to the following example. Since DSM provides a variety of globally registered Vue.js components, please refer to the DSM UI Framework for details on the available Vue.js components on DSM.

```
<template>
    <pkg-center-step-content>
        <v-form syno-id="form">
            <v-form-item syno-id="form-item" label="Password">
                <v-input type="password" v-model="password" syno-id="password" />
            </v-form-item>
            <v-form-item syno-id="form-item" label="Confirm Password">
                <v-input type="password" v-model="confirmPassword" syno-id="confirm-password" />
            </v-form-item>
            <v-form-item syno-id="form-item" :label="removeSettingTitle">
                <v-checkbox v-model="valid" syno-id="checkbox">
                    Checkbox Value: {{ valid }}
                </v-checkbox>
            </v-form-item>
        </v-form>
    </pkg-center-step-content>
</template>

<script>
import { $t } from './utils/uistring';
import { defineComponent, watchEffect, ref } from 'vue';
export default defineComponent({
    props: {
        ...SYNO.SDS.PkgManApp.Custom.useHook.props,
    },
    setup(props) {
        const { getNext, checkState: _checkState } = SYNO.SDS.PkgManApp.Custom.useHook(props);

        const valid = ref(false);
        const password = ref('');
        const confirmPassword = ref('');
        const removeSettingTitle = $t(_S('lang'), 'wizard', 'remove_setting_title');
        const headline = $t(_S('lang'), 'wizard', 'remove_setting_title');

        const checkState = (owner) => {
            owner = owner ?? props.getOwner();
            _checkState(owner);
            const nextButton = owner.getButton('next');
            nextButton.setDisabled(!valid.value);
        };

        const getValues = () => {
            return [{
                isSelected: valid.value,
            }];
        };

        watchEffect(() => {
            checkState();
        });

        return {
        /* package center needed */
            getNext,
            checkState,
            headline,
            getValues,
        /*  */
            valid,
            password,
            confirmPassword,
            removeSettingTitle,
        };
    },
});
</script>
```

## Related files

- uifile_setting.sh

```
#!/bin/bash

REMOVE_ENTRY_JS='./dist/remove_entry.bundle.js'
```

- create_uninstall_uifile.sh

```
#!/bin/bash

UISTRING_PATH=/source/uistring/webstation
PKG_UTILS="/source/synopkgutils/pkg_util.sh"

. $PKG_UTILS
. ./uifile_setting.sh

pkg_dump_wizard_content()
{
    local out=$1
    cat > "$out" <<EOF
[{
    "custom_render_fn": $(cat $REMOVE_ENTRY_JS | jq -R),
    "custom_render_name": "remove_setting"
}]
EOF
}

pkg_dump_uninst_wizard()
{
    if [ ! -d "$PKG_WIZARD_DIR" ]; then
        mkdir $PKG_WIZARD_DIR
    fi

    pkg_dump_wizard_content $PKG_WIZARD_DIR/uninstall_uifile
}

PKG_WIZARD_DIR="."
pkg_dump_uninst_wizard
```

- Makefile

```
include ../Makefile.inc

.PHONY: all install package clean

UIFILES = uninstall_uifile

all install:
    # Snpm is a tool to install npm modules in Synology
    /usr/local/tool/snpm i
    /usr/local/tool/snpm build

package: $(UIFILES)
    [ -d $(PACKAGEDIR)/WIZARD_UIFILES ] || install -d $(PACKAGEDIR)/WIZARD_UIFILES
    for i in $(UIFILES); do \
        install -c -m 644 $$i $(PACKAGEDIR)/WIZARD_UIFILES; \
    done

clean:
    @for i in $(UIFILES); do $(RM) $$i $${i}_*; done

%: create_%.sh
    ./$<
```

> Note:

> 1. All words are case sensitive.
