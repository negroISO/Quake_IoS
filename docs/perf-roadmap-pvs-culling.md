TASK: Add PVS+frustum world culling to Quake3-iOS Metal renderer.

FILE: /Users/targus/Documents/Quake_IoS/code/ios/metal_renderer_stub.c ONLY.
DO NOT TOUCH: Swift, MSL, ios_main.m, headers, fog math, lightmaps, blend modes, pipelines.

STARTING STATE WARNING:
The working tree may already contain a partial PVS attempt. First ensure the file has balanced braces and does not leave a half-open block around the world surface emission loop. If partial code is unusable, revert the partial PVS edits before implementing cleanly.

ROOT PROBLEM:
Current Metal path bakes the full BSP into s_world.draws[] and sends s_world.drawCount every frame. Heavy maps like nv15 encode ~74K world draw commands. ioquake3/Quake3e cull world surfaces before backend draw submission via R_MarkLeaves + R_RecursiveWorldNode.

CRITICAL ABI INVARIANT — SWIFT MUST NOT NOTICE:
Swift calls Q3MetalRenderer_GetWorldDrawCommands() and loops 0..<snapshot.worldCommandCount over a CONTIGUOUS command array.
Safe pattern:
1. Keep s_world.draws[] and s_world.drawCount as the full static baked map.
2. Add s_world.visibleDraws[] and s_world.visibleDrawCount.
3. Per frame, copy visible commands contiguously into visibleDraws[0..visibleDrawCount-1].
4. Q3MetalRenderer_GetWorldDrawCommands() returns visibleDraws when culling has produced a list, else s_world.draws.
5. snapshot.worldCommandCount = visibleDrawCount when culling active, else drawCount.
Do NOT set worldCommandCount=visibleCount while still returning s_world.draws.

IMPORTANT Q3 VISIBILITY CORRECTION:
Quake3 BSP LUMP_VISIBILITY is NOT Quake2-style RLE. It is:
  int numClusters;
  int clusterBytes;
  byte bitsets[numClusters * clusterBytes];
Prefer using existing ri.CM_ClusterPVS(cluster) if available; it already returns the right row and handles novis. If parsing the lump locally, copy after the 8-byte header and index as row = vis + cluster * clusterBytes. Do NOT implement 0x00 RLE decompression.

EXISTING LOCAL BSP DATA:
Use the already-loaded tree in metal_renderer_stub.c:
- s_bspWorld.nodes, s_bspWorld.numDecisionNodes, s_bspWorld.numnodes
- bspMnode_t has contents, visframe, mins/maxs, parent, plane, children, cluster, area, firstmarksurface, nummarksurfaces.
- s_bspWorld.surfaces is a contiguous bspMsurface_t array. If a mark surface pointer is `surf`, compute surface index with `(int)(surf - s_bspWorld.surfaces)` and bounds-check.
- bspMsurface_t already has viewCount; use it or add a separate surfaceVisFrame/int array to dedupe surfaces spanning multiple leaves.

IMPLEMENTATION:
1. At map load, allocate:
   - s_world.surfaceDrawRanges sized to surfaceCount.
   - s_world.visibleDraws sized to totalDraws or final s_world.drawCount capacity.
   Free both in FreeWorldMapData.

2. Fill surface->draw range while building s_world.draws:
   For each source BSP surface i, capture `uint32_t first = drawCursor;` before that surface emits stages/lightmap/fog, then after emission set:
     s_world.surfaceDrawRanges[i].firstDraw = first;
     s_world.surfaceDrawRanges[i].drawCount = drawCursor - first;
   This is the only allowed edit inside the emission loop. Do not change how draws are emitted.

3. Add PointInLeaf equivalent using s_bspWorld.nodes and node planes.

4. Add MarkLeaves using Q3 semantics:
   - Find leaf for fd->vieworg / pvs origin.
   - Get cluster.
   - Use a persistent vis stamp (like ioq3 tr.visCount), not frameNum if you intend to skip same-cluster remarking.
     If cluster unchanged, keep using the previous stamp; do not compare against a new frameNum or all nodes become stale.
   - If no valid vis/PVS row, mark all non-solid leaves/nodes visible as fallback.
   - For every leaf whose cluster bit is visible, walk parent chain setting node->visframe = currentVisStamp.
   - Optional areamask can be ignored in first pass unless fd exposes it cleanly.

5. Build frustum planes inside RE_RenderScene after vieworg/axis/fov fallback is finalized.
   Use fd->viewaxis[0..2], fovX, fovY. Copy formula from code/renderervk/tr_main.c R_SetupFrustum for 4 side planes. Call SetPlaneSignbits on each plane.

6. Add RecursiveWorldNode:
   - PVS reject: if node->visframe != currentVisStamp return.
   - Frustum AABB reject with BoxOnPlaneSide(node->mins,node->maxs,&frustum[p]).
   - If leaf: iterate node->firstmarksurface/nummarksurfaces, dedupe surface, append that surface range into visibleDraws by copying commands from s_world.draws.
   - Else recurse children front/back. Order is not critical for opaque, but preserve deterministic order.

7. Per-frame call site:
   In RE_RenderScene, after vieworg/axis/fov are valid and before assigning s_frameSnapshot.worldCommandCount, run:
     BuildVisibleWorldDraws(vieworg, axis0, axis1, axis2, fovX, fovY, fd)
   Only for world scene: s_world.loaded && !(fd->rdflags & RDF_NOWORLDMODEL).

8. Accessors/snapshot:
   Q3MetalRenderer_GetWorldDrawCommands returns visibleDraws if visibleDrawCount > 0 else draws.
   s_frameSnapshot.worldCommandCount = visibleDrawCount if culling active else drawCount.
   Update debug log to print both visible/static draw counts.

9. R_inPVS:
   Replace stub with real PointInLeaf + ri.CM_ClusterPVS cluster-bit test. Return qfalse for invalid clusters.

HARD RULES:
- Do not change Q3MetalWorldDrawCmd layout.
- Do not change Swift or MSL.
- Do not change draw emission semantics/stages/fog/lightmaps.
- If implementation cannot be completed, revert to clean tree; no half-patches.
- Build check at least: braces balance, no undefined globals, arm64 simulator compile if possible.

DELIVERABLE:
- Edited metal_renderer_stub.c only.
- Summary with line numbers: visibility source, mark/recursive functions, RE_RenderScene call site, accessor/snapshot changes.
- Report static draw count vs visible draw count from log if run.

EXPECTED IMPACT:
nv15 world commands ~74K -> ~5K-9K visible commands, then Swift encode cost becomes manageable.
