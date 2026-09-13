---
source: https://help.synology.com/developer-guide/integrate_dsm/web_authentication.html
title: Application Authentication
fetched: 2026-09-11
---

# Application Authentication

After integrating your application into Synology DSM, you may want to perform an authentication check to ensure only logged-in users can access the page.

You can run /usr/syno/synoman/webman/modules/authenticate.cgi to check the user login status. However the authenticate.cgi must be run with some environment variables (HTTP_COOKIE, REMOTE_ADDR, SERVER_ADDR, etc.). So execute the authenticate.cgi directly from the package custom CGI is recommended since the environment variables needed are set automatically.

## Sample Code *test.cgi*

The *authenticate.cgi* will output the user name if the user has logged in. There will be no output if the user has not been authenticated.

Here is the sample code for 3rd party CGI (Note. compile this with -std=c99)

```
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/**
 * Check whether user is logged in.
 *
 * If user has logged in, put the username into "user".
 *
 * @param user    The buffer for get username
 * @param bufsize The buffer size of user
 *
 * @return 0: User not logged in or error
 *         1: User logged in. The user name is written to given "user"
 */

int IsUserLogin(char *user, int bufsize)
{
    FILE *fp = NULL;
    char buf[1024];
    int login = 0;

    bzero(user, bufsize);

    fp = popen("/usr/syno/synoman/webman/modules/authenticate.cgi", "r");
    if (!fp) {
        return 0;
    }
    bzero(buf, sizeof(buf));
    fread(buf, 1024, 1, fp);

    if (strlen(buf) > 0) {
        snprintf(user, bufsize, "%s", buf);
        login = 1;
    }
    pclose(fp);

    return login;
}

int main(int argc, char **argv)
{
    char user[256];

    printf("Content-Type: text/html\r\n\r\n");
    if (IsUserLogin(user, sizeof(user)) == 1) {
        printf("User is authenticated. Name: %s\n", user);
    } else {
        printf("User is not authenticated.\n");
    }
    return 0;
}
```

## How to run the *test.cgi*

DSM requires cookie to validate the DSM login session.

### Login

Access the following cgi with your credential information, you will receive the session information in your cookie.

```
https://your-ip:5001/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=admin&passwd=your_admin_password&format=cookie
```

Note. If you're using the insecure http protocol, please alter the protocol and change the port number to 5000.

### Access *test.cgi* with cookie

Access *test.cgi* with cookie information.

```
https://your-ip:5001/path/to/test.cgi
```

If you are having trouble accessing your *test.cgi*, please try to access any other webapi with your cookie. This would help you to clearify if your cookie information is valid or not.

```
https://your-ip:5001/webapi/entry.cgi?api=SYNO.Core.System&version=3&method=info
```

### Logout

By accessing the following webapi, you will be logged out.

```
https://your-ip:5001/webapi/auth.cgi?api=SYNO.API.Auth&version=1&method=logout
```
