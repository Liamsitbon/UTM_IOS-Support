#include "CMobileGuest.h"
#include <dlfcn.h>
#include <stdio.h>

static void *engine;
static int (*run_vm)(int, char **);
static const QemuIosDeviceInfo *(*machine_at)(int);
static bool (*ready)(void);
static bool (*frame)(const void **, int *, int *, uint64_t *);
static void (*foreground)(bool);
static void (*attach)(qemu_ios_frame_cb, void *);
static void (*touch)(int, int, double, double);
static void (*button)(int, bool);
static void (*pause_vm)(void), (*resume_vm)(void), (*quit_vm)(void);

const char *utm_ltm_load(const char *path, bool require_interpreter) {
    if (engine) return "The LightTouch engine has already been loaded. Reopen UTM to select another engine.";
    void *candidate = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!candidate) return dlerror();
    uint32_t (*version)(void) = dlsym(candidate, "qemu_ios_api_version");
    bool (*interpreter)(void) = dlsym(candidate, "qemu_ios_utm_is_interpreter");
    const char *failure = NULL;
    if (!version || version() >> 16 != 2) failure = "LightTouch requires QEMU iOS C API 2.x.";
    if (require_interpreter && (!interpreter || !interpreter()))
        failure = "UTM SE requires a LightTouch engine built with the TCG interpreter (no JIT).";
#define LOAD(variable, symbol) variable = dlsym(candidate, symbol); if (!variable) failure = "Missing LightTouch entry point: " symbol
    LOAD(run_vm, "qemu_ios_main");
    LOAD(machine_at, "qemu_ios_device_info_at");
    LOAD(ready, "qemu_ios_ui_ready");
    LOAD(frame, "qemu_ios_ui_frame");
    LOAD(foreground, "qemu_ios_set_foreground");
    LOAD(attach, "qemu_ios_ui_attach");
    LOAD(touch, "qemu_ios_ui_touch");
    LOAD(button, "qemu_ios_ui_button");
    LOAD(pause_vm, "qemu_ios_ui_pause");
    LOAD(resume_vm, "qemu_ios_ui_resume");
    LOAD(quit_vm, "qemu_ios_ui_quit");
#undef LOAD
    if (failure) { dlclose(candidate); return failure; }
    engine = candidate;
    return NULL;
}
const QemuIosDeviceInfo *utm_ltm_machine(int index) { return engine ? machine_at(index) : NULL; }
int utm_ltm_run(int argc, char **argv) { attach(NULL, NULL); return run_vm(argc, argv); }
bool utm_ltm_ready(void) { return engine && ready(); }
bool utm_ltm_frame(const void **p, int *w, int *h, uint64_t *s) { return engine && frame(p, w, h, s); }
void utm_ltm_touch(int phase, double x, double y) { if (utm_ltm_ready()) touch(0, phase, x, y); }
void utm_ltm_button(int value, bool down) { if (utm_ltm_ready()) button(value, down); }
void utm_ltm_pause(bool paused) { if (utm_ltm_ready()) { foreground(!paused); if (paused) pause_vm(); else resume_vm(); } }
void utm_ltm_quit(void) { if (utm_ltm_ready()) quit_vm(); }
