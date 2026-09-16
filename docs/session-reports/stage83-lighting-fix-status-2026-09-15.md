# Stage-83 viewmodel lighting fix — landed-status record (2026-09-15)

Supervisor source review, session of 2026-09-15. Approved by user as a
surgical docs-only correction; CLAUDE.md is intentionally untracked
(commit `57bb26a0`, "local only"), so this tracked report is the durable
record. The matching surgical edit was applied to the local CLAUDE.md.

## Finding

The Stage-83 diagnosed defect — `q3_entity_fragment`'s PBR branch
discarding the Q3 lightgrid/`applyDlights` diffuse via a bare
`base.rgb = iblTerm + radiance;` assignment — is **already fixed**.

- **Fixing commit:** `fde9d961` "fix(entity): preserve Q3 lighting
  under the PBR viewmodel path" (2026-07-13 16:24:38 -0500)
- **Reviewed HEAD:** `6d19e11f` (2026-09-15) — `fde9d961` verified an
  ancestor (`git merge-base --is-ancestor`), 27 commits back
- **Source anchors:** `Quake3-iOS/MetalView.swift` — `q3LitBase`
  captured before the specular/IBL block (~line 3651, comment names
  "BSP lightgrid, authored/local dlights, fog"); additive restore
  `base.rgb = q3LitBase + radiance + localSpecular + iblTerm;`
  (~line 3757). No bare `base.rgb = iblTerm + radiance;` remains
  (grep-clean). Residual `kD`/`kD_v` sites (`:3047/3112/3141`) are the
  WORLD fragment env-fill path, not the entity viewmodel path.
- **Evidence:** supervisor review, session transcript 2026-09-15;
  `/Volumes/iOS/Quake_iOS27_Review_20260914/codex_viewmodel_geometry_run2.log`
  (Codex diagnostic run 2, 8,955 lines).

## Scope limits (explicit)

- This retires the **lighting-preservation implementation task only**.
- It is **not** a device-validation pass and not certification of the
  complete PBR lighting equation.
- The separate weapon-**geometry** question ("bent hoop") remains
  **NOT REPRODUCED** in the demo-four captures (raster and RT, device
  and Catalyst — 2×2 matrix, 2026-09-15); live-phone equivalence
  remains **UNCONFIRMED** pending user review of
  `~/Desktop/q3_review_clips/`.
- Deployed device-binary provenance: `com.quake3ios.rt` v1.0(1);
  console feature markers confirm it contains the July-13 RTTexTable
  (1120-texture, arg-encoder 8960 B) and Sept-14 MTLBinaryArchive
  features; exact source commit not byte-verified.
