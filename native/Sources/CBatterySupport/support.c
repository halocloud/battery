#include "CBatterySupport.h"
#include <membership.h>
#include <uuid/uuid.h>
#include <sys/sysctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <IOKit/IOMessage.h>

unsigned int bc_can_sleep(void) { return kIOMessageCanSystemSleep; }
unsigned int bc_will_sleep(void) { return kIOMessageSystemWillSleep; }
unsigned int bc_has_woken(void) { return kIOMessageSystemHasPoweredOn; }

int bc_is_admin(uid_t uid) {
    if (uid == 0) return 1;
    uuid_t user, admin;
    int member = 0;
    if (mbr_uid_to_uuid(uid, user) || mbr_gid_to_uuid(80, admin)) return 0;
    return mbr_check_membership(user, admin, &member) == 0 && member != 0;
}
int bc_machine_model(char *buffer, size_t size) {
    return sysctlbyname("hw.model", buffer, &size, NULL, 0);
}
int bc_os_build(char *buffer, size_t size) {
    return sysctlbyname("kern.osversion", buffer, &size, NULL, 0);
}
int bc_lock_service(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 ||
        (st.st_mode & 077) || flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd);
        return -1;
    }
    return fd; // Held open for the daemon's entire lifetime.
}
