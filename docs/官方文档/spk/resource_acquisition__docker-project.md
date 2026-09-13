---
source: https://help.synology.com/developer-guide/resource_acquisition/docker-project.html
title: Docker Project Worker
fetched: 2026-09-11
---

# Docker Project Worker

### Description

**Docker Project Woker** is provided by ContainerManager power by docker-compose, a tool for running multi-container applications on Docker defined using the Compose file format.

It's more flexible to **Docker Worker** which only provides limited configuration, and available to define multiple projects.

When the package install/uninstall stage, the worker will use the compose file inside to create (or update) the project according to the provided path, and build it. And start or stop projects on package start or stop stage.

### Provider

ContainerManager>=1432 (since DSM7.2.1)

### Timing

`FROM_POSTINST_TO_PREUNINST`

- `Acquire()`: According to the configuration provided, create (or update) and build these.

- `Release()`: Delete projects

`FROM_STARTUP_TO_HALT`

- `Acquire()`: Start projects.

- `Release()`: Stop projects.

### Environment Variables

None

### Updatable

No

### Syntax

```
{
    // ...
    "docker-project": {
        "preload-image": "image.tar.gz",
        "projects": [{
            "name": "django-project",
            "path": "django"
        }, {
            "name": "wordpress-project",
            "path": "wordpress-mysql"
        }]
    }
}
```

| Key | Type | Required | Description |
|---|---|---|---|
| preload-image | String | false | Load image tar ball |
| projects | Array | true | List of docker projects |

#### projects

`projects` specify name, and path of directory of compose.yml

``
``

``
``

``
``

| Key | Type | Required | Description |
|---|---|---|---|
| name | string | true | project name |
| path | string | true | directory of compose.yaml, relative path from target |
| build_params | object | false | build project params, describe below. |

#### `build_params`

these attributes are helpful when performing upgrades.

``
``

``
``

``
``

| Key | Type | Default | Description |
|---|---|---|---|
| force_pull | boolean | false | force pull image |
| force_recreate | boolean | true | force recreate contianers |
| build | boolean | true | force build Dockerfile |

### Example

- Example: `compose.yml`:

```
services:
  db:
    # We use a mariadb image which supports both amd64 & arm64 architecture
    image: mariadb:10.6.4-focal
    # If you really want to use MySQL, uncomment the following line
    #image: mysql:8.0.27
    command: '--default-authentication-plugin=mysql_native_password'
    volumes:
      - db_data:/var/lib/mysql
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=somewordpress
      - MYSQL_DATABASE=wordpress
      - MYSQL_USER=wordpress
      - MYSQL_PASSWORD=wordpress
    expose:
      - 3306
      - 33060
  wordpress:
    image: wordpress:latest
    ports:
      - 9527:80
    restart: always
    environment:
      - WORDPRESS_DB_HOST=db
      - WORDPRESS_DB_USER=wordpress
      - WORDPRESS_DB_PASSWORD=wordpress
      - WORDPRESS_DB_NAME=wordpress
volumes:
  db_data:
```

- Example: target structor

```
target
├── image.tar.gz
├── django
│   ├── app
│   │   ├── Dockerfile
│   │   ├── example
│   │   │   ├── __init__.py
│   │   │   ├── settings.py
│   │   │   ├── urls.py
│   │   │   └── wsgi.py
│   │   ├── manage.py
│   │   └── requirements.txt
│   ├── compose.yaml
│   └── README.md
└── wordpress-mysql
    └── compose.yml
```
