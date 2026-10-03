---
source: https://help.synology.com/developer-guide/synology_package/package_tgz/launch_app.html
title: Launch an App
fetched: 2026-09-11
---

# Launch an App

This section introduces how to launch an app by packaging the minimal files needed for the UI inside the package.tgz.

```
 package.tgz
   ├── ui                       (specified by dsmuidir in INFO)
   |   ├── config               (the UI config file describing components in JavaScript file and their dependencies)
   |   ├── ExamplePackage.js    (the main JavaScript file of the package)
   |   └── style.css            (the style of the package)
   └── ....
```

To prepare the files (UI config, main JavaScript file) in package.tgz, organize your application source code in the `ui` folder in your package project. You can also use other names, but remember to match it with the `dsmuidir` specified in the `INFO` file during installation.

The project structure of the application ui might look like this:

```
ExamplePackage
└── ui
    ├── app.config
    ├── config.define
    ├── Makefile
    ├── package.json
    ├── pnpm-lock.yaml
    ├── src
    │   ├── App.vue
    │   │── components
    │   │   └── CustomForm.vue
    │   ├── main.js
    │   └── styles
    └── webpack.config.js
```

Here is the detailed information about the files mentioned above:

First, to generate the `config` file in package.tgz, prepare `app.config`, `config.defind`, and the `Makefile`

**app.config**

`app.config` describes the components in the package.

Format:

```
{
    "[Classname]": {
        "[Attribute]": "[Value]",
        ...
    }
}
```

Example:

```
{
    "SYNO.SDS.App.ExamplePackage.Instance": {
        "type": "app",
        "title": "ExamplePackage",
        "appWindow": "SYNO.SDS.App.ExamplePackage.Instance",
        "allUsers": true,
        "allowMultiInstance": false,
        "hidden": false,
        "icon": "images/icon.png"
    }
}
```

Attribute details:

| Attribute | Description | Value |
|---|---|---|
| type | specifies the type of this class | String |
| title | the title of package application | String |
| appWindow | specifies the classname of the AppWindow when opening this application | String |
| allUsers | set all users can use this app | Boolean |
| allowMultiInstance | application can be launched more then one instance | Boolean |
| hidden | set true to hide the package in the StartMenu | Boolean |
| icon | application icon | String |

**config.define**

`config.define` defines the deployed JavaScript file name which is installed in package.tgz. The `JSfiles` should include all the JavaScript files you want to deploy, typically the output of a bundling tool (e.g. webpack).

Example:

```
{
    "ExamplePackage.js":{
        "JSfiles": [
            "dist/example-package.bundle.js"
        ],
        "params": "-s -c skip"
    }
}
```

**Makefile**

This `Makefile` is used to manage the build process of package application.

```
include /env.mak
include ../Makefile.inc

JS_DIR="dist"                                 # the directory where your JavaScript files are stored
JS_NAMESPACE="SYNO.SDS.App.ExamplePackage"    # the class name prefix in your project, which should match the namespace defined in main.js
BUNDLE_JS="dist/example-package.bundle.js"
BUNDLE_CSS="dist/style/example-package.bundle.css"

.PHONY: all $(SUBDIR)

all: $(BUNDLE_JS) style.css $(SUBDIR)

$(BUNDLE_JS):
    # Snpm is a tool to install npm modules in Synology
    /usr/local/tool/snpm install
    /usr/local/tool/snpm run build
    $(MAKE) -f Makefile.js.inc JSCompress JS_NAMESPACE=\"${JS_NAMESPACE}\" JS_DIR=${JS_DIR}

$(SUBDIR):
    @echo "===>" $@
    $(MAKE) -C $@ INSTALLDIR=$(INSTALLDIR)/$@ DESTDIR=$(DESTDIR) PREFIX=$(PREFIX) $(MAKECMDGOALS);
    @echo "<===" $@

style.css: $(BUNDLE_JS)
    cp $(BUNDLE_CSS) $@

clean: clean_JSCompress $(SUBDIR)
    rm $(BUNDLE_JS)

install: $(SUBDIR) install_JSCompress
    [ -d $(INSTALLDIR)/dist/assets ] || install -d $(INSTALLDIR)/dist/assets
    install --mode 644 dist/assets/*.png $(INSTALLDIR)/dist/assets

include Makefile.js.inc
```

**package.json**

Also, you need a `package.json` for configure and describe the dependencies for your application.

```
{
    "name": "ExamplePackage",
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

**main.js**

The file serves as the entry point for your bundle tool and initializes of your Vue application by setting up the necessary components and configurations.

```
import Vue from 'vue';
import App from './App.vue';

SYNO.namespace('SYNO.SDS.App.ExamplePackage');

// @require SYNO.SDS.App.ExamplePackage.ModalWindow
SYNO.SDS.App.ExamplePackage.Instance = Vue.extend({
    components: { App },
    template: '<App/>',
});
```

**App.vue**

Your app instance is defined here, allowing you to write Vue components to render your application, for more detail about UI framework please refer to DSM UI Framework.

```
<template>
    <v-app-instance class-name="SYNO.SDS.App.ExamplePackage.Instance">
        <v-app-window width=850 height=574 ref="appWindow" :resizable="false" syno-id="SYNO.SDS.App.ExamplePackage.Window">
            <div class="example-package-app">
                Hello Synology Package
            </div>
        </v-app-window>
    </v-app-instance>
</template>

<script>
export default {
    data() {
        return {
        };
    },
    methods: {
        close() {
            this.$refs.appWindow.close();
        },
    },
}
</script>
<style lang="scss">
.example-package-app {
    height: 100%;
}
</style>
```

**webpack.config.js**

```
const path = require('path');
const webpack = require('webpack');
const VueLoaderPlugin = require('vue-loader/lib/plugin');

module.exports = async (env, argv) => {
    const isDevelopment = argv.mode === 'development';
    return {
        mode: isDevelopment ? 'development' : 'production',
        devtool: isDevelopment ? 'inline-cheap-module-source-map' : false,
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
        /* your package entry with Vue.extend and SYNO.namespace defined */
        entry: './src/main.js',
        output: {
            /* Need to write in config.define */
            filename: 'example-package.js',
            path: path.resolve('dist')
        },
        resolve: {
            extensions: ['.js', '.vue', '.json']
        },
        plugins: [
            new VueLoaderPlugin()
        ],
        externals: {
            'vue': 'Vue'
        },
        watchOptions: {
            poll: true
        }
    };
};
```
