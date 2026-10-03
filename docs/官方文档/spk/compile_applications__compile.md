---
source: https://help.synology.com/developer-guide/compile_applications/compile.html
title: Compile
fetched: 2026-09-11
---

# Compile

You can start compiling an application called examplePkg.c”, for example, that looks like this:

```
#include <sys/sysinfo.h>

int main()
{
    struct sysinfo info;
    int ret;
    ret = sysinfo(&info);
    if (ret != 0) {
        printf("Failed to get system information.\n");
        return -1;
    }
    printf("Total RAM: %u\n", info.totalram);
    printf("Free RAM: %u\n", info.freeram);
    return 0;
}
```

To compile the application, run the following command:

```
/usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linux-gnueabigcc examplePkg.c –o sysinfo
```

You can also write a Makefile for it:

```
EXEC= sysinfo
OBJS= sysinfo.o

CC= /usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linuxgnueabi-gcc
LD= /usr/local/arm-marvell-linux-gnueabi/bin/arm-marvell-linuxgnueabi-ld
CFLAGS += -I/usr/local/arm-marvell-linux-gnueabi/arm-marvell-linuxgnueabi/libc/include
LDFLAGS += -L/usr/local/arm-marvell-linux-gnueabi/arm-marvell-linuxgnueabi/libc/lib

all: $(EXEC)

$(EXEC): $(OBJS)
    $(CC) $(CFLAGS) $(OBJS) -o $@ $(LDFLAGS)

clean:
    rm -rf *.o $(PROG) *.core
```
