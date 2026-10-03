---
source: https://help.synology.com/developer-guide/resource_acquisition/docker.html
title: Docker (since DSM7.0)
fetched: 2026-09-11
---

# Docker (since DSM7.0)

### Description

Docker worker is made for docker package to help them easily deploy their containers without calling docker command by themselves. Docker worker use docker-compose framework, it will generate docker-compose.yaml according to user's docker worker configuration and create containers during installation.

When in install/remove package stage, worker will create/remove docker-compose.yaml, volume on host directory, images and containers.

When in start/stop package stage, worker will start/stop containers by calling docker-compose start/stop.

**FROM_POSTINST_TO_PREUNINST**

- `Acquire()`: Create docker-compose.yaml and prepare host volume for container to mount. Worker will also create containers in this stage.

- `Release()`: Remove docker-compose.yaml, host volume, containers and images. Note that worker will not remove host volume during upgrade docker package.

**FROM_STARTUP_TO_HALT**

- `Acquire()`: Start containers.

- `Release()`: Stop containers.

### Provider

Docker

### Timing

`FROM_POSTINST_TO_PREUNINST`
`FROM_STARTUP_TO_HALT`

### Environment Variables

None

### Updatable

No

### Syntax

```
"docker":{
    "services": [{
        service setting 1
    },{
        service setting 2
    }...],
}
```

``

| Key | Since | Type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| services | 18.09.0-1018 | Array | true | false | N/A | List of docker services information to create docker-compose.yaml |

### services

`services` specify service configurations such as service name, image name and tag, container name, volume ... etc. Docker worker will create docker-compose.yaml according to given service configurations.

``

``

``

| Key | Since | type | Required | Nullable | Default Value | Description |
|---|---|---|---|---|---|---|
| service | 18.09.0-1018 | string | true | false | N/A | Service name. |
| image | 18.09.0-1018 | string | true | false | N/A | Image name. |
| tag | 18.09.0-1018 | string | true | false | N/A | Image tag. |
| build | 18.09.0-1018 | string | true | false | N/A | Relative path to Dockerfile directory that package carries. More detail will be elaborated in build section. |
| container_name | 18.09.0-1018 | string | false | true | N/A | Container name. |
| shares | 18.09.0-1018 | array of objects | false | true | N/A | Container mount volume specifications especially for persistant data perpose. More detail will be elaborated in volumes section. |
| volumes | 18.09.0-1018 | array of objects | false | true | N/A | Container mount volume specifications especially for mounting config file perpose. More detail will be elaborated in volumes section. |
| ports | 18.09.0-1018 | array of objects | false | true | N/A | Container ports specification. |
| environment | 18.09.0-1018 | array of objects | false | false | N/A | Container environment variables specification. |
| depends | 18.09.0-1018 | array of objects | false | false | N/A | Specify dependent service. |

#### build

`build` attribute is for building image with given Dockerfile path. The path will be relative path based on package target path (/var/packages/PKG_NAME/target/).

- Syntax:

```
{
  "build": "[Dockerfile directory]"
}
```

Transform to docker-compose.yaml:

```
build: /var/packages/PKG_NAME/target/[Dockerfile directory]
```

- Example:
Let odoo_docker directory containers Dockerfile and is under "/var/packages/Odoo/target/"

```
{
  "build": "odoo_docker"
}
```

Transform to docker-compose.yaml:

```
build: /var/packages/Odoo/target/odoo_docker
```

#### volumes

Volumes contains two categories - `shares` and `volumes` which are for different purposes. Although those two categories will all be transform into docker-compose's "volumes" section, we seperate them for different usage. That is, `shares` attribute is for persistant data volumes while `volumes` is for configuration files or any other configurations relative files.

**shares**:
The `shares` attribute is for containers to persistant data. User only need to fill in the a directory name in `shares` and the worker will first create directory under docker share directory for user and, then, genterate `SOURCE:TARGET` pair under `volumes` section in docker-compose.yaml.

- Syntax:

```
{
  "shares": [{
      "host_dir": "[host directory]",
      "mount_point": "[mount point]"
  }, ... {
      ...
  }]
}
```

Transform to docker-compose.yaml:

```
volumes:
  - /volumeX/docker/PKG_NAME/[host directory]:[mount point]
```

- Example:

```
{
  "shares": [{
      "host_dir": "odoo_data",
      "mount_point": "/var/lib/odoo"
  }]
}
```

Transform to docker-compose.yaml:

```
volumes:
  - /volume1/docker/Odoo/odoo_data:/var/lib/odoo
```

**volumes**:
The `volumes` attribute is similar to `shares` attribute but is design for configuration files or directory that user would like to mount into contianer. User can specify relative path of host configuration file or directory based on package target path (/var/packages/PKG_NAME/target/) and the worker will genterate `SOURCE:TARGET` pair under `volumes` section in docker-compose.yaml.

- Syntax:

```
{
  "volumes": [{
      "host_dir": "[host config or directory]",
      "mount_point": "[mount point]"
  }, ... {
      ...
  }]
}
```

Transform to docker-compose.yaml:

```
volumes:
  - /var/packages/PKG_NAME/target/[host config or directory]:[mount point]
```

- Example:

```
{
  "volumes": [{
      "host_dir": "odoo_docker/config",
      "mount_point": "/etc/odoo"
  }]
}
```

Transform to docker-compose.yaml:

```
volumes:
  - /var/packages/Odoo/target/odoo_docker:/etc/odoo
```

#### ports

`ports` attribute is for creating ports binding for container.

-

Restriction:
Host port needs to be at between 1025 to 65535.

-

Syntax:

```
{
  "ports": [{
      "host_port": "[port on host]",
      "container_port": "[port in container]",
      "protocol": "[tcp or udp]"
  }, ... {
      ...
  }]
}
```

Transform to docker-compose.yaml:

```
ports:
  - "[port on host]:[port in container]/[tcp or udp]"
```

- Example:

```
{
  "ports": [{
      "host_port": "30076",
      "container_port": "80",
      "protocol": "tcp"
  }, {
      "host_port": "30078",
      "container_port": "443",
      "protocol": "tcp"
 }]
}
```

Transform to docker-compose.yaml:

```
ports:
  - "30076:80/tcp"
  - "30078:443/tcp"
```

#### environment

`environment` attribute is for creating environment variables and values for containers.

- Syntax:

```
{
  "environment": [{
      "env_var": "[variable name]",
      "env_value": "[value]"
  }, ... {
      ...
  }]
}
```

Transform to docker-compose.yaml:

```
environment:
  - "[variable name]:[value]"
```

- Example:

```
{
  "environment": [{
      "env_var": "HOST",
      "env_value": "odoo_db"
  }, {
      "env_var": "USER",
      "env_value": "odoo"
  }, {
      "env_var": "PASSWORD",
      "env_value": "odoo"
  }]
}
```

Transform to docker-compose.yaml:

```
environment:
  - HOST=odoo_db
  - USER=odoo
  - PASSWORD=odoo
```

#### depends

`depends` attribute is for specifying dependent services, in the same way as docker-comopose.

- Syntax:

```
{
  "depends": [{
      "dep_service": "[service name]"
  }, ... {
      ...
  }]
}
```

Transform to docker-compose.yaml:

```
depends_on:
  - [service name]
```

- Example:

```
{
  "depends": [{
      "dep_service": "odoo_db"
  }]
}
```

Transform to docker-compose.yaml:

```
depends_on:
  - odoo_db
```

#### docker-compose generation example

conf/resource:

```
{
    "docker": {
        "services": [{
            "service": "odoo",
            "build": "odoo_docker",
            "image": "odoo",
            "container_name": "Odoo",
            "tag": "12.0",
            "environment": [{
                "env_var": "HOST",
                "env_value": "odoo_db"
            }, {
                "env_var": "USER",
                "env_value": "odoo"
            }, {
                "env_var": "PASSWORD",
                "env_value": "odoo"
            }],
            "shares": [{
                "host_dir": "odoo_data",
                "mount_point": "/var/lib/odoo"
            }],
            "ports": [{
                "host_port": "{{wizard_http_port}}",
                "container_port": "8069",
                "protocol": "tcp"
            }],
            "depends": [{
                "dep_service": "odoo_db"
            }]
        }, {
            "service": "odoo_db",
            "image": "postgres",
            "tag": "10",
            "container_name": "Odoo_db",
            "shares": [{
                "host_dir": "db",
                "mount_point": "/var/lib/postgresql/data/pgdata"
            }],
            "environment": [{
                "env_var": "POSTGRES_DB",
                "env_value": "postgres"
            }, {
                "env_var": "POSTGRES_PASSWORD",
                "env_value": "odoo"
            }, {
                "env_var": "POSTGRES_USER",
                "env_value": "odoo"
            }, {
                "env_var": "PGDATA",
                "env_value": "/var/lib/postgresql/data/pgdata"
            }]
        }]
    }
}
```

Transform to docker-compose.yaml:

```
version: '3'
services:
  odoo:
    build: /var/packages/Docker_Odoo_SynoCommunity/target/odoo_docker
    image: odoo:12.0
    container_name: Odoo
    environment:
      - HOST=odoo_db
      - USER=odoo
      - PASSWORD=odoo
    volumes:
      - /volume1/docker/Docker_Odoo_SynoCommunity//odoo_data:/var/lib/odoo
    ports:
      - "30076:8069/tcp"
    depends_on:
      - odoo_db
    networks:
      - Docker_Odoo_SynoCommunity
  odoo_db:
    image: postgres:10
    container_name: Odoo_db
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_PASSWORD=odoo
      - POSTGRES_USER=odoo
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - /volume1/docker/Docker_Odoo_SynoCommunity//db:/var/lib/postgresql/data/pgdata
    networks:
      - Docker_Odoo_SynoCommunity
networks:
  Docker_Odoo_SynoCommunity:
    driver: bridge
```
