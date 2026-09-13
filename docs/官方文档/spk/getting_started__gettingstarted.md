---
source: https://help.synology.com/developer-guide/getting_started/gettingstarted.html
title: Getting Started
fetched: 2026-09-11
---

# Getting Started

Getting started to learn how to easily build packages just the way you like!

## What can packages do ?

- access DSM API

- access owned data share folder

- integrate desktop application

- integrate help documents

- integrate firewall rules

- integrate resource monitor

- define lifecycle behaviour

- define relationship between packages

- define identity privilege

## How to develop packages ?

To develop packages, you first need to know the entire working flow:

1.

Prepare a NAS

You can choose one at our official site and buy it from local synology partner. It is recommended to take one from the Plus Series.

2.

Prepare environments for local development

Since our NAS is not always in `x86` or `x86_64` architecture, we should prepare corresponding environment to our NAS (for cross compiling if you are developing in C/C++). We provide tons of tools for creating different development environments of our NAS in an easy way.

3.

Decide what you want to make

If you want to develop an application in `Node.js`, you can make your package depend on our official `Node.js` package. If you want to develop in `PHP`, you can still make your package depend on `PHP` package. We have already provided `Node.js`, `PHP`, `Perl`, `Python`, `Java` packages for langugage run time on DSM.

You can make great packages by leveraging our Package Framework to have stable, controllable and power saving properties. We provide complete toolkit for cross compiling and packing so you can also develop in an easy way.

4.

Decide whether to publish packages onto official Synology Package Center

## Begin to develop packages

In later topics, we will take a closer look at development. You can find articles such as

- System Requirement

- Prepare Environment

- Your First Package
