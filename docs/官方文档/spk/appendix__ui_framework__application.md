---
source: https://help.synology.com/developer-guide/appendix/ui_framework/application.html
title: Appliation
fetched: 2026-09-11
---

## Appliation

> **DSM-Only** components

---

## Usage

```
<template>
    <v-app-instance syno-id="app-instance" class-name="SYNO.SDS.XX.YY.Instance">
        <v-app-window
            syno-id="app-window"
            ref="appWindow"
            class="app-window-class"
            width=850
            height=574
            :resizable="false"
        >
            ...
        </v-app-window>
    </v-app-instance>
</template>
```
