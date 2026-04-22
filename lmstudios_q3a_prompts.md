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
