// ios_main.m — iOS platform layer replacing unix_main.c
// Implements all Sys_* functions required by the engine

#include <unistd.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/time.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <dirent.h>
#include <sys/mman.h>
#include <pwd.h>
#include <dlfcn.h>
#include <libgen.h>
#include <assert.h>
#include <math.h>

#import <Foundation/Foundation.h>

#include "../qcommon/q_shared.h"
#include "../qcommon/qcommon.h"
#include "../client/keycodes.h"
#include "ios_local.h"

#ifndef DEDICATED
#include "../client/client.h"
#endif

// =============================================================
// Time
// =============================================================

static unsigned long sys_timeBase = 0;

int Sys_Milliseconds(void) {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    if (!sys_timeBase) {
        sys_timeBase = tp.tv_sec;
        return tp.tv_usec / 1000;
    }
    return (int)((tp.tv_sec - sys_timeBase) * 1000 + tp.tv_usec / 1000);
}

// Sys_Microseconds provided by common.c

// =============================================================
// Paths
// =============================================================

static char installPath[MAX_OSPATH] = {0};

const char *Sys_Pwd(void) {
    static char pwd[MAX_OSPATH];
    if (pwd[0] == '\0') {
        getcwd(pwd, sizeof(pwd));
    }
    return pwd;
}

const char *Sys_DefaultBasePath(void) {
    if (installPath[0] == '\0') {
        @autoreleasepool {
            NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
            Q_strncpyz(installPath, [bundlePath UTF8String], sizeof(installPath));
        }
    }
    return installPath;
}

const char *Sys_DefaultHomePath(void) {
    static char homePath[MAX_OSPATH] = {0};
    if (homePath[0] == '\0') {
        @autoreleasepool {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *documentsDir = [paths firstObject];
            Q_strncpyz(homePath, [documentsDir UTF8String], sizeof(homePath));
        }
    }
    return homePath;
}

char *Sys_DefaultAppPath(void) {
    static char appPath[MAX_OSPATH] = {0};
    if (appPath[0] == '\0') {
        @autoreleasepool {
            NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
            Q_strncpyz(appPath, [bundlePath UTF8String], sizeof(appPath));
        }
    }
    return appPath;
}

const char *Sys_SteamPath(void) {
    return "";
}

const char *Sys_BinName(const char *arg0) {
    return "Quake3-iOS";
}

// =============================================================
// System
// =============================================================

void Sys_Init(void) {
    Cvar_Set("arch", "arm64");
    Com_Printf("Sys_Init: iOS platform (arm64)\n");
}

void NORETURN QDECL Sys_Error(const char *format, ...) {
    va_list argptr;
    char text[1024];
    va_start(argptr, format);
    Q_vsnprintf(text, sizeof(text), format, argptr);
    va_end(argptr);
    NSLog(@"Sys_Error: %s", text);
    exit(1);
}

void NORETURN Sys_Quit(void) {
    exit(0);
}

void Sys_Print(const char *msg) {
    if (msg && msg[0]) {
        fputs(msg, stdout);
    }
}

void QDECL Sys_SetStatus(const char *format, ...) {
}

qboolean Sys_LowPhysicalMemory(void) {
    return qfalse;
}

void Sys_BeginProfiling(void) {}
void Sys_EndProfiling(void) {}

void Sys_Sleep(int msec) {
    if (msec > 0) usleep(msec * 1000);
}

void Sys_SendKeyEvents(void) {
}

char *Sys_ConsoleInput(void) {
    return NULL;
}

char *Sys_GetClipboardData(void) {
    return NULL;
}

void Sys_SetClipboardBitmap(const byte *bitmap, int length) {
}

qboolean Sys_RandomBytes(byte *string, int len) {
    FILE *fp = fopen("/dev/urandom", "r");
    if (!fp) return qfalse;
    size_t read_count = fread(string, sizeof(byte), len, fp);
    fclose(fp);
    return (read_count == (size_t)len) ? qtrue : qfalse;
}

// Sys_SnapVector provided by common.c

int Sys_MonkeyShouldBeSpanked(void) {
    return 0;
}

void Sys_DisplaySystemConsole(qboolean show) {}
void Sys_ShowConsole(int visLevel, qboolean quitOnClose) {}
void Sys_SetErrorText(const char *text) {}

// =============================================================
// Filesystem
// =============================================================

qboolean Sys_Mkdir(const char *path) {
    if (mkdir(path, 0750) == 0 || errno == EEXIST) return qtrue;
    return qfalse;
}

FILE *Sys_FOpen(const char *ospath, const char *mode) {
    return fopen(ospath, mode);
}

qboolean Sys_ResetReadOnlyAttribute(const char *ospath) {
    return qfalse;
}

char **Sys_ListFiles(const char *directory, const char *extension,
                     const char *filter, int *numfiles, int subdirs) {
    int nfiles = 0;
    char **listCopy;
    char *list[MAX_FOUND_FILES];
    DIR *fdir;
    struct dirent *d;
    struct stat st;
    char search[MAX_OSPATH];
    int extLen;

    if (!extension) extension = "";
    extLen = (int)strlen(extension);

    Q_strncpyz(search, directory, sizeof(search));
    fdir = opendir(search);
    if (!fdir) {
        *numfiles = 0;
        return NULL;
    }

    while ((d = readdir(fdir)) != NULL && nfiles < MAX_FOUND_FILES - 1) {
        char filename[MAX_OSPATH];
        Com_sprintf(filename, sizeof(filename), "%s/%s", search, d->d_name);
        if (stat(filename, &st) == -1) continue;

        if (subdirs) {
            if (S_ISDIR(st.st_mode) &&
                Q_stricmp(d->d_name, ".") && Q_stricmp(d->d_name, "..")) {
                list[nfiles++] = CopyString(d->d_name);
            }
        } else {
            if (!S_ISDIR(st.st_mode)) {
                int nameLen = (int)strlen(d->d_name);
                if (extLen == 0 ||
                    (nameLen >= extLen &&
                     !Q_stricmp(d->d_name + nameLen - extLen, extension))) {
                    list[nfiles++] = CopyString(d->d_name);
                }
            }
        }
    }
    closedir(fdir);

    listCopy = Z_Malloc((nfiles + 1) * sizeof(*listCopy));
    for (int i = 0; i < nfiles; i++) listCopy[i] = list[i];
    listCopy[nfiles] = NULL;
    *numfiles = nfiles;
    return listCopy;
}

void Sys_FreeFileList(char **list) {
    int i;
    if (!list) return;
    for (i = 0; list[i]; i++) Z_Free(list[i]);
    Z_Free(list);
}

qboolean Sys_GetFileStats(const char *filename, fileOffset_t *size,
                          fileTime_t *mtime, fileTime_t *ctime) {
    struct stat buf;
    if (stat(filename, &buf) == -1) return qfalse;
    if (size) *size = buf.st_size;
    if (mtime) *mtime = buf.st_mtime;
    if (ctime) *ctime = buf.st_ctime;
    return qtrue;
}

// =============================================================
// Dynamic libraries (limited on iOS)
// =============================================================

void *Sys_LoadLibrary(const char *name) {
    return dlopen(name, RTLD_NOW);
}

void Sys_UnloadLibrary(void *handle) {
    if (handle) dlclose(handle);
}

void *Sys_LoadFunction(void *handle, const char *name) {
    return dlsym(handle, name);
}

int Sys_LoadFunctionErrors(void) {
    return dlerror() ? 1 : 0;
}

// =============================================================
// Affinity (no-op)
// =============================================================

uint64_t Sys_GetAffinityMask(void) { return 0; }
qboolean Sys_SetAffinityMask(const uint64_t mask) { return qfalse; }

// =============================================================
// Input stubs
// =============================================================

typedef struct {
    float leftX;
    float leftY;
    float rightX;
    float rightY;
    qboolean firePressed;
    qboolean jumpPressed;
    qboolean crouchPressed;
    unsigned int buttonMask; /* extended Q3_PAD_* bits from Swift */
} iosGamepadState_t;

static iosGamepadState_t s_gamepadState;
static iosGamepadState_t s_prevGamepadState;
static int s_lastGamepadPollMsec;

/* Map Q3_PAD_* bits to Q3 key codes. Order matters only for iteration. */
typedef struct {
    unsigned int bit;
    int key;
} gamepadBitMap_t;

static const gamepadBitMap_t s_gamepadBitMap[] = {
    { Q3_PAD_A,              K_PAD0_A },
    { Q3_PAD_B,              K_PAD0_B },
    { Q3_PAD_X,              K_PAD0_X },
    { Q3_PAD_Y,              K_PAD0_Y },
    { Q3_PAD_LEFT_SHOULDER,  K_PAD0_LEFTSHOULDER },
    { Q3_PAD_RIGHT_SHOULDER, K_PAD0_RIGHTSHOULDER },
    { Q3_PAD_LEFT_TRIGGER,   K_PAD0_LEFTTRIGGER },
    { Q3_PAD_RIGHT_TRIGGER,  K_PAD0_RIGHTTRIGGER },
    { Q3_PAD_DPAD_UP,        K_PAD0_DPAD_UP },
    { Q3_PAD_DPAD_DOWN,      K_PAD0_DPAD_DOWN },
    { Q3_PAD_DPAD_LEFT,      K_PAD0_DPAD_LEFT },
    { Q3_PAD_DPAD_RIGHT,     K_PAD0_DPAD_RIGHT },
    { Q3_PAD_MENU,           K_PAD0_START },
    { Q3_PAD_OPTIONS,        K_PAD0_BACK },
    { Q3_PAD_LEFT_THUMB,     K_PAD0_LEFTSTICK_CLICK },
    { Q3_PAD_RIGHT_THUMB,    K_PAD0_RIGHTSTICK_CLICK },
};

static float ClampUnitAxis(float value) {
    if (value < -1.0f) {
        return -1.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

static float ApplyDeadzone(float value, float deadzone) {
    float magnitude = fabsf(value);

    if (magnitude <= deadzone) {
        return 0.0f;
    }

    magnitude = (magnitude - deadzone) / (1.0f - deadzone);
    return copysignf(magnitude, value);
}

static int GamepadAxisToQuake(float value) {
    float clamped = ClampUnitAxis(value);
    int scaled = (int)lrintf(clamped * 127.0f);

    if (scaled < -127) {
        return -127;
    }
    if (scaled > 127) {
        return 127;
    }
    return scaled;
}

static void QueueGamepadButtonEvent(int key, qboolean previous, qboolean current, int eventTime) {
    if (previous != current) {
        Sys_QueEvent(eventTime, SE_KEY, key, current, 0, NULL);
    }
}

void IN_Init(void) {
    Com_Printf("IN_Init: iOS touch + controller input\n");
    /* Cbuf_AddText + Cbuf_Execute, NOT Cbuf_ExecuteText(EXEC_NOW, ...).
     * EXEC_NOW calls Cmd_ExecuteString on the whole string, which stops
     * at the first newline — so for a multi-line script only the FIRST
     * line (`seta cl_freelook 1`) would run and every bind after it got
     * silently dropped. Discovered via IN_Init bind-verify diagnostic
     * returning 'PAD0_A is not bound' (commit 701e736 log capture).
     *
     * AddText queues the full multi-line block; Cbuf_Execute then drains
     * every command to completion. Config files that ran before this
     * point have already loaded, so our binds still win. */
    Cbuf_AddText(
        "seta cl_freelook 1\n"
        "seta in_joystick 1\n"
        "seta j_yaw -0.005\n"
        "seta j_pitch -0.005\n"
        "seta j_forward -0.25\n"
        "seta j_side 0.25\n"
        "seta j_up 0.25\n"
        "seta j_yaw_axis 3\n"
        "seta j_pitch_axis 4\n"
        "seta j_forward_axis 1\n"
        "seta j_side_axis 0\n"
        "seta j_up_axis 2\n"
        "set cl_pitchspeed 20\n"
        "set cl_yawspeed 20\n"
        "set sensitivity 1.0\n"
        "bind PAD0_RIGHTTRIGGER \"+attack\"\n"
        "bind PAD0_LEFTTRIGGER \"+zoom\"\n"
        "bind PAD0_A \"+moveup\"\n"
        "bind PAD0_B \"+movedown\"\n"
        "bind PAD0_X \"+activate\"\n"
        "bind PAD0_Y \"weapnext\"\n"
        "bind PAD0_LEFTSHOULDER \"weapprev\"\n"
        "bind PAD0_RIGHTSHOULDER \"weapnext\"\n"
        "bind PAD0_START \"togglemenu\"\n"
        "bind PAD0_BACK \"+scores\"\n"
        "bind PAD0_DPAD_UP \"weapon 7\"\n"
        "bind PAD0_DPAD_DOWN \"weapon 2\"\n"
        "bind PAD0_DPAD_LEFT \"weapon 5\"\n"
        "bind PAD0_DPAD_RIGHT \"weapon 6\"\n"
    );
    Cbuf_Execute();
    /* Verify the binds actually installed. `bind PAD0_A` with no second
     * arg prints the current binding. If these come back empty or
     * 'not bound', something clobbered the bind table after IN_Init
     * (probably q3config.cfg re-exec). */
    Com_Printf("IN_Init: verifying bindings...\n");
    Cbuf_ExecuteText(EXEC_NOW, "bind PAD0_A\n");
    Cbuf_ExecuteText(EXEC_NOW, "bind PAD0_B\n");
    Cbuf_ExecuteText(EXEC_NOW, "bind PAD0_Y\n");
    Cbuf_ExecuteText(EXEC_NOW, "bind PAD0_RIGHTTRIGGER\n");
}
void IN_Frame(void) {
    int eventTime = Sys_Milliseconds();
    int leftSide;
    int leftForward;
    s_lastGamepadPollMsec = eventTime;

    /* Left stick: X = strafe (side), Y = forward/back (push up = forward) */
    leftSide = GamepadAxisToQuake(ApplyDeadzone(s_gamepadState.leftX, 0.18f));
    leftForward = GamepadAxisToQuake(ApplyDeadzone(s_gamepadState.leftY, 0.18f));
    Sys_QueEvent(eventTime, SE_JOYSTICK_AXIS, AXIS_SIDE, leftSide, 0, NULL);
    Sys_QueEvent(eventTime, SE_JOYSTICK_AXIS, AXIS_FORWARD, leftForward, 0, NULL);
    Sys_QueEvent(eventTime, SE_JOYSTICK_AXIS, AXIS_UP, 0, 0, NULL);
    /* Right stick: X = yaw (look left/right), Y = pitch (look up/down)
     * Scale down hard because engine applies cl_yawspeed/pitchspeed on top. */
    {
        /* Right stick inverted: push left = look right, push up = look down */
        float rx = -ApplyDeadzone(s_gamepadState.rightX, 0.12f) * 0.07f;
        float ry = -ApplyDeadzone(s_gamepadState.rightY, 0.12f) * 0.035f;
        Sys_QueEvent(eventTime, SE_JOYSTICK_AXIS, AXIS_YAW,
                     GamepadAxisToQuake(rx), 0, NULL);
        Sys_QueEvent(eventTime, SE_JOYSTICK_AXIS, AXIS_PITCH,
                     GamepadAxisToQuake(ry), 0, NULL);
    }
    /* Clamp pitch so we don't spin 360 vertically */
    if (cl.viewangles[0] > 89.0f) cl.viewangles[0] = 89.0f;
    if (cl.viewangles[0] < -89.0f) cl.viewangles[0] = -89.0f;

    QueueGamepadButtonEvent(K_PAD0_RIGHTTRIGGER, s_prevGamepadState.firePressed, s_gamepadState.firePressed, eventTime);
    QueueGamepadButtonEvent(K_PAD0_A, s_prevGamepadState.jumpPressed, s_gamepadState.jumpPressed, eventTime);
    QueueGamepadButtonEvent(K_PAD0_B, s_prevGamepadState.crouchPressed, s_gamepadState.crouchPressed, eventTime);

    /* Extended button mask from Swift. Diff against previous and queue
     * SE_KEY events for each bit that toggled. */
    {
        unsigned int prev = s_prevGamepadState.buttonMask;
        unsigned int cur = s_gamepadState.buttonMask;
        unsigned int changed = prev ^ cur;
        size_t bitIdx;
        if (changed != 0) {
            for (bitIdx = 0; bitIdx < sizeof(s_gamepadBitMap)/sizeof(s_gamepadBitMap[0]); ++bitIdx) {
                unsigned int bit = s_gamepadBitMap[bitIdx].bit;
                if (changed & bit) {
                    qboolean down = (cur & bit) ? qtrue : qfalse;
                    Sys_QueEvent(eventTime, SE_KEY, s_gamepadBitMap[bitIdx].key, down, 0, NULL);
                    /* Diagnostic: log every SE_KEY we hand to the engine
                     * so we can tell whether events reach Com_EventLoop.
                     * If this prints but the game ignores the press, the
                     * keyCatcher or bind table is at fault, not the
                     * input pipeline. */
                    Com_Printf("IN: queued SE_KEY key=%d down=%d (mask prev=0x%X cur=0x%X)\n",
                               s_gamepadBitMap[bitIdx].key, (int)down, prev, cur);
                }
            }
        }
    }

    s_prevGamepadState = s_gamepadState;
}
void IN_Shutdown(void) {}

void Q3Gamepad_SetState(float leftX, float leftY, float rightX, float rightY,
                        int firePressed, int jumpPressed, int crouchPressed) {
    s_gamepadState.leftX = ClampUnitAxis(leftX);
    s_gamepadState.leftY = ClampUnitAxis(leftY);
    s_gamepadState.rightX = ClampUnitAxis(rightX);
    s_gamepadState.rightY = ClampUnitAxis(rightY);
    s_gamepadState.firePressed = firePressed ? qtrue : qfalse;
    s_gamepadState.jumpPressed = jumpPressed ? qtrue : qfalse;
    s_gamepadState.crouchPressed = crouchPressed ? qtrue : qfalse;
}

void Q3Gamepad_SetButtons(unsigned int buttonMask) {
    s_gamepadState.buttonMask = buttonMask;
}

// =============================================================
// GLimp stubs (we use Metal, but engine expects these)
// =============================================================

void GLimp_Init(glconfig_t *config) {
    Com_Printf("GLimp_Init: Metal renderer stub\n");
    config->vidWidth = 1290;
    config->vidHeight = 2796;
    config->windowAspect = (float)config->vidWidth / (float)config->vidHeight;
    config->colorBits = 32;
    config->depthBits = 24;
    config->stencilBits = 8;
    config->isFullscreen = qtrue;
    config->deviceSupportsGamma = qtrue;
    Q_strncpyz(config->renderer_string, "Apple Metal (iOS)", sizeof(config->renderer_string));
    Q_strncpyz(config->vendor_string, "Apple", sizeof(config->vendor_string));
    Q_strncpyz(config->version_string, "Metal 4", sizeof(config->version_string));
}

void GLimp_Shutdown(qboolean unloadDLL) {
}

void GLimp_EndFrame(void) {
}

void *GL_GetProcAddress(const char *name) {
    return NULL;
}

void GLimp_InitGamma(glconfig_t *config) {
}

void GLimp_SetGamma(unsigned char red[256], unsigned char green[256], unsigned char blue[256]) {
}

// VK stubs
void VKimp_Init(glconfig_t *config) {}
void VKimp_Shutdown(qboolean unloadDLL) {}
void *VK_GetInstanceProcAddr(void *instance, const char *name) { return NULL; }
qboolean VK_CreateSurface(void *instance, void *pSurface) { return qfalse; }

// =============================================================
// Misc
// =============================================================

char *strlwr(char *s) {
    if (!s) return s;
    char *p = s;
    while (*p) { *p = tolower(*p); p++; }
    return s;
}

void Sys_ConfigureFPU(void) {}

// Network functions provided by net_ip.c

// =============================================================
// Sound DMA stubs (replacing SDL audio driver)
// =============================================================

#include "../client/snd_local.h"

qboolean SNDDMA_Init(void) {
    return qfalse;
}

int SNDDMA_GetDMAPos(void) {
    return 0;
}

void SNDDMA_Shutdown(void) {
}

void SNDDMA_BeginPainting(void) {
}

void SNDDMA_Submit(void) {
}

// =============================================================
// Engine entry (called from Swift)
// =============================================================

static qboolean engine_initialized = qfalse;

void Quake3_Init(const char *basePath) {
    if (engine_initialized) return;

    if (basePath && basePath[0]) {
        Q_strncpyz(installPath, basePath, sizeof(installPath));
    }

    char cmdline[256] = "";
    Com_Init(cmdline);
    Cvar_Set("com_maxfps", "120");
    Cvar_Set("com_maxfpsUnfocused", "120");

    /* Register the statically-linked native cgame so VM_Create (called
     * from CL_InitCGame on map load) resolves to our in-binary cgame
     * instead of loading baseq3/pak8.pk3's cgame.qvm. Kills the QVM
     * ABI mismatch that's been driving every workaround commit (head
     * hide, weapons2 hide, fallback camera, synthetic viewmodel). */
    {
        extern vmMainFunc_t CG_Native_GetEntryPoint(void);
        extern dllEntry_t   CG_Native_GetDllEntry(void);
        VM_RegisterNative("cgame", CG_Native_GetEntryPoint(), CG_Native_GetDllEntry());
    }

    /* Q3's stock client (sdl_input.c / linux_glimp.c) is NOT linked on
     * iOS — only our ios_main.m defines IN_Init, and nothing in the
     * engine was calling it. Result: PAD0_* binds never ran and
     * controller buttons produced SE_KEY events that hit no bindings.
     * Call it explicitly here, after Com_Init so the cvar and command
     * subsystems are up. */
    IN_Init();
    Cbuf_AddText("map q3dm16\n");
    engine_initialized = qtrue;

    Com_Printf("=== Quake3 iOS Engine Initialized ===\n");
}

void Quake3_Frame(void) {
    if (!engine_initialized) return;
    IN_Frame();
    Com_Frame(qfalse);
}
