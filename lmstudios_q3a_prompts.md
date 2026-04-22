# LMStudio verification prompts — Quake 3 iOS Metal parity

Append-only. Each entry = a deterministic YES/NO (or short-factual) prompt
that produced a verified correct answer, tagged by category.

---

## [VERIFY_PIPELINE] tcMod rotate sign convention
> In ioquake3 function RB_CalcRotateTexCoords in tr_shade_calc.c, the first
> statement is `degs = -degsPerSecond * timeScale`. Given that upstream
> tcmod directive `tcmod rotate 30` passes degsPerSecond=30 (positive), is
> the resulting rotation CLOCKWISE in texture-space (as opposed to
> counter-clockwise)? Answer YES or NO and state whether the negative sign
> in degs produces clockwise rotation.

Gemma-4-31B: **YES. The negative sign results in a clockwise rotation of
the texture coordinates over time.**

## [VERIFY_PIPELINE] tcMod scroll applied as direct addition
> In ioquake3 RB_CalcScrollTexCoords (tr_shade_calc.c), the per-vertex
> update is `dst[0] = src[0] + adjustedScrollS` and `dst[1] = src[1] +
> adjustedScrollT` where adjustedScrollS/T = scrollSpeed[0/1] * timeScale
> (modulo 1 for overflow safety). So scrolling is applied as a direct
> ADDITION of (speed * time) to the source UV, with NO negation. YES/NO.

Gemma-4-31B: **YES. The code adds the calculated scroll offset directly to
the source texture coordinates.**

## [VERIFY_PIPELINE] alphaFunc pass/fail semantics
> In ioquake3 tr_backend.c line ~358, the GLS_ATEST_* state bits map to
> OpenGL alphaFunc calls: GLS_ATEST_GT_0 → qglAlphaFunc(GL_GREATER, 0.0),
> GLS_ATEST_LT_80 → qglAlphaFunc(GL_LESS, 0.5), GLS_ATEST_GE_80 →
> qglAlphaFunc(GL_GEQUAL, 0.5). Under GL_GREATER ref=0, a fragment PASSES
> only when its alpha is strictly greater than 0 (so it is killed when
> alpha==0). Under GL_LESS ref=0.5, a fragment PASSES only when its alpha
> is strictly less than 0.5. Is this description of the upstream
> passing-vs-killed semantics correct? YES/NO.

Gemma-4-31B: **YES. The OpenGL glAlphaFunc specification dictates that
fragments are passed if they satisfy the specified comparison against the
reference value and discarded otherwise.**

## [VERIFY_PIPELINE] tcMod scale is pure component-wise multiply
> In ioquake3 RB_CalcScaleTexCoords (tr_shade_calc.c), the per-vertex
> operation is `dst[0] = src[0] * scale[0]` and `dst[1] = src[1] *
> scale[1]` — pure component-wise multiplication with NO time dependency.
> Answer YES or NO.

Gemma-4-31B: **YES. The function performs a simple component-wise
multiplication of the source coordinates by the scale factors.**

## [VERIFY_PIPELINE] tcMod stretch is center-zoom by 1/EvalWave
> In ioquake3 RB_CalcStretchTexCoords (tr_shade_calc.c), the
> implementation sets `p = 1 / EvalWaveForm(wf)` then builds a
> texModInfo with matrix={{p,0},{0,p}} and translate={0.5-0.5*p,
> 0.5-0.5*p}, then calls RB_CalcTransformTexCoords. This is equivalent
> to: `dst = (src - 0.5) * p + 0.5` — a zoom about the texture center
> by factor p. For a GF_SIN wave with base B, amplitude A, phase P,
> frequency F, EvalWaveForm returns B + sin(2π*(P + t*F)) * A where
> t = tess.shaderTime. Is this math description accurate? YES/NO.

Gemma-4-31B: **YES. The described transformation and waveform
evaluation accurately reflect the implementation in tr_shade_calc.c.**

## [VERIFY_PIPELINE] tcMod turb uses world-space domain
> In ioquake3 RB_CalcTurbulentTexCoords, the per-vertex formula reduces
> to: `dst[0] = src[0] + sin(2π*((xyz[0]+xyz[2]) / 1024 + phase + t*freq))
> * amp` and `dst[1] = src[1] + sin(2π*(xyz[1] / 1024 + phase + t*freq))
> * amp`, where t = tess.shaderTime, and 1024 comes from `1.0/128 *
> 0.125 = 1/1024`. Note: the domain uses WORLD-SPACE xyz (tess.xyz),
> NOT UV coordinates. Is this reduction correct? YES/NO.

Gemma-4-31B: **YES. The calculation uses world-space positions scaled
by a constant factor and offset by time and phase to perturb texture
coordinates.**

## [VERIFY_SHADER] CGEN_IDENTITY sets full-white per-vertex color
> In ioquake3 tr_shade.c RB_IterateStagesGeneric, the CGEN_IDENTITY
> case does `Com_Memset(tess.svars.colors, 0xff, tess.numVertexes *
> 4)` — setting all per-vertex RGBA bytes to 0xff, which is equivalent
> to each vertex color being (1.0, 1.0, 1.0, 1.0). So a shader stage
> with `rgbGen identity` outputs vertex colors that, when multiplied
> with the texel, leave the texel unchanged (full-bright). YES/NO.

Gemma-4-31B: **YES. The memset to 0xff sets all RGBA components to
maximum value, resulting in a multiplicative identity for the texture
color.**

## [VERIFY_SHADER] AGEN_IDENTITY forces opaque alpha
> In ioquake3 tr_shade.c RB_IterateStagesGeneric, the AGEN_IDENTITY
> case sets tess.svars.colors[i].rgba[3] = 255 for every vertex —
> forcing the alpha channel to full 1.0, regardless of whatever alpha
> was in the vertex color. So a stage declaring `alphaGen identity`
> outputs fully opaque alpha irrespective of the per-vertex alpha
> input. YES/NO.

Gemma-4-31B: **YES. The code explicitly assigns 255 to the alpha
component, overriding any existing vertex alpha data.**

## [VERIFY_SHADER] RB_CalcWaveColor outputs grayscale brightness
> In ioquake3 tr_shade_calc.c RB_CalcWaveColor, for the GF_SIN
> waveform the implementation computes `glow = EvalWaveForm(wf) *
> tr.identityLight` where EvalWaveForm returns `base + sin(2π*(phase
> + t*freq)) * amplitude` for GF_SIN. It then clamps `v = myftol(255
> * glow)` to [0, 255] and writes rgb = (v, v, v) and alpha = 255
> into the per-vertex color. So the output is a GRAYSCALE brightness
> multiplier applied to all three rgb channels. YES/NO.

Gemma-4-31B: **YES. The implementation calculates a single scalar
glow value that is applied uniformly to the red, green, and blue
components of the vertex color.**

## [VERIFY_SHADER] RB_CalcWaveAlpha uses EvalWaveFormClamped
> In ioquake3 RB_CalcWaveAlpha (tr_shade_calc.c line 714), glow =
> EvalWaveFormClamped(wf); v = 255 * glow; then for every vertex
> dstColors[3] = v. EvalWaveFormClamped is EvalWaveForm clamped to
> [0,1]. So the output is: alpha = clamp(base + sin(2π*(phase +
> t*freq)) * amp, 0, 1) for GF_SIN. YES/NO.

Gemma-4-31B: **YES. The function EvalWaveFormClamped applies a clamp
to the result of EvalWaveForm, ensuring the output is within the
[0, 1] range.**
