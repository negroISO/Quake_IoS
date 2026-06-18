# Patch note for Codex — atlas/animation directive status (2026-06-11)

Directive items 1 (FX atlas override in `worldTextureSelectionForPBRDebug`) and
5 (RT kernel atlas remap via `RTPrimitiveMaterial.spriteAtlasParams`) were
already landed by Codex — verified present and correct. Items 3 and 4 were
applied by Claude directly; build SUCCEEDED (dylib 2026-06-11 12:34). Diffs:

## rgbConstColor passthrough (both world uniform sites)

```diff
- rgbConstColor: SIMD4(1, 1, 1, 1),
+ rgbConstColor: SIMD4(stage.rgbConstColor.0,
+                      stage.rgbConstColor.1,
+                      stage.rgbConstColor.2,
+                      stage.alphaConst),
```
Applied at the non-batched site (~7120) and the batched site (~7689; its TODO
claiming Q3MetalWorldStage lacks the field was stale — `metal_renderer_shared.h`
lines 168–169 carry `rgbConstColor[3]` + `alphaConst`, filled by stub.c
1250–1252 gated on rgbGen==4).

## One-shot atlas log poisoning

```diff
- private func pbrSpriteAtlasParams(for handle: UInt32, atlasTime: Float) -> SIMD4<Float> {
+ private func pbrSpriteAtlasParams(for handle: UInt32, atlasTime: Float,
+                                   logEnabled: Bool = true) -> SIMD4<Float> {
```
Both log blocks (generic + launchpad_diamond targeted) now gate on
`logEnabled`; the RT prepass call in `buildRTPrimitiveMaterials` passes
`logEnabled: false` so `world-atlas params` lines show real atlasTime.

## envCube cache item from the earlier diagnosis: DROPPED
Grey-change + stem-change invalidation already exist (`ensurePBREnvCube`,
~6056–6092) with device-log proof. Do not re-implement.

## Verify on device
- q3dm17 launchpad / q3dm0 jump pads animate in raster and `r_rt_mix 1`.
- `grep "world-atlas params" q3_diag.log` → nonzero atlasTime.
- Const-tint stages (rgbGen const) no longer white.
