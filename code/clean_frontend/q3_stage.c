#include "q3_stage.h"

#include <string.h>

void Q3cShaderGraph_Clear(Q3cShaderGraph *graph) {
    if (!graph) return;
    memset(graph, 0, sizeof(*graph));
}

Q3cShaderStage *Q3cShaderGraph_AddStage(Q3cShaderGraph *graph) {
    if (!graph || graph->stageCount >= Q3C_MAX_STAGES) return 0;
    return &graph->stages[graph->stageCount++];
}

int Q3cShaderStage_AddTcMod(Q3cShaderStage *stage, Q3cTcModType type, const float *args, uint32_t argCount) {
    Q3cTcMod *mod;
    uint32_t i;
    if (!stage || stage->tcModCount >= Q3C_MAX_TCMODS) return 0;
    mod = &stage->tcMods[stage->tcModCount++];
    memset(mod, 0, sizeof(*mod));
    mod->type = type;
    if (argCount > 6) argCount = 6;
    for (i = 0; i < argCount; ++i) mod->args[i] = args ? args[i] : 0.0f;
    return 1;
}

int Q3cShaderGraph_AddDeform(Q3cShaderGraph *graph, Q3cDeformType type, const float *args, uint32_t argCount) {
    Q3cDeform *deform;
    uint32_t i;
    if (!graph || graph->deformCount >= Q3C_MAX_DEFORMS) return 0;
    deform = &graph->deforms[graph->deformCount++];
    memset(deform, 0, sizeof(*deform));
    deform->type = type;
    if (argCount > 8) argCount = 8;
    for (i = 0; i < argCount; ++i) deform->args[i] = args ? args[i] : 0.0f;
    return 1;
}

