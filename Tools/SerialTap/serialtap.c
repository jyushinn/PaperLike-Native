#define _DARWIN_C_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <unistd.h>

static ssize_t (*real_read)(int, void *, size_t);
static ssize_t (*real_write)(int, const void *, size_t);
static int log_fd = -1;
static os_unfair_lock log_lock = OS_UNFAIR_LOCK_INIT;

static int is_serial_fd(int fd) {
    char path[MAXPATHLEN];
    return fcntl(fd, F_GETPATH, path) == 0 &&
           strstr(path, "/dev/cu.usbserial-") != NULL;
}

static void initialize(void) {
    if (!real_read) {
        real_read = dlsym(RTLD_NEXT, "read");
    }
    if (!real_write) {
        real_write = dlsym(RTLD_NEXT, "write");
    }
    if (log_fd < 0) {
        const char *path = getenv("PAPERLIKE_CAPTURE_PATH");
        if (path) {
            log_fd = open(path, O_CREAT | O_APPEND | O_WRONLY, 0600);
        }
    }
}

static void log_bytes(char direction, const unsigned char *bytes, size_t count) {
    if (log_fd < 0 || count == 0) {
        return;
    }

    char line[8192];
    int used = snprintf(line, sizeof(line), "%c\t%zu\t", direction, count);
    for (size_t index = 0;
         index < count && used + 3 < (int)sizeof(line);
         index++) {
        used += snprintf(line + used, sizeof(line) - (size_t)used,
                         "%02X", bytes[index]);
    }
    if (used + 1 < (int)sizeof(line)) {
        line[used++] = '\n';
    }

    os_unfair_lock_lock(&log_lock);
    real_write(log_fd, line, (size_t)used);
    os_unfair_lock_unlock(&log_lock);
}

ssize_t write(int fd, const void *buffer, size_t count) {
    initialize();
    ssize_t result = real_write(fd, buffer, count);
    if (fd != log_fd && result > 0 && is_serial_fd(fd)) {
        log_bytes('W', buffer, (size_t)result);
    }
    return result;
}

ssize_t read(int fd, void *buffer, size_t count) {
    initialize();
    ssize_t result = real_read(fd, buffer, count);
    if (fd != log_fd && result > 0 && is_serial_fd(fd)) {
        log_bytes('R', buffer, (size_t)result);
    }
    return result;
}
