#ifndef Q3_METAL_CLEAN_STAGE_H
#define Q3_METAL_CLEAN_STAGE_H

#include <stdint.h>

#define Q3C_MAX_STAGES 8
#define Q3C_MAX_TCMODS 8
#define Q3C_MAX_DEFORMS 8
#define Q3C_MAX_ANIM_FRAMES 16
#define Q3C_MAX_QPATH 64

typedef enum {
    Q3C_TCGEN_BASE = 0,
    Q3C_TCGEN_LIGHTMAP,
    Q3C_TCGEN_ENVIRONMENT_MAPPED,
    Q3C_TCGEN_VECTOR
} Q3cTcGen;

typedef enum {
    Q3C_TCMOD_SCROLL = 0,
    Q3C_TCMOD_SCALE,
    Q3C_TCMOD_ROTATE,
    Q3C_TCMOD_STRETCH,
    Q3C_TCMOD_TURB,
    Q3C_TCMOD_TRANSFORM,
    Q3C_TCMOD_ENTITY_TRANSLATE
} Q3cTcModType;

typedef enum {
    Q3C_DEFORM_WAVE = 0,
    Q3C_DEFORM_BULGE,
    Q3C_DEFORM_MOVE,
    Q3C_DEFORM_NORMAL,
    Q3C_DEFORM_AUTOSPRITE,
    Q3C_DEFORM_AUTOSPRITE2,
    Q3C_DEFORM_PROJECTION_SHADOW
} Q3cDeformType;

typedef struct {
    Q3cTcModType type;
    float args[6];
} Q3cTcMod;

typedef struct {
    Q3cDeformType type;
    float args[8];
} Q3cDeform;

typedef struct {
    char image[Q3C_MAX_QPATH];
    char animFrames[Q3C_MAX_ANIM_FRAMES][Q3C_MAX_QPATH];
    uint32_t animFrameCount;
    float animFrequency;

    Q3cTcGen tcGen;
    float tcGenVectors[2][3];
    Q3cTcMod tcMods[Q3C_MAX_TCMODS];
    uint32_t tcModCount;

    uint32_t rgbGen;
    uint32_t alphaGen;
    float rgbWave[4];
    float alphaWave[4];

    uint32_t stateBits;
    uint32_t srcBlend;
    uint32_t dstBlend;
    uint32_t depthFunc;
    uint32_t depthWrite;
    uint32_t alphaFunc;
    uint32_t isLightmap;
} Q3cShaderStage;

typedef struct {
    char name[Q3C_MAX_QPATH];
    Q3cShaderStage stages[Q3C_MAX_STAGES];
    uint32_t stageCount;

    Q3cDeform deforms[Q3C_MAX_DEFORMS];
    uint32_t deformCount;

    uint32_t cullType;
    uint32_t sort;
    uint32_t fogIndex;
    float fogColor[3];
    float fogDistance;
} Q3cShaderGraph;

void Q3cShaderGraph_Clear(Q3cShaderGraph *graph);
Q3cShaderStage *Q3cShaderGraph_AddStage(Q3cShaderGraph *graph);
int Q3cShaderStage_AddTcMod(Q3cShaderStage *stage, Q3cTcModType type, const float *args, uint32_t argCount);
int Q3cShaderGraph_AddDeform(Q3cShaderGraph *graph, Q3cDeformType type, const float *args, uint32_t argCount);

#endif

