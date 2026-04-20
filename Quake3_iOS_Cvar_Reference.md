# Quake3-iOS — Cvar & Command Reference

Consolidated reference for Quake 3 / Quake3e console variables (cvars) and commands, with iOS-Metal-port specifics called out alongside.

## Sources

The two URLs you shared are the canonical "community reference" sources for Q3 cvars, but both are blocked by this environment's network egress proxy and cannot be fetched directly:

- https://www.quakearea.com/blog/q3-cvars&cmds.html — blocked
- https://www.excessiveplus.net/forums/thread/commandcvar-list-of-e-quake?page=1 — blocked

Instead, the cvar descriptions below are drawn from **Quake3e PR #189** ([`ab804c42`](https://github.com/ec-/Quake3e/commit/ab804c42dc849a8e0720537d28f2f4aa21a322f8)), which the author of [Quake3e issue #188](https://github.com/ec-/Quake3e/issues/188) compiled specifically from those two community pages plus themuffinator's dm-engine fork. That PR is the closest thing to an authoritative, single-source list; using it avoids re-scraping the same pages.

Issue #188 summary: community request to describe every Quake3e cvar via `Cvar_SetDescription`. PR #189 landed descriptions for most of them; 18 cvars explicitly still undocumented at merge time (e.g. `cl_reconnectArgs`, `s_mixOffset`, `com_noErrorInterrupt`).

Engine-version coverage: this matches the Quake3e codebase Quake3-iOS is built on (`1.32e`, per the device log `Q3 1.32e macos-aarch64-debug Apr 16 2026`).

iOS-port relevance flags (third column of each table):

- **Active** — cvar works in the iOS Metal build.
- **N/A-GL** — OpenGL/driver-specific, dead code on iOS Metal. Keep for compat; do not expect an effect.
- **Host** — useful for desktop Quake3e but has no meaning on iOS (no window manager, SOCKS, headless dedicated, etc.).
- **Metal-only** — port-specific cvar added for this project; not in upstream Quake3e.

---

## Console / HUD

| Cvar | Description | iOS |
|---|---|---|
| `con_notifytime` | How long chat/system messages stay on screen (seconds). | Active |
| `con_conspeed` | Console open/close scroll speed. | Active |
| `con_autoclear` | Clear console input text when console is closed. | Active |
| `con_scale` | Console font size scale. | Active |
| `cl_conXOffset` | Console notifications X-offset. | Active |
| `cl_conColor` | Console background color, `R G B A` 0-255. | Active |

On iOS there is no physical keyboard by default — the on-screen `ConsoleOverlay` (`>_` tap-target, upper-left) feeds commands through `Q3Exec_Command` → `Cbuf_AddText` + `Cbuf_Execute`. All cvars below are settable from it.

---

## Client — input / movement

| Cvar | Description | iOS |
|---|---|---|
| `cl_nodelta` | Disable delta compression on uploaded user commands. | Active |
| `cl_debugMove` | Graph view-angle deltas (`1` yaw, `2` pitch). | Active |
| `cl_showSend` | Print client→server packet info. | Active |
| `cl_yawspeed` | Keyboard turn speed (`+left`/`+right`). | Active |
| `cl_pitchspeed` | Keyboard pitch speed (`+lookup`/`+lookdown`). | Active |
| `cl_anglespeedkey` | Speed modifier for direction keys. | Active |
| `cl_maxpackets` | Max packet upload rate to server. | Active |
| `cl_packetdup` | Duplicate-commands-per-packet limit. | Active |
| `cl_run` | Persistent player running movement. | Active |
| `cl_sensitivity` | Base mouse sensitivity. | Controller-equivalent (stick sensitivity) |
| `cl_mouseAccel` | Mouse acceleration on/off. | N/A (no mouse) |
| `cl_mouseAccelStyle` | Mouse acceleration style `0`/`1`. | N/A |
| `cl_mouseAccelOffset` | Mouse accel offset; requires `cl_mouseAccelStyle 1`. | N/A |
| `cl_showMouseRate` | Print mouse accel rate per frame. | N/A |
| `cl_freelook` | Allow mouse up/down look. | Active (stick) |
| `m_pitch` | Mouse pitch multiplier. | Stick-applicable |
| `m_yaw` | Mouse yaw multiplier. | Stick-applicable |
| `m_forward` | Mouse-forward movement multiplier. | N/A |
| `m_side` | Mouse strafe multiplier. | N/A |
| `m_filter` | Mouse smoothing. | N/A |

Game-controller note: controller input pipeline is documented in `CLAUDE.md` — `Q3_PAD_*` bitmask in `code/ios/ios_local.h`, diffed each frame in `IN_Frame`. Binds (`bind PAD0_A …`) are installed synchronously via `Cbuf_AddText` + `Cbuf_Execute` in `IN_Init`. Do not use `Cbuf_ExecuteText(EXEC_NOW, ...)` for multi-line bind blocks — halts at first newline.

---

## Networking

| Cvar | Description | iOS |
|---|---|---|
| `cl_timeout` | Client disconnect after N seconds of no traffic. | Active |
| `cl_autoNudge` | Auto time-nudge using median ping (`0` = use fixed `cl_timeNudge`). | Active |
| `cl_timeNudge` | Adds/removes latency for smoothness vs. responsiveness. | Active |
| `cl_shownet` | Display current network status. | Active |
| `cl_showTimeDelta` | Print per-packet server-update time delta. | Active |
| `cl_packetdelay` | Artificial client-side packet delay (simulates loss). | Active |
| `sv_packetdelay` | Server-side simulated packet delay. | Active (when hosting) |
| `rcon_client_password` | Remote-console password for `rcon` commands. | Active |
| `rconAddress` | IP address of remote console to connect to. | Active |
| `cl_serverStatusResendTime` | Server-status resend interval, ms. | Active |
| `cl_maxPing` | Maximum allowed ping to server in browser. | Active |
| `cl_motd` | Toggle Message-Of-The-Day display. | Active |
| `cl_motdString` | MOTD string from master server (read-only). | Active |
| `cl_guidServerUniq` | Make `cl_guid` unique per server. | Active |
| `cl_dlURL` | Download URL (for `cl_allowDownload` HTTP/FTP). | Active |
| `cl_allowDownload` | Bitmask: `1` enable, `2` no HTTP/FTP, `4` no UDP. | Active |
| `cl_mapAutoDownload` | Auto-download maps for play/demo. | Active |
| `cl_cURLLib` | Filename of cURL library to load. | N/A (static libcurl/no download) |
| `net_ip` | IPv4 bind interface. | Active |
| `net_port` | IPv4 port. | Active |
| `net_ip6` | IPv6 bind interface. | Active |
| `net_port6` | IPv6 port. | Active |
| `net_mcast6addr` | IPv6 multicast scan address. | Active |
| `net_mcast6iface` | IPv6 multicast outgoing interface. | Active |
| `qport` | Internal NAT port for multi-client on one IP. | Active |
| `net_socksEnabled` | SOCKS5 proxy enable (command line only). | Host |
| `net_socksServer` | SOCKS server address. | Host |
| `net_socksPort` | SOCKS port (default 1080). | Host |
| `net_socksUsername` | SOCKS username (RFC-1929). | Host |
| `net_socksPassword` | SOCKS password. | Host |
| `net_dropsim` | Simulate packet drops. | Active |
| `showpackets` | Toggle all-packet info. | Active |
| `showdrop` | Toggle dropped-packet info. | Active |

---

## Renderer — video mode / GL driver (mostly N/A on Metal)

Every `r_` cvar below is inherited from the upstream OpenGL renderer. The iOS build uses a Metal renderer (`MetalView.swift`) — the GL/driver cvars have no effect. They are listed so you can identify which ones are dead on iOS before wiring up behavior or accepting bug reports.

| Cvar | Description | iOS |
|---|---|---|
| `r_allowSoftwareGL` | Use default software GL driver. | N/A-GL |
| `r_glDriver` | OpenGL driver name. | N/A-GL |
| `r_swapInterval` | V-sync (`0` off, `1` on). | N/A-GL (Metal VSync via `MTKView.preferredFramesPerSecond`) |
| `r_displayRefresh` | Override monitor refresh in fullscreen. | N/A |
| `vid_xpos` / `vid_ypos` | Windowed X/Y position. | N/A |
| `r_noborder` | Borderless windowed mode. | N/A |
| `r_mode` | Video mode index. | N/A |
| `r_modeFullscreen` | Dedicated fullscreen mode. | N/A |
| `r_fullscreen` | Fullscreen on/off. | N/A (always fullscreen) |
| `r_customPixelAspect` | Custom aspect ratio with `r_mode -1`. | N/A |
| `r_customwidth` / `r_customheight` | Custom resolution with `r_mode -1`. | N/A (drawable size from `MTKView`) |
| `r_colorbits` | Color bit depth (`0` desktop). | N/A (fixed `bgra8Unorm`) |
| `cl_stencilbits` | Stencil buffer bits. | N/A |
| `cl_depthbits` | Z-buffer precision. | N/A (fixed `depth32Float`) |
| `cl_drawBuffer` | `GL_FRONT` / `GL_BACK`. | N/A-GL |
| `cl_renderer` | Renderer plugin selection. | N/A (Metal only) |
| `r_ignorehwgamma` | Override hardware gamma. | N/A |
| `r_gamma` | Gamma correction. | N/A |

---

## Renderer — lighting & textures (partial Metal coverage)

| Cvar | Description | iOS |
|---|---|---|
| `r_fullbright` | Render level without lighting (debug). | Not wired — candidate for port |
| `r_overBrightBits` | Intensity of overall texture brightness. | Not currently applied (2x boost reverted in `ed461eb`) |
| `r_mapOverBrightBits` | Overbright baked into lightmaps. | N/A (lightmap baked as-is) |
| `r_intensity` | Global texture lighting scale. | Not wired |
| `r_singleShader` | Debug: render everything with default shader. | Not wired |
| `r_defaultImage` | Replace missing texture with file or `#rgb` color. | Not wired |
| `r_simpleMipMaps` | Simple vs. proper linear mipmap filter. | N/A-GL |
| `r_vertexLight` | Vertex lighting on world, no multi-texture. | N/A-GL |
| `r_picmip` | Texture downscale (quality). | Not wired |
| `r_nomip` | picmip only on worldspawn textures. | Not wired |
| `r_neatsky` | Mip sky textures. | Not wired |
| `r_roundImagesDown` | Round down on image scale. | N/A |
| `r_colorMipLevels` | Tint mip levels for debug. | Not wired |
| `r_detailTextures` | Enable `detail` shader stages. | Not wired (stage parser in place; detail flag not respected yet) |
| `r_texturebits` | Per-texture bit depth. | N/A |
| `r_mergeLightmaps` | Merge lightmaps into 2 giant ones. | Partial (single lightmap atlas path) |
| `r_vbo` | Vertex Buffer Objects for static geometry. | N/A-GL (Metal uses MTLBuffer by default) |
| `r_mapGreyScale` | Desaturate world textures (neg = lightmap only). | Not wired |
| `r_subdivisions` | Bezier subdivision distance. | Active (BSP patch tesselation) |
| `r_maxpolys` / `r_maxpolyverts` | Scene poly/vert caps. | Active (relevant to `RE_AddPolyToScene` pipeline) |
| `r_lodbias` | Model LOD level. | Not wired |
| `r_znear` / `r_zproj` | Near plane / projected frustum. | Active (applied in view matrix) |
| `r_stereoSeparation` | Eye separation for stereo. | N/A |
| `r_ignoreGLErrors` | Ignore GL errors. | N/A-GL |
| `r_fastsky` | Flat colored skies. | Not wired (cubemap/dome sky is always on) |
| `r_drawSun` | Draw sun shader in skies. | Not wired |
| `r_dynamiclight` | Enable dynamic lighting. | Not wired |
| `r_dlightMode` | `0` VQ3 fake / `1` per-pixel / `2` also MD3s. | Not wired |
| `r_dlightScale` | Dlight radius multiplier. | Not wired |
| `r_dlightSpecPower` | Specular from dlights. | Not wired |
| `r_dlightSpecColor` | Specular color base. | Not wired |
| `r_dlightIntensity` | Dlight intensity scale. | Not wired |
| `r_dlightBacks` | Dlight back-face culled geometry. | Not wired |
| `r_ambientScale` | Lightgrid ambient scale on entities. | Partial — see `kAmbientFloor=0.5f` floor in `SetupEntityLighting` |
| `r_directedScale` | Lightgrid directed scale on entities. | Applied via per-vertex Lambert (`ndotl`) in `RE_RenderScene` |
| `r_debugLight` | Print ambient/directed light info. | Not wired |
| `r_lightmap` | Show only lightmaps. | Partially covered by `worldDebugMode=2` (compile-time in `MetalView.swift`) |

---

## Renderer — advanced FX (Quake3e HD features)

All of these are Quake3e-specific, tied to its OpenGL 3.0 FBO pipeline (`r_fbo 1`). They are **not ported to the Metal backend** and setting them has no effect on iOS.

| Cvar | Description | iOS |
|---|---|---|
| `r_fbo` | Enable framebuffer objects (required for HDR/bloom/AA). | N/A-GL |
| `r_hdr` | HDR framebuffer (`-1` 4-bit test, `0` 8-bit, `1` 16-bit). | Candidate future work |
| `r_bloom` | Enable bloom post. | Candidate |
| `r_bloom_threshold` | Bloom extraction threshold (0.6 default). | Candidate |
| `r_bloom_threshold_mode` | `0` max-channel, `1` average, `2` luma. | Candidate |
| `r_bloom_intensity` | Final blend factor (0.5 default). | Candidate |
| `r_bloom_passes` | Downsample passes (5 default). | Candidate |
| `r_bloom_blend_base` | Topmost downsample to use. | Candidate |
| `r_bloom_modulate` | `0` off, `1` self-modulate, `2` by luma. | Candidate |
| `r_bloom_filter_size` | Gaussian blur filter size (6 default). | Candidate |
| `r_bloom_reflection` | Lens-reflection intensity. | Candidate |
| `r_ext_multisample` | Geometry MSAA (0/2/4/6/8). | Candidate (Metal sample count on `MTKView`) |
| `r_ext_supersample` | Super-sample AA. | N/A-GL |
| `r_renderWidth` / `r_renderHeight` | Internal render target size. | N/A-GL |
| `r_ext_framebuffer_multisample` | FBO MSAA. | N/A-GL |
| `r_postProcess` | Enable post-processing. | N/A-GL |
| `r_toneMap` | Enable tone mapping. | N/A-GL |
| `r_autoExposure` | Auto exposure based on scene brightness. | N/A-GL |
| `r_depthPrepass` | Depth-only prepass (required for sun shadows). | N/A-GL |
| `r_ssao` | Screen-space AO. | N/A-GL |
| `r_normalMapping` | Normal maps. | N/A-GL |
| `r_specularMapping` | Specular maps. | N/A-GL |
| `r_deluxeMapping` | Deluxe maps / lightgrid approximation. | N/A-GL |
| `r_parallaxMapping` | `0` off / `1` POM / `2` relief. | N/A-GL |
| `r_parallaxMapOffset` | Parallax height offset. | N/A-GL |
| `r_parallaxMapShadows` | Parallax self-shadowing. | N/A-GL |
| `r_pbr` | Physically based rendering. | N/A-GL |
| `r_shadowFilter` | Shadow filtering `0`/`1`/`2`. | N/A-GL |
| `r_shadowMapSize` | Cascade shadow map size. | N/A-GL |
| `r_shadowCascadeZNear` / `ZFar` / `ZBias` | Cascade frustum params. | N/A-GL |
| `r_dither` | Ordered dithering (`0`/`1`) — requires `r_fbo 1`. | N/A-GL |
| `r_presentBits` | Presentation surface color bits. | N/A-GL |
| `r_imageUpsample` | Image upsample mode. | N/A-GL |

---

## Renderer — rail / flares / anaglyph / misc

| Cvar | Description | iOS |
|---|---|---|
| `r_railWidth` | Railgun trail radius. | Candidate (scene-poly path) |
| `r_railCoreWidth` | Railgun trail ring size (`cg_oldRail 0`). | Candidate |
| `r_railSegmentLength` | Railgun trail segment length. | Candidate |
| `r_anaglyphMode` | Anaglyph 3D (`0` off, `1-4` color pairs). | N/A |
| `r_greyscale` | Desaturate frame — requires `r_fbo 1`. | N/A-GL |
| `r_showImages` | Dump loaded images to screen. | Not wired |
| `r_printShaders` | Debug count of shaders. | Not wired |
| `r_debugSort` | Filter shaders above sort value. | Not wired |
| `r_nocurves` | Disable bezier curves. | Active (checked in BSP loader) |
| `r_drawworld` | Disable drawing world. | **Active — `metal_draw_world` wired via `Q3MetalRenderer_GetDrawWorld()`** |
| `r_drawentities` | Draw world entities. | **Active — `metal_draw_entities` wired via `Q3MetalRenderer_GetDrawEntities()`** |
| `r_nocull` | Draw all culled objects. | **Active — `metal_nocull` wired via `Q3MetalRenderer_GetNoCull()`** |
| `r_novis` | Disable PVS. | Not wired (whole-scene draw path) |
| `r_showcluster` | Show current cluster index. | Not wired |
| `r_speeds` | Print render stats (0-6). | Not wired |
| `r_debugSurface` | Backend bezier mesh debug. | N/A |
| `r_nobind` | Disable texture binding. | N/A-GL |
| `r_showtris` | Wireframe triangle rendering. | Not wired |
| `r_showsky` | Sky in front of all surfaces. | Not wired |
| `r_shownormals` | Wireframe surface normals. | Not wired |
| `r_clear` | Clear framebuffer every frame. | N/A (always cleared) |
| `r_offsetFactor` / `r_offsetUnits` | polygonOffset params. | N/A (handled per-pipeline state) |
| `r_drawBuffer` | Frame buffer to draw into. | N/A-GL |
| `r_lockpvs` | Lock current PVS (debug). | Not wired |
| `r_noportals` | `0` on, `1` portals off, `2` portals+mirrors off. | **Active — `Q3MetalRenderer_GetNoPortals()`** |
| `r_marksOnTriangleMeshes` | Impact marks on MD3s. | Not wired |
| `r_aviMotionJpegQuality` | AVI capture JPEG quality. | N/A |
| `r_screenshotJpegQuality` | JPEG screenshot quality. | Candidate |
| `r_allowExtensions` | Use all GL extensions. | N/A-GL |
| `r_ext_compressed_textures` | Texture compression. | N/A-GL |
| `r_ext_multitexture` | Hardware multi-texturing. | N/A-GL |
| `r_ext_compiled_vertex_array` | Compiled vertex arrays. | N/A-GL |
| `r_ext_texture_env_add` | Additive blending in multitexturing. | N/A-GL |
| `r_ext_texture_filter_anisotropic` | Anisotropic filtering. | N/A-GL |
| `r_ext_max_anisotropy` | Max anisotropy level. | N/A-GL |
| `r_stencilbits` | Stencil buffer size. | N/A |
| `r_flares` | Enable light-source coronas. | Not wired |
| `r_flareSize` | Flare radius — requires `r_flares 1`. | Not wired |
| `r_flareFade` | Flare fade distance. | Not wired |
| `r_flareCoeff` | Flare intensity coefficient. | Not wired |
| `r_portalOnly` | Disable stencil-buffer portal clip. | N/A (Metal RTT portal; no stencil portal path) |
| `r_skipBackEnd` | Skip loading rendering backend. | N/A-GL |
| `r_lodscale` | LOD adjustment scale. | Not wired |
| `r_norefresh` | Bypass scene refresh. | Not wired |
| `r_facePlaneCull` | Back-side cull planar surfaces. | Active (via `cullMode`) |
| `r_textureMode` | Texture interp (`GL_NEAREST`/`GL_LINEAR`/MipMap variants). | N/A-GL (Metal sampler state) |
| `r_finish` | Force `glFinish` after render. | N/A-GL |

---

## Sound

| Cvar | Description | iOS |
|---|---|---|
| `s_khz` | Sample rate (11/22/44/48 kHz). | Active if sound init succeeds |
| `s_mixahead` | Mix-ahead duration (s); lower = more responsive, less stable. | Active |
| `s_show` | Debug: used sound files. | Active |
| `s_testsound` | Sine-wave tone test. | Active |
| `s_device` | ALSA output device. | N/A (iOS is CoreAudio) |
| `s_volume` | Master volume. | Active |
| `s_musicVolume` | Music-only volume. | Active |
| `s_doppler` | Doppler on moving projectiles. | Active |
| `s_muteWhenUnfocused` | Mute when window unfocused. | Applies on app background |
| `s_muteWhenMinimized` | Mute when minimized. | Applies on app background |
| `s_initsound` | Start the sound system at boot. | Active — but `Sound initialization failed.` currently observed in iOS logs |

---

## Common engine / hunk / timing

| Cvar | Description | iOS |
|---|---|---|
| `com_zoneMegs` | Zone block memory (MB). | Active |
| `com_hunkMegs` | Hunk memory size (MB). | Active |
| `com_soundMegs` | Sound RAM hunk (MB). | Active |
| `com_journal` | Write events + data to `journal.dat`. | Active |
| `com_protocol` | Protocol version number. | Active |
| `com_dedicated` | `0` listen / `1` unlisted-dedi / `2` listed-dedi. | Host |
| `com_maxfps` | Cap rendered FPS. | Active |
| `com_maxfpsUnfocused` | FPS cap when unfocused. | Active |
| `com_yieldCPU` | Sleep ms between rendered frames; 0 if laggy. | Active |
| `com_affinityMask` | Bind process to CPU bitmask. | N/A |
| `com_timescale` | `<1` slow-mo / `>1` speed-up. | Active (cheat-protected) |
| `com_fixedtime` | Render every frame, wait for completion. | Active |
| `com_showtrace` | Trace info debug. | Active |
| `com_viewlog` | Show startup console over game. | N/A (no external console window) |
| `com_speeds` | Print speed info per frame. | Active |
| `com_timedemo` | Run timed demo (FPS benchmark). | Active |
| `com_cl_running` | Read-only: client running. | Active |
| `com_sv_running` | Read-only: server running. | Active |
| `com_buildScript` | Load all assets regardless of need. | Active |
| `com_introPlayed` | Skip intro cinematic. | Active |
| `com_skipIdLogo` | Skip id logo cinematic. | Active |
| `com_version` | Read-only engine version. | Active |
| `cl_paused` | Read-only paused state. | Active |

---

## Cheats, developer, filesystem

| Cvar | Description | iOS |
|---|---|---|
| `cheats` (`sv_cheats`) | Enable cheat commands (server-side). | Active |
| `developer` | Toggle developer-mode verbose logging. | Active — use `\developer 1` from the `ConsoleOverlay` |
| `fs_debug` | Filesystem debug trace to console. | Active |
| `fs_copyfiles` | Copy files from `cdpath`. | N/A |
| `fs_basepath` | Install folder (write-protected). | Active — points at `Quake3-iOS.app` bundle |
| `fs_basegame` | Base mod folder (write-protected). | Active |
| `fs_gamedirvar` | Alternate mod directory. | Active |

---

## Collision / VM

| Cvar | Description | iOS |
|---|---|---|
| `cm_noAreas` | All areas connected; ignore areaportals. | Active |
| `cm_noCurves` | Don't collide against curves. | Active |
| `cm_playerCurveClip` | Collide player against curves. | Active |
| `vm_cgame` | cgame VM mode (native/dll/qvm/interpreted). | **Overridden**: native cgame is registered via `VM_RegisterNative("cgame", ...)` in `Quake3_Init()`, so the registry check in `VM_Create()` bypasses this cvar. |
| `vm_game` | qagame VM mode. | Same pattern — native when registered. |
| `vm_ui` | ui VM mode. | Same pattern. |

---

## Demo / capture

| Cvar | Description | iOS |
|---|---|---|
| `cl_autoRecordDemo` | Auto-record demos on join. | Active |
| `cl_aviFrameRate` | AVI capture framerate. | N/A (no AVI writer) |
| `cl_aviMotionJpeg` | AVI MJPEG codec toggle. | N/A |
| `cl_forceavidemo` | Record demo as TGA sequence. | N/A |
| `cl_aviPipeFormat` | Encoder args for `video-pipe`. | N/A |

---

## Quake3-iOS (Metal-only) cvars

Added by this port. All are `CVAR_ARCHIVE` (persist across launches) unless noted. See `metal_renderer_stub.c` and `CLAUDE.md`.

| Cvar | Default | Description |
|---|---|---|
| `metal_draw_world` | `1` | Gate rendering of world BSP geometry. Read by Swift draw loop. |
| `metal_draw_entities` | `1` | Gate rendering of MD3/sprite entities. |
| `metal_nocull` | `0` | Disable per-pipeline back-face cull (overrides `cullMode`). |
| `metal_synth_viewmodel` | `0` (OFF) | Synthesize a first-person viewmodel entity in C (pre-native-cgame fallback). Native cgame (`CG_AddViewWeapon`) places the real weapon correctly — re-enable only if it regresses. |
| `metal_vm_forward` | `6` | Synthetic viewmodel forward offset (world units). Live-tunable. |
| `metal_vm_right` | `5` | Synthetic viewmodel right offset. |
| `metal_vm_up` | `-4` | Synthetic viewmodel up offset. |
| `metal_vm_scale` | `0.3` | Synthetic viewmodel scale factor. |
| `metal_vm_sway` | `0.4` | Synthetic viewmodel sway amplitude. |
| `metal_hide_nearby` | `0` (OFF) | Proximity filter for player body parts + weapons2. QVM-ABI workaround, obsolete since native cgame. |
| `metal_fallback_camera` | `0` (OFF) | Build fallback refdef when fovX<45. Obsolete since native cgame writes a valid refdef. |
| `metal_debug_passes` | `0` (OFF) | `1` solid replace, `2` tint. Colorizes the four-pass render (opaque/filter/alpha/additive) for debug. |
| `metal_debug_render_mode` | `0` | World debug mode mirror (see `worldDebugMode` compile-time constant in `MetalView.swift`: 0=normal, 1=base texture, 2=lightmap, 3=UV0, 4=UV1). |
| `r_disableTcMod` | `0` | When `1`, Swift world draw loop zeroes `WorldDrawUniforms.tcMod` on every stage, pinning UVs to BSP-baked values. Diagnoses whether "flying texture" artifacts come from the tcMod parameter chain. |
| `r_portalSmokeTest` | `0` | When no `RT_PORTALSURFACE` entity is submitted, shift main camera +50u Z to validate Phase-1 RTT pipeline. |

Notes on retained fallback cvars: `metal_synth_viewmodel`, `metal_hide_nearby`, and `metal_fallback_camera` defaulted **OFF** as of commits `6089c82`/`61c093a`/`2067b21` because native cgame (commit `5977485`) makes them unnecessary. They remain as flip-switch regression fallbacks — do not remove the code paths.

---

## Commonly used console commands

Console commands (as opposed to cvars) are actions rather than state. Non-exhaustive — these are the ones most useful while debugging the iOS port:

### Map / game

- `map <mapname>` — load a map, allows cheats only if `+set sv_cheats 1`.
- `devmap <mapname>` — load with cheats enabled.
- `spdevmap <mapname>` — single-player devmap (Quake3e).
- `map_restart <delay>` — restart current map.
- `disconnect` — disconnect from server.
- `quit` — exit engine.

### VM / modules

- `vmprofile` — profile QVM execution.
- `vmrun <module>` — run VM.

### Renderer

- `vid_restart` — full renderer re-init. Required after changes to `r_mode`, `r_fullscreen`, `cl_renderer`, etc.
- `modelist` — list available video modes (desktop).
- `imagelist` — list loaded images.
- `shaderlist` — list parsed shaders.
- `screenshot`, `screenshotJpeg`, `screenshotBmp` — capture.
- `gfxinfo` — renderer/GL info dump.

### Demos

- `record <name>` / `stoprecord` — record demo.
- `demo <name>` — play back demo.
- `video <name>` / `video-pipe <name>` / `stopvideo` — capture to AVI / ffmpeg pipe.

### Binds / aliases

- `bind <key> "<cmd>"` — bind key to command string.
- `unbind <key>` / `unbindall`.
- `bindlist` — dump current binds.
- `alias <name> "<cmds>"` — define command alias.

### Cvars / cfg

- `set`, `seta`, `sets`, `setu` — set cvar (archive / server / userinfo).
- `cvarlist [filter]` — list cvars with descriptions (this is what PR #189 feeds).
- `cvar_restart` — reset all cvars.
- `exec <file.cfg>` — execute config file.
- `writeconfig <file>` — dump current config.
- `toggle <cvar> [val1 val2 ...]` — cycle cvar values.

### Network / server browser

- `connect <host[:port]>` — connect to server.
- `reconnect` — reconnect to last server.
- `ping <host>` — ping a host.
- `serverstatus [host]` — query status of connected or specified server.
- `rcon <command>` — remote console. Needs `rconAddress` + `rcon_client_password`.
- `dlmap <mapname>` — manual map download.

### Player / game (most run in-game as binds)

- `say "<text>"` / `say_team` — chat.
- `tell <player> "<text>"` — private message.
- `give all`, `god`, `notarget`, `noclip` — cheats (require `sv_cheats 1`).
- `kill` — suicide.
- `callvote <args>`, `vote yes|no` — server voting.
- `kick <player>`, `banClient <num>` — admin.

### iOS-specific

- Anything typed into the `>_` `ConsoleOverlay` goes through `Q3Exec_Command` → `Cbuf_AddText` + `Cbuf_Execute`. Prefix cheats with `\` (e.g. `\devmap q3dm1`). The focus is retained post-submit for chaining.

---

## Retrieval notes for issue #188 / PR #189

- PR #189 commit: [`ab804c42dc849a8e0720537d28f2f4aa21a322f8`](https://github.com/ec-/Quake3e/commit/ab804c42dc849a8e0720537d28f2f4aa21a322f8) — single-commit merge, title "CVARS: describe as much cvars as possible, using the Cvar_SetDescription functionality."
- Cvars explicitly called out as still undescribed at merge time (18 total, including): `cl_reconnectArgs`, `s_mixOffset`, `com_noErrorInterrupt`.
- If the two original community pages come online later in an unblocked environment, rerun the fetch — there will likely be mod-specific or e+-specific cvars (ex-ball / excessiveplus) not covered here, e.g. `df_*`, `pmove_*`, `ex_*`.

## Sources

- [Quake3e issue #188 — CVARS: Describe as much CVARS as possible](https://github.com/ec-/Quake3e/issues/188)
- [Quake3e PR #189 diff (authoritative cvar descriptions)](https://github.com/ec-/Quake3e/commit/ab804c42dc849a8e0720537d28f2f4aa21a322f8)
- Quake3-iOS `CLAUDE.md` (in-repo) — Metal-only cvars and port-specific behavior.

---

## Full cvar dump (community big-list, uploaded sources)

Sourced from the two HTML pages you uploaded: quakearea.com console-commands page and the excessiveplus.net community thread. Both are the same canonical Q3 "big list" with slight differences (the e+ thread has no mod-specific cvars despite the title). Descriptions abbreviated from community text.

**Class ID legend**: `A`=archive (saved to q3config.cfg), `C`=cheat-protected, `L`=latched (restart/map load), `S`=server, `R`=read-only, `U`=userinfo, `I`=init-only. Multiple letters stack.

Cvars already covered in the grouped tables above are not repeated here. iOS-relevance is applied at the family level: gameplay (`cg_*` / `g_*` / `ui_*` / `sv_*` / `bot_*`) runs inside the native VMs; renderer/platform families (`gl_*` / `win_*` / `joy_*` / `in_*` / `d_*` / `scr_*`) are dead on iOS Metal.


### CGame - HUD / view / crosshair / viewmodel (`cg_*`)

_iOS: Active (native cgame)_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `cg_animspeed` | `1` | toggle linear interpolation between successive frames in a player animation. 0 = no interpolation 1 = it does interpolate - Coriolis + WhatEver | C |
| `cg_autoswitch` | `1` | auto-switch weapons (on pick-up) | A |
| `cg_bobpitch` | `0.002` | set amount player view bobs forward/back while moving | A |
| `cg_bobroll` | `0.002` | set amount player view rolls side to side while moving | A |
| `cg_bobup` | `0.005` | set amount player view bobs up/down while moving | A |
| `cg_brassTime` | `1250` | set amount of time a shell casing gets displayed if set to 0 the game engine will skip all shell eject code | A |
| `cg_cameraOrbit` | `0` | change the step or increment units of the orbit rotation from one angle how much of a step to next angle | C |
| `cg_cameraOrbitDelay` | `50` | change the rate at wich the camara moves to the next orbit position the higher the number the slower | A |
| `cg_centertime` | `3` | set display time for center screen messages (0 off) | C |
| `cg_crosshairHealth` | `1` | show health by the cross hairs (only works with #10 now?) | A |
| `cg_crosshairSize` | `24` | crosshair size...incase you have crosshair envy (c: | A |
| `cg_crosshairX` | `0` | set X coordinates of the crosshair if cg_crosshairSize not 0 | A |
| `cg_crosshairY` | `0` | set Y coordinates of the crosshair if cg_crosshairSize not 0 | A |
| `cg_debuganim` | `0` | toggle model animation debug mode | C |
| `cg_debugevents` | `0` | toggle event debug mode | C |
| `cg_debugposition` | `0` | toggle player position debug mode | C |
| `cg_deferPlayers` | `1` | the loading of player models will not take place until the next map, or when you die, or toggle the scoreboard (tab) this prevents the "hitch" effect when a... | A |
| `cg_demoLook` | `0` | possibly to change the look of a recorded demo? |  |
| `cg_draw2D` | `1` | toggle the drawing of 2D items or text on the status display | A |
| `cg_draw3dIcons` | `1` | toggle the drawing of 3D icons on the HUD off and on draw 2D icon for ammo if cg_draw3dicons 0 "John Carmack" | A |
| `cg_drawAmmoWarning` | `1` | toggle low-ammo warning display | A |
| `cg_drawAttacker` | `1` | toggle the display of last know assailant | A |
| `cg_drawCrosshair` | `1` | select crosshair (change to zero if you have really good aim ha! ha!) 10 crosshairs to select from (cg_drawCrosshair 1 - 10) "John Carmack" | A |
| `cg_drawCrosshairNames` | `1` | toggle displaying of the name of the player you're aiming at | A |
| `cg_drawFPS` | `0` | toggle Frames Per Second display (when set to one "0" is default) | A |
| `cg_drawFriend` | `1` | toggle the display of triangle shaped icon over the heads of your team mates | A |
| `cg_drawGun` | `1` | toggle determines if the weapon you're holding is visible or not | A |
| `cg_drawIcons` | `1` | toggle the drawing of any icons on the HUD and scoreboard | A |
| `cg_drawKiller` | `1` | toggle display of player's name and picture that fragged you last | A |
| `cg_drawRewards` | `1` | toggle display of award icons above the "you fragged..." message | A |
| `cg_drawSnapshot` | `0` | toggle the display of snapshots counter (# of snaps since game start) | A |
| `cg_drawStatus` | `1` | draw the HUD. (toggle weather or not health and score are displayed) | A |
| `cg_drawTeamOverlay` | `0` | set the drawing location of the team status overlay 1=top right 2=bottom right 3=bottom left of the screen it shows team player names, location, ammo (and what... |  |
| `cg_drawTimer` | `1` | show timer on HUD. shows time since map start counts up | A |
| `cg_errordecay` | `100` | helps to smooth animation during player prediction while experiencing packet loss or snapshot errors. "detect prediction errors and allow them to be decayed... |  |
| `cg_extrapolate` | `1` | toggle blending of animations from one to the next (like a segue) |  |
| `cg_footsteps` | `1` | toggle the footstep sounds of all players (cheat protected) | C |
| `cg_forceModel` | `0` | force model selection, also forces player sounds "John Carmack" | A |
| `cg_fov` | `90` | field of view/vision "90" is default higher numbers give peripheral vision. | A |
| `cg_gibs` | `1` | toggle the display of animated gibs (explosions flying body parts!) | A |
| `cg_gun` | `1` | toggle determines if the weapon your holding is visible or not | A |
| `cg_gunX` | `0` | set X coordinates of viewable weapon if cg_drawGun is set to 1 | C |
| `cg_gunY` | `0` | set Y coordinates of viewable weapon if cg_drawGun is set to 1 | C |
| `cg_gunZ` | `0` | set Z coordinates of viewable weapon if cg_drawGun is set to 1 moves the gun model forward or backward in relation to the player models hold | C |
| `cg_ignore` | `0` | used for debugging possibly like the notarget command |  |
| `cg_lagometer` | `1` | toggle the display of Lag-O-Meter on the HUD 1=netgraph 0=frag counter which changes color to reflect what place your in as well Section 6 of the... | A |
| `cg_markoffset` | `1` | set marks (decals) offset. some video cards display the marks with the wrong offset, so you will be able to see the square decal that encapsulates the effect... |  |
| `cg_marks` | `1` | toggle the marks the projectiles leave on the wall (bullet holes, etc) | A |
| `cg_noplayeranims` | `0` | toggle player model animations. (the animation frame displayed when this is disabled is rather odd, though.) | C |
| `cg_nopredict` | `0` | toggle client-side player prediction. (disabling causes the client to wait for updates from the server before updating the player location.) . |  |
| `cg_noProjectileTrail` | `0` | toggle the display of smoke trail effect behind rockets - Jax_Gator Dekard | A |
| `cg_noTaunt` | `0` | possibly turn off the ability to hear voice taunts | A |
| `cg_noVoiceChats` | `0` | possibly turn off the ability to hear voice chats | A |
| `cg_noVoiceText` | `0` | possibly turn off the display of the voice chat text copied to the console | A |
| `cg_oldPlasma` | `1` | toggle the use of old or new particle style plasma gun effect - 20 20 | A |
| `cg_oldRail` | `0` | toggle the use of old or new spiral style rail trail effect - 20 20 | A |
| `cg_oldRocket` | `1` | toggle the use of old or new style rocket trail effect - 20 20 | A |
| `cg_predictItems` | `1` | toggle client-side item prediction. 0 option to not do local prediction of item pickup - John Carmack | U A |
| `cg_railTrailTime` | `400` | set how long the railgun's trails last | A |
| `cg_runpitch` | `0.002` | set amount player view bobs up and down while running | A |
| `cg_runroll` | `0.005` | set amount player view rolls side to side while running (in 3rd person only?) | A |
| `cg_scorePlums` | `1` | toggle the display of the floating scoring number balloons when a player scores a point or points (including negative points) in any game type, the awarded... | U A |
| `cg_shadows` | `0` | set shadow detail level (0 = OFF, 1 = basic discs, 2 = stencil buffered 3 = simple stencil buffered(if r_stencilebits is not=0)) - Andre Lucas | A |
| `cg_showcrosshair` | `1` | appeared in version 1.06 then removed in 1.07 now back in 1.08 then removed again in 1.09…hmm (replaced with multi-crosshairs) |  |
| `cg_showmiss` | `0` | toggle the display of missed packets or predictions on the HUD |  |
| `cg_simpleItems` | `0` | toggle the use of 2D sprite objects in place of the 3D animated objects makes some objects more "simple" (faster to render) - hacker | A |
| `cg_smoothClients` | `0` | when g_smoothClients is enabled on the server and you enable cg_smoothClients then players in your view will be predicted and will appear more smooth even if... | U A |
| `cg_stats` | `0` | toggles display of client frames in sequence missed frames are not shown |  |
| `cg_stereoSeparation` | `0.4` | the amount of stereo separation (for 3D glasses!) You ever take off your glasses at a 3D movie, remember how the images were separated into 3 colors? that's... | A |
| `cg_swingSpeed` | `0.3` | set speed player model rotates to match position (1 is no delay, 0 will never turn) | C |
| `cg_teamChatHeight` | `8` | set number of lines or strings of text that remain on screen in team play chat mode (messagemode2) values are 1 - 8 | A |
| `cg_teamChatsOnly` | `0` | when this is set to a one only chats from team mates will be displayed | A |
| `cg_teamChatTime` | `3000` | set how long messages from teammates are displayed on the screen | A |
| `cg_temp` | `0` |  |  |
| `cg_testentities` | `0` |  |  |
| `cg_thirdPerson` | `0` | toggle the use of and third person view |  |
| `cg_thirdPersonAngle` | `0` | change the angle of perspective you view your player (180 changes view to the front of the model) | C |
| `cg_thirdPersonRange` | `40` | change the distance you view your player from when in 3rd person view |  |
| `cg_timescaleFadeEnd` | `1` |  |  |
| `cg_timescaleFadeSpeed` | `0` |  |  |
| `cg_tracerchance` | `0.4` | set frequency of tracer bullets (1 is all tracers) | C |
| `cg_tracerlength` | `100` | set length of tracer bullets | C |
| `cg_tracerwidth` | `1` | set width of tracer bullets | C |
| `cg_trueLightning` | `0` | settings of the new shaft style. from the OSP readme...specifies the "lag" imposed on the rendering of the lightning gun shaft. a value of 0.0 is just like the... | A |
| `cg_viewsize` | `100` | changes view port size 30 - 100 (you probably wouldn't want less than 100) | A |
| `cg_waveamplitude` | `1` |  |  |
| `cg_wavefrequency1` | `0.4` |  |  |
| `cg_zoomfov` | `22.5` | what the zoomed in field of view will be any thing more than 30 would not be sniper friendly | A |

### Game - rules / arena / gametype (`g_*`)

_iOS: Active (native qagame)_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `g_aimTest` | `0` | removed possibly was a cheat (bot like aiming) |  |
| `g_allowVote` | `1` | toggle the use of voting on a server |  |
| `g_arenaName` | `0` | possibly toggles the display of the name of the current arena? |  |
| `g_arenaRank` | `` | possibly a variable to hold the value for your rank in the current series | A |
| `g_arenaScores` | `` | possibly a variable to hold the value of previous arena series scores | A |
| `g_arenasFile` | `` | sets the file name to use for map rotation and bot names and game type for each arena default scripts/arenas.txt within the PK3 file | R I |
| `g_banIPs` | `` | ban specified TCP/IP address from connecting to your server | A |
| `g_blueTeam` | `` | set the icon for the blue team (example Pagans) | S A |
| `g_botsFile` | `` | sets the file name to use for setting up the bots configuration and characters for each bot default scripts/bots.txt within the PK3 file | R I |
| `g_debugAlloc` | `0` | possibly debugging tool for memory allocation? |  |
| `g_debugDamage` | `0` | debugging tool for damage effects? |  |
| `g_debugMove` | `0` | debugging tool for brush/entity movements? |  |
| `g_doWarmup` | `0` | toggle the use of a warmup period before a match game | A |
| `g_enableBreath` | `0` | enable breath in cold maps you can see the players breath |  |
| `g_enableDust` | `0` | enable dust to be kicked up from feet in areas that have that map entity |  |
| `g_filterBan` | `1` | toggle the banning of players that match a certain criteria/filter? | A |
| `g_forcerespawn` | `10` | set the respawn time in seconds, 0 = don't force respawn |  |
| `g_friendlyFire` | `0` | toggle damage caused by friendly fire 1 = can kill or injure teammate | A |
| `g_gametype` | `0` | 0 - Free For All 1 - Tournament 2 - Single Player 3 - Team Deathmatch 4 - Capture the Flag to start a dedicated server in tournament mode, you would use:... | 0 - Free For All |
| `g_gravity` | `800` | set the gravity level. (this is normally set by a property of the map loaded) |  |
| `g_inactivity` | `0` | set the amount of time a player can remain inactive before kicked |  |
| `g_knockback` | `1000` | the knockback from a weapon, higher number = greater knockback. |  |
| `g_listEntity` | `0` | toggles the display of map entities shows them by number |  |
| `g_log` | `1` | toggles logging of game data or statistics John Carmack made g_log a filename instead of a 0/1 in this version | A |
| `g_logSync` | `0` | toggle the logging to append to the existing file and not overwrite | A |
| `g_maxGameClients` | `0` | set maximum # of players who may join the game the remainder of clients are forced to spectate | S A L |
| `g_motd` | `` | set message of the day to "X" (see "cl_motd" to display it) |  |
| `g_needpass` | `0` | variable alerts the client that a password is needed to join your server | S R |
| `g_password` | `` | set the serverside password players use to get on the server | U |
| `g_podiumDist` | `80` | sets the draw distance of the podium object player models stand on after a single player bot match |  |
| `g_podiumDrop` | `70` | sets the height of the podium object player models stand on after a single player bot match |  |
| `g_quadfactor` | `3` | allows the admin to set the amount of damage the quad damage will do. |  |
| `g_rankings` | `0` |  |  |
| `g_redTeam` | `` | set the team icon for the red team (example Stroggs) | S A |
| `g_restarted` | `0` | read only variable that is toggled when the game has been restarted in match mode this sets an event trap for if warmup is needed | R |
| `g_singlePlayer` | `0` | possibly to allow 3 rd party's to make TC's for single player style games? | R |
| `g_smoothClients` | `1` | enable players to use the smooth clients option on the server (cg_smoothClients) |  |
| `g_spAwards` | `` | variable holds the names of the award icons that have been earned in the tier levels in single player mode | R A |
| `g_speed` | `320` | how fast you move in Q3Test. The greater the number, the greater the velocity |  |
| `g_spScores1` | `` | holds your scores on skill level 1 in single player games - Dr Qube | R A |
| `g_spScores2` | `` | holds your scores on skill level 2 in single player games - Dr Qube | R A |
| `g_spScores3` | `` | holds your scores on skill level 3 in single player games - Dr Qube | R A |
| `g_spScores4` | `` | holds your scores on skill level 4 in single player games - Dr Qube | R A |
| `g_spScores5` | `` | holds your scores on skill level 5 in single player games - Dr Qube | R A |
| `g_spSkill` | `2` | holds your current skill level for single player 1 = I can win 2 = bring it on 3 = hurt me plenty 4 = hardcore and 5 = nightmare | A L |
| `g_spVideos` | `` | variable holds the names of the cinematic videos that are unlocked at the end of each tier completion | R A |
| `g_syncronousClients` | `0` | toggle synching of all client movements (1 required to record server demo) show "snc" on lagometer "John Carmack" |  |
| `g_teamAutoJoin` | `0` | toggle the automatic joining of the smallest or loosing team | A |
| `g_teamForceBalance` | `0` | toggle the forcing of teams to be as even as possible on a server | A |
| `g_warmup` | `` | the warmup time for tournament play is set with g_warmup. A tournament game is implicitly a one on one match, and further players are automatically entered as... | A |
| `g_weaponrespawn` | `5` | set time before a picked up weapon will respawn again 0 = weapons stay |  |
| `g_weaponTeamRespawn` | `30` |  |  |

### Server (`sv_*`)

_iOS: Active when hosting; many are Host-only on iOS_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `sv_allowAnonymous` | `0` | possibly to toggle the allowing of anonymous clients to connect to your server | S |
| `sv_allowdownload` | `1` | toggle the ability for clients to download files maps etc. from server. . |  |
| `sv_cheats` | `1` | enable cheating commands (give all) (serverside only) | R |
| `sv_floodProtect` | `1` | toggle server flood protection to keep players from bringing the server down | S A |
| `sv_fps` | `20` | set the max frames per second the server sends the client |  |
| `sv_hostname` | `` | set the name of the server "Shadowlands" | S A |
| `sv_keywords` | `` | variable holds the search string entered in the internet connection menu | S |
| `sv_killserver` | `0` | if set to a one the server goes down (server console only I hope) |  |
| `sv_mapChecksum` | `` | allows check for client server map to match | R |
| `sv_mapname` | `` | display the name of the current map being used on a server | S R |
| `sv_master1` | `` | set URL or address to master server "master3.idsoftware.com" |  |
| `sv_master2` | `` | optional master 2 | A |
| `sv_master3` | `` | optional master 3 | A |
| `sv_master4` | `` | optional master 4 | A |
| `sv_master5` | `` | optional master 5 | A |
| `sv_maxclients` | `8` | maximum number of people allowed to join the server dedicated server memory optimizations. Tips: com_hunkMegs 4 sv_maxclients 3 bot_enable 0 "John Carmack" | S A L |
| `sv_maxPing` | `0` | set the maximum ping aloud on the server to keep HPB out | S A |
| `sv_maxRate` | `` | option to force all clients to play with a max rate. This can be used to limit the advantage of LPB, or to cap bandwidth utilization for a server. Note that... | S A |
| `sv_minPing` | `0` | set the minimum ping aloud on the server to keep LPB out | S A |
| `sv_nopredict` | `0` | is it possible that the server is handling some prediction of player location? |  |
| `sv_pad` | `0` |  |  |
| `sv_padPackets` | `0` | possibly toggles the padding of network packets on the server PAD - Packet Assembler/Disassembler |  |
| `sv_pakNames` | `antilogic` | variable holds a list of all the pk3 files the server found "antilogic" | R |
| `sv_paks` | `182784856 ` | variable holds the checksum of all pk3 files | R |
| `sv_paused` | `0` | allow the game to be paused from the server console? | R |
| `sv_privateClients` | `0` | the number of spots, out of sv_maxclients, reserved for players with the server password (sv_privatePassword) | S |
| `sv_privatePassword` | `` | set password for private clients to login with |  |
| `sv_pure` | `1` | disallow native DLL loading if sv_pure, requires clients to only get data from pk3 files the server is using "John Carmack" |  |
| `sv_reconnectlimit` | `3` | number of times a disconnected client can come back and reconnect |  |
| `sv_referencedPakNames` | `` | variable holds a list of all the pk3 files the server loaded data from. these pk3 files will be autodownloaded by a client if the client does not have them.... | R |
| `sv_referencedPaks` | `` | variable holds the checksum of the referenced pk3 files | R |
| `sv_running` | `1` | variable flag tells the console weather or not a local server is running | R |
| `sv_serverid` | `` | hmm…"8021204" | R |
| `sv_showloss` | `0` | toggle sever packet loss display |  |
| `sv_timeout` | `120` | sets the amount of time for the server to wait for a client packet before assuming a disconnected state. |  |
| `sv_zombietime` | `2` | the amount of time in minutes before a frozen character is removed from the map. |  |
| `sv_zone` | `default` | this is the keyword that clients will search for, server admin's should set this variable to the gametype they have running. free for all, tournament, team... | S |

### UI menu system (`ui_*`)

_iOS: Active (native ui module)_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `ui_bigFont` | `0.4` |  | A |
| `ui_browserGameType` | `0` | set server search game type in the browser list (see g_gametype) | A |
| `ui_browserMaster` | `0` | set server search 0=LAN 1=Mplayer 2=Internet 3=Favorites | A |
| `ui_browserShowEmpty` | `1` | toggle the displaying of empty servers in the browser list | A |
| `ui_browserShowFull` | `1` | toggle the displaying of full servers in the browser list | A |
| `ui_browserSortKey` | `4` | set the field number to sort by in the browser list 0=Server Name 1=Map Name 2=Open Player Spots 3=Game Type 4=PingTime | A |
| `ui_cdkeychecked` | `1` | set to a 1 after the cdkey has been checked so won't ask again | R |
| `ui_ctf_capturelimit` | `8` | set the menu default capture limit for single player bot matches | A |
| `ui_ctf_friendly` | `0` | toggle team mate damage in single player CTF bot matches | A |
| `ui_ctf_timelimit` | `30` | set the menu default CTF time limit for single player bot matches | A |
| `ui_ffa_fraglimit` | `20` | set the menu default frag limit for single player FFA bot matches | A |
| `ui_ffa_timelimit` | `0` | set the menu default time limit for single player FFA bot matches | A |
| `ui_master` | `0` | set server search 0=LAN 1=Mplayer 2=Internet 3=Favorites | A |
| `ui_singlePlayerActive` | `0` |  |  |
| `ui_smallFont` | `0.25` |  | A |
| `ui_spSelection` | `2` | set the menu default gametype of single player? 16 = CTF 2 = FFA DM | R |
| `ui_team_fraglimit` | `0` | set the menu default frag limit for single player team bot matches | A |
| `ui_team_friendly` | `1` | toggle default team mate damage in single player team bot matches | A |
| `ui_team_timelimit` | `20` | set the menu default time limit for single player team bot matches | A |
| `ui_tourney_fraglimit` | `0` | set the menu default frag limit for single player tourney bot matches | A |
| `ui_tourney_timelimit` | `15` | sets the menu default time limit for single player tourney bot matches | A |

### Bots (`bot_*`)

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `bot_aasoptimize` | `0` | optimize the .aas file when one is written |  |
| `bot_challenge` | `0` | make the bot a bit more challenging |  |
| `bot_debug` | `0` | toggle debugging tool for bot code |  |
| `bot_developer` | `0` | toggle developer mode for bots |  |
| `bot_enable` | `0` | enable and disable adding of bots to the map/game | L |
| `bot_fastchat` | `0` | toggle between frequent and less frequent bot chat strings 1 = more often |  |
| `bot_forceclustering` | `0` | force recalculating the aas clusters |  |
| `bot_forcereachability` | `0` | force recalculating the aas reachabilities |  |
| `bot_forcewrite` | `0` | force writing out a new .aas file |  |
| `bot_grapple` | `0` | toggle determines weather the bots will use the grappling hook |  |
| `bot_groundonly` | `1` | this is a debug cvar to show areas which does not work in the retail version special thanks to |  |
| `bot_interbreedbots` | `10` | number of bots used for goal fuzzy logic interbreeding | C |
| `bot_interbreedchar` | `` | bot character to be used with goal fuzzy logic interbreeding | C |
| `bot_interbreedcycle` | `20` | number of matches between interbreeding | C |
| `bot_interbreedwrite` | `` | file to write interbreeded goal fuzzy logic to | C |
| `bot_maxdebugpolys` | `128` | max number of polygons available for visualizing things when debugging MrElusive |  |
| `bot_memorydump` | `0` | possibly displays memory allocation/use for bots used for debugging? | C |
| `bot_minplayers` | `0` | this is used to ensure a minimum numbers of players are playing on a server bots are added/removed to get the specified number of players in the game special... | S |
| `bot_nochat` | `0` | toggle determines weather bots will chat or not 0 = bots will chat |  |
| `bot_pause` | `0` | debug command to pause the bots | C |
| `bot_predictobstacles` | `1` | possibly tells bot's to predict an obstacle and turn before running into it |  |
| `bot_reachability` | `0` | this is a debug cvar which does not work in the retail version |  |
| `bot_reloadcharacters` | `0` | this cvar if set to 1 disabled bot character file caching. used when creating bot characters while keeping Q3A running. kicking and re-adding a bot will reload... |  |
| `bot_report` | `0` | debug command to have the bots report what they are doing in CTF MrElusive | C |
| `bot_rocketjump` | `1` | toggle determines weather the bots will use the rocket jump technique |  |
| `bot_saveroutingcache` | `0` | possibly allows the BOT AI to save routes for custom maps in memory. | C |
| `bot_testclusters` | `0` | possibly a debug variable for testing BOT's on new terrain maps | C |
| `bot_testichat` | `0` | used to test the initial bot chats. set this to 1 and add a bot. the bot will spit out all initial chats. |  |
| `bot_testrchat` | `0` | used to test the reply chats. set this to 1 and add one bot. the bot will always reply and dump all possible replies |  |
| `bot_testsolid` | `0` | test for "solid areas" in the .aas file (read the q3r manual) | C |
| `bot_thinktime` | `100` | this is the time in milliseconds between two AI frames. - MrElusiveset the amount of time a bot thinks about a move before making it AI...(c: |  |
| `bot_usehook` | `0` | toggle determines weather the bots will use the grappling hook |  |
| `bot_visualizejumppads` | `0` | visualizes the default arch of a jumppad (read the q3r manual) | C |

### Client (`cl_*`) - extras

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `cl_allowDownload` | `1` | toggle automatic downloading of maps, models, sounds, and textures | A |
| `cl_anglespeedkey` | `1.5` | set the speed that the direction keys (not mouse) change the view angle |  |
| `cl_anonymous` | `0` | possibly to toggle anonymous connection to a server | U A |
| `cl_avidemo` | `0` | toggle recording of a slideshow of screenshots records into the snapshot folder and appears to have overwritten some snapshots I had in there…)c: |  |
| `cl_cdkey` | `123456789` | variable to hold the CD key number to prevent bootleg/warez | A |
| `cl_conXOffset` | `0` | offset the console message display 0 - top left 999 - extreme top right (off the page) |  |
| `cl_currentServerAddress` | `` | variable holds the IP address of the currently connected server |  |
| `cl_debugMove` | `0` | used for debugging cl_debugmove [1/2] from John Carmack's plan file |  |
| `cl_downloadName` | `` | variable holds filename of file currently downloading |  |
| `cl_forceavidemo` | `0` |  |  |
| `cl_freelook` | `1` | toggle the use of freelook with the mouse (your ability to look up and down) | A |
| `cl_freezeDemo` | `0` | stops a demo play back and freeze on one frame |  |
| `cl_maxpackets` | `30` | set the transmission packet size or how many packets are sent to client | A |
| `cl_maxPing` | `800` | controls which servers are displayed in the in-game server browser - ata | A |
| `cl_motd` | `1` | toggle the display of "Message of the day" When Quake 3 Arena starts a map up, it sends the GL_RENDERER string to the Message Of The Day server at id. This... |  |
| `cl_motdString` | `` | possibly a MOTD from id's master server it is a read only variable | R |
| `cl_mouseAccel` | `0` | toggle the use of mouse acceleration the mouse speeds up or becomes more sensitive as it continues in one direction | A |
| `cl_nodelta` | `0` | disable delta compression (slows net performance, only use if net errors happen otherwise not recommended) |  |
| `cl_noprint` | `0` | printout messages to your screen or to the console (tired of all the chatter?) |  |
| `cl_packetdup` | `1` | default was 2 but changed to 1 since version 1.09 | A |
| `cl_paused` | `0` | variable holds the status of the paused flag on the client side | R |
| `cl_pitchspeed` | `140` | set the pitch rate when +lookup and/or +lookdown are active | A |
| `cl_run` | `1` | always run...play without it I dare you! (c: | A |
| `cl_running` | `1` | variable which shows weather or not a client game is running or weather we are in server/client mode (read only) | R |
| `cl_serverStatusResendTime` | `750` | possibly allows the admin to change the rate of the heartbeats to the master server(s) |  |
| `cl_showmouserate` | `0` | show the mouse rate of mouse samples per frame (USB 1/per frame) |  |
| `cl_shownet` | `0` | display network quality info |  |
| `cl_showSend` | `0` | network debugging tool "John Carmack" |  |
| `cl_showTimeDelta` | `0` | display time delta between server updates |  |
| `cl_timeNudge` | `0` | effectively adds local lag to try to make sure you interpolate instead of extrapolate (try 100 for a really laggy server) |  |
| `cl_timeout` | `125` | seconds to wait before you are removed from the server when you lag out. |  |
| `cl_updateInfoString` | `` | "challenge\14985\motd\This is used by id when new versions come out" | R |
| `cl_yawspeed` | `140` | set the yaw rate when +left and/or +right are active | A |

### Player movement physics (`pmove_*`)

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `pmove_fixed` | `0` | typically the player physics advances in small time steps. when this option is enabled all players will use fixed frequency player physics, the time between... |  |
| `pmove_msec` | `8` | set the time in milliseconds between two advances of the player physics. should do what you want for prediction and should even out the machine dependent... |  |

### Team (`team_*`)

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `team_headmodel` | `` | set head of team_model to a head that will only be used during team game play | U A |
| `team_model` | `` | set player model that will only be used during team game play | U A |

### Gun view tweaks (`gun_*`)

_iOS: Active (viewmodel)_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `gun_frame` | `0` | turns off weapon animation and displays specified frame in the weapons animation sequence 0=animate 1 and up step through frames...(c: |  |
| `gun_x` | `0` | set the x location of the gun model (one is up and down one is side to side) |  |
| `gun_y` | `0` | set the y location of the gun model (one is up and down one is side to side) |  |
| `gun_z` | `0` | set the z location of the gun model (possibly angle?) |  |

### Renderer (`r_*`) - extras from community big-list

_iOS: Mostly N/A-GL on iOS Metal_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `r_allowExtensions` | `1` | use all of the OpenGL extensions your card is capable of | AL |
| `r_allowSoftwareGL` | `0` | toggle the use of the default software OpenGL driver supplied by the Operating System < maddog | L |
| `r_ambientScale` | `0.5` | set the scale or intensity of ambient light | C |
| `r_clear` | `0` | toggle the clearing of the screen between frames | C |
| `r_colorbits` | `16` | set number of bits used for each color from 0 to 32 bit | AL |
| `r_colorMipLevels` | `0` | "texture visualization tool" John Carmack | L |
| `r_customaspect` | `1` | toggle the use of custom screen resolution/sizes | AL |
| `r_customheight` | `1024` | custom resolution (Height) | AL |
| `r_customwidth` | `1600` | custom resolution (Width) | AL |
| `r_debuglight` | `0` | possibly toggle debugging of lighting effects |  |
| `r_debugSort` | `0` | possibly toggle debugging of sorting of list like scoreboard | C |
| `r_debugSurface` | `0` | possibly used for debugging the curve rendering and possibly for map debugging. | C |
| `r_debugSurfaceUpdate` | `1` | possibly used for debugging the curve rendering and possibly for map debugging. |  |
| `r_depthbits` | `16` | set number of bits used for color depth from 0 to 24 bit | A L |
| `r_detailtextures` | `1` | toggle the use of detailed textures, when disabled every stage of a shader is rendered except those with the keyword "detail". when enabled detail stages are... | A L |
| `r_directedScale` | `1` | set scale/intensity of light shinning directly upon objects | C |
| `r_displayRefresh` | `0` | monitor refresh rate in game (will change desktop settings too in Windows 98 anyway) | L |
| `r_dlightBacks` | `1` | "brighter areas are changed more by dlights than dark areas. I don't feel TOO bad about that, because its not like the dlight is much of a proper lighting... | A |
| `r_drawBuffer` | `GL_BACK` | set which frame buffer to draw into. basically you draw into a "back" buffer while simultaneously showing a "front" buffer. next frame you "swap" these. the... |  |
| `r_drawentities` | `1` | toggle display of brush entities | C |
| `r_drawstrips` | `1` | toggle triangle strips rendering method |  |
| `r_drawSun` | `1` | set to zero if you do not want to render sunlight into the equation of lighting effects | A |
| `r_drawworld` | `1` | toggle rendering of map architecture | C |
| `r_dynamiclight` | `0` | toggle dynamic lighting (different "dynamic" method of rendering lights) | A |
| `r_ext_compiled_vertex_array` | `` | toggle hardware compiled vertex array rendering method default is 1 | AL |
| `r_ext_compress_textures` | `1` | toggle compression of textures | AL |
| `r_ext_compressed_textures` | `1` | toggle compression of textures (1.27g changed to past tense compressed) | AL |
| `r_ext_gamma_control` | `1` | enable external gamma control settings | AL |
| `r_ext_multitexture` | `1` | toggle hardware mutitexturing if set to zero is a direct FPS benefit | AL |
| `r_ext_swapinterval` | `1` | toggle hardware frame swapping | AL |
| `r_ext_texenv_add` | `1` | possible duplicate cvar or an extension to the r_ext_texture_add variable | AL |
| `r_ext_texture_env_add` | `1` | toggle additive blending in multitexturing. If not present, OpenGL limits you to multiplicative blending only, so additive will require an extra pass. -... | AL |
| `r_facePlaneCull` | `1` | toggle culling of brush faces not in view (0 will slow FPS) | A |
| `r_fastsky` | `1` | toggle fast rendering of sky if set to 1 (0 is default and will slow FPS when outdoors 1 will disable your ability to see through portals)...Thanx hacker | A |
| `r_finish` | `1` | toggle synchronization of rendered frames (engine will wait for GL calls to finish) | A |
| `r_fixtjunctions` | `1` | toggle fixing of a problem with a certain type of vertex in models that can make gaps appear between polygons - Andre Lucas | L |
| `r_flareFade` | `7` | set scale of fading of flares in relation to distance | C |
| `r_flares` | `0` | toggle projectile flare and lighting effect. the flare effect is a translucent disk that is used to alter the colors around lights with a corona effect | A |
| `r_flaresSize` | `40` | set the size of flares? I wish you could make the big balls smaller now those are flares | C |
| `r_fullbright` | `0` | toggle textures to full brightness level (is set as a cheat code?) boy who turned on the lights…(c: | L C |
| `r_fullscreen` | `1` | toggle full screen or play in a window | A L |
| `r_gamma` | `1` | gamma correction | A |
| `r_glDriver` | `opengl32` | used "x" OpenGL driver (Standard OpenGL32 or 3dfxvgl) | A L |
| `r_ignore` | `0` | possibly ignores hardware driver settings in favor of variable settings | C |
| `r_ignoreFastPath` | `0` | possibly to disable the looking outside of the PAK file first feature in case of duplicate file names etc. | A L |
| `r_ignoreGLErrors` | `1` | ignores OpenGL errors that occur | A |
| `r_ignorehwgamma` | `0` | possibly to toggle the use of DirectX gamma correction or video driver gamma correction? | A L |
| `r_ignoreOffset` | `0` | see r_offsetfactor this will just turn the offset off completely | A L |
| `r_inGameVideo` | `1` | toggle the display of in game animations on bigscreen map objects that display a camera view of the current game | A |
| `r_intensity` | `1` | increase brightness of texture colors (may be like gl_modulate?) | L |
| `r_lastValidRenderer` | `` | last known video driver (RIVA 128/RIVA 128 ZX (PCI)) | A |
| `r_lightmap` | `0` | toggle entire map to full brightness level all textures become blurred with light (is set as a cheat code?) |  |
| `r_lightningSegmentLength` | `32` | possibly to set the distance between bends in the lightning bolt of the lightning gun…(c: | A |
| `r_lockpvs` | `0` | disable update to PVS table as player moves through map (new areas not rendered) | C |
| `r_lockview` | `0` | possibly was intended to lock a certain Field Of View (FOV) is removed now |  |
| `r_lodbias` | `0` | change the geometric level of detail (0 - 2) | A |
| `r_lodCurveError` | `250` | another level of detail setting if set to 10000 "don't drop curve rows for a long time" John Carmack (really mean 3D cards only??) | A |
| `r_lodscale` | `5` | set scale for level of detail adjustment | C |
| `r_logFile` | `0` | possibly toggles logging of rendering errors | C |
| `r_mapOverBrightBits` | `2` | set intensity level of lights reflected from textures | L |
| `r_maskMinidriver` | `0` | treat the current OpenGL32 driver as an ICD, even if it is in fact a MCD Questy/Zoid | L |
| `r_maxpolys` | `600` |  |  |
| `r_maxpolyverts` | `3000` |  |  |
| `r_measureOverdraw` | `0` | overdraw' is when the same pixel is written to more than once when rendering a scene. I guess r_measureOverdraw is used to see how much is going on. used for... | C |
| `r_mode` | `3` | set video display mode (resolution), use listmodes for list of modes (3 is 640X480) | A L |
| `r_nobind` | `0` | toggle the binding of textures to triangles | C |
| `r_nocull` | `0` | toggle rendering of hidden objects (1=slow performance) | C |
| `r_nocurves` | `0` | map diagnostic command toggle the use of curved geometry | C |
| `r_nolightcalc` | `0` | disable lighting and shadow calculations…hmm |  |
| `r_noportals` | `0` | toggle player view through portals | C |
| `r_norefresh` | `0` | toggle the refreshing of the rendered display | C |
| `r_novis` | `0` | the VIS tables hold information about which areas should be displayed from other areas. | C |
| `r_offsetfactor` | `-1` | control the OpenGL Polygon Offset, If you see lines appearing in decals, or they seem to flick on and off, these variables may help out. - Questy/Andre | C |
| `r_offsetunits` | `-2` | see r_offsetfactor | C |
| `r_overBrightBits` | `1` | possibly similar to r_mapOverBrightBits (no visible effect on mine) | A L |
| `r_picmip` | `1` | set maximum texture size (0 - 3, 3=fastest 0=quality) | A L |
| `r_portalOnly` | `0` | when set to "1" turns off stencil buffering for portals, this allows you to see the entire portal before it's clipped, i.e. more of the room, to get a better... |  |
| `r_preloadTextures` | `0` | enable video processor to pre-cache textures | A L |
| `r_primitives` | `0` | set the rendering method. -1 = skips drawing 0 = uses glDrawElements if compiled vertex arrays are present, or strips of glArrayElement if not present 1 =... | A |
| `r_printShaders` | `0` | possibly toggle the printing on console of the number of shaders used? | A |
| `r_railCoreWidth` | `16` | set size of the rail trail's core | A |
| `r_railSegmentLength` | `64` | set distance between rail "sun bursts" | A |
| `r_railWidth` | `128` | set width of the rail trail | A |
| `r_roundImagesDown` | `1` | set rounding down amount (larger = faster, lower quality) | A L |
| `r_saveFontData` | `0` |  |  |
| `r_showcluster` | `0` | toggle the display of clusters by number as the player enters them on the currently loaded map<maddog | C |
| `r_showImages` | `0` | toggle displaying a collage of all image files when set to a one...texture use debugging tool |  |
| `r_shownormals` | `0` | toggle the drawing of short lines indicating brush and entity polygon vertices, useful when debugging model lighting - Andre Lucas < maddog | C |
| `r_showsky` | `0` | enable rendering sky in front of other objects | C |
| `r_showSmp` | `0` | toggle display of multi processor (SMP) info on the HUD | C |
| `r_showtris` | `0` | map diagnostic command show triangles, pretty cool looking... | C |
| `r_simpleMipMaps` | `1` | toggle the use of "simple" mip mapping. used to "dumb-down" resoluiton displays for slower machines | A L |
| `r_singleShader` | `0` | possibly toggles use of 1 shader for objects that have multiple shaders | L C |
| `r_skipBackEnd` | `0` | possibly to toggle the skipping of the backend video buffer | C |
| `r_smp` | `0` | toggle the use of multi processor acceleration code | A L |
| `r_speeds` | `0` | show the rendering info e.g. how many triangles are drawn added r_speeds timing info to cinematic texture uploads "John Carmack" | C |
| `r_stencilbits` | `8` | stencil buffer size (0, 8bit, and 16bit) | A L |
| `r_stereo` | `0` | toggle the use of stereo separation for 3D glasses | A L |
| `r_subdivisions` | `4` | set maximum level of detail. (an example would be the complexity of curves. 1=highest detail) | A L |
| `r_swapInterval` | `0` | toggle frame swapping. | A |
| `r_texturebits` | `0` | set number of bits used for each texture from 0 to 32 bit | A L |
| `r_textureMode` | `` | select texture mode. "GL_LINEAR_MIPMAP_NEAREST" (nearest or linear) | A |
| `r_uiFullScreen` | `0` |  |  |
| `r_verbose` | `0` | toggle display of rendering commands as they happen on the console | C |
| `r_vertexLight` | `1` | enable vertex lighting (faster, lower quality than lightmap) removes lightmaps, forces every shader to only use a single rendering pass, no layered... | A L |
| `r_znear` | `4` | set how close objects can be to the player before they're clipped out of the scene - Questy/Andre | C |

### Sound (`s_*`) - extras (incl. A3D legacy)

_iOS: A3D dead; core cvars active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `s_2dvolume` | `0.7` | vortex of sound - has a good description of this A3D variable |  |
| `s_bloat` | `2.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_compression` | `1` | toggle the use of sound compression | A |
| `s_distance` | `100.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_doppler` | `1.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_fogeq` | `0.8` | vortex of sound - has a good description of this A3D variable |  |
| `s_geometry` | `1` | vortex of sound - has a good description of this A3D variable |  |
| `s_initsound` | `1` | toggle weather sound is initialized or not (on next game) |  |
| `s_khz` | `11` | set the sampling frequency of sounds lower=performance higher=quality | A |
| `s_leafnum` | `0` |  | A |
| `s_loadas8bit` | `1` | load sounds in 8bit mode | A |
| `s_max_distance` | `1000.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_min_distance` | `3.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_mixahead` | `0.2` | set delay before mixing sound samples. | A |
| `s_mixPreStep` | `0.05` | possibly to set the prefetching of sound on sound cards that have that power | A |
| `s_musicvolume` | `1` | music volume level 0=off | A |
| `s_numpolys` | `400` | vortex of sound - has a good description of this A3D variable | A |
| `s_occ_eq` | `0.75` | vortex of sound - has a good description of this A3D variable | A |
| `s_occfactor` | `0.5` | vortex of sound - has a good description of this A3D variable | A |
| `s_occlude` | `0` | vortex of sound - has a good description of this A3D variable |  |
| `s_polykeep` | `1000000000` |  | A |
| `s_polyreflectsize` | `10000000` |  | A |
| `s_polysize` | `10000000` |  | A |
| `s_refdelay` | `2.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_refgain` | `0.45` | vortex of sound - has a good description of this A3D variable | A |
| `s_reflect` | `1` | vortex of sound - has a good description of this A3D variable |  |
| `s_rolloff` | `1.0` | vortex of sound - has a good description of this A3D variable | A |
| `s_separation` | `0.5` | set separation between left and right sound channels (this one is it) | A |
| `s_show` | `0` | toggle display of paths and filenames of all sound files as they are played. | C |
| `s_testsound` | `0` | toggle a test tone to test sound system. 0=disables,1=toggles. | C |
| `s_usingA3D` | `0` | vortex of sound - has a good description of this A3D variable | R |
| `s_volume` | `0.7` | Sound FX Volume | A |
| `s_watereq` | `0.2` | vortex of sound - has a good description of this A3D variable |  |

### Network (`net_*`) - extras

_iOS: Active where applicable_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `net_ip` | `localhost` | variable holds the IP of the local machine (or the "hosts" name) passed from the OS environment | L |
| `net_noipx` | `0` | toggle the use of IPX/SPX network protocol (command line only) | A L |
| `net_noudp` | `0` | toggle the use of TCP/IP network protocol (command line only) | A L |
| `net_port` | `27960` | set port number server will use if you want to run more than one instance of Q3A server on the same machine | L |
| `net_qport` | `16392` | set internal network port. this allows more than one person to play from behind a NAT router by using only one IP address | I |
| `net_socksEnabled` | `0` | toggle the use of network socks 5 protocol enabling firewall access (only settable at init time from the OS command line) - Graeme Devine | A L |
| `net_socksPassword` | `` | variable holds password for socks firewall access supports no authentication and username/password authentication method (RFC-1929); it does NOT support... | A L |
| `net_socksPort` | `1080` | set proxy and/or firewall port default is 1080 (only settable at init time from the OS command line) - Graeme Devine | A L |
| `net_socksServer` | `` | set the address (name or IP number) of the SOCKS server (firewall machine), NOT a Q3ATEST server. (only settable at init time from the OS command line) -... | A L |
| `net_socksUsername` | `` | variable holds username for socks firewall supports no authentication and username/password authentication method (RFC-1929); it does NOT support GSS-API... | A L |

### Common engine (`com_*`) - extras

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `com_blood` | `1` | toggle the blood mist effect in the gib animations. 0 option for no gibs and no blood on hits "John Carmack" | A |
| `com_buildScript` | `0` | possibly used for the loading and caching of game data like a list of things to be loaded and caches the data for quicker reloading |  |
| `com_cameraMode` | `0` | seems to toggle the view of your player model off and on when in 3D camera view | C |
| `com_dropsim` | `0` | for testing simulates packet loss during communication drops | C |
| `com_hunkMegs` | `20` | set the amount of memory you want quake3.exe to reserve for game play dedicated server memory optimizations. Tips: com_hunkMegs 4 sv_maxclients 3 bot_enable 0... | A L |
| `com_introplayed` | `1` | toggle displaying of intro cinematic once it has been seen this variable keeps it from playing each time, to see it again set this to zero | A |
| `com_maxfps` | `100` | set max frames per second you receive from server (maxfps was removed) | A |
| `com_showtrace` | `0` | toggle display of packet traces. 0=disables,1=toggles. | C |
| `com_soundMegs` | `8` | com_soundmegs and com_zonemegs can be adjusted to provide better performance on systems with more than 64mb of memory. the default configuration is set to... | A L |
| `com_speeds` | `0` | toggle display of frame counter, all, sv, cl, gm, rf, and bk whatever they are |  |
| `com_zoneMegs` | `16` | com_soundmegs and com_zonemegs can be adjusted to provide better performance on systems with more than 64mb of memory. the default configuration is set to... | A L |

### Filesystem (`fs_*`) - extras

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `fs_basegame` | `` | allows people to base mods upon mods syntax to follow | I |
| `fs_basepath` | `` | set base path root C:\Program Files\Quake III Arena for files to be downloaded from this path may change for TC's and MOD's | I |
| `fs_cdpath` | `` | possibly a variable to use when the full CD was copied to the HDD | I |
| `fs_copyfiles` | `0` | toggle if files can be copied from servers or if client will download | I |
| `fs_debug` | `0` | possibly enables file server debug mode for download/uploads or something |  |
| `fs_game` | `` | set gamedir set the game folder/dir default is baseq3 (other for MODS) | S I |
| `fs_homepath` | `` | possibly for TC's and MODS the default is the path to quake3.exe | I |
| `fs_openedList` | `` | variable holds a list of all the pk3 files the client found | I |
| `fs_referencedList` | `` | variable holds a list of all the pk3 files the client loaded data from | I |
| `fs_restrict` | `` | demoversion if set to 1 restricts game to 4 arenas like the Q3A demo | I |

### Collision (`cm_*`) - extras

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `cm_curveClipHack` | `0` | must have been a cheat!!! removed now |  |
| `cm_noAreas` | `0` | toggle the ability of the player bounding box to clip through areas? | C |
| `cm_noCurves` | `0` | toggle the ability of the player bounding box to clip through curved surfaces | C |
| `cm_playerCurveClip` | `1` | toggles the ability of the player bounding box to respect curved surfaces. | A C |

### Remote console (`rcon_*`) - extras

_iOS: Active_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `rcon_password` | `` | set password for remote console control of the server removed cause dupe |  |

### Joystick (`joy_*`)

_iOS: N/A on iOS (use GCController bridge)_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `joy_advanced` | `0` | applies game controller axis mapping settings < maddog |  |
| `joy_advaxisr` | `0` | bind an action to the joystick r axis |  |
| `joy_advaxisu` | `0` | bind an action to the joystick u axis |  |
| `joy_advaxisv` | `0` | bind an action to the joystick v axis |  |
| `joy_advaxisx` | `0` | bind an action to the joystick x axis |  |
| `joy_advaxisy` | `0` | bind an action to the joystick y axis |  |
| `joy_advaxisz` | `0` | bind an action to the joystick z axis |  |
| `joy_forwardsensitivity` | `-1` | set forward/back sensitivity (negative is inverted) |  |
| `joy_forwardthreshold` | `0.15` | set forward/back dead zone |  |
| `joy_name` | `joystick` | set joystick name |  |
| `joy_pitchsensitivity` | `1` | set pitch sensitivity (negative is inverted) |  |
| `joy_pitchthreshold` | `0.15` | set pitch dead zone |  |
| `joy_sidesensitivity` | `-1` | set side sensitivity (negative is inverted) |  |
| `joy_sidethreshold` | `0.15` | set side dead zone |  |
| `joy_threshold` | `0.15` | possibly an overall threshold setting all other joy variables removed in 1.08 | A |
| `joy_upsensitivity` | `-1` | set up/down sensitivity (negative is inverted) |  |
| `joy_upthreshold` | `0.15` | set up/down dead zone |  |
| `joy_yawsensitivity` | `-1` | set yaw sensitivity (negative is inverted) |  |
| `joy_yawthreshold` | `0.15` | set yaw dead zone |  |

### Input (`in_*`)

_iOS: Mostly N/A (desktop drivers)_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `in_debugjoystick` | `0` | possibly to set the debug level of direct input |  |
| `in_joyBall` | `0` | possibly to allow support for trackball style joy sticks and orb's | A |
| `in_joyBallScale` | `0.02` | possibly sets the scale of a joyball rotation to player model rotation? | A |
| `in_joystick` | `0` | toggle the initialization of the joystick (command line) | A L |
| `in_midi` | `0` | toggle the use of a midi port as an input device r-d-x | A |
| `in_midichannel` | `1` | toggle the use of a midi channel as an input device r-d-x | A |
| `in_mididevice` | `0` | toggle the use of a midi device as an input device r-d-x | A |
| `in_midiport` | `1` | toggle the use of a midi port as an input device r-d-x | A |
| `in_mouse` | `1` | toggle initialization of the mouse as an input device (command line) | AL |

### Legacy GL driver (`gl_*`)

_iOS: N/A-GL_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `gl_pixelformat` | `` | color(16) depth(16) stencil(8) sets up how many bits for each pixel item 8, 16, or 32 bit? | R |
| `gl_renderer` | `` | variable holds the GL Renderer driver information "RIVA 128/RIVA 128 ZX (PCI)" | R |
| `gl_vendor` | `` | variable holds the brand of your chipmaker "NVIDIA Corporation" | R |
| `gl_version` | `` | variable holds the driver version number "1.1.0" | R |

### Windows platform (`win_*`)

_iOS: N/A_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `win_hinstance` | `` | address of the handle instance of quake3 under windows | R |
| `win_wndproc` | `` | hmm..."4368704" | R |

### System info (`sys_*`)

_iOS: Read-only / N/A_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `sys_cpuid` | `33` | more snooping into your CPU |  |
| `sys_cpustring` | `` | variable holds a string that identifies your processor |  |

### Direct3D legacy (`d_*`)

_iOS: N/A_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `d_bot` | `` | all d_ commands have been removed to disable bots most likely |  |
| `d_botai` | `0` | all d_ commands have been removed to disable bots most likely |  |
| `d_botaiming` | `0` | all d_ commands have been removed to disable bots most likely |  |
| `d_botfreeze` | `0` | all d_ commands have been removed to disable bots most likely |  |
| `d_break` | `0` | all d_ commands have been removed to disable bots most likely |  |
| `d_noroam` | `0` | all d_ commands have been removed to disable bots most likely |  |

### Screen (`scr_*`)

_iOS: N/A_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `scr_conspeed` | `3` | set how fast the console goes up and down |  |

### Host (`host_*`)

_iOS: N/A_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `host_speeds` | `0` | toggle the display of timing information sv=server cl=client gm=gametime rf=render time all=total time |  |

### Miscellaneous (no prefix)

_iOS: Mixed_

| Cvar | Default | Description | Class |
|---|---|---|---|
| `activeaction` | `` | variable holds a command to be executed upon connecting to a server |  |
| `arch` | `win98` | architecture/operating system |  |
| `capturelimit` | `8` | set # of times a team must grab the others flag before the win is declared | S A |
| `cheats` | `0` | enable cheating commands (give all) (serverside only) | S I L |
| `color` | `1` | rail trail color blue/green/cyan/red/magenta/yellow/white respectively 1/2/3/4/5/6/7 | U A |
| `color1` | `2` | spiral rail trail color spiral core - special thanks to schiz Jax_Gator Dekard blue/green/cyan/red/magenta/yellow/white respectively 1/2/3/4/5/6/7 | U A |
| `color2` | `5` | spiral rail trail color spiral ring - special thanks to schiz Jax_Gator Dekard blue/green/cyan/red/magenta/yellow/white respectively 1/2/3/4/5/6/7 | U A |
| `conback` | `` | select console background file "gfx/2d/conback.tga" |  |
| `crosshairhealth` | `1` | show health by the cross hairs | A |
| `crosshairsize` | `24` | crosshair size...incase you have crosshair envy (c: | A |
| `debuggraph` | `0` |  | C |
| `dedicated` | `0` | set console to server only 0 is a listen, 1 is lan, and 2 is internet (command line cvar causes engine not to load 3D game just a server console... | L |
| `developer` | `0` | enable developer mode (more verbose messages) |  |
| `disable.cfg` | `` | enable.cfg | configs by zYmO |
| `dmflags` | `0` | set deathmatch flags originally I posted the values of Quake 2 dmflags but have since tested them and most of them don't work |  |
| `fixedtime` | `0` | toggle the rendering of every frame the game will wait until each frame is completely rendered before sending the next frame | C |
| `fov` | `90` | field of view/vision "90" is default higher numbers give peripheral vision. | A |
| `fraglimit` | `20` | set fraglimit on a server (0 is no limit) | S A |
| `freelook` | `1` | steer aim and control head movement with the mouse…a must (c: | A |
| `gamedate` | `` | Aug 20 2001 | R |
| `gamename` | `baseq3` | display the game name for TC's basedir would be other than baseq3 | S R |
| `graphheight` | `32` | set height, in pixels?, for graph displays | C |
| `graphscale` | `1` | set scale multiplier for graph displays | C |
| `graphshift` | `0` | set offset for graph displays | C |
| `handicap` | `100` | set player handicap (max health), valid values 1 - 99 | U A |
| `headmodel` | `` | changes only the head of the model to another model Example: If you are playing as the Grunt model, /headmodel "sarge" will stick Sarge's head on Grunt's body... | U A |
| `journal` | `0` | possibly logs console events but is read only and can not be toggled | I |
| `logfile` | `0` | enable console logging 0=no log 1=buffered 2=continuous 3=append so as not to overwrite old logs |  |
| `mapname` | `` | display the name of the current map being used | S R |
| `maxfps` | `0` | set the max frames per second the server should send you |  |
| `memorydump` | `0` | possibly used for debugging memory allocation/use? |  |
| `model` | `visor/blue` | set the model used to represent your player Hey John a 3D Keen model would be nice…(c: | U A |
| `name` | `Commander Keen` | pick your own be original (no Player) | U A |
| `nextmap` | `` | variable holds the name of the next map in the server rotation myserver.cfg |  |
| `nohealth` | `0` | toggle the use of health items on next map or do it now from the command line | S A |
| `password` | `` | set password for entering a password protected server | U |
| `paused` | `0` | possible to allow the game to pause while in single player mode |  |
| `port` | `27960` | set port number server will use if you want to run more than one instance of Q3A server on the same machine |  |
| `protocol` | ` 66 ` | display network protocol version. Useful for backward compatibility with servers with otherwise incompatible versions < maddog read only | S R |
| `qport` | `59337` | set internal network port. this allows more than one person to play from behind a NAT router by using only one IP address | I |
| `rate` | `` | modem speed/rate of data transfer "4500" (take a zero off the end of your connection speed?) | U A |
| `rconAddress` | `` | variable holds IP address of the server for rcon |  |
| `rconPassword` | `` | set password for remote console control of the server |  |
| `sensitivity` | `9` | set how far your mouse moves in relation to travel on the mouse pad | A |
| `server1` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server10` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server11` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server12` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server13` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server14` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server15` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server16` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server2` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server3` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server4` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server5` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server6` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server7` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server8` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `server9` | `` | holds IP/URL of a servers from the favorite servers list - Dr Qube | A |
| `session` | `2` | possibly holds the value for the active session number when running multiple addresses and sockets for multiple servers on one machine? |  |
| `session1` | `0 300 1 0 0 0` | possibly to set up multiple addresses and sockets for multiple servers on one machine (can you say BFServer with multiple processors?) |  |
| `session2` | `0 300 1 0 0 0` | possibly to set up multiple addresses and sockets for multiple servers on one machine (can you say BFServer with multiple processors?) |  |
| `session3` | `0 300 1 0 0 0` | possibly to set up multiple addresses and sockets for multiple servers on one machine (can you say BFServer with multiple processors?) |  |
| `session4` | `0 300 1 0 0 0` | possibly to set up multiple addresses and sockets for multiple servers on one machine (can you say BFServer with multiple processors?) |  |
| `sex` | `male` | set gender for model characteristics (sounds, obituary's etc.) | U A |
| `showdrop` | `0` | toggle display of dropped packets. 0=disables,1=toggles. |  |
| `showpackets` | `0` | toggle display of all packets sent and received. 0=disables,1=toggles. |  |
| `showtrace` | `0` | toggle display of packet traces. 0=disables,1=toggles. |  |
| `snaps` | `20` | set the number of snapshots sever will send to a client (server run at 40Hz, so use 40, 20, or 10) | U A |
| `snd` | `visor` | select which model sounds your player uses (mix it up) | U A |
| `teamflags` | `0` | set flags for team play (probably will be a hex value like deathmatch flags) | S A |
| `teamoverlay` | `0` | toggle the drawing of the colored team overlay on the HUD | U R |
| `teamtask` | `0` | variable holds the number of the team task you are currently asigned 1 - offense 2 - defense 3 - point/patroll 4 - following 5 - retrieving 6 - escort(gaurding... | U |
| `timedemo` | `0` | when set to "1" times a demo and returns frames per second like a benchmark | C |
| `timegraph` | `0` | toggle the display of the timegraph. . | C |
| `timelimit` | `0` | amount of time before new map loads or next match begins | S A |
| `timescale` | `1` | set the ratio between game time and real time | C |
| `username` | `vern` | variable holds your network login id from %username% env variable…hmmm? id hackers! |  |
| `version` | `` | Q3 1.30 win-x86 Aug 20 2001 | S R |
| `versionNumber` | `` | "Q3T 1.08" | A |
| `viewlog` | `0` | toggle the display of the startup console window over the game screen | C |
| `viewsize` | `100` | changes view port size 0 - 100 (you probably wouldn't want less than 100) | A |
| `zoomfov` | `22.5` | what the zoomed in field of view will be any thing more than 30 would not be sniper friendly | A |

---

## Full command list (quakearea.com, uploaded source)

Console commands extracted from the Quake Area table. `+cmd`/`-cmd` pairs are keypress/keyrelease actions (bind to a key).

### Movement / action (`+cmd` / `-cmd` pairs)

| Command | Description |
|---|---|
| `+attack` | start attacking (shooting, punching) |
| `-attack` | stop attacking (shooting, punching) |
| `+back` | start moving backwards |
| `-back` | stop moving backwards |
| `+button0` | start firing same as mouse button 1 (fires weapon) |
| `-button0` | stop firing same as mouse button 1 (fires weapon) |
| `+button1` | start displaying chat bubble |
| `-button1` | stop displaying chat bubble |
| `+button10` | start hand signal, player model looks like it's motioning to team "come to my right side" (Team Arena Models Only) |
| `-button10` | stop hand signal, player model looks like it's motioning to team "come to my right side" (Team Arena Models Only) |
| `+button11` |  |
| `-button11` |  |
| `+button12` |  |
| `-button12` |  |
| `+button13` |  |
| `-button13` |  |
| `+button14` |  |
| `-button14` |  |
| `+button2` | start using items (same as enter) |
| `-button2` | stop using items (same as releasing enter) |
| `+button3` | start player taunt animation |
| `-button3` | stop player taunt animation |
| `+button4` | fixed +button4 not causing footsteps "John Carmack" |
| `-button4` | fixed +button4 not causing footsteps "John Carmack" |
| `+button5` | used for MODS also used by Team Arena Mission Pack |
| `-button5` | used for MODS also used by Team Arena Mission Pack |
| `+button6` | used for MODS also used by Team Arena Mission Pack |
| `-button6` | used for MODS also used by Team Arena Mission Pack |
| `+button7` | start hand signal, player model looks like it's motioning to team "move forward" (Team Arena Models Only) |
| `-button7` | stop hand signal, player model looks like it's motioning to team "move forward" (Team Arena Models Only) |
| `+button8` | start hand signal, player model looks like it's motioning to team "come here" (Team Arena Models Only) |
| `-button8` | stop hand signal, player model looks like it's motioning to team "come here" (Team Arena Models Only) |
| `+button9` | stop hand signal, player model looks like it's motioning to team "come to my left side" (Team Arena Models Only) |
| `-button9` | start hand signal, player model looks like it's motioning to team "come to my left side" (Team Arena Models Only) |
| `+forward` | start moving forward |
| `-forward` | stop moving forward |
| `+info` | start displaying server information (sv_hostname, map, rules, g_gametype, fraglimit) |
| `-info` | stop displaying server information (sv_hostname, map, rules, g_gametype, fraglimit) |
| `+left` | start turning left |
| `-left` | stop turning left |
| `+lookdown` | start looking down |
| `-lookdown` | stop looking down |
| `+lookup` | start looking up |
| `-lookup` | stop looking up |
| `+mlook` | start using mouse movements to control head movement |
| `-mlook` | stop using mouse look |
| `+movedown` | start moving down (crouch, climb down, swim down) |
| `-movedown` | stop moving down (crouch, climb down, swim down) |
| `+moveleft` | start strafing to the left |
| `-moveleft` | stop strafing to the left |
| `+moveright` | start strafing to the right |
| `-moveright` | stop strafing to the right |
| `+moveup` | start moving up (jump, climb up, swim up) |
| `-moveup` | stop moving up (jump, climb up, swim up) |
| `+right` | start turning right |
| `-right` | stop turning right |
| `+scores` | start displaying current scores |
| `-scores` | stop displaying current scores |
| `+speed` | speed toggle bound to shift key by default toggles run/walk |
| `-speed` | speed toggle bound to shift key by default toggles run/walk |
| `+strafe` | start changing directional movement into strafing movement |
| `-strafe` | stop changing directional movement into strafing movement |
| `+zoom` | zoom in to fov specified by the zoomfov variable |
| `-zoom` | zoom out to fov specified by the fov variable |

### Standalone console commands (alphabetical)

| Command | Description |
|---|---|
| `addbot` | add one bot <botlib> name of the bot library <name> name of the bot <skin> skin of the bot <charfile> file with the bot character <charname> name of the... |
| `arena` | load arena and bots "name" from arena.txt (arena <name>) |
| `banClient` | ban a client by slot number used in conjunction with serverstatus you can ban players by their slot number regardless of player name (from server console only)... |
| `banUser` | ban a client by their player name. once the name is entered the players name, IP, and CD-Key are sent to the master server where the player will be band for a... |
| `bind` | assign a key to command(s). (bind <key> "<command>") |
| `bindlist` | list all currently bound keys and what command they are bound to |
| `callteamvote` | allows a team to vote for a captain or team leader |
| `callvote` | callvote <command> vote <y/n> Caller automatically votes yes vote has a 30 second timeout each client can only call 3 votes a level vote is displayed on screen... |
| `centerview` | quickly move current view to the center of screen |
| `changeVectors` | change to vector defined by FIND_NEW_CHANGE_VECTORS as in vector graphics - with vector graphics it is possible to change any element of the picture at any... |
| `cinematic` | play the q3a movie RoQ files (cinematic intro.RoQ) |
| `clear` | clear all text from console |
| `clientinfo` | display name, rate, number of snaps, player model, rail color, and handicap (state number?) |
| `clientkick` | kick a client by slot number used in conjunction with serverstatus you can kick players by their slot number regardless of player name (from server console... |
| `cmd` | send a command to server remote console |
| `cmdlist` | list all available console commands |
| `condump` | condump "x" write the console text to a file where "x" is the name of that file |
| `configstrings` | list the current config strings in effect |
| `connect` | connect to server (connect 204.52.135.50) or (connect serverURL.com) |
| `crash` | causes Q3TEST.EXE to perform an illegal operation in Windows |
| `cvar_restart` | reset all variables back to factory defaults (could be handy) |
| `cvarlist` | list all available console variables and their values |
| `demo` | play demo (demo q3demo001.dm3) |
| `devmap` | load maps in development mode? (loads map with cheats enabled) |
| `dir` | display directory if syntax is correct ex. (dir \) or (dir ..\) or (dir ..\baseq3) |
| `disconnect` | disconnects you from server (local included) |
| `dumpuser` | display user info (handicap, model/color, rail color, more…)(dumpuser "<name>") |
| `echo` | echo a string to the message display to your console only |
| `error` | execute an error routine to protect the server |
| `exec` | execute a config file or script |
| `fdir` | allows the user to search his game directory for the presence of file types. a common use for this might be to search out the file names of maps that are often... |
| `follow` | switch to follow mode (follow "<name>" or follow1 for 1 ST place follow2 for 2 ND etc…) |
| `freeze` | freeze game and all animation for specified time (freeze 5) (5 seconds) |
| `fs_openedList` | display the file name of open pak files (pk3) |
| `Fs_pureList` | this command basically displays the contents of the sv_referencedPaks variable |
| `Fs_referencedList` | this variable basically displays the contents of the sv_referencedPakNames variable |
| `gfxinfo` | returns extensive information about video settings |
| `give` | cheat - give player item (give railgun) |
| `globalservers` | list public servers on the internet |
| `god` | cheat - give player invulnerability |
| `heartbeat` | send a manual heartbeat to the master servers |
| `hunk_stats` | returns value of some registers how many bits high/low and total meminfo command replaces hunk_stats and z_stats "John Carmack" |
| `imagelist` | list currently open images/textures used by the current map. also displays the amount of texture memory the map is using which is the last number displayed |
| `in_restart` | restarts all the input drivers, dinput, joystick, etc |
| `joy_advancedupdate` | removed Graeme says joy support still broken |
| `kick` | kick the player with the given name off the server. if nobody uses the name "all" and "all" is specified as player name then everyone is kicked. if there are... |
| `kill` | kills your player (suicide but can get you unstuck some times) |
| `killserver` | stops server from running and broadcasting heartbeat?? |
| `levelshot` | display the image used at the end of a level |
| `loaddefered` | load models and skins that have not yet been loaded |
| `loaddeferred` | load models and skins that have not yet been loaded (corrected spelling) |
| `localservers` | list servers on LAN or local sub net only |
| `map` | loads specified map (map q3dm7) |
| `map_restart` | resets the game on the same map (also plays fight! sound file and displays FIGHT!) |
| `meminfo` | meminfo command replaces hunk_stats and z_stats "John Carmack" |
| `messagemode` | send a message to everyone |
| `messagemode2` | send a message to teammates |
| `messagemode3` | send a message to tourney opponents? |
| `messagemode4` | send a message to attacker? (does not work) |
| `midiinfo` | display information about MIDI music system |
| `model` | display the name of current player model if no parameters are given (see also model variable) |
| `modelist` | list of accessible screen resolutions |
| `modellist` | list of currently open player models |
| `music` | plays specified music file (music music.wav) |
| `net_restart` | reset all the network related variables like rate etc... |
| `nextframe` | "nextframe", "prevframe", "nextskin", and "prevskin" commands will change the frame or skin of the testmodel. These are bound to F5, F6, F7, and F8 in... |
| `nextskin` | "nextframe", "prevframe", "nextskin", and "prevskin" commands will change the frame or skin of the testmodel. These are bound to F5, F6, F7, and F8 in... |
| `noclip` | no clipping objects (nothing will be solid) |
| `notarget` | BOTS will not fight/see you (good for getting cool screenshots) |
| `path` | display all current game paths |
| `ping` | manually ping a server (ping "<sv_hostname>" or by the IP address) |
| `play` | play a sound file (play sound.wav) |
| `prevframe` | "nextframe", "prevframe", "nextskin", and "prevskin" commands will change the frame or skin of the testmodel. These are bound to F5, F6, F7, and F8 in... |
| `prevskin` | "nextframe", "prevframe", "nextskin", and "prevskin" commands will change the frame or skin of the testmodel. These are bound to F5, F6, F7, and F8 in... |
| `quit` | quit arena and quit Quake 3 Arena and return to your OS…Thanx for flying |
| `rcon` | start a remote console to a server. |
| `reconnect` | re-initialize the connection to the last server you were connected to |
| `record` | records a demo (record mydemo.dm3) (g_syncronousClients must be a 1 to start) |
| `reset` | reset specified variable (reset model) single variable as opposed to cvar_restart…(c: |
| `restart` | restart the game on the current map (server only) |
| `s_disable_a3d` | disable support for Aureal 3D sound system |
| `s_enable_a3d` | enable support for Aureal 3D sound system |
| `s_info` | display information about sound system (replaced soundinfo command) |
| `s_list` | display paths and filenames of all sound files as they are played. (replaced soundlist command) |
| `s_stop` | stop whatever sound that is currently playing from playing. (Replaced stopsound command) |
| `say` | say something to everyone on the server. |
| `say_team` | say something to your team only. |
| `scanservers` | scan the local area network for servers (only works for same subnet) |
| `screenshot` | save current viewport to a TARGA image file (usually named sequentially shot0001.tga) |
| `screenshotJPEG` | save current viewport to a JPEG image file (usually named sequentially shot0001.jpg) |
| `sectorlist` | lists sectors and number of entities in each on the currently loaded map |
| `serverinfo` | gives information about local server from the console of that server |
| `serverrecord` | records a serverside demo (serverrecord srvrdemo.dm3) |
| `serverstatus` | display the current status of the connected server as well as connected users and their slot number. if you specify an IP address it will display the status of... |
| `serverstop` | stops the recording of a serverside demo |
| `set` | set a variable (set <variable name> <commands;separate by;semi;colon>) |
| `seta` | sets the variable with the archive flag will save the last setting to q3config.cfg and reload that setting every time you run the game. Any changes to... |
| `setenv` | sets environment variables |
| `sets` | sets the variable with the serverinfo flag, so it will be transmitted from a server to connecting clients |
| `setu` | sets the variable with the userinfo flag, so it will be transmitted from a client to a server while connecting |
| `setviewpos` | sets the VR coordinates of the players view screen |
| `shaderlist` | list of currently open shaders (light effects). |
| `showip` | display your current TCP/IP address |
| `sizedown` | makes viewport one size smaller |
| `sizeup` | makes viewport one size larger |
| `skinlist` | list of currently open skins |
| `snd_restart` | reinitialize sound |
| `soundinfo` | information about sound system |
| `soundlist` | list of currently open sound files |
| `spdevmap` | load a devmap with bots spawned in. (cheats enabled) |
| `spmap` | load a map with bots spawned in. (cheats disabled) |
| `startOrbit` | start the 3rd person display of your player model and orbit in a circle around it |
| `stats` |  |
| `status` | status of currently connected server |
| `stopdemo` | stop recording demo |
| `stoprecord` | stop recording a demo |
| `stopsound` | stop whatever sound that is currently playing from playing. |
| `systeminfo` | returns values for: g_syncronousclients, sv_serverid, and timescale. |
| `tcmd` | display the current target command or displays some type of code address |
| `team` | set player status. p=player s=spectator red, blue, or free (team free joins smallest/loosing team)also in tourney play team follow1 2 etc.(follow players by... |
| `teamtask` | display the current task you have been assigned 1 - offense 2 - defense 3 - point/patroll 4 - following 5 - retrieving 6 - escort(gaurding flag carrier) 7 -... |
| `teamvote` | allows user to cast a vote on a called team vote yes or no callteamvote <playername> vote <y/n> Caller automatically votes yes vote has a 30 second timeout... |
| `tell` | say something to an individual on the server tell <playername> "go get the flag" |
| `tell_attacker` | possibly to pass a complement to your last known attacker..he he more like insult |
| `tell_target` | possibly to pass a complement back…ha ha more like "Die Llama" |
| `testfog` | removed may have been used for development of fog emulation |
| `testgun` | weapon model dissapears cg_gun 1 does not bring it back. will cause the model to follow the player around and suppress the real view weapon model. The default... |
| `testmodel` | testmodel <path\model.md3> will create a fake entity 100 units in front of the current view position, directly facing the viewer. It will remain immobile, so... |
| `testshader` | covers all brushes and entities with the selected texture, and lights the map using the effect of that texture as well. entering testshader without a parameter... |
| `toggle` | toggle "X", where X is the variable you give, to a 1 if it is 0 and 0 if it is 1 (toggle cg_autoswitch) "The 'toggle' command can toggle write protected... |
| `toggleconsole` | usually bound to ~ the tilde key brings the console up and down |
| `touchFile` | make the file a zero byte file (not a good idea I did not test this one) |
| `unbind` | unbinds a key |
| `unbindall` | unbinds all keys (be careful) |
| `userinfo` | list user information like (possibly replaced by clientinfo) |
| `vid_restart` | reinitialize video |
| `viewpos` | returns player coordinates on the map in x y z form |
| `vminfo` | display information about virtual machine interpreter on the local machine |
| `vmprofile` | possibly more of the virtual machine John's talking about, profile…hmm? |
| `vmtest` | probably a developer test which returns levels of success, returns >display "C: test 1234" |
| `vosay` | use a predefined voice message and play everyone |
| `vosay_team` | use a predefined voice message and play to your team |
| `vote` | allows user to cast a vote on a called vote usually bound to F1 (yes) and F2 (no)...(c: callvote <command> vote <y/n> Caller automatically votes yes vote has a... |
| `votell` | use a predefined voice message and play to a <playername> you specify |
| `vsay` | use a predefined voice message and play to everyone |
| `vsay_team` | use a predefined voice message and play to your team |
| `vstr` | identifies the attached command as a variable sting (bind a vstr "myvariable") |
| `vtaunt` | play a random voice taunt wav file to everyone |
| `vtell` | possibly to play a random voice taunt to a <playername> you specify |
| `vtell_attacker` | possibly to play a random voice taunt to your last known attacker |
| `vtell_target` | possibly to play a random voice taunt at player you last hit |
| `wait` | stop execution and wait one game tick (no alias support will be added in Q3A per J.C.) |
| `weapnext` | switch to the next higher numbered weapon |
| `weapon` | select a weapon by it's number (weapon "5") |
| `weapprev` | switch to the next lower numbered weapon |
| `writeconfig` | saves current configuration to a cfg file…this is cool! (c: |
| `z_stats` | display the memory statistics for the Z-buffer in the game "lists all blocks >= given size" John Carmack meminfo command replaces hunk_stats and z_stats "John... |
