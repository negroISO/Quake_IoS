/*
===========================================================================
cg_native.c — native-link shim for cgame on iOS.

This file is only compiled when CGAME_NATIVE is defined (the Xcode target
passes -DCGAME_NATIVE for every cgame translation unit). It provides the
external entry points the engine's VM_Create uses to locate the statically-
linked cgame module, plus the file-static `syscall` function pointer the
renamed cgame references via cg_local.h.

Why: cgame, qagame, and ui each define their own `vmMain`, `dllEntry`, and
file-static `syscall`. When all three are linked into the same binary (iOS
app target) those symbols collide. cg_local.h's CGAME_NATIVE-guarded
#defines rename the cgame originals to CG_vmMain / CG_dllEntry / CG_syscall,
and this file re-exposes them under stable extern names that the engine's
platform init (ios_main.m) can pass to VM_RegisterNative("cgame", ...).
===========================================================================
*/

#include "../qcommon/q_shared.h"
#include "../qcommon/qcommon.h"
#include "cg_public.h"

/* After the cg_local.h rename macros, the imported cgame's vmMain and
 * dllEntry emit as CG_vmMain and CG_dllEntry. Declare them extern here
 * so the engine can take their addresses without pulling in cg_local.h
 * (which has a mountain of cgame-internal types). */
extern intptr_t CG_vmMain( int command, int arg0, int arg1, int arg2,
                           int arg3, int arg4, int arg5, int arg6,
                           int arg7, int arg8, int arg9, int arg10,
                           int arg11 );
extern void CG_dllEntry( intptr_t ( QDECL *syscallptr )( intptr_t arg, ... ) );

/* Thin accessors the engine platform init uses to avoid taking function-
 * pointer addresses directly across translation-unit boundaries. */
vmMainFunc_t CG_Native_GetEntryPoint( void ) {
    return (vmMainFunc_t)CG_vmMain;
}

dllEntry_t CG_Native_GetDllEntry( void ) {
    return (dllEntry_t)CG_dllEntry;
}
