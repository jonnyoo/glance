#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <libproc.h>
#include <pwd.h>
#include <unistd.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SOCKET_SUFFIX "/Library/Application Support/glance-sudo/glance-sudo.sock"
#define TRUSTED_EXECUTABLE "/Applications/Glance.app/Contents/MacOS/glance"

static int trusted_peer(int fd, uid_t expected_uid) {
    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(fd, &peer_uid, &peer_gid) != 0 || peer_uid != expected_uid)
        return 0;

    pid_t pid = 0;
    socklen_t pid_len = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pid_len) != 0 || pid <= 0)
        return 0;

    char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, executable, sizeof(executable)) <= 0 ||
        strcmp(executable, TRUSTED_EXECUTABLE) != 0)
        return 0;

    struct stat st;
    if (stat(TRUSTED_EXECUTABLE, &st) != 0 || st.st_uid != 0 ||
        !S_ISREG(st.st_mode) || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0)
        return 0;
    return 1;
}

static int calling_user(pam_handle_t *pamh, const char **name, uid_t *uid) {
    const void *item = NULL;
    if (pam_get_item(pamh, PAM_RUSER, &item) == PAM_SUCCESS && item && ((const char *)item)[0]) {
        *name = (const char *)item;
    } else if (pam_get_user(pamh, name, NULL) != PAM_SUCCESS || !*name) {
        return 0;
    }
    struct passwd *pw = getpwnam(*name);
    if (!pw || pw->pw_uid == 0 || !pw->pw_dir) return 0;
    *uid = pw->pw_uid;
    return 1;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                   int argc, const char **argv) {
    (void)flags; (void)argc; (void)argv;
    const char *user = NULL;
    uid_t uid = 0;
    if (!calling_user(pamh, &user, &uid)) return PAM_AUTHINFO_UNAVAIL;

    /* Never offer camera authentication to remote sessions. */
    const void *rhost = NULL;
    if (pam_get_item(pamh, PAM_RHOST, &rhost) == PAM_SUCCESS && rhost && ((const char *)rhost)[0])
        return PAM_AUTHINFO_UNAVAIL;

    struct passwd *pw = getpwnam(user);
    char socket_path[PATH_MAX];
    if (!pw || snprintf(socket_path, sizeof(socket_path), "%s%s", pw->pw_dir, SOCKET_SUFFIX) >= (int)sizeof(socket_path))
        return PAM_AUTHINFO_UNAVAIL;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return PAM_AUTHINFO_UNAVAIL;
    struct timeval timeout = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || !trusted_peer(fd, uid)) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    unsigned char random_bytes[32];
    char nonce[65];
    arc4random_buf(random_bytes, sizeof(random_bytes));
    for (size_t i = 0; i < sizeof(random_bytes); i++) snprintf(nonce + i * 2, 3, "%02x", random_bytes[i]);

    char request[80];
    snprintf(request, sizeof(request), "AUTH %s\n", nonce);
    if (write(fd, request, strlen(request)) != (ssize_t)strlen(request)) {
        close(fd);
        return PAM_AUTHINFO_UNAVAIL;
    }

    char response[96] = {0};
    ssize_t count = read(fd, response, sizeof(response) - 1);
    close(fd);
    if (count <= 0) return PAM_AUTHINFO_UNAVAIL;

    char expected[80];
    snprintf(expected, sizeof(expected), "OK %s\n", nonce);
    return strcmp(response, expected) == 0 ? PAM_SUCCESS : PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                              int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
