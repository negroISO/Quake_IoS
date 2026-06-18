# Fixes

## PBR SIGSEGV — Dangling material pointers after vid_restart

**Symptom:** `EXC_BAD_ACCESS` at `_platform_strlen + 4` inside `pbrAlbedoTexture(for:)` → `String(cString: albedoCStr)`. The `guard let` nil-check passed but the pointer was freed.

**Root cause:** `q3_pbr_free_table()` freed `g_materials[]` and all material strings, but `metalTexture_t.pbrMaterial` pointers in the texture table still referenced freed entries. On `vid_restart`, `GetRefAPI` reloaded the PBR table (freeing the old one first) while Swift's render loop still held handles referencing old material data.

**Why:** The `q3_pbr.h` API promised "Strings remain valid for the process lifetime" but the implementation freed them on every `q3_pbr_table_load` call.

**Fix (2026-06-15):**
1. `q3_pbr.c:q3_pbr_free_table()` — removed all `free()` calls for material data. Now only NULLs container pointers. Old table leaks ~1.4 MB on vid_restart but pointers stay valid.
2. `metal_renderer_stub.c` — `UpdatePathField()` strdups path strings in both `Q3MetalRenderer_GetPBRMaterial` and `GetPBRMaterialByName`, so the static `s_paths` owns independent copies.
3. `q3_pbr.c` — Added missing `str_arena_dup` forward declaration (build error fix).

**Files:** `code/ios/q3_pbr.c`, `code/ios/metal_renderer_stub.c`
