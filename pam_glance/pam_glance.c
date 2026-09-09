/*
 * pam_glance — Face authentication for sudo via the Glance Mac app.
 *
 * Asks the user-session Glance process (Unix socket) to match a face.
 * On ALLOW → PAM success. On DENY / UNAVAIL / error → PAM failure so the
 * next sufficient module (pam_tid) or password can run.
 *
 * Socket: /tmp/com.jonathan.glance.sudoauth.<uid>
 * Request: "AUTH <timeoutSeconds>\n"
 * Response: "ALLOW" | "DENY" | "UNAVAIL"
 */

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define PAM_SM_AUTH
#include <security/pam_modules.h>
#include <security/pam_appl.h>

#define SERVICE_NAME "com.jonathan.glance.sudoauth"
#define DEFAULT_TIMEOUT 8
#define MAX_TIMEOUT 20

static int connect_user_socket(uid_t uid) {
    char path[160];
    snprintf(path, sizeof(path), "/tmp/%s.%u", SERVICE_NAME, (unsigned)uid);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int read_full_line(int fd, char *buf, size_t buflen, int timeout_sec) {
    struct timeval tv;
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    size_t filled = 0;
    while (filled + 1 < buflen) {
        ssize_t n = read(fd, buf + filled, 1);
        if (n <= 0) {
            return -1;
        }
        if (buf[filled] == '\n') {
            buf[filled] = '\0';
            return 0;
        }
        filled++;
    }
    buf[buflen - 1] = '\0';
    return -1;
}

static int glance_authenticate(uid_t uid, unsigned timeout) {
    int fd = connect_user_socket(uid);
    if (fd < 0) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    char req[32];
    snprintf(req, sizeof(req), "AUTH %u\n", timeout);
    if (write(fd, req, strlen(req)) < 0) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    /* Wait a little longer than the face scan so ALLOW can still arrive. */
    char resp[32];
    if (read_full_line(fd, resp, sizeof(resp), (int)timeout + 3) < 0) {
        close(fd);
        return PAM_AUTH_ERR;
    }
    close(fd);

    if (strcmp(resp, "ALLOW") == 0) {
        return PAM_SUCCESS;
    }
    if (strcmp(resp, "UNAVAIL") == 0) {
        return PAM_AUTHINFO_UNAVAIL;
    }
    return PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                   int argc, const char **argv) {
    (void)flags;

    unsigned timeout = DEFAULT_TIMEOUT;
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            unsigned v = (unsigned)atoi(argv[i] + 8);
            if (v >= 1 && v <= MAX_TIMEOUT) {
                timeout = v;
            }
        }
    }

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    struct passwd *pw = getpwnam(user);
    if (pw == NULL) {
        return PAM_AUTHINFO_UNAVAIL;
    }

    int rc = glance_authenticate(pw->pw_uid, timeout);
    /* sufficient modules treat any non-success as "try next". */
    return rc;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                              int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
