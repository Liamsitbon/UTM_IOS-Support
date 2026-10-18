#ifndef UTM_MOBILE_GUEST_H
#define UTM_MOBILE_GUEST_H
#include "qemu-ios-ui.h"
/* An engine stays loaded for the process lifetime; QEMU cannot be reinitialized. */
const char *utm_ltm_load(const char *path, bool require_interpreter);
const QemuIosDeviceInfo *utm_ltm_machine(int index);
int utm_ltm_run(int argc, char **argv);
bool utm_ltm_ready(void);
bool utm_ltm_frame(const void **pixels, int *width, int *height, uint64_t *serial);
void utm_ltm_touch(int phase, double x, double y);
void utm_ltm_button(int button, bool down);
void utm_ltm_pause(bool paused);
void utm_ltm_quit(void);
#endif
