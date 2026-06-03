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
#import <UIKit/UIKit.h>

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

/* Pre-engine-init mod selection (see Q3_SetBootMod() below). File-scope
 * static so Quake3_Init() cmdline construction (~line 850) can read it
 * BEFORE the function definition near Q3Exec_Command. Empty = vanilla. */
static char g_bootMod[64] = "";

/* Pre-engine-init upscale render resolution. Swift launcher selects the
 * MetalFX quality level (Native/High/Medium/Low) and computes the input
 * render dimensions; we inject them as r_customwidth/r_customheight on
 * the cmdline so Q3's vidWidth/vidHeight + projection match the offscreen
 * RT Swift will create. Drawable size stays at the existing iPhone target
 * (1920×888 / 2560×1920) — MetalFX upscales RT → drawable.
 * 0 = use the default native-target path (no upscale-driven override). */
static int g_renderResW = 0;
static int g_renderResH = 0;

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
        /* Keep stdout for any future shell-piped CI workflow. */
        fputs(msg, stdout);
        /* On iOS app sandboxes, stdout is not connected to anything by
         * default — fputs landed in the void, so neither Console.app nor
         * idevicesyslog could see Com_Printf / ri.Printf output (every
         * [METAL-SHADER] diagnostic dump came up empty when grepped from
         * the device syslog). NSLog routes the same text into Apple
         * System Log, which Console.app + idevicesyslog both consume.
         * Cost: ~microseconds per call — negligible vs Q3 frame budget,
         * and only Com_Printf gates flow through here (mixer / renderer
         * inner loops never call Sys_Print). Strip trailing newline
         * because NSLog appends its own. */
        size_t len = strlen(msg);
        if (len > 0 && msg[len - 1] == '\n') {
            char trimmed[2048];
            size_t copy = len - 1;
            if (copy >= sizeof(trimmed)) copy = sizeof(trimmed) - 1;
            memcpy(trimmed, msg, copy);
            trimmed[copy] = '\0';
            NSLog(@"%s", trimmed);
        } else {
            NSLog(@"%s", msg);
        }
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
        qboolean menuActive = (Key_GetCatcher() & KEYCATCH_UI) ? qtrue : qfalse;
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

                    /* Menu navigation: when the UI keyCatcher is active,
                     * also translate D-pad / A / B / Start into the
                     * arrow / enter / escape keys the Q3 UI QVM listens
                     * for. Emitted in ADDITION to the PAD0_* event above
                     * so in-game bindings still work when a menu is not
                     * up. A/B assignments match Xbox convention (A = OK,
                     * B = back/cancel). Start also opens/closes menu. */
                    if (menuActive) {
                        int navKey = 0;
                        if      (bit == Q3_PAD_DPAD_UP)    navKey = K_UPARROW;
                        else if (bit == Q3_PAD_DPAD_DOWN)  navKey = K_DOWNARROW;
                        else if (bit == Q3_PAD_DPAD_LEFT)  navKey = K_LEFTARROW;
                        else if (bit == Q3_PAD_DPAD_RIGHT) navKey = K_RIGHTARROW;
                        else if (bit == Q3_PAD_A)          navKey = K_ENTER;
                        else if (bit == Q3_PAD_B)          navKey = K_ESCAPE;
                        else if (bit == Q3_PAD_MENU)       navKey = K_ESCAPE;
                        if (navKey != 0) {
                            Sys_QueEvent(eventTime, SE_KEY, navKey, down, 0, NULL);
                        }
                    }
                }
            }
        }

        /* Left-stick menu navigation. The UI doesn't listen to joystick
         * axes, so we synthesize arrow-key presses when the stick crosses
         * a cardinal threshold. Edge-triggered: emit once on cross, emit
         * release when stick returns to neutral. Diagonals are ignored
         * to avoid double-firing. */
        if (menuActive) {
            static int s_prevStickKey = 0;
            int nextKey = 0;
            float lx = s_gamepadState.leftX;
            float ly = s_gamepadState.leftY;
            const float threshold = 0.5f;
            if (fabsf(ly) > fabsf(lx)) {
                if (ly >  threshold) nextKey = K_DOWNARROW;
                if (ly < -threshold) nextKey = K_UPARROW;
            } else {
                if (lx >  threshold) nextKey = K_RIGHTARROW;
                if (lx < -threshold) nextKey = K_LEFTARROW;
            }
            if (nextKey != s_prevStickKey) {
                if (s_prevStickKey != 0) {
                    Sys_QueEvent(eventTime, SE_KEY, s_prevStickKey, qfalse, 0, NULL);
                }
                if (nextKey != 0) {
                    Sys_QueEvent(eventTime, SE_KEY, nextKey, qtrue, 0, NULL);
                }
                s_prevStickKey = nextKey;
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

    /* Disable C-side stdio buffering so Com_Printf and any other
     * stdout/stderr writes flush immediately. Without this, on
     * device captures via devicectl --console can lose the last
     * 4-8KB of output when the app is SIGKILL'd, hiding the actual
     * crash signature. */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    NSLog(@"[Q3-INIT] entered Quake3_Init basePath=%s", basePath ? basePath : "(null)");

    if (basePath && basePath[0]) {
        Q_strncpyz(installPath, basePath, sizeof(installPath));
    }

    /* Force the QVM bytecode interpreter (vm_* = 1) instead of the
     * JIT compiler (vm_* = 2). On Apple Silicon iPad (M-series) the
     * JIT path's W^X enforcement is stricter than on A-series iPhone:
     * Quake3e's vm_aarch64.c writes JIT pages without calling
     * pthread_jit_write_protect_np(), and iPad SIGKILLs the app the
     * first time it tries to execute JITted code (right after
     * "ui loaded" prints, which is when CL_InitGUI calls
     * vmMain(UI_GETAPIVERSION)). Bytecode interpretation is plenty
     * fast for UI/cgame on modern hardware. cgame uses native VM
     * registry (in-binary, not QVM), so vm_cgame doesn't really
     * matter, but we set it for symmetry. */
    const char *matchProfileName = getenv("Q3_MATCH_PROFILE");
    BOOL matchProfile960 = (matchProfileName && !strcmp(matchProfileName, "metal_960_25"));
    BOOL matchProfile1280 = (matchProfileName && !strcmp(matchProfileName, "metal_1280_25"));
    BOOL matchProfileNative = (matchProfileName && !strcmp(matchProfileName, "native_ipad_25"));
    BOOL matchProfile = (matchProfile960 || matchProfile1280 || matchProfileNative);
    CGSize nativeSize = [UIScreen mainScreen].nativeBounds.size;
    int nativeWidth = (int)MAX(nativeSize.width, nativeSize.height);
    int nativeHeight = (int)MIN(nativeSize.width, nativeSize.height);
    if (nativeWidth <= 0 || nativeHeight <= 0) {
        nativeWidth = 1280;
        nativeHeight = 720;
    }
    {
        const char *maxDrawableEnv = getenv("Q3_MAX_DRAWABLE_WIDTH");
        int maxDrawableWidth = maxDrawableEnv ? atoi(maxDrawableEnv) : 0;
        if (maxDrawableWidth > 0 && nativeWidth > maxDrawableWidth) {
            nativeHeight = MAX(1, (nativeHeight * maxDrawableWidth) / nativeWidth);
            nativeWidth = maxDrawableWidth;
        }
    }
    int matchWidth = nativeWidth;
    int matchHeight = nativeHeight;
    if (matchProfile960) {
        matchWidth = 960;
        matchHeight = 444;
    } else if (matchProfile1280) {
        matchWidth = 1280;
        matchHeight = 960;
    }

    // com_zoneMegs / com_hunkMegs / com_soundMegs are CVAR_LATCH — they
    // must be set on the command line, BEFORE Z_Init allocates. Setting
    // them in q3config.cfg is a no-op (the cvars persist, but Z_Init has
    // already used the default DEF_COMZONEMEGS=12 by the time the config
    // parses). Heavy custom maps (nv15, ts_q3dm13, ztn3dm1) overflow 12 MB
    // of zone during cgame init and crash in Z_CheckHeap with "next block
    // doesn't have proper back link". Bumping to 64/256/16 covers the
    // heaviest community maps with margin on iPhone 17 Pro (12 GB unified).
    /* Brightness cvars MUST land on the cmdline +set path, not via
     * post-init Cbuf seta. r_mapOverBrightBits is CVAR_LATCH — `seta`
     * after Com_Init only updates latchedString; cvar->integer keeps
     * the old value until vid_restart. Cmdline +set runs through
     * Com_StartupVariable BEFORE the renderer's Cvar_Get registers
     * the cvar, so the +set value IS the registered initial value
     * (no latch needed). This means the lightmap pre-shift at first
     * BSP load (metal_renderer_stub.c:2421) reads the value we want.
     *
     * Bumped values vs PC reference (chosen for OLED iPhone vs PC CRT
     * reference look — user reported world too dark vs LvL HD captures):
     *   r_mapOverBrightBits 3  (PC default 2) — shift = 3-1 = 2,
     *                            gives ×4 lightmap vs PC's ×2.
     *                            Hue-preserving normalize in load
     *                            shift code clamps blowouts.
     *   r_overBrightBits   1  (PC default 1) — kept stock so the
     *                            shift formula stays sane.
     * r_gamma / r_intensity / r_ignorehwgamma are also set so they're
     * in place IF a postprocess gamma kernel is added later, but the
     * current Metal renderer ignores them. */
    char cmdline[1024] = "+set com_zoneMegs 64 +set com_hunkMegs 256 +set com_soundMegs 16 +set vm_ui 1 +set vm_game 1 +set vm_cgame 1"
        " +set r_overBrightBits 1"
        /* Q3A-1.32e-REMASTERED recommended graphics block (2026-06-02):
         *   r_mapOverBrightBits 1 (PC default 2) — value 3 caused q3dm4 fog
         *     to blow blue, value 2 looked dim; the remaster uses 1 paired
         *     with r_intensity 1.4 + r_gamma 1.2 to compensate downstream.
         *   r_intensity 1.4 (PC default 1.0) — base-texture multiplier;
         *     compensates for the lower mapOverBrightBits shift.
         *   r_gamma 1.2 (PC default 1.0) — slight midtone lift.
         *   r_picmip 0 — full-detail textures (stock default; explicit).
         *   r_mapGreyScale -0.25 — Quake3e cvar: negative = SATURATION BOOST.
         *     Adds a touch of color punch on top of the remaster's HD assets.
         *   r_ignorehwgamma 1 — bypass hardware gamma ramp (we do software
         *     gamma via postprocess instead). */
        /* PURE 1999 VANILLA cvars for PBR-baseline work. The remaster
         * tuning above is preserved in comments — flip these back to
         * 1.4 / 1.2 / -0.25 once PBR Phase 1 is locked in. */
        " +set r_mapOverBrightBits 2"
        " +set r_intensity 1.0"
        " +set r_gamma 1.0"
        " +set r_picmip 1"
        " +set r_mapGreyScale 0"
        " +set r_ignorehwgamma 1"
        /* Widescreen FOV with Hor+ patch applied to CG_CalcFov (see
         * code/cgame/cg_view.c). cg_fov is the 4:3 REFERENCE horizontal
         * FOV — vertical FOV stays consistent across aspect ratios.
         *
         * Q3A-1.32e-REMASTERED recommends cg_fov 109 (range 100-130). On
         * our 2.16:1 phone with Hor+ that derives to fov_x ≈ 132° / fov_y
         * ≈ 92° — wide / borderline fish-eye but matches the modern Q3
         * pro-player feel. If too wide for your taste, dial down to 100
         * (fov_x ≈ 122° / fov_y ≈ 82° on phone).
         *
         * cg_zoomfov 75 is the remaster recommendation (range 50-80). The
         * previous 22 was the canonical Q3 railgun zoom — fine for tight
         * shots but jarring; 75 gives a gentler half-zoom. */
        " +set cg_fov 109"
        " +set cg_zoomfov 75"
        /* Max-quality geometry knobs requested 2026-06-02. r_subdivisions
         * controls bezier-patch tessellation (lower = smoother curves);
         * r_lodbias forces higher-detail LOD pick at all distances
         * (negative = always prefer the highest-detail model variant).
         * Both are CVAR_ARCHIVE so they ALSO persist into q3config.cfg
         * on writeconfig, but baking on the cmdline guarantees they
         * apply from the very first frame even before config load. */
        /* Vanilla-stock geometry knobs (PBR-baseline lockdown):
         *   r_subdivisions 4  (stock default; lower = smoother curves)
         *   r_lodbias       0 (stock default; negative = always-highest LOD) */
        " +set r_subdivisions 4"
        " +set r_lodbias 0";
    if (matchProfile) {
        char matchCmds[768];
        snprintf(matchCmds, sizeof(matchCmds),
                 " +safe"
                 " +set developer 1"
                 " +set logfile 2"
                 " +set com_introplayed 1"
                 " +set r_mode -1"
                 " +set r_customwidth %d"
                 " +set r_customheight %d"
                 " +set r_fullscreen 1"
                 " +set cg_draw2D 0"
                 " +set cg_drawGun 1"
                 " +set cg_drawCrosshair 0"
                 " +set cg_marks 1"
                 " +set r_picmip 0"
                 " +set r_texturebits 32"
                 " +set r_colorbits 32"
                 " +set r_depthbits 24"
                 " +set r_overBrightBits 1"
                 " +set r_mapOverBrightBits 2"
                 // OLED visibility lift. PC stock r_gamma is 1.0 which
                 // can look murky on OLED panels (perfect-black crushes
                 // dim shadow detail). 1.15 lifts midtones just enough
                 // to read low-light corridors without washing out the
                 // bright lights. r_intensity stays at 1.0 — bumping
                 // that compounds across base + lightmap stages and
                 // overshoots fast.
                 " +set r_gamma 1.15"
                 " +set r_intensity 1.0"
                 " +set r_ignorehwgamma 1"
                 " +set com_maxfps 25"
                 " +set com_maxfpsUnfocused 25"
                 " +set timescale 1"
                 " +set fixedtime 0"
                 " +set r_swapInterval 0"
                 " +set s_initsound 0"
                 " +set con_notifytime 0",
                 matchWidth, matchHeight);
        Q_strcat(cmdline, sizeof(cmdline),
                 matchCmds);
    }
    /* fs_game mod selection. g_bootMod is set by Swift via Q3_SetBootMod()
     * before this function runs (LaunchMenuView mod row tap). When set,
     * append `+set fs_game <mod>` so Com_Init's FS_Startup discovers the
     * mod's pak3 cascade in <basepath>/<mod>/ during pak loading. Also
     * honour the Q3_FS_GAME env var as a fallback (devicectl scripts /
     * Xcode scheme env). Empty / NULL means stay on baseq3. */
    {
        const char *envMod = getenv("Q3_FS_GAME");
        const char *modSel = (g_bootMod[0] != '\0') ? g_bootMod
                             : (envMod && envMod[0] ? envMod : NULL);
        if (modSel != NULL) {
            char fsGameCmd[96];
            snprintf(fsGameCmd, sizeof(fsGameCmd), " +set fs_game %s", modSel);
            Q_strcat(cmdline, sizeof(cmdline), fsGameCmd);
            NSLog(@"[Q3-INIT] mod-active: fs_game=%s (cgame native will be skipped)", modSel);
        }
    }
    NSLog(@"[Q3-INIT] calling Com_Init cmdline='%s'", cmdline);
    Com_Init(cmdline);
    NSLog(@"[Q3-INIT] Com_Init returned");
    if (matchProfile) {
        Cvar_Set("com_maxfps", "25");
        Cvar_Set("com_maxfpsUnfocused", "25");
    } else {
        /* com_maxfps 250 — Q3 "blessed" jump-physics value (msec=4 exactly,
         * 1000/250 = 4 ms). Was 125 (also blessed) but we never benefit
         * from sub-display-refresh caps and 125 gated the engine BEFORE
         * the ProMotion display gated. With 250 the engine pumps until
         * CADisplayLink fires, giving us the real GPU-bound frame rate
         * shown by cg_drawFPS — useful for MetalFX quality A/B perf
         * comparisons. (On the simulator the Mac host display still caps
         * at 60 Hz regardless — that's CoreAnimation architecture, not
         * Q3's gate.) */
        Cvar_Set("com_maxfps", "250");
        Cvar_Set("com_maxfpsUnfocused", "250");
    }

    /* Register the statically-linked native cgame so VM_Create (called
     * from CL_InitCGame on map load) resolves to our in-binary cgame
     * instead of loading baseq3/pak8.pk3's cgame.qvm. Kills the QVM
     * ABI mismatch that's been driving every workaround commit (head
     * hide, weapons2 hide, fallback camera, synthetic viewmodel). */
    NSLog(@"[Q3-INIT] registering native cgame");
    {
        extern vmMainFunc_t CG_Native_GetEntryPoint(void);
        extern dllEntry_t   CG_Native_GetDllEntry(void);
        VM_RegisterNative("cgame", CG_Native_GetEntryPoint(), CG_Native_GetDllEntry());
    }
    NSLog(@"[Q3-INIT] cgame registered; calling IN_Init");

    /* Q3's stock client (sdl_input.c / linux_glimp.c) is NOT linked on
     * iOS — only our ios_main.m defines IN_Init, and nothing in the
     * engine was calling it. Result: PAD0_* binds never ran and
     * controller buttons produced SE_KEY events that hit no bindings.
     * Call it explicitly here, after Com_Init so the cvar and command
     * subsystems are up. */
    IN_Init();
    NSLog(@"[Q3-INIT] IN_Init returned; queuing boot cbuf");
    /* Normal simulator/device runs use native landscape pixels. The old
     * fixed capture sizes are still available through Q3_MATCH_PROFILE so
     * reference-video diffs remain deterministic when needed. */
    /* MetalFX upscale render-res override (Swift launcher picker): when
     * g_renderResW/H were set via Q3_SetRenderResolution() before this
     * function ran, use them as Q3's logical render resolution. Swift's
     * MetalView Coordinator will create an offscreen RT at the same size,
     * run all Q3 drawing into it, then MTLFXSpatialScaler-upscales the
     * RT into the drawable for present. Drawable size stays at the
     * existing iPhone/iPad target — only Q3's internal viewport, depth,
     * + projection math shrink. Native quality keeps the existing path. */
    char resCmds[96];
    if (matchProfile) {
        snprintf(resCmds, sizeof(resCmds), "seta r_customwidth %d; seta r_customheight %d; ", matchWidth, matchHeight);
    } else if (g_renderResW > 0 && g_renderResH > 0) {
        snprintf(resCmds, sizeof(resCmds), "seta r_customwidth %d; seta r_customheight %d; ", g_renderResW, g_renderResH);
        NSLog(@"[Q3-INIT] upscale-override: r_customwidth=%d r_customheight=%d (was native %dx%d)",
              g_renderResW, g_renderResH, nativeWidth, nativeHeight);
    } else {
        snprintf(resCmds, sizeof(resCmds), "seta r_customwidth %d; seta r_customheight %d; ", nativeWidth, nativeHeight);
    }
    NSLog(@"[Q3-INIT] resolution: %s", resCmds);
    Cbuf_AddText(resCmds);
    Cbuf_AddText("seta r_mode -1; ");
    Cbuf_AddText(matchProfile
                 ? "seta r_fullscreen 1; "
                 : "seta r_fullscreen 0; ");
    Cbuf_AddText(
        /* HUD + 2D elements ON (2026-06-02). The previous draw2D 0 +
         * crosshair 0 state was for matching reference AVI captures so
         * the captured frame would be HUD-free. Normal play wants:
         *   cg_draw2D 1   — health/armor/ammo counters, powerup icons,
         *                   weapon icon, scoreboard, lag-o-meter, hit
         *                   markers, mini-map (where supported). All
         *                   the 2D bottom-of-screen UI.
         *   cg_drawCrosshair 4 — Q3 stock default crosshair (numeric
         *                        values 1-10 are different styles).
         *                        4 is the canonical "plus sign with
         *                        small open gap" — most readable.
         *   cg_drawCrosshairHealth 1 — colour the crosshair by player
         *                              health (canonical Q3 behaviour;
         *                              the visual hint that you're low).
         *   cg_drawStatus 1 — armor/health/ammo numeric panel.
         *   cg_draw3dIcons 1 — rotating weapon/powerup icons on HUD.
         *   cg_drawTeamOverlay 1 — team-mate status (CTF / team games).
         *   cg_drawTimer 1 — match timer (frag count / time remaining).
         *   cg_drawFPS 1 — display FPS counter top-right (useful for
         *                  perf verification of async-tex / deformBulge /
         *                  postprocess passes). Toggle off later if you
         *                  want a clean look. */
        /* PBR Phase 1: OFF for pure-vanilla baseline lockdown. The
         * PBR table includes rtx_player_* entries that substitute HD
         * normal/emissive/metallic on the player models — which gives
         * bots a "new model" look even with vanilla pak0..pak8 only.
         * Re-enable (flip to "1") once the vanilla baseline is signed
         * off and we know what's being replaced. */
        "seta r_pbrMaterials 0; "
        "seta cg_draw2D 1; "
        "seta cg_drawGun 1; "
        "seta cg_drawCrosshair 4; "
        "seta cg_drawCrosshairHealth 1; "
        "seta cg_drawStatus 1; "
        /* cg_draw3dIcons OFF (2026-06-02): the 3D-rotating player head /
         * weapon icon HUD widget uses a render-to-texture sub-scene that
         * our Metal pipeline doesn't handle correctly — the sarge head
         * comes out as a garbled mess. 2D fallback icons render via the
         * normal pic pipeline and look clean. Re-enable once the sub-
         * scene render path is fixed (3D icon uses cg.refdef.x/y/width/
         * height on a tiny portion of the framebuffer; needs viewport +
         * scissor + render-pass handling at the MTKView coordinator). */
        "seta cg_draw3dIcons 0; "
        /* cg_drawTeamOverlay OFF — only meaningful in team games
         * (CTF, Team DM). Single-player demos show a confusing
         * partial-data widget at bottom-right (the "20 / 0" the user
         * noticed). */
        "seta cg_drawTeamOverlay 0; "
        /* cg_drawTimer OFF — match timer is for live matches; on demo
         * playback it just shows the recorded demo's elapsed time which
         * jumps strangely as the demo seeks. Re-enable in live play. */
        "seta cg_drawTimer 0; "
        /* cg_drawFPS ON (re-enabled after cg_draw.c patch). The stock
         * Q3 right-edge anchor (`635 - w`) clipped the "fps" suffix on
         * 2.16:1 widescreen — we patched CG_DrawFPS in code/cgame/cg_draw.c
         * to anchor TOP-LEFT (virtual x=5) instead. Now visible on every
         * aspect ratio and lands in the captured AVI alongside the
         * MetalFX-upscaled scene, so the four quality-level recordings
         * (Native/High/Medium/Low) can be A/B'd by FPS visually. */
        "seta cg_drawFPS 1; "
        /* Force wall marks ON so blood/bullet/shadow decals submit
         * via trap_R_AddPolyToScene → RE_AddPolyToScene. */
        "seta cg_marks 1; "
        "seta cg_brassTime 2500; "
        /* PURE 1999 VANILLA seta values — must match the cmdline +set
         * block above. PBR-baseline lockdown: anything that "polishes"
         * the look gets reset to stock Q3 1.32 default. Flip back to
         * picmip 0 + gamma 1.25 + intensity 1.0 + LINEAR_NEAREST etc.
         * once PBR Phase 1 is signed off. */
        "seta r_picmip 1; "
        "seta r_textureMode GL_LINEAR_MIPMAP_NEAREST; "
        "seta r_texturebits 32; "
        "seta r_colorbits 32; "
        "seta r_depthbits 24; "
        "seta r_overBrightBits 1; "
        "seta r_mapOverBrightBits 2; "
        "seta r_gamma 1.0; "
        "seta r_intensity 1.0; "
        "seta r_mapGreyScale 0; "
        "seta r_ignorehwgamma 1; "
        /* Widescreen FOV — see cmdline comment above. 95 = compromise
         * value chosen because this fork has no cg_gunFov separator. */
        "seta cg_fov 95; "
        "seta cg_zoomfov 22; "
        /* Max-quality geometry — mirrors the cmdline +set block above
         * so the values land in q3config.cfg on writeconfig. */
        "seta r_subdivisions 4; "
        "seta r_lodbias 0; "
        "seta r_dynamiclight 1; "
        "seta metal_render_audit 0; "
        "seta metal_cgame_instr 0; "
        "seta r_swapinterval 0; "
        /* Disable sound so the AVI muxer skips the audio stream (our
         * sim build doesn't wire up CoreAudio — dma.speed stays 0,
         * which ffprobe rejects as Invalid sample rate). */
        "seta s_initsound 0; "
        /* Notify area off: obituary kill-feed and engine diagnostic
         * spam both route through Com_Printf, so we can't show one
         * without the other. Losing obituary-text parity with the
         * reference capture (small top-left region only) in exchange
         * for clean frames with no `[cgame syscalls] / Metal scene
         * frame:` spam dominating the top of every frame. Follow-up:
         * gate engine Com_Printf spam behind !CL_VideoRecording so
         * obituary can coexist cleanly. */
        "seta con_notifytime 0; "
        /* Full demo-four AVI capture. 180 frame warmup @ 60fps = 3s for
         * the demo to reach gameplay state. 3600 frame record = 60s,
         * matching the reference's ~1497 frames at 25fps. Path:
         * ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/
         * Containers/Data/Application/<UUID>/Documents/baseq3/videos/
         * four.avi. */
        /* Give the demo + map load ~2s of engine time to produce a
         * rendered scene before video starts. 1500 frames = 60s of
         * demo at 25fps — full demo four coverage. */
        /* `test_menu_assets` exercises a curated list of known menu/UI/
         * HUD shaders BEFORE the demo runs so [asset-miss] captures
         * cover the menu-render path that the demo path skips. Cheap
         * (~50 RegisterShader calls); does not affect the demo
         * playback or AVI capture. */
        "test_menu_assets\n");
    Cbuf_AddText(matchProfile
                 ? "seta com_maxfps 25; seta com_maxfpsUnfocused 25; "
                 : "seta com_maxfps 120; seta com_maxfpsUnfocused 120; ");

    /* MAX GRAPHICS — applied only in normal play (skipped when a
     * reference-video Q3_MATCH_PROFILE capture is active so the AVI
     * remains bit-identical to prior CI captures). Wins the cvar set
     * race against default.cfg + q3config.cfg because Cbuf_AddText
     * runs after both have loaded. User can still override any of
     * these via the in-game console (~ key) or by writing q3config.cfg.
     *
     * Geometry — finer bezier patch subdivisions (Q3 default 80!)
     *   r_subdivisions 4    -> ~20x more triangles on curved surfaces
     *   r_lodbias    -2     -> never drop LOD on alias models / patches
     *   r_lodCurveError    -> hold patch detail at distance
     * Textures — disable mip downscale, force trilinear, kill DXT
     * compression for crisp world art; max anisotropy if the Metal
     * stub honours it.
     * Lighting / shadows — keep stencil shadows (cg_shadows 3),
     * full dynamic lights, lightmaps (not vertex lighting), keep the
     * existing OLED midtone lift via r_gamma 1.15.
     * Effects — sun shafts, mark decals, lingering shell brass.
     * No FPS cap — iPhone 17 Pro Max ProMotion floor handled
     * separately in MetalView. */
    if (!matchProfile) {
        Cbuf_AddText(
            "seta r_picmip 0; "
            "seta r_skymip 0; "
            "seta r_roundImagesDown 0; "
            "seta r_textureMode GL_LINEAR_MIPMAP_LINEAR; "
            "seta r_ext_compress_textures 0; "
            "seta r_detailtextures 1; "
            "seta r_ext_texture_filter_anisotropic 1; "
            "seta r_ext_max_anisotropy 16; "
            "seta r_subdivisions 4; "
            "seta r_lodbias -2; "
            "seta r_lodCurveError 10000; "
            "seta r_lodscale 5; "
            "seta r_vertexLight 0; "
            "seta cg_shadows 3; "
            "seta cg_marks 1; "
            "seta cg_brassTime 10000; "
            "seta cg_simpleItems 0; "
            "seta r_drawSun 1; "
            "seta r_fastsky 0; "
            "seta r_finish 0; "
            "seta cl_maxpackets 100; "
        );
    }
    /* The actual launch command (e.g. "demo four", "map q3dm6", or
     * a custom demo from the SwiftUI launch menu) is queued from the
     * Swift app shell after Quake3_Init returns, via Q3Exec_Command.
     * That keeps Scope-A demo selection menu-driven without a recompile
     * for each demo. q3dev_run.sh capture flow can still record a demo
     * by tapping the matching button in the launch menu (or by issuing
     * `demo four; wait 50; video four; wait 1500; stopvideo; quit`
     * via Q3Exec_Command directly during a CI capture). */
    engine_initialized = qtrue;
    NSLog(@"[Q3-INIT] engine_initialized = qtrue; returning from Quake3_Init");

    Com_Printf("=== Quake3 iOS Engine Initialized ===\n");
}

void Quake3_Frame(void) {
    if (!engine_initialized) return;
    IN_Frame();
    Com_Frame(qfalse);
}

/* Pre-engine-init mod selection. Swift calls Q3_SetBootMod("cpma") before
 * Quake3_Init() so we can inject `+set fs_game cpma` into the cmdline →
 * Com_Init's FS_Startup reads that and adds <basepath>/cpma/*.pk3 to the
 * search path BEFORE pak loading. VM_FindNative (qcommon/vm.c) was patched
 * to skip the registered native cgame when fs_game points at a mod, so
 * cgame.qvm / qagame.qvm / ui.qvm from the mod's pk3s load via the
 * AArch64 JIT path (qagame + ui already use this path on every map).
 *
 * Empty / NULL / "baseq3" = vanilla (uses the native cgame).
 * g_bootMod buffer declared at file scope (top of file). */

void Q3_SetBootMod(const char *modname) {
    if (modname == NULL || modname[0] == '\0' ||
        !strcasecmp(modname, "baseq3")) {
        g_bootMod[0] = '\0';
        NSLog(@"[Q3-BOOT-MOD] cleared (vanilla baseq3)");
        return;
    }
    /* Allow only [A-Za-z0-9_-] in mod folder names; reject anything that
     * could escape the fs_game value into the cmdline (semicolons, spaces,
     * quotes). Mods like cpma / osp / excessiveplus are all safe. */
    {
        size_t i;
        for (i = 0; modname[i] && i < sizeof(g_bootMod) - 1; ++i) {
            char c = modname[i];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-')) {
                NSLog(@"[Q3-BOOT-MOD] reject (bad char in '%s')", modname);
                g_bootMod[0] = '\0';
                return;
            }
            g_bootMod[i] = c;
        }
        g_bootMod[i] = '\0';
    }
    NSLog(@"[Q3-BOOT-MOD] set to '%s'", g_bootMod);
}

/* Pre-engine-init render-resolution override (driven by Swift's MetalFX
 * upscale quality picker). Called BEFORE Quake3_Init. Pass 0/0 to leave
 * the default native-target sizing intact (Native quality). Otherwise
 * inject into cmdline as r_customwidth/r_customheight so Q3's projection
 * + viewport math match the offscreen RT Swift will render into. Sub-
 * pixel sizes are clamped to [320, 7680] each axis as a sanity guard. */
void Q3_SetRenderResolution(int w, int h) {
    if (w <= 0 || h <= 0) {
        g_renderResW = 0;
        g_renderResH = 0;
        NSLog(@"[Q3-UPSCALE] cleared (use default native res)");
        return;
    }
    if (w < 320) w = 320;
    if (h < 240) h = 240;
    if (w > 7680) w = 7680;
    if (h > 4320) h = 4320;
    g_renderResW = w;
    g_renderResH = h;
    NSLog(@"[Q3-UPSCALE] render res = %dx%d", g_renderResW, g_renderResH);
}

/* Execute an arbitrary Q3 command string from Swift. Used by the
 * on-screen console overlay so the user can type cvars/commands when
 * no physical keyboard is attached. Appends a trailing newline if the
 * caller didn't include one, since Cbuf_AddText is line-delimited. */
void Q3Exec_Command(const char *cmd) {
    char buf[1024];
    size_t len;
    if (!engine_initialized || cmd == NULL || cmd[0] == '\0') return;
    len = strlen(cmd);
    if (len >= sizeof(buf) - 2) len = sizeof(buf) - 2;
    memcpy(buf, cmd, len);
    if (len == 0 || buf[len - 1] != '\n') {
        buf[len++] = '\n';
    }
    buf[len] = '\0';
    Cbuf_AddText(buf);
    Cbuf_Execute();
}

/* Hardware keyboard / trackpad input bridges. Called from
 * Q3InputView (MetalView.swift) on the main thread; Sys_QueEvent's
 * ring buffer is single-thread-safe and Com_Frame drains it during
 * the next MTKView draw tick — no extra synchronization needed. */
void Q3Sys_KeyEvent(int q3Key, int down) {
    if (!engine_initialized) return;
    Sys_QueEvent(0, SE_KEY, q3Key, down ? qtrue : qfalse, 0, NULL);
}

void Q3Sys_MouseMove(int dx, int dy) {
    if (!engine_initialized) return;
    if (dx == 0 && dy == 0) return;
    Sys_QueEvent(0, SE_MOUSE, dx, dy, 0, NULL);
}

/* Console / menu text-input bridge. Q3 has TWO event paths for the
 * keyboard: SE_KEY drives bind execution and editing controls
 * (arrows/backspace/enter/esc); SE_CHAR drives the actual character
 * insertion into the console line, player-name field, cvar-value
 * field, etc. Without SE_CHAR, the user can press W/A/S/D and walk
 * around but can't type their name or a cvar value. We still need
 * SE_KEY for the same physical keypress (so bind 'a' "+moveleft"
 * keeps working); fire both. */
void Q3Sys_CharEvent(int ch) {
    if (!engine_initialized) return;
    if (ch <= 0) return;
    Sys_QueEvent(0, SE_CHAR, ch, 0, 0, NULL);
}
