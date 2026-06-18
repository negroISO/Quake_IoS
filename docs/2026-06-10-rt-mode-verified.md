# RT mix mode verified on device — 2026-06-10 morning

## TL;DR

✅ The `force_opaque` fix shipped last night works. Q3_RT.app deployed to iPad Pro 13" M4 ("Oled", 937CF279-EC34-51CC-8FB6-A0B8C719B6E2), launched with `r_rt_mix 1`, played 20s of `q3dm11`. **Zero `[RT] library compile failed` lines.** Full RT pipeline came up:
- `[RT] rtKernel pipeline ready`
- `[RT] accumulateRT pipeline ready`
- `[RT] blendRT pipeline ready`
- `[RT] built world AS: vertices=61170 indices=122625 tris=40875 size=4479680` (4.3 MB)
- `[RT] material table: albedo=110/187 lightmap=16/26 assigned=40325/40875`
- `[RT] overlay active mix=1.0 trace=1032x774 scale=0.5 bounces=1`

22 RT-metrics frames captured over the run. Clean quit.

## Performance baseline (q3dm11, mix=1.0, full pipeline)

| Metric | Value |
|---|---|
| FPS (steady-state, frame 200+) | ~68 |
| Total frame ms | 14.7 |
| Engine (`q3Ms`) | 1.2 |
| CPU per-frame (`frameCpuMs`) | 1.6–2.9 |
| Encoder build (`encodeMs`) | 0.4–0.9 |
| Drawable acquire | <0.1 |
| **RT GPU command time** | **6.73 ms steady-state** (warmup frame 1: 14.84) |
| RT trace resolution | 1032 × 774 (½ composite) |
| RT composite resolution | 2064 × 1548 |
| RT bounces | 1 |
| TAA | disabled |

Logs archived: `docs/q3-logs/2026-06-10-rt-test-stdout.log` and `2026-06-10-rt-test-q3_diag.log`.

## What this unblocks

The user's morning gate was "if RT works, move to Phase 2". RT works. Phase 2 candidates the user listed:

### Option A — Pre-allocate `Q3.RT.primitiveMaterials`
Stub baseline: the material-table assignment log fires fast (`assigned=40325/40875`) but we don't know if the underlying `primitiveMaterials` buffer reallocates per frame or per map load. **Highest immediate value if reallocation is per-frame** — would directly cut CPU/encodeMs. Audit needs a quick grep + Instruments allocation trace.

### Option B — Coalesce two `Q3.render` encoders
Frame trace shows `encodeMs` ranging 0.39–0.88ms — modest. Coalescing two encoders could save ~0.3–0.5ms per frame if barriers between them are unnecessary. **Lower magnitude but cleaner refactor.**

### Option C — Audit 80+ suspicious JSON emissive paths
Pure content / asset workstream. **No perf impact** — fixes ugly emissive-overdrive bugs (where albedo or normal DDS was wrongly listed as the `emissive` path; the canonical-path guard in `pbrEmissiveTexture(for:)` already prevents the runtime overdrive). This is a data quality / RTX-Remix authoring fix.

### Independently: IBL register-pressure refactor
Still gated on opening `Q3_RT.gputrace` in Xcode → Shader Profiler → reading the **Register Allocation** field for `q3_world_fragment`. Without that number, refactor is speculative.

## Recommendation

**Option A first.** Encoder coalescing's upside is ~0.5ms; pre-alloc could save more if the per-frame allocation hypothesis is right, and it's the easiest to audit (grep `primitiveMaterials` and look at allocator call sites). Option C is asset work that should happen but doesn't move the perf needle. Option B is fine cleanup but probably not the next move.

For IBL: don't pursue until the `Q3_RT.gputrace` register count is read.

## Steps run this session

1. Built Q3_RT.app for device: `xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath build-device-rt build` → `** BUILD SUCCEEDED **` (no warnings).
2. Installed: `xcrun devicectl device install app --device 937CF279-... build-device-rt/Build/Products/Debug-iphoneos/Q3_RT.app`.
3. Launched with `Q3_LAUNCH_COMMAND="r_rt_mix 1; wait 200; demo q3dm11; wait 1200; quit"` for 60s.
4. Pulled `Documents/q3_diag.log` from `com.quake3ios.rt` sandbox.
5. Verified `grep -c "RT.*library compile failed" → 0`.

## Toolchain notes

`scripts/q3dev_run.sh` still hardcodes `BUNDLE_ID="com.quake3ios.app"` (the old non-RT build). To deploy Q3_RT it has to be done via `devicectl` directly as above, or the script needs a one-line `BUNDLE_ID` override (a `BUNDLE_ID="${BUNDLE_ID:-com.quake3ios.app}"` change would let `BUNDLE_ID=com.quake3ios.rt scripts/q3dev_run.sh` work). Same for `scripts/pull_q3_diag.sh`.

That's a 30-second cleanup if we end up running these often.
