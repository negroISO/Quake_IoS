// Pre-engine-init mod selection. Swift calls Q3_SetBootMod("cpma") before
// Quake3_Init() so we can inject `+set fs_game cpma` into the cmdline →
// Com_Init's FS_Startup reads that and adds <basepath>/cpma/*.pk3 to the
// search path BEFORE pak loading. VM_FindNative (qcommon/vm.c) was patched
// to skip the registered native cgame when fs_game points at a mod, so
// cgame.qvm / qagame.qvm / ui.qvm from the mod's pk3s load via the
// AArch64 JIT path (qagame + ui already use this path on every map).
