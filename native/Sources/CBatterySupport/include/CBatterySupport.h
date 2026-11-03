#pragma once
#include <stddef.h>
#include <sys/types.h>
int bc_is_admin(uid_t uid);
int bc_machine_model(char *buffer, size_t size);
int bc_os_build(char *buffer, size_t size);
int bc_lock_service(const char *path);
unsigned int bc_can_sleep(void);
unsigned int bc_will_sleep(void);
unsigned int bc_has_woken(void);
