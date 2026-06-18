; ModuleID = 'world.metal'
source_filename = "world.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v27-apple-ios18.0.0"

%struct.VertexIn = type { <2 x float>, <2 x float>, <4 x float> }
%struct.Uniforms = type { %"struct.metal::matrix" }
%"struct.metal::matrix" = type { [4 x <4 x float>] }
%struct._texture_2d_t = type opaque
%struct._sampler_t = type opaque
%struct.FogVolumeUniforms = type { %"struct.metal::matrix", %"struct.metal::matrix", [3 x float], float, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float> }
%struct._depth_2d_t = type opaque
%struct.DLightBlock = type { i32, i32, i32, i32, [32 x %struct.MSLLight] }
%struct.MSLLight = type { [3 x float], float, [3 x float], float }
%struct.Q3FogTexCoord = type { float, float }
%struct.WorldUniforms = type { %"struct.metal::matrix", [3 x float], float, [3 x float], float, [3 x float], float }
%struct.WorldDrawUniforms = type { float, i32, float, float, float, float, i32, i32, i32, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, i32, float, float, float, float, float, i32, <3 x float>, float, float, float, float, float, float, float, i32, float, float, float, float, float, float, float, float, float, [12 x i8] }
%struct.EntityUniforms = type { %"struct.metal::matrix", <3 x float>, <3 x float>, float, float, i32, float, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, i32, i32, i32, i32, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, <4 x float>, i32, i32, i32, float, float, float, float, float, <4 x float>, <4 x float> }
%struct.WorldVertexIn = type { <3 x float>, <2 x float>, <2 x float>, <3 x float>, <4 x float>, <4 x float>, <4 x float>, <3 x float> }
%struct._texture_cube_t = type opaque
%struct.EntityVertexIn = type { <3 x float>, <2 x float>, <4 x float>, <3 x float> }

@__air_sampler_state.1 = internal addrspace(2) constant [2 x i64] [i64 34901797601017929, i64 0], align 8

; Function Attrs: argmemonly mustprogress nofree norecurse nosync nounwind readonly willreturn
define <{ <4 x float>, <2 x float>, <4 x float> }> @q3_ui_vertex(%struct.VertexIn addrspace(1)* nocapture noundef readonly "air-buffer-no-alias" %0, %struct.Uniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(64) "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds %struct.VertexIn, %struct.VertexIn addrspace(1)* %0, i64 %4, i32 0
  %6 = load <2 x float>, <2 x float> addrspace(1)* %5, align 16, !tbaa.struct !122, !alias.scope !126, !noalias !129
  %7 = getelementptr inbounds %struct.VertexIn, %struct.VertexIn addrspace(1)* %0, i64 %4, i32 1
  %8 = load <2 x float>, <2 x float> addrspace(1)* %7, align 8, !tbaa.struct !131, !alias.scope !126, !noalias !129
  %9 = getelementptr inbounds %struct.VertexIn, %struct.VertexIn addrspace(1)* %0, i64 %4, i32 2
  %10 = load <4 x float>, <4 x float> addrspace(1)* %9, align 16, !tbaa.struct !132, !alias.scope !126, !noalias !129
  %11 = getelementptr inbounds %struct.Uniforms, %struct.Uniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 0
  %12 = load <4 x float>, <4 x float> addrspace(2)* %11, align 16, !tbaa !123, !alias.scope !129, !noalias !126
  %13 = shufflevector <2 x float> %6, <2 x float> undef, <4 x i32> zeroinitializer
  %14 = fmul fast <4 x float> %12, %13
  %15 = getelementptr inbounds %struct.Uniforms, %struct.Uniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 1
  %16 = load <4 x float>, <4 x float> addrspace(2)* %15, align 16, !tbaa !123, !alias.scope !129, !noalias !126
  %17 = shufflevector <2 x float> %6, <2 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %18 = fmul fast <4 x float> %16, %17
  %19 = fadd fast <4 x float> %18, %14
  %20 = getelementptr inbounds %struct.Uniforms, %struct.Uniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 3
  %21 = load <4 x float>, <4 x float> addrspace(2)* %20, align 16, !tbaa !123, !alias.scope !129, !noalias !126
  %22 = fadd fast <4 x float> %19, %21
  %23 = insertvalue <{ <4 x float>, <2 x float>, <4 x float> }> undef, <4 x float> %22, 0
  %24 = insertvalue <{ <4 x float>, <2 x float>, <4 x float> }> %23, <2 x float> %8, 1
  %25 = insertvalue <{ <4 x float>, <2 x float>, <4 x float> }> %24, <4 x float> %10, 2
  ret <{ <4 x float>, <2 x float>, <4 x float> }> %25
}

; Function Attrs: argmemonly mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.lifetime.start.p0i8(i64 immarg, i8* nocapture) #1

; Function Attrs: argmemonly mustprogress nocallback nofree nosync nounwind willreturn
declare void @llvm.lifetime.end.p0i8(i64 immarg, i8* nocapture) #1

; Function Attrs: argmemonly convergent mustprogress nofree nounwind readonly willreturn
define <4 x float> @q3_ui_fragment(<4 x float> %0, <2 x float> %1, <4 x float> %2, %struct._texture_2d_t addrspace(1)* nocapture readonly %3, %struct._sampler_t addrspace(2)* nocapture readonly %4) local_unnamed_addr #2 {
  %6 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %3, %struct._sampler_t addrspace(2)* nocapture readonly %4, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !133
  %7 = extractvalue { <4 x float>, i8 } %6, 0
  %8 = fmul fast <4 x float> %7, %2
  ret <4 x float> %8
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define <3 x float> @_Z18q3ResolvedFogColorDv3_f(<3 x float> noundef %0) local_unnamed_addr #3 {
  %2 = tail call fast float @air.dot.v3f32(<3 x float> %0, <3 x float> %0) #20
  %3 = fcmp fast olt float %2, 0x3F50624DE0000000
  %4 = select i1 %3, <3 x float> <float 0x3FD70A3D80000000, float 0x3FD70A3D80000000, float 0x3FD70A3D80000000>, <3 x float> %0
  ret <3 x float> %4
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define <{ <4 x float>, <2 x float> }> @q3_fog_volume_vertex(i32 noundef %0, %struct.FogVolumeUniforms addrspace(2)* nocapture noundef readnone align 16 dereferenceable(224) "air-buffer-no-alias" %1) local_unnamed_addr #4 {
  %3 = alloca [3 x <2 x float>], align 8
  %4 = bitcast [3 x <2 x float>]* %3 to i8*
  call void @llvm.lifetime.start.p0i8(i64 24, i8* nonnull %4) #21
  %5 = getelementptr inbounds [3 x <2 x float>], [3 x <2 x float>]* %3, i64 0, i64 0
  store <2 x float> <float -1.000000e+00, float -1.000000e+00>, <2 x float>* %5, align 8
  %6 = getelementptr inbounds [3 x <2 x float>], [3 x <2 x float>]* %3, i64 0, i64 1
  store <2 x float> <float 3.000000e+00, float -1.000000e+00>, <2 x float>* %6, align 8
  %7 = getelementptr inbounds [3 x <2 x float>], [3 x <2 x float>]* %3, i64 0, i64 2
  store <2 x float> <float -1.000000e+00, float 3.000000e+00>, <2 x float>* %7, align 8
  %8 = zext i32 %0 to i64
  %9 = getelementptr inbounds [3 x <2 x float>], [3 x <2 x float>]* %3, i64 0, i64 %8
  %10 = load <2 x float>, <2 x float>* %9, align 8, !tbaa !123
  %11 = shufflevector <2 x float> %10, <2 x float> poison, <4 x i32> <i32 0, i32 1, i32 undef, i32 undef>
  %12 = shufflevector <4 x float> %11, <4 x float> <float poison, float poison, float 0.000000e+00, float 1.000000e+00>, <4 x i32> <i32 0, i32 1, i32 6, i32 7>
  call void @llvm.lifetime.end.p0i8(i64 24, i8* nonnull %4) #21
  %13 = insertvalue <{ <4 x float>, <2 x float> }> undef, <4 x float> %12, 0
  %14 = insertvalue <{ <4 x float>, <2 x float> }> %13, <2 x float> %10, 1
  ret <{ <4 x float>, <2 x float> }> %14
}

; Function Attrs: convergent mustprogress nofree nounwind readonly willreturn
define <4 x float> @q3_fog_volume_fragment(<4 x float> %0, <2 x float> %1, %struct.FogVolumeUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(224) "air-buffer-no-alias" %2, %struct._depth_2d_t addrspace(1)* %3) local_unnamed_addr #5 {
  %5 = tail call i32 @air.get_width_depth_2d(%struct._depth_2d_t addrspace(1)* nocapture readonly %3, i32 0) #22, !alias.scope !137, !noalias !140
  %6 = tail call fast float @air.convert.f.f32.u.i32(i32 %5) #20
  %7 = insertelement <2 x float> undef, float %6, i64 0
  %8 = tail call i32 @air.get_height_depth_2d(%struct._depth_2d_t addrspace(1)* nocapture readonly %3, i32 0) #22, !alias.scope !137, !noalias !140
  %9 = tail call fast float @air.convert.f.f32.u.i32(i32 %8) #20
  %10 = insertelement <2 x float> %7, float %9, i64 1
  %11 = shufflevector <4 x float> %0, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %12 = fadd fast <2 x float> %11, <float 5.000000e-01, float 5.000000e-01>
  %13 = tail call fast <2 x float> @air.fast_fmax.v2f32(<2 x float> %10, <2 x float> <float 1.000000e+00, float 1.000000e+00>) #20
  %14 = fdiv fast <2 x float> %12, %13
  %15 = tail call { float, i8 } @air.sample_depth_2d.f32(%struct._depth_2d_t addrspace(1)* nocapture readonly %3, %struct._sampler_t addrspace(2)* nocapture readonly bitcast ([2 x i64] addrspace(2)* @__air_sampler_state.1 to %struct._sampler_t addrspace(2)*), i32 1, <2 x float> %14, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19
  %16 = extractvalue { float, i8 } %15, 0
  %17 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 5
  %18 = load <4 x float>, <4 x float> addrspace(2)* %17, align 16, !alias.scope !140, !noalias !137
  %19 = shufflevector <4 x float> %18, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %20 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 6
  %21 = load <4 x float>, <4 x float> addrspace(2)* %20, align 16, !alias.scope !140, !noalias !137
  %22 = shufflevector <4 x float> %21, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %23 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 1, i32 0, i64 0
  %24 = load <4 x float>, <4 x float> addrspace(2)* %23, align 16, !tbaa !123, !alias.scope !140, !noalias !137
  %25 = shufflevector <2 x float> %1, <2 x float> undef, <4 x i32> zeroinitializer
  %26 = fmul fast <4 x float> %24, %25
  %27 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 1, i32 0, i64 1
  %28 = load <4 x float>, <4 x float> addrspace(2)* %27, align 16, !tbaa !123, !alias.scope !140, !noalias !137
  %29 = shufflevector <2 x float> %1, <2 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %30 = fmul fast <4 x float> %28, %29
  %31 = fadd fast <4 x float> %30, %26
  %32 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 1, i32 0, i64 2
  %33 = load <4 x float>, <4 x float> addrspace(2)* %32, align 16, !tbaa !123, !alias.scope !140, !noalias !137
  %34 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 1, i32 0, i64 3
  %35 = load <4 x float>, <4 x float> addrspace(2)* %34, align 16, !tbaa !123, !alias.scope !140, !noalias !137
  %36 = fadd fast <4 x float> %35, %31
  %37 = fadd fast <4 x float> %36, %33
  %38 = shufflevector <4 x float> %37, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %39 = extractelement <4 x float> %37, i64 3
  %40 = tail call fast float @air.fast_fmax.f32(float %39, float 0x3EB0C6F7A0000000) #20
  %41 = insertelement <3 x float> poison, float %40, i64 0
  %42 = shufflevector <3 x float> %41, <3 x float> poison, <3 x i32> zeroinitializer
  %43 = fdiv fast <3 x float> %38, %42
  %44 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 2, i64 0
  %45 = load float, float addrspace(2)* %44, align 16, !alias.scope !140, !noalias !137
  %46 = insertelement <3 x float> undef, float %45, i64 0
  %47 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 2, i64 1
  %48 = load float, float addrspace(2)* %47, align 4, !alias.scope !140, !noalias !137
  %49 = insertelement <3 x float> %46, float %48, i64 1
  %50 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 2, i64 2
  %51 = load float, float addrspace(2)* %50, align 8, !alias.scope !140, !noalias !137
  %52 = insertelement <3 x float> %49, float %51, i64 2
  %53 = fsub fast <3 x float> %43, %52
  %54 = tail call fast float @air.dot.v3f32(<3 x float> %53, <3 x float> %53) #20
  %55 = tail call fast float @air.fast_rsqrt.f32(float %54) #20
  %56 = insertelement <3 x float> poison, float %55, i64 0
  %57 = shufflevector <3 x float> %56, <3 x float> poison, <3 x i32> zeroinitializer
  %58 = fmul fast <3 x float> %57, %53
  %59 = tail call fast <3 x float> @air.fast_fabs.v3f32(<3 x float> %58) #20
  %60 = fcmp fast ogt <3 x float> %59, <float 0x3EB0C6F7A0000000, float 0x3EB0C6F7A0000000, float 0x3EB0C6F7A0000000>
  %61 = fdiv fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %58
  %62 = select <3 x i1> %60, <3 x float> %61, <3 x float> <float 1.000000e+06, float 1.000000e+06, float 1.000000e+06>
  %63 = fsub fast <3 x float> %19, %52
  %64 = fmul fast <3 x float> %62, %63
  %65 = fsub fast <3 x float> %22, %52
  %66 = fmul fast <3 x float> %62, %65
  %67 = tail call fast <3 x float> @air.fast_fmin.v3f32(<3 x float> %64, <3 x float> %66) #20
  %68 = tail call fast <3 x float> @air.fast_fmax.v3f32(<3 x float> %64, <3 x float> %66) #20
  %69 = extractelement <3 x float> %67, i64 0
  %70 = extractelement <3 x float> %67, i64 1
  %71 = tail call fast float @air.fast_fmax.f32(float %69, float %70) #20
  %72 = extractelement <3 x float> %67, i64 2
  %73 = tail call fast float @air.fast_fmax.f32(float %71, float %72) #20
  %74 = extractelement <3 x float> %68, i64 0
  %75 = extractelement <3 x float> %68, i64 1
  %76 = tail call fast float @air.fast_fmin.f32(float %74, float %75) #20
  %77 = extractelement <3 x float> %68, i64 2
  %78 = tail call fast float @air.fast_fmin.f32(float %76, float %77) #20
  %79 = tail call fast float @air.fast_fmax.f32(float %73, float 0.000000e+00) #20
  %80 = fcmp fast olt float %16, 0x3FEFFFFDE0000000
  br i1 %80, label %81, label %95

81:                                               ; preds = %4
  %82 = insertelement <4 x float> poison, float %16, i64 0
  %83 = shufflevector <4 x float> %82, <4 x float> poison, <4 x i32> zeroinitializer
  %84 = fmul fast <4 x float> %33, %83
  %85 = fadd fast <4 x float> %36, %84
  %86 = shufflevector <4 x float> %85, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %87 = extractelement <4 x float> %85, i64 3
  %88 = tail call fast float @air.fast_fmax.f32(float %87, float 0x3EB0C6F7A0000000) #20
  %89 = insertelement <3 x float> poison, float %88, i64 0
  %90 = shufflevector <3 x float> %89, <3 x float> poison, <3 x i32> zeroinitializer
  %91 = fdiv fast <3 x float> %86, %90
  %92 = fsub fast <3 x float> %91, %52
  %93 = tail call fast float @air.dot.v3f32(<3 x float> %92, <3 x float> %58) #20
  %94 = tail call fast float @air.fast_fmax.f32(float %93, float 0.000000e+00) #20
  br label %95

95:                                               ; preds = %81, %4
  %96 = phi float [ %94, %81 ], [ 0x4415AF1D80000000, %4 ]
  %97 = tail call fast float @air.fast_fmin.f32(float %78, float %96) #20
  %98 = fsub fast float %97, %79
  %99 = tail call fast float @air.fast_fmax.f32(float %98, float 0.000000e+00) #20
  %100 = fcmp fast ugt float %99, 0.000000e+00
  br i1 %100, label %101, label %120

101:                                              ; preds = %95
  %102 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 8
  %103 = load <4 x float>, <4 x float> addrspace(2)* %102, align 16, !alias.scope !140, !noalias !137
  %104 = extractelement <4 x float> %103, i64 0
  %105 = fcmp fast ogt float %104, 0.000000e+00
  %106 = select fast i1 %105, float %104, float 0x3F554C9860000000
  %107 = fneg fast float %99
  %108 = fmul fast float %106, %107
  %109 = tail call fast float @air.fast_exp.f32(float %108) #20
  %110 = fsub fast float 1.000000e+00, %109
  %111 = tail call fast float @air.fast_saturate.f32(float %110) #20
  %112 = getelementptr inbounds %struct.FogVolumeUniforms, %struct.FogVolumeUniforms addrspace(2)* %2, i64 0, i32 4
  %113 = load <4 x float>, <4 x float> addrspace(2)* %112, align 16, !alias.scope !140, !noalias !137
  %114 = shufflevector <4 x float> %113, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %115 = tail call fast float @air.dot.v3f32(<3 x float> %114, <3 x float> %114) #20
  %116 = fcmp fast olt float %115, 0x3F50624DE0000000
  %117 = select i1 %116, <3 x float> <float 0x3FD70A3D80000000, float 0x3FD70A3D80000000, float 0x3FD70A3D80000000>, <3 x float> %114
  %118 = shufflevector <3 x float> %117, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %119 = insertelement <4 x float> %118, float %111, i64 3
  br label %120

120:                                              ; preds = %95, %101
  %121 = phi <4 x float> [ %119, %101 ], [ zeroinitializer, %95 ]
  ret <4 x float> %121
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.convert.f.f32.u.i32(i32) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define <3 x float> @_Z12applyDlightsDv3_fS_S_RU11MTLconstantK11DLightBlock(<3 x float> noundef %0, <3 x float> noundef %1, <3 x float> noundef %2, %struct.DLightBlock addrspace(2)* nocapture noundef readonly align 4 dereferenceable(1040) %3) local_unnamed_addr #3 {
  %5 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 0
  %6 = load i32, i32 addrspace(2)* %5, align 4, !tbaa !142
  %7 = tail call i32 @air.min.u.i32(i32 %6, i32 32) #20
  %8 = tail call fast float @air.dot.v3f32(<3 x float> %2, <3 x float> %2) #20
  %9 = tail call fast float @air.fast_sqrt.f32(float %8) #20
  %10 = fcmp fast ogt float %9, 0x3F1A36E2E0000000
  %11 = insertelement <3 x float> poison, float %9, i64 0
  %12 = shufflevector <3 x float> %11, <3 x float> poison, <3 x i32> zeroinitializer
  %13 = fdiv fast <3 x float> %2, %12
  %14 = select i1 %10, <3 x float> %13, <3 x float> %2
  %15 = icmp eq i32 %7, 0
  br i1 %15, label %16, label %20

16:                                               ; preds = %63, %4
  %17 = phi <3 x float> [ zeroinitializer, %4 ], [ %72, %63 ]
  %18 = tail call fast <3 x float> @air.fast_fmin.v3f32(<3 x float> %17, <3 x float> <float 0x3FEB333340000000, float 0x3FEB333340000000, float 0x3FEB333340000000>) #20
  %19 = fadd fast <3 x float> %18, %0
  ret <3 x float> %19

20:                                               ; preds = %4, %63
  %21 = phi <3 x float> [ %72, %63 ], [ zeroinitializer, %4 ]
  %22 = phi i32 [ %73, %63 ], [ 0, %4 ]
  %23 = zext i32 %22 to i64
  %24 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 0, i64 0
  %25 = load float, float addrspace(2)* %24, align 4, !tbaa.struct !145
  %26 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 0, i64 1
  %27 = load float, float addrspace(2)* %26, align 4, !tbaa.struct !148
  %28 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 0, i64 2
  %29 = load float, float addrspace(2)* %28, align 4, !tbaa.struct !149
  %30 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 1
  %31 = load float, float addrspace(2)* %30, align 4, !tbaa.struct !150
  %32 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 2, i64 0
  %33 = load float, float addrspace(2)* %32, align 4, !tbaa.struct !151
  %34 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 2, i64 1
  %35 = load float, float addrspace(2)* %34, align 4, !tbaa.struct !152
  %36 = getelementptr inbounds %struct.DLightBlock, %struct.DLightBlock addrspace(2)* %3, i64 0, i32 4, i64 %23, i32 2, i64 2
  %37 = load float, float addrspace(2)* %36, align 4, !tbaa.struct !153
  %38 = tail call fast float @air.fast_fmax.f32(float %31, float 1.000000e+00) #20
  %39 = insertelement <3 x float> undef, float %25, i64 0
  %40 = insertelement <3 x float> %39, float %27, i64 1
  %41 = insertelement <3 x float> %40, float %29, i64 2
  %42 = fsub fast <3 x float> %1, %41
  %43 = tail call fast float @air.dot.v3f32(<3 x float> %42, <3 x float> %42) #20
  %44 = tail call fast float @air.fast_sqrt.f32(float %43) #20
  %45 = fdiv fast float %44, %38
  %46 = fsub fast float 1.000000e+00, %45
  %47 = tail call fast float @air.fast_saturate.f32(float %46) #20
  %48 = fmul fast float %47, %47
  %49 = fcmp fast ogt float %44, 0x3F1A36E2E0000000
  %50 = select i1 %10, i1 %49, i1 false
  br i1 %50, label %51, label %63

51:                                               ; preds = %20
  %52 = fneg fast <3 x float> %42
  %53 = tail call fast float @air.dot.v3f32(<3 x float> %52, <3 x float> %52) #20
  %54 = tail call fast float @air.fast_rsqrt.f32(float %53) #20
  %55 = insertelement <3 x float> poison, float %54, i64 0
  %56 = shufflevector <3 x float> %55, <3 x float> poison, <3 x i32> zeroinitializer
  %57 = fmul fast <3 x float> %56, %52
  %58 = tail call fast float @air.dot.v3f32(<3 x float> %14, <3 x float> %57) #20
  %59 = tail call fast float @air.fast_saturate.f32(float %58) #20
  %60 = fmul fast float %59, 0x3FEB333340000000
  %61 = fadd fast float %60, 0x3FC3333340000000
  %62 = fmul fast float %61, %48
  br label %63

63:                                               ; preds = %51, %20
  %64 = phi float [ %62, %51 ], [ %48, %20 ]
  %65 = insertelement <3 x float> undef, float %33, i64 0
  %66 = insertelement <3 x float> %65, float %35, i64 1
  %67 = insertelement <3 x float> %66, float %37, i64 2
  %68 = insertelement <3 x float> poison, float %64, i64 0
  %69 = shufflevector <3 x float> %68, <3 x float> poison, <3 x i32> zeroinitializer
  %70 = fmul fast <3 x float> %67, <float 0x3FE4CCCCC0000000, float 0x3FE4CCCCC0000000, float 0x3FE4CCCCC0000000>
  %71 = fmul fast <3 x float> %70, %69
  %72 = fadd fast <3 x float> %71, %21
  %73 = add nuw i32 %22, 1
  %74 = icmp eq i32 %73, %7
  br i1 %74, label %16, label %20, !llvm.loop !154
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define float @_Z8evalWavejfffff(i32 noundef %0, float noundef %1, float noundef %2, float noundef %3, float noundef %4, float noundef %5) local_unnamed_addr #4 {
  %7 = fmul fast float %5, %4
  %8 = fadd fast float %7, %3
  %9 = tail call fast float @air.fast_fract.f32(float %8) #20
  switch i32 %0, label %31 [
    i32 3, label %10
    i32 4, label %34
    i32 5, label %13
    i32 2, label %15
  ]

10:                                               ; preds = %6
  %11 = fcmp fast olt float %9, 5.000000e-01
  %12 = select fast i1 %11, float 1.000000e+00, float -1.000000e+00
  br label %34

13:                                               ; preds = %6
  %14 = fsub fast float 1.000000e+00, %9
  br label %34

15:                                               ; preds = %6
  %16 = fcmp fast olt float %9, 2.500000e-01
  br i1 %16, label %17, label %19

17:                                               ; preds = %15
  %18 = fmul fast float %9, 4.000000e+00
  br label %34

19:                                               ; preds = %15
  %20 = fcmp fast olt float %9, 5.000000e-01
  br i1 %20, label %21, label %24

21:                                               ; preds = %19
  %22 = fmul fast float %9, 4.000000e+00
  %23 = fsub fast float 2.000000e+00, %22
  br label %34

24:                                               ; preds = %19
  %25 = fcmp fast olt float %9, 7.500000e-01
  %26 = fmul fast float %9, 4.000000e+00
  br i1 %25, label %27, label %29

27:                                               ; preds = %24
  %28 = fsub fast float 2.000000e+00, %26
  br label %34

29:                                               ; preds = %24
  %30 = fadd fast float %26, -4.000000e+00
  br label %34

31:                                               ; preds = %6
  %32 = fmul fast float %9, 0x401921FB60000000
  %33 = tail call fast float @air.fast_sin.f32(float %32) #20
  br label %34

34:                                               ; preds = %17, %27, %29, %21, %6, %31, %13, %10
  %35 = phi float [ %12, %10 ], [ %14, %13 ], [ %33, %31 ], [ %9, %6 ], [ %18, %17 ], [ %23, %21 ], [ %28, %27 ], [ %30, %29 ]
  %36 = fmul fast float %35, %2
  %37 = fadd fast float %36, %1
  ret float %37
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind readnone willreturn
define <3 x float> @_Z13ComputeRGBGeniDv3_fDv4_fS_S_f(i32 noundef %0, <3 x float> noundef %1, <4 x float> noundef %2, <3 x float> noundef %3, <3 x float> noundef %4, float noundef %5) local_unnamed_addr #7 {
  switch i32 %0, label %16 [
    i32 1, label %17
    i32 2, label %7
    i32 3, label %8
    i32 4, label %11
    i32 5, label %13
    i32 6, label %14
  ]

7:                                                ; preds = %6
  br label %17

8:                                                ; preds = %6
  %9 = insertelement <3 x float> poison, float %5, i64 0
  %10 = shufflevector <3 x float> %9, <3 x float> poison, <3 x i32> zeroinitializer
  br label %17

11:                                               ; preds = %6
  %12 = shufflevector <4 x float> %2, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  br label %17

13:                                               ; preds = %6
  br label %17

14:                                               ; preds = %6
  %15 = fsub fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %3
  br label %17

16:                                               ; preds = %6
  br label %17

17:                                               ; preds = %6, %16, %14, %13, %11, %8, %7
  %18 = phi <3 x float> [ <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %16 ], [ %15, %14 ], [ %3, %13 ], [ %12, %11 ], [ %10, %8 ], [ %4, %7 ], [ %1, %6 ]
  ret <3 x float> %18
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind readnone willreturn
define float @_Z15ComputeAlphaGeniffff(i32 noundef %0, float noundef %1, float noundef %2, float noundef %3, float noundef %4) local_unnamed_addr #8 {
  switch i32 %0, label %11 [
    i32 1, label %12
    i32 3, label %6
    i32 4, label %7
    i32 5, label %8
    i32 6, label %9
  ]

6:                                                ; preds = %5
  br label %12

7:                                                ; preds = %5
  br label %12

8:                                                ; preds = %5
  br label %12

9:                                                ; preds = %5
  %10 = fsub fast float 1.000000e+00, %3
  br label %12

11:                                               ; preds = %5
  br label %12

12:                                               ; preds = %5, %11, %9, %8, %7, %6
  %13 = phi float [ 1.000000e+00, %11 ], [ %10, %9 ], [ %3, %8 ], [ %2, %7 ], [ %4, %6 ], [ %1, %5 ]
  ret float %13
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %0, <3 x float> noundef %1, i32 noundef %2, <4 x float> noundef %3, float noundef %4) local_unnamed_addr #9 {
  switch i32 %2, label %107 [
    i32 1, label %6
    i32 2, label %14
    i32 3, label %23
    i32 4, label %42
    i32 5, label %45
    i32 6, label %69
    i32 7, label %89
    i32 8, label %104
  ]

6:                                                ; preds = %5
  %7 = shufflevector <4 x float> %3, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %8 = insertelement <2 x float> poison, float %4, i64 0
  %9 = shufflevector <2 x float> %8, <2 x float> poison, <2 x i32> zeroinitializer
  %10 = fmul fast <2 x float> %9, %7
  %11 = tail call fast <2 x float> @air.fast_floor.v2f32(<2 x float> %10) #20
  %12 = fadd fast <2 x float> %10, %0
  %13 = fsub fast <2 x float> %12, %11
  br label %107

14:                                               ; preds = %5
  %15 = extractelement <4 x float> %3, i64 3
  %16 = fmul fast float %15, %4
  %17 = tail call fast float @air.fast_sin.f32(float %16) #20
  %18 = extractelement <4 x float> %3, i64 1
  %19 = fmul fast float %17, %18
  %20 = insertelement <2 x float> undef, float %19, i64 0
  %21 = shufflevector <2 x float> %20, <2 x float> poison, <2 x i32> zeroinitializer
  %22 = fadd fast <2 x float> %21, %0
  br label %107

23:                                               ; preds = %5
  %24 = extractelement <4 x float> %3, i64 0
  %25 = fmul fast float %24, %4
  %26 = tail call fast float @air.fast_fmod.f32(float %25, float 3.600000e+02) #20
  %27 = fmul fast float %26, 0x3F91DF46A0000000
  %28 = tail call fast float @air.fast_cos.f32(float %27) #20
  %29 = tail call fast float @air.fast_sin.f32(float %27) #20
  %30 = fadd fast <2 x float> %0, <float -5.000000e-01, float -5.000000e-01>
  %31 = extractelement <2 x float> %30, i64 0
  %32 = fmul fast float %28, %31
  %33 = extractelement <2 x float> %30, i64 1
  %34 = fmul fast float %29, %33
  %35 = fsub fast float %32, %34
  %36 = insertelement <2 x float> undef, float %35, i64 0
  %37 = fmul fast float %29, %31
  %38 = fmul fast float %28, %33
  %39 = fadd fast float %37, %38
  %40 = insertelement <2 x float> %36, float %39, i64 1
  %41 = fadd fast <2 x float> %40, <float 5.000000e-01, float 5.000000e-01>
  br label %107

42:                                               ; preds = %5
  %43 = shufflevector <4 x float> %3, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %44 = fmul fast <2 x float> %43, %0
  br label %107

45:                                               ; preds = %5
  %46 = extractelement <4 x float> %3, i64 0
  %47 = extractelement <4 x float> %3, i64 1
  %48 = extractelement <4 x float> %3, i64 2
  %49 = fmul fast float %47, %4
  %50 = fadd fast float %49, %48
  %51 = tail call fast float @air.fast_fract.f32(float %50) #20
  %52 = extractelement <3 x float> %1, i64 0
  %53 = extractelement <3 x float> %1, i64 2
  %54 = fadd fast float %52, %53
  %55 = fmul fast float %54, 0x3F50000000000000
  %56 = fadd fast float %51, %55
  %57 = extractelement <3 x float> %1, i64 1
  %58 = fmul fast float %57, 0x3F50000000000000
  %59 = fadd fast float %51, %58
  %60 = fmul fast float %56, 0x401921FB60000000
  %61 = tail call fast float @air.fast_sin.f32(float %60) #20
  %62 = fmul fast float %61, %46
  %63 = insertelement <2 x float> undef, float %62, i64 0
  %64 = fmul fast float %59, 0x401921FB60000000
  %65 = tail call fast float @air.fast_sin.f32(float %64) #20
  %66 = fmul fast float %65, %46
  %67 = insertelement <2 x float> %63, float %66, i64 1
  %68 = fadd fast <2 x float> %67, %0
  br label %107

69:                                               ; preds = %5
  %70 = extractelement <4 x float> %3, i64 2
  %71 = extractelement <4 x float> %3, i64 3
  %72 = fmul fast float %71, %4
  %73 = fadd fast float %72, %70
  %74 = fmul fast float %73, 0x401921FB60000000
  %75 = extractelement <4 x float> %3, i64 0
  %76 = tail call fast float @air.fast_sin.f32(float %74) #20
  %77 = extractelement <4 x float> %3, i64 1
  %78 = fmul fast float %76, %77
  %79 = fadd fast float %78, %75
  %80 = tail call fast float @air.fast_fabs.f32(float %79) #20
  %81 = fcmp fast olt float %80, 0x3F1A36E2E0000000
  %82 = fdiv fast float 1.000000e+00, %79
  %83 = select i1 %81, float 1.000000e+00, float %82
  %84 = fadd fast <2 x float> %0, <float -5.000000e-01, float -5.000000e-01>
  %85 = insertelement <2 x float> poison, float %83, i64 0
  %86 = shufflevector <2 x float> %85, <2 x float> poison, <2 x i32> zeroinitializer
  %87 = fmul fast <2 x float> %86, %84
  %88 = fadd fast <2 x float> %87, <float 5.000000e-01, float 5.000000e-01>
  br label %107

89:                                               ; preds = %5
  %90 = extractelement <2 x float> %0, i64 0
  %91 = extractelement <4 x float> %3, i64 0
  %92 = fmul fast float %91, %90
  %93 = extractelement <2 x float> %0, i64 1
  %94 = extractelement <4 x float> %3, i64 1
  %95 = fmul fast float %94, %93
  %96 = fadd fast float %92, %95
  %97 = insertelement <2 x float> undef, float %96, i64 0
  %98 = extractelement <4 x float> %3, i64 2
  %99 = fmul fast float %98, %90
  %100 = extractelement <4 x float> %3, i64 3
  %101 = fmul fast float %100, %93
  %102 = fadd fast float %99, %101
  %103 = insertelement <2 x float> %97, float %102, i64 1
  br label %107

104:                                              ; preds = %5
  %105 = shufflevector <4 x float> %3, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %106 = fadd fast <2 x float> %105, %0
  br label %107

107:                                              ; preds = %5, %104, %89, %69, %45, %42, %23, %14, %6
  %108 = phi <2 x float> [ %13, %6 ], [ %22, %14 ], [ %41, %23 ], [ %44, %42 ], [ %68, %45 ], [ %88, %69 ], [ %103, %89 ], [ %106, %104 ], [ %0, %5 ]
  ret <2 x float> %108
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define float @_Z17q3FogDirectFactorff(float noundef %0, float noundef %1) local_unnamed_addr #4 {
  %3 = fadd fast float %0, 0xBF60000000000000
  %4 = fcmp fast olt float %3, 0.000000e+00
  %5 = fcmp fast olt float %1, 3.125000e-02
  %6 = select i1 %4, i1 true, i1 %5
  br i1 %6, label %16, label %7

7:                                                ; preds = %2
  %8 = fcmp fast olt float %1, 9.687500e-01
  %9 = fadd fast float %1, -3.125000e-02
  %10 = fmul fast float %9, 0x3FF1111120000000
  %11 = select i1 %8, float %10, float 1.000000e+00
  %12 = fmul fast float %3, 8.000000e+00
  %13 = fmul fast float %12, %11
  %14 = tail call fast float @air.fast_saturate.f32(float %13) #20
  %15 = tail call fast float @air.fast_sqrt.f32(float %14) #20
  br label %16

16:                                               ; preds = %2, %7
  %17 = phi float [ %15, %7 ], [ 0.000000e+00, %2 ]
  ret float %17
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define float @_Z16q3FogImageFactorff(float noundef %0, float noundef %1) local_unnamed_addr #4 {
  %3 = tail call fast float @air.fast_clamp.f32(float %0, float 0.000000e+00, float 1.000000e+00) #20
  %4 = fmul fast float %3, 2.560000e+02
  %5 = fadd fast float %4, -5.000000e-01
  %6 = tail call fast float @air.fast_clamp.f32(float %1, float 0.000000e+00, float 1.000000e+00) #20
  %7 = fmul fast float %6, 3.200000e+01
  %8 = fadd fast float %7, -5.000000e-01
  %9 = tail call fast float @air.fast_floor.f32(float %5) #20
  %10 = tail call fast float @air.fast_floor.f32(float %8) #20
  %11 = tail call fast float @air.fast_clamp.f32(float %9, float 0.000000e+00, float 2.550000e+02) #20
  %12 = fadd fast float %11, 5.000000e-01
  %13 = fmul fast float %12, 3.906250e-03
  %14 = fadd fast float %9, 1.000000e+00
  %15 = tail call fast float @air.fast_clamp.f32(float %14, float 0.000000e+00, float 2.550000e+02) #20
  %16 = fadd fast float %15, 5.000000e-01
  %17 = fmul fast float %16, 3.906250e-03
  %18 = tail call fast float @air.fast_clamp.f32(float %10, float 0.000000e+00, float 3.100000e+01) #20
  %19 = fadd fast float %18, 5.000000e-01
  %20 = fmul fast float %19, 3.125000e-02
  %21 = fadd fast float %10, 1.000000e+00
  %22 = tail call fast float @air.fast_clamp.f32(float %21, float 0.000000e+00, float 3.100000e+01) #20
  %23 = fadd fast float %22, 5.000000e-01
  %24 = fmul fast float %23, 3.125000e-02
  %25 = fadd fast float %13, 0xBF60000000000000
  %26 = fcmp fast olt float %25, 0.000000e+00
  %27 = fcmp fast olt float %20, 3.125000e-02
  %28 = select i1 %26, i1 true, i1 %27
  br i1 %28, label %38, label %29

29:                                               ; preds = %2
  %30 = fmul fast float %25, 8.000000e+00
  %31 = fcmp fast olt float %20, 9.687500e-01
  %32 = fmul fast float %19, 0x3FA1111120000000
  %33 = fadd fast float %32, 0xBFA1111120000000
  %34 = select i1 %31, float %33, float 1.000000e+00
  %35 = fmul fast float %30, %34
  %36 = tail call fast float @air.fast_saturate.f32(float %35) #20
  %37 = tail call fast float @air.fast_sqrt.f32(float %36) #20
  br label %38

38:                                               ; preds = %2, %29
  %39 = phi float [ %37, %29 ], [ 0.000000e+00, %2 ]
  %40 = fadd fast float %17, 0xBF60000000000000
  %41 = fcmp fast olt float %40, 0.000000e+00
  %42 = select i1 %41, i1 true, i1 %27
  br i1 %42, label %52, label %43

43:                                               ; preds = %38
  %44 = fmul fast float %40, 8.000000e+00
  %45 = fcmp fast olt float %20, 9.687500e-01
  %46 = fmul fast float %19, 0x3FA1111120000000
  %47 = fadd fast float %46, 0xBFA1111120000000
  %48 = select i1 %45, float %47, float 1.000000e+00
  %49 = fmul fast float %44, %48
  %50 = tail call fast float @air.fast_saturate.f32(float %49) #20
  %51 = tail call fast float @air.fast_sqrt.f32(float %50) #20
  br label %52

52:                                               ; preds = %38, %43
  %53 = phi float [ %51, %43 ], [ 0.000000e+00, %38 ]
  %54 = fcmp fast olt float %24, 3.125000e-02
  %55 = select i1 %26, i1 true, i1 %54
  br i1 %55, label %65, label %56

56:                                               ; preds = %52
  %57 = fmul fast float %25, 8.000000e+00
  %58 = fcmp fast olt float %24, 9.687500e-01
  %59 = fmul fast float %23, 0x3FA1111120000000
  %60 = fadd fast float %59, 0xBFA1111120000000
  %61 = select i1 %58, float %60, float 1.000000e+00
  %62 = fmul fast float %57, %61
  %63 = tail call fast float @air.fast_saturate.f32(float %62) #20
  %64 = tail call fast float @air.fast_sqrt.f32(float %63) #20
  br label %65

65:                                               ; preds = %52, %56
  %66 = phi float [ %64, %56 ], [ 0.000000e+00, %52 ]
  %67 = select i1 %41, i1 true, i1 %54
  br i1 %67, label %77, label %68

68:                                               ; preds = %65
  %69 = fmul fast float %40, 8.000000e+00
  %70 = fcmp fast olt float %24, 9.687500e-01
  %71 = fmul fast float %23, 0x3FA1111120000000
  %72 = fadd fast float %71, 0xBFA1111120000000
  %73 = select i1 %70, float %72, float 1.000000e+00
  %74 = fmul fast float %69, %73
  %75 = tail call fast float @air.fast_saturate.f32(float %74) #20
  %76 = tail call fast float @air.fast_sqrt.f32(float %75) #20
  br label %77

77:                                               ; preds = %65, %68
  %78 = phi float [ %76, %68 ], [ 0.000000e+00, %65 ]
  %79 = fsub fast float %8, %10
  %80 = tail call fast float @air.fast_clamp.f32(float %79, float 0.000000e+00, float 1.000000e+00) #20
  %81 = fsub fast float %5, %9
  %82 = tail call fast float @air.fast_clamp.f32(float %81, float 0.000000e+00, float 1.000000e+00) #20
  %83 = tail call fast float @air.mix.f32(float %39, float %53, float %82) #20
  %84 = tail call fast float @air.mix.f32(float %66, float %78, float %82) #20
  %85 = tail call fast float @air.mix.f32(float %83, float %84, float %80) #20
  ret float %85
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
define %struct.Q3FogTexCoord @_Z14q3FogTexCoordsDv3_fRU11MTLconstantK13WorldUniformsRU11MTLconstantK17WorldDrawUniforms(<3 x float> noundef %0, %struct.WorldUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(112) %1, %struct.WorldDrawUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(432) %2) local_unnamed_addr #3 {
  %4 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 18
  %5 = load <4 x float>, <4 x float> addrspace(2)* %4, align 16
  %6 = extractelement <4 x float> %5, i64 3
  %7 = fcmp fast ugt float %6, 0.000000e+00
  br i1 %7, label %8, label %78

8:                                                ; preds = %3
  %9 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 19
  %10 = load <4 x float>, <4 x float> addrspace(2)* %9, align 16
  %11 = extractelement <4 x float> %10, i64 0
  %12 = fcmp fast ugt float %11, 0.000000e+00
  br i1 %12, label %13, label %78

13:                                               ; preds = %8
  %14 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 0
  %15 = load float, float addrspace(2)* %14, align 16
  %16 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 1
  %17 = load float, float addrspace(2)* %16, align 4
  %18 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 2
  %19 = load float, float addrspace(2)* %18, align 8
  %20 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 0
  %21 = load float, float addrspace(2)* %20, align 16
  %22 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 1
  %23 = load float, float addrspace(2)* %22, align 4
  %24 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 2
  %25 = load float, float addrspace(2)* %24, align 8
  %26 = fmul fast float %25, %17
  %27 = fmul fast float %23, %19
  %28 = fsub fast float %26, %27
  %29 = insertelement <3 x float> undef, float %28, i64 0
  %30 = fmul fast float %21, %19
  %31 = fmul fast float %25, %15
  %32 = fsub fast float %30, %31
  %33 = insertelement <3 x float> %29, float %32, i64 1
  %34 = fmul fast float %23, %15
  %35 = fmul fast float %21, %17
  %36 = fsub fast float %34, %35
  %37 = insertelement <3 x float> %33, float %36, i64 2
  %38 = tail call fast float @air.dot.v3f32(<3 x float> %37, <3 x float> %37) #20
  %39 = tail call fast float @air.fast_rsqrt.f32(float %38) #20
  %40 = insertelement <3 x float> poison, float %39, i64 0
  %41 = shufflevector <3 x float> %40, <3 x float> poison, <3 x i32> zeroinitializer
  %42 = fmul fast <3 x float> %37, %41
  %43 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 1, i64 0
  %44 = load float, float addrspace(2)* %43, align 16
  %45 = insertelement <3 x float> undef, float %44, i64 0
  %46 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 1, i64 1
  %47 = load float, float addrspace(2)* %46, align 4
  %48 = insertelement <3 x float> %45, float %47, i64 1
  %49 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 1, i64 2
  %50 = load float, float addrspace(2)* %49, align 8
  %51 = insertelement <3 x float> %48, float %50, i64 2
  %52 = fsub fast <3 x float> %0, %51
  %53 = tail call fast float @air.dot.v3f32(<3 x float> %52, <3 x float> %42) #20
  %54 = fmul fast float %53, %11
  %55 = fadd fast float %54, 0x3F60000000000000
  %56 = extractelement <4 x float> %10, i64 1
  %57 = fcmp fast ogt float %56, 5.000000e-01
  br i1 %57, label %58, label %78

58:                                               ; preds = %13
  %59 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 20
  %60 = load <4 x float>, <4 x float> addrspace(2)* %59, align 16, !tbaa !123
  %61 = shufflevector <4 x float> %60, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %62 = tail call fast float @air.dot.v3f32(<3 x float> %0, <3 x float> %61) #20
  %63 = extractelement <4 x float> %60, i64 3
  %64 = fsub fast float %62, %63
  %65 = tail call fast float @air.dot.v3f32(<3 x float> %51, <3 x float> %61) #20
  %66 = fsub fast float %65, %63
  %67 = fcmp fast olt float %66, 0.000000e+00
  br i1 %67, label %68, label %75

68:                                               ; preds = %58
  %69 = fcmp fast olt float %64, 1.000000e+00
  br i1 %69, label %78, label %70

70:                                               ; preds = %68
  %71 = fmul fast float %64, 9.375000e-01
  %72 = fsub fast float %62, %65
  %73 = fdiv fast float %71, %72
  %74 = fadd fast float %73, 3.125000e-02
  br label %78

75:                                               ; preds = %58
  %76 = fcmp fast olt float %64, 0.000000e+00
  %77 = select fast i1 %76, float 3.125000e-02, float 9.687500e-01
  br label %78

78:                                               ; preds = %13, %68, %70, %75, %3, %8
  %79 = phi float [ -1.000000e+00, %3 ], [ -1.000000e+00, %8 ], [ %55, %75 ], [ %55, %70 ], [ %55, %68 ], [ %55, %13 ]
  %80 = phi float [ 0.000000e+00, %3 ], [ 0.000000e+00, %8 ], [ %77, %75 ], [ %74, %70 ], [ 3.125000e-02, %68 ], [ 9.687500e-01, %13 ]
  %81 = insertvalue %struct.Q3FogTexCoord poison, float %79, 0
  %82 = insertvalue %struct.Q3FogTexCoord %81, float %80, 1
  ret %struct.Q3FogTexCoord %82
}

; Function Attrs: convergent mustprogress nofree nosync nounwind readnone willreturn
define float @_Z11q3FogFactorDv3_fRU11MTLconstantK13WorldUniformsRU11MTLconstantK17WorldDrawUniforms(<3 x float> noundef %0, %struct.WorldUniforms addrspace(2)* nocapture noundef readnone align 16 dereferenceable(112) %1, %struct.WorldDrawUniforms addrspace(2)* nocapture noundef readnone align 16 dereferenceable(432) %2) local_unnamed_addr #10 {
  %4 = tail call %struct.Q3FogTexCoord @_Z14q3FogTexCoordsDv3_fRU11MTLconstantK13WorldUniformsRU11MTLconstantK17WorldDrawUniforms(<3 x float> noundef %0, %struct.WorldUniforms addrspace(2)* noundef align 16 dereferenceable(112) %1, %struct.WorldDrawUniforms addrspace(2)* noundef align 16 dereferenceable(432) %2) #23
  %5 = extractvalue %struct.Q3FogTexCoord %4, 0
  %6 = extractvalue %struct.Q3FogTexCoord %4, 1
  %7 = fcmp fast olt float %5, 0.000000e+00
  %8 = fcmp fast olt float %6, 3.125000e-02
  %9 = select i1 %7, i1 true, i1 %8
  br i1 %9, label %13, label %10

10:                                               ; preds = %3
  %11 = tail call fast float @_Z16q3FogImageFactorff(float noundef %5, float noundef %6) #23
  %12 = tail call fast float @air.fast_saturate.f32(float %11) #20
  br label %13

13:                                               ; preds = %3, %10
  %14 = phi float [ %12, %10 ], [ 0.000000e+00, %3 ]
  ret float %14
}

; Function Attrs: convergent mustprogress nofree nosync nounwind readnone willreturn
define float @_Z17q3EntityFogFactorDv3_fRU11MTLconstantK14EntityUniforms(<3 x float> noundef %0, %struct.EntityUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(384) %1) local_unnamed_addr #10 {
  %3 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 20
  %4 = load <4 x float>, <4 x float> addrspace(2)* %3, align 16
  %5 = extractelement <4 x float> %4, i64 3
  %6 = fcmp fast ugt float %5, 0.000000e+00
  br i1 %6, label %7, label %56

7:                                                ; preds = %2
  %8 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 21
  %9 = load <4 x float>, <4 x float> addrspace(2)* %8, align 16
  %10 = extractelement <4 x float> %9, i64 0
  %11 = fcmp fast ugt float %10, 0.000000e+00
  br i1 %11, label %12, label %56

12:                                               ; preds = %7
  %13 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 1
  %14 = load <3 x float>, <3 x float> addrspace(2)* %13, align 16, !tbaa !123
  %15 = fsub fast <3 x float> %0, %14
  %16 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 2
  %17 = load <3 x float>, <3 x float> addrspace(2)* %16, align 16, !tbaa !123
  %18 = tail call fast float @air.dot.v3f32(<3 x float> %17, <3 x float> %17) #20
  %19 = tail call fast float @air.fast_rsqrt.f32(float %18) #20
  %20 = insertelement <3 x float> poison, float %19, i64 0
  %21 = shufflevector <3 x float> %20, <3 x float> poison, <3 x i32> zeroinitializer
  %22 = fmul fast <3 x float> %21, %17
  %23 = tail call fast float @air.dot.v3f32(<3 x float> %15, <3 x float> %22) #20
  %24 = fmul fast float %23, %10
  %25 = fadd fast float %24, 0x3F60000000000000
  %26 = extractelement <4 x float> %9, i64 1
  %27 = fcmp fast ogt float %26, 5.000000e-01
  br i1 %27, label %28, label %48

28:                                               ; preds = %12
  %29 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 22
  %30 = load <4 x float>, <4 x float> addrspace(2)* %29, align 16, !tbaa !123
  %31 = shufflevector <4 x float> %30, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %32 = tail call fast float @air.dot.v3f32(<3 x float> %0, <3 x float> %31) #20
  %33 = extractelement <4 x float> %30, i64 3
  %34 = fsub fast float %32, %33
  %35 = tail call fast float @air.dot.v3f32(<3 x float> %14, <3 x float> %31) #20
  %36 = fsub fast float %35, %33
  %37 = fcmp fast olt float %36, 0.000000e+00
  br i1 %37, label %38, label %45

38:                                               ; preds = %28
  %39 = fcmp fast olt float %34, 1.000000e+00
  br i1 %39, label %48, label %40

40:                                               ; preds = %38
  %41 = fmul fast float %34, 9.375000e-01
  %42 = fsub fast float %32, %35
  %43 = fdiv fast float %41, %42
  %44 = fadd fast float %43, 3.125000e-02
  br label %48

45:                                               ; preds = %28
  %46 = fcmp fast olt float %34, 0.000000e+00
  %47 = select fast i1 %46, float 3.125000e-02, float 9.687500e-01
  br label %48

48:                                               ; preds = %45, %40, %38, %12
  %49 = phi float [ 9.687500e-01, %12 ], [ %44, %40 ], [ %47, %45 ], [ 3.125000e-02, %38 ]
  %50 = fcmp fast olt float %25, 0.000000e+00
  %51 = fcmp fast olt float %49, 3.125000e-02
  %52 = select i1 %50, i1 true, i1 %51
  br i1 %52, label %56, label %53

53:                                               ; preds = %48
  %54 = tail call fast float @_Z16q3FogImageFactorff(float noundef %25, float noundef %49) #23
  %55 = tail call fast float @air.fast_saturate.f32(float %54) #20
  br label %56

56:                                               ; preds = %53, %48, %2, %7
  %57 = phi float [ 0.000000e+00, %7 ], [ 0.000000e+00, %2 ], [ %55, %53 ], [ 0.000000e+00, %48 ]
  ret float %57
}

; Function Attrs: argmemonly mustprogress nofree nosync nounwind readonly willreturn
define <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> @q3_world_vertex(%struct.WorldVertexIn addrspace(1)* nocapture noundef readonly "air-buffer-no-alias" %0, %struct.WorldUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(112) "air-buffer-no-alias" %1, %struct.WorldDrawUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(432) "air-buffer-no-alias" %2, i32 noundef %3) local_unnamed_addr #11 {
  %5 = zext i32 %3 to i64
  %6 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 0
  %7 = load <3 x float>, <3 x float> addrspace(1)* %6, align 16, !tbaa.struct !156, !alias.scope !157, !noalias !160
  %8 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 1
  %9 = load <2 x float>, <2 x float> addrspace(1)* %8, align 16, !tbaa.struct !163, !alias.scope !157, !noalias !160
  %10 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 2
  %11 = load <2 x float>, <2 x float> addrspace(1)* %10, align 8, !tbaa.struct !164, !alias.scope !157, !noalias !160
  %12 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 3
  %13 = load <3 x float>, <3 x float> addrspace(1)* %12, align 16, !tbaa.struct !165, !alias.scope !157, !noalias !160
  %14 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 4
  %15 = load <4 x float>, <4 x float> addrspace(1)* %14, align 16, !tbaa.struct !166, !alias.scope !157, !noalias !160
  %16 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 5
  %17 = load <4 x float>, <4 x float> addrspace(1)* %16, align 16, !tbaa.struct !167, !alias.scope !157, !noalias !160
  %18 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 6
  %19 = load <4 x float>, <4 x float> addrspace(1)* %18, align 16, !tbaa.struct !168, !alias.scope !157, !noalias !160
  %20 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %5, i32 7
  %21 = load <3 x float>, <3 x float> addrspace(1)* %20, align 16, !tbaa.struct !132, !alias.scope !157, !noalias !160
  %22 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 25
  %23 = load i32, i32 addrspace(2)* %22, align 16, !tbaa !169, !alias.scope !171, !noalias !172
  %24 = icmp eq i32 %23, 0
  br i1 %24, label %87, label %25

25:                                               ; preds = %4
  %26 = tail call fast float @air.dot.v3f32(<3 x float> %13, <3 x float> %13) #20
  %27 = tail call fast float @air.fast_sqrt.f32(float %26) #20
  %28 = fcmp fast ogt float %27, 0x3F1A36E2E0000000
  br i1 %28, label %29, label %87

29:                                               ; preds = %25
  %30 = insertelement <3 x float> poison, float %27, i64 0
  %31 = shufflevector <3 x float> %30, <3 x float> poison, <3 x i32> zeroinitializer
  %32 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 26
  %33 = load float, float addrspace(2)* %32, align 4, !tbaa !173, !alias.scope !171, !noalias !172
  %34 = extractelement <3 x float> %7, i64 0
  %35 = extractelement <3 x float> %7, i64 1
  %36 = fadd fast float %34, %35
  %37 = extractelement <3 x float> %7, i64 2
  %38 = fadd fast float %36, %37
  %39 = fdiv fast float %38, %33
  %40 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 27
  %41 = load float, float addrspace(2)* %40, align 8, !tbaa !174, !alias.scope !171, !noalias !172
  %42 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 28
  %43 = load float, float addrspace(2)* %42, align 4, !tbaa !175, !alias.scope !171, !noalias !172
  %44 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 29
  %45 = load float, float addrspace(2)* %44, align 16, !tbaa !176, !alias.scope !171, !noalias !172
  %46 = fadd fast float %45, %39
  %47 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 30
  %48 = load float, float addrspace(2)* %47, align 4, !tbaa !177, !alias.scope !171, !noalias !172
  %49 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 5
  %50 = load float, float addrspace(2)* %49, align 4, !tbaa !178, !alias.scope !171, !noalias !172
  %51 = fmul fast float %50, %48
  %52 = fadd fast float %46, %51
  %53 = tail call fast float @air.fast_fract.f32(float %52) #20
  switch i32 %23, label %75 [
    i32 3, label %54
    i32 4, label %78
    i32 5, label %57
    i32 2, label %59
  ]

54:                                               ; preds = %29
  %55 = fcmp fast olt float %53, 5.000000e-01
  %56 = select fast i1 %55, float 1.000000e+00, float -1.000000e+00
  br label %78

57:                                               ; preds = %29
  %58 = fsub fast float 1.000000e+00, %53
  br label %78

59:                                               ; preds = %29
  %60 = fcmp fast olt float %53, 2.500000e-01
  br i1 %60, label %61, label %63

61:                                               ; preds = %59
  %62 = fmul fast float %53, 4.000000e+00
  br label %78

63:                                               ; preds = %59
  %64 = fcmp fast olt float %53, 5.000000e-01
  br i1 %64, label %65, label %68

65:                                               ; preds = %63
  %66 = fmul fast float %53, 4.000000e+00
  %67 = fsub fast float 2.000000e+00, %66
  br label %78

68:                                               ; preds = %63
  %69 = fcmp fast olt float %53, 7.500000e-01
  %70 = fmul fast float %53, 4.000000e+00
  br i1 %69, label %71, label %73

71:                                               ; preds = %68
  %72 = fsub fast float 2.000000e+00, %70
  br label %78

73:                                               ; preds = %68
  %74 = fadd fast float %70, -4.000000e+00
  br label %78

75:                                               ; preds = %29
  %76 = fmul fast float %53, 0x401921FB60000000
  %77 = tail call fast float @air.fast_sin.f32(float %76) #20
  br label %78

78:                                               ; preds = %29, %54, %57, %61, %65, %71, %73, %75
  %79 = phi float [ %56, %54 ], [ %58, %57 ], [ %77, %75 ], [ %53, %29 ], [ %62, %61 ], [ %67, %65 ], [ %72, %71 ], [ %74, %73 ]
  %80 = fmul fast float %79, %43
  %81 = fadd fast float %80, %41
  %82 = insertelement <3 x float> poison, float %81, i64 0
  %83 = shufflevector <3 x float> %82, <3 x float> poison, <3 x i32> zeroinitializer
  %84 = fmul fast <3 x float> %83, %13
  %85 = fdiv fast <3 x float> %84, %31
  %86 = fadd fast <3 x float> %85, %7
  br label %87

87:                                               ; preds = %25, %78, %4
  %88 = phi <3 x float> [ %7, %4 ], [ %86, %78 ], [ %7, %25 ]
  %89 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 37
  %90 = load float, float addrspace(2)* %89, align 16, !tbaa !179, !alias.scope !171, !noalias !172
  %91 = fcmp fast une float %90, 0.000000e+00
  br i1 %91, label %96, label %92

92:                                               ; preds = %87
  %93 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 38
  %94 = load float, float addrspace(2)* %93, align 4, !tbaa !180, !alias.scope !171, !noalias !172
  %95 = fcmp fast une float %94, 0.000000e+00
  br i1 %95, label %96, label %120

96:                                               ; preds = %92, %87
  %97 = tail call fast float @air.dot.v3f32(<3 x float> %13, <3 x float> %13) #20
  %98 = tail call fast float @air.fast_sqrt.f32(float %97) #20
  %99 = fcmp fast ogt float %98, 0x3F1A36E2E0000000
  br i1 %99, label %100, label %120

100:                                              ; preds = %96
  %101 = insertelement <3 x float> poison, float %98, i64 0
  %102 = shufflevector <3 x float> %101, <3 x float> poison, <3 x i32> zeroinitializer
  %103 = extractelement <2 x float> %9, i64 0
  %104 = fmul fast float %90, %103
  %105 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 5
  %106 = load float, float addrspace(2)* %105, align 4, !tbaa !178, !alias.scope !171, !noalias !172
  %107 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 39
  %108 = load float, float addrspace(2)* %107, align 8, !tbaa !181, !alias.scope !171, !noalias !172
  %109 = fmul fast float %108, %106
  %110 = fadd fast float %109, %104
  %111 = tail call fast float @air.fast_sin.f32(float %110) #20
  %112 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 38
  %113 = load float, float addrspace(2)* %112, align 4, !tbaa !180, !alias.scope !171, !noalias !172
  %114 = fmul fast float %113, %111
  %115 = insertelement <3 x float> poison, float %114, i64 0
  %116 = shufflevector <3 x float> %115, <3 x float> poison, <3 x i32> zeroinitializer
  %117 = fmul fast <3 x float> %116, %13
  %118 = fdiv fast <3 x float> %117, %102
  %119 = fadd fast <3 x float> %118, %88
  br label %120

120:                                              ; preds = %96, %100, %92
  %121 = phi <3 x float> [ %88, %92 ], [ %119, %100 ], [ %88, %96 ]
  %122 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 31
  %123 = load i32, i32 addrspace(2)* %122, align 8, !tbaa !182, !alias.scope !171, !noalias !172
  %124 = icmp eq i32 %123, 0
  br i1 %124, label %173, label %125

125:                                              ; preds = %120
  %126 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 33
  %127 = load float, float addrspace(2)* %126, align 16, !tbaa !183, !alias.scope !171, !noalias !172
  %128 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 34
  %129 = load float, float addrspace(2)* %128, align 4, !tbaa !184, !alias.scope !171, !noalias !172
  %130 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 35
  %131 = load float, float addrspace(2)* %130, align 8, !tbaa !185, !alias.scope !171, !noalias !172
  %132 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 36
  %133 = load float, float addrspace(2)* %132, align 4, !tbaa !186, !alias.scope !171, !noalias !172
  %134 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 5
  %135 = load float, float addrspace(2)* %134, align 4, !tbaa !178, !alias.scope !171, !noalias !172
  %136 = fmul fast float %135, %133
  %137 = fadd fast float %136, %131
  %138 = tail call fast float @air.fast_fract.f32(float %137) #20
  switch i32 %123, label %160 [
    i32 3, label %139
    i32 4, label %163
    i32 5, label %142
    i32 2, label %144
  ]

139:                                              ; preds = %125
  %140 = fcmp fast olt float %138, 5.000000e-01
  %141 = select fast i1 %140, float 1.000000e+00, float -1.000000e+00
  br label %163

142:                                              ; preds = %125
  %143 = fsub fast float 1.000000e+00, %138
  br label %163

144:                                              ; preds = %125
  %145 = fcmp fast olt float %138, 2.500000e-01
  br i1 %145, label %146, label %148

146:                                              ; preds = %144
  %147 = fmul fast float %138, 4.000000e+00
  br label %163

148:                                              ; preds = %144
  %149 = fcmp fast olt float %138, 5.000000e-01
  br i1 %149, label %150, label %153

150:                                              ; preds = %148
  %151 = fmul fast float %138, 4.000000e+00
  %152 = fsub fast float 2.000000e+00, %151
  br label %163

153:                                              ; preds = %148
  %154 = fcmp fast olt float %138, 7.500000e-01
  %155 = fmul fast float %138, 4.000000e+00
  br i1 %154, label %156, label %158

156:                                              ; preds = %153
  %157 = fsub fast float 2.000000e+00, %155
  br label %163

158:                                              ; preds = %153
  %159 = fadd fast float %155, -4.000000e+00
  br label %163

160:                                              ; preds = %125
  %161 = fmul fast float %138, 0x401921FB60000000
  %162 = tail call fast float @air.fast_sin.f32(float %161) #20
  br label %163

163:                                              ; preds = %125, %139, %142, %146, %150, %156, %158, %160
  %164 = phi float [ %141, %139 ], [ %143, %142 ], [ %162, %160 ], [ %138, %125 ], [ %147, %146 ], [ %152, %150 ], [ %157, %156 ], [ %159, %158 ]
  %165 = fmul fast float %164, %129
  %166 = fadd fast float %165, %127
  %167 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 32
  %168 = load <3 x float>, <3 x float> addrspace(2)* %167, align 16, !tbaa !123, !alias.scope !171, !noalias !172
  %169 = insertelement <3 x float> poison, float %166, i64 0
  %170 = shufflevector <3 x float> %169, <3 x float> poison, <3 x i32> zeroinitializer
  %171 = fmul fast <3 x float> %170, %168
  %172 = fadd fast <3 x float> %171, %121
  br label %173

173:                                              ; preds = %163, %120
  %174 = phi <3 x float> [ %172, %163 ], [ %121, %120 ]
  %175 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %2, i64 0, i32 40
  %176 = load i32, i32 addrspace(2)* %175, align 4, !tbaa !187, !alias.scope !171, !noalias !172
  %177 = icmp eq i32 %176, 1
  br i1 %177, label %178, label %221

178:                                              ; preds = %173
  %179 = shufflevector <4 x float> %17, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %180 = tail call fast float @air.dot.v3f32(<3 x float> %179, <3 x float> %179) #20
  %181 = tail call fast float @air.fast_sqrt.f32(float %180) #20
  %182 = fcmp fast ogt float %181, 0x3F1A36E2E0000000
  br i1 %182, label %183, label %221

183:                                              ; preds = %178
  %184 = fsub fast <3 x float> %174, %179
  %185 = tail call fast float @air.dot.v3f32(<3 x float> %184, <3 x float> %184) #20
  %186 = tail call fast float @air.fast_sqrt.f32(float %185) #20
  %187 = fmul fast float %186, 0x3FE6A09E80000000
  %188 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 0
  %189 = load float, float addrspace(2)* %188, align 16, !alias.scope !188, !noalias !189
  %190 = insertelement <3 x float> undef, float %189, i64 0
  %191 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 1
  %192 = load float, float addrspace(2)* %191, align 4, !alias.scope !188, !noalias !189
  %193 = insertelement <3 x float> %190, float %192, i64 1
  %194 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 2
  %195 = load float, float addrspace(2)* %194, align 8, !alias.scope !188, !noalias !189
  %196 = insertelement <3 x float> %193, float %195, i64 2
  %197 = tail call fast float @air.dot.v3f32(<3 x float> %184, <3 x float> %196) #20
  %198 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 0
  %199 = load float, float addrspace(2)* %198, align 16, !alias.scope !188, !noalias !189
  %200 = insertelement <3 x float> undef, float %199, i64 0
  %201 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 1
  %202 = load float, float addrspace(2)* %201, align 4, !alias.scope !188, !noalias !189
  %203 = insertelement <3 x float> %200, float %202, i64 1
  %204 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 2
  %205 = load float, float addrspace(2)* %204, align 8, !alias.scope !188, !noalias !189
  %206 = insertelement <3 x float> %203, float %205, i64 2
  %207 = tail call fast float @air.dot.v3f32(<3 x float> %184, <3 x float> %206) #20
  %208 = fcmp fast oge float %197, 0.000000e+00
  %209 = fcmp fast oge float %207, 0.000000e+00
  %210 = fneg fast float %187
  %211 = select fast i1 %208, float %187, float %210
  %212 = insertelement <3 x float> poison, float %211, i64 0
  %213 = shufflevector <3 x float> %212, <3 x float> poison, <3 x i32> zeroinitializer
  %214 = fmul fast <3 x float> %213, %196
  %215 = fadd fast <3 x float> %214, %179
  %216 = select fast i1 %209, float %187, float %210
  %217 = insertelement <3 x float> poison, float %216, i64 0
  %218 = shufflevector <3 x float> %217, <3 x float> poison, <3 x i32> zeroinitializer
  %219 = fmul fast <3 x float> %218, %206
  %220 = fadd fast <3 x float> %215, %219
  br label %221

221:                                              ; preds = %183, %178, %173
  %222 = phi <3 x float> [ %220, %183 ], [ %174, %178 ], [ %174, %173 ]
  %223 = icmp eq i32 %176, 2
  br i1 %223, label %224, label %297

224:                                              ; preds = %221
  %225 = shufflevector <4 x float> %17, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %226 = tail call fast float @air.dot.v3f32(<3 x float> %225, <3 x float> %225) #20
  %227 = tail call fast float @air.fast_sqrt.f32(float %226) #20
  %228 = fcmp fast ogt float %227, 0x3F1A36E2E0000000
  br i1 %228, label %229, label %297

229:                                              ; preds = %224
  %230 = shufflevector <4 x float> %19, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %231 = tail call fast float @air.dot.v3f32(<3 x float> %230, <3 x float> %230) #20
  %232 = tail call fast float @air.fast_sqrt.f32(float %231) #20
  %233 = fcmp fast ogt float %232, 0x3F1A36E2E0000000
  br i1 %233, label %234, label %297

234:                                              ; preds = %229
  %235 = fsub fast <3 x float> %222, %225
  %236 = tail call fast float @air.dot.v3f32(<3 x float> %235, <3 x float> %230) #20
  %237 = insertelement <3 x float> poison, float %236, i64 0
  %238 = shufflevector <3 x float> %237, <3 x float> poison, <3 x i32> zeroinitializer
  %239 = fmul fast <3 x float> %238, %230
  %240 = fsub fast <3 x float> %235, %239
  %241 = tail call fast float @air.dot.v3f32(<3 x float> %240, <3 x float> %240) #20
  %242 = tail call fast float @air.fast_sqrt.f32(float %241) #20
  %243 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 0
  %244 = load float, float addrspace(2)* %243, align 16, !alias.scope !188, !noalias !189
  %245 = insertelement <3 x float> undef, float %244, i64 0
  %246 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 1
  %247 = load float, float addrspace(2)* %246, align 4, !alias.scope !188, !noalias !189
  %248 = insertelement <3 x float> %245, float %247, i64 1
  %249 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 3, i64 2
  %250 = load float, float addrspace(2)* %249, align 8, !alias.scope !188, !noalias !189
  %251 = insertelement <3 x float> %248, float %250, i64 2
  %252 = tail call fast float @air.dot.v3f32(<3 x float> %251, <3 x float> %230) #20
  %253 = insertelement <3 x float> poison, float %252, i64 0
  %254 = shufflevector <3 x float> %253, <3 x float> poison, <3 x i32> zeroinitializer
  %255 = fmul fast <3 x float> %254, %230
  %256 = fsub fast <3 x float> %251, %255
  %257 = tail call fast float @air.dot.v3f32(<3 x float> %256, <3 x float> %256) #20
  %258 = tail call fast float @air.fast_sqrt.f32(float %257) #20
  %259 = fcmp fast ogt float %258, 0x3F50624DE0000000
  br i1 %259, label %260, label %264

260:                                              ; preds = %234
  %261 = insertelement <3 x float> poison, float %258, i64 0
  %262 = shufflevector <3 x float> %261, <3 x float> poison, <3 x i32> zeroinitializer
  %263 = fdiv fast <3 x float> %256, %262
  br label %286

264:                                              ; preds = %234
  %265 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 0
  %266 = load float, float addrspace(2)* %265, align 16, !alias.scope !188, !noalias !189
  %267 = insertelement <3 x float> undef, float %266, i64 0
  %268 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 1
  %269 = load float, float addrspace(2)* %268, align 4, !alias.scope !188, !noalias !189
  %270 = insertelement <3 x float> %267, float %269, i64 1
  %271 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 5, i64 2
  %272 = load float, float addrspace(2)* %271, align 8, !alias.scope !188, !noalias !189
  %273 = insertelement <3 x float> %270, float %272, i64 2
  %274 = tail call fast float @air.dot.v3f32(<3 x float> %273, <3 x float> %230) #20
  %275 = insertelement <3 x float> poison, float %274, i64 0
  %276 = shufflevector <3 x float> %275, <3 x float> poison, <3 x i32> zeroinitializer
  %277 = fmul fast <3 x float> %276, %230
  %278 = fsub fast <3 x float> %273, %277
  %279 = tail call fast float @air.dot.v3f32(<3 x float> %278, <3 x float> %278) #20
  %280 = tail call fast float @air.fast_sqrt.f32(float %279) #20
  %281 = fcmp fast ogt float %280, 0x3F50624DE0000000
  br i1 %281, label %282, label %286

282:                                              ; preds = %264
  %283 = insertelement <3 x float> poison, float %280, i64 0
  %284 = shufflevector <3 x float> %283, <3 x float> poison, <3 x i32> zeroinitializer
  %285 = fdiv fast <3 x float> %278, %284
  br label %286

286:                                              ; preds = %282, %264, %260
  %287 = phi <3 x float> [ %263, %260 ], [ %285, %282 ], [ <float 0.000000e+00, float 0.000000e+00, float 1.000000e+00>, %264 ]
  %288 = tail call fast float @air.dot.v3f32(<3 x float> %240, <3 x float> %287) #20
  %289 = fcmp fast oge float %288, 0.000000e+00
  %290 = fadd fast <3 x float> %239, %225
  %291 = fneg fast float %242
  %292 = select fast i1 %289, float %242, float %291
  %293 = insertelement <3 x float> poison, float %292, i64 0
  %294 = shufflevector <3 x float> %293, <3 x float> poison, <3 x i32> zeroinitializer
  %295 = fmul fast <3 x float> %294, %287
  %296 = fadd fast <3 x float> %290, %295
  br label %297

297:                                              ; preds = %286, %229, %224, %221
  %298 = phi <3 x float> [ %296, %286 ], [ %222, %229 ], [ %222, %224 ], [ %222, %221 ]
  %299 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 0
  %300 = load <4 x float>, <4 x float> addrspace(2)* %299, align 16, !tbaa !123, !alias.scope !188, !noalias !189
  %301 = shufflevector <3 x float> %298, <3 x float> undef, <4 x i32> zeroinitializer
  %302 = fmul fast <4 x float> %300, %301
  %303 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 1
  %304 = load <4 x float>, <4 x float> addrspace(2)* %303, align 16, !tbaa !123, !alias.scope !188, !noalias !189
  %305 = shufflevector <3 x float> %298, <3 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %306 = fmul fast <4 x float> %304, %305
  %307 = fadd fast <4 x float> %306, %302
  %308 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 2
  %309 = load <4 x float>, <4 x float> addrspace(2)* %308, align 16, !tbaa !123, !alias.scope !188, !noalias !189
  %310 = shufflevector <3 x float> %298, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %311 = fmul fast <4 x float> %309, %310
  %312 = fadd fast <4 x float> %307, %311
  %313 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 3
  %314 = load <4 x float>, <4 x float> addrspace(2)* %313, align 16, !tbaa !123, !alias.scope !188, !noalias !189
  %315 = fadd fast <4 x float> %312, %314
  %316 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> undef, <4 x float> %315, 0
  %317 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %316, <2 x float> %9, 1
  %318 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %317, <2 x float> %11, 2
  %319 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %318, <4 x float> %15, 3
  %320 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %319, <3 x float> %298, 4
  %321 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %320, <3 x float> %13, 5
  %322 = insertvalue <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %321, <3 x float> %21, 6
  ret <{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> %322
}

; Function Attrs: convergent nounwind
define <4 x float> @q3_world_fragment(<4 x float> %0, <2 x float> %1, <2 x float> %2, <4 x float> %3, <3 x float> %4, <3 x float> %5, <3 x float> %6, %struct.WorldDrawUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(432) "air-buffer-no-alias" %7, %struct.WorldUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(112) "air-buffer-no-alias" %8, %struct.DLightBlock addrspace(2)* nocapture noundef readnone align 4 dereferenceable(1040) "air-buffer-no-alias" %9, <4 x float> addrspace(2)* nocapture noundef readonly align 16 dereferenceable(16) "air-buffer-no-alias" %10, %struct._texture_2d_t addrspace(1)* %11, %struct._texture_2d_t addrspace(1)* %12, %struct._texture_2d_t addrspace(1)* %13, %struct._texture_cube_t addrspace(1)* %14, %struct._texture_2d_t addrspace(1)* %15, %struct._texture_2d_t addrspace(1)* %16, %struct._texture_2d_t addrspace(1)* %17, %struct._sampler_t addrspace(2)* nocapture readonly %18, %struct._sampler_t addrspace(2)* nocapture readonly %19) local_unnamed_addr #12 {
  %21 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 2
  %22 = load float, float addrspace(2)* %21, align 8, !tbaa !190, !alias.scope !191, !noalias !194
  %23 = fadd fast float %22, 5.000000e-01
  %24 = tail call i32 @air.convert.s.i32.f.f32(float %23) #20
  %25 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 3
  %26 = load float, float addrspace(2)* %25, align 4, !tbaa !200, !alias.scope !191, !noalias !194
  %27 = fadd fast float %26, 5.000000e-01
  %28 = tail call i32 @air.convert.s.i32.f.f32(float %27) #20
  %29 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 4
  %30 = load float, float addrspace(2)* %29, align 16, !tbaa !201, !alias.scope !191, !noalias !194
  %31 = fadd fast float %30, 5.000000e-01
  %32 = tail call i32 @air.convert.s.i32.f.f32(float %31) #20
  %33 = and i32 %32, -5
  %34 = icmp eq i32 %33, 1
  %35 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 0
  %36 = load float, float addrspace(2)* %35, align 16, !tbaa !202, !alias.scope !191, !noalias !194
  %37 = fadd fast float %36, 5.000000e-01
  %38 = tail call i32 @air.convert.s.i32.f.f32(float %37) #20
  switch i32 %38, label %116 [
    i32 1, label %39
    i32 2, label %104
    i32 4, label %115
  ]

39:                                               ; preds = %20
  %40 = tail call fast float @air.dot.v3f32(<3 x float> %5, <3 x float> %5) #20
  %41 = tail call fast float @air.fast_sqrt.f32(float %40) #20
  %42 = fcmp fast ogt float %41, 0x3F1A36E2E0000000
  br i1 %42, label %43, label %47

43:                                               ; preds = %39
  %44 = insertelement <3 x float> poison, float %41, i64 0
  %45 = shufflevector <3 x float> %44, <3 x float> poison, <3 x i32> zeroinitializer
  %46 = fdiv fast <3 x float> %5, %45
  br label %73

47:                                               ; preds = %39
  %48 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %4) #24
  %49 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %4) #24
  %50 = extractelement <3 x float> %48, i64 1
  %51 = extractelement <3 x float> %49, i64 2
  %52 = fmul fast float %51, %50
  %53 = extractelement <3 x float> %49, i64 1
  %54 = extractelement <3 x float> %48, i64 2
  %55 = fmul fast float %53, %54
  %56 = fsub fast float %52, %55
  %57 = insertelement <3 x float> undef, float %56, i64 0
  %58 = extractelement <3 x float> %49, i64 0
  %59 = fmul fast float %58, %54
  %60 = extractelement <3 x float> %48, i64 0
  %61 = fmul fast float %51, %60
  %62 = fsub fast float %59, %61
  %63 = insertelement <3 x float> %57, float %62, i64 1
  %64 = fmul fast float %53, %60
  %65 = fmul fast float %58, %50
  %66 = fsub fast float %64, %65
  %67 = insertelement <3 x float> %63, float %66, i64 2
  %68 = tail call fast float @air.dot.v3f32(<3 x float> %67, <3 x float> %67) #20
  %69 = tail call fast float @air.fast_rsqrt.f32(float %68) #20
  %70 = insertelement <3 x float> poison, float %69, i64 0
  %71 = shufflevector <3 x float> %70, <3 x float> poison, <3 x i32> zeroinitializer
  %72 = fmul fast <3 x float> %67, %71
  br label %73

73:                                               ; preds = %47, %43
  %74 = phi <3 x float> [ %46, %43 ], [ %72, %47 ]
  %75 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %8, i64 0, i32 1, i64 0
  %76 = load float, float addrspace(2)* %75, align 16, !alias.scope !203, !noalias !204
  %77 = insertelement <3 x float> undef, float %76, i64 0
  %78 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %8, i64 0, i32 1, i64 1
  %79 = load float, float addrspace(2)* %78, align 4, !alias.scope !203, !noalias !204
  %80 = insertelement <3 x float> %77, float %79, i64 1
  %81 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %8, i64 0, i32 1, i64 2
  %82 = load float, float addrspace(2)* %81, align 8, !alias.scope !203, !noalias !204
  %83 = insertelement <3 x float> %80, float %82, i64 2
  %84 = fsub fast <3 x float> %83, %4
  %85 = tail call fast float @air.dot.v3f32(<3 x float> %84, <3 x float> %84) #20
  %86 = tail call fast float @air.fast_rsqrt.f32(float %85) #20
  %87 = insertelement <3 x float> poison, float %86, i64 0
  %88 = shufflevector <3 x float> %87, <3 x float> poison, <3 x i32> zeroinitializer
  %89 = fmul fast <3 x float> %88, %84
  %90 = tail call fast float @air.dot.v3f32(<3 x float> %89, <3 x float> %74) #20
  %91 = fmul fast float %90, 2.000000e+00
  %92 = insertelement <3 x float> poison, float %91, i64 0
  %93 = shufflevector <3 x float> %92, <3 x float> poison, <3 x i32> <i32 undef, i32 0, i32 0>
  %94 = fmul fast <3 x float> %93, %74
  %95 = fsub fast <3 x float> %94, %89
  %96 = extractelement <3 x float> %95, i64 1
  %97 = fmul fast float %96, 5.000000e-01
  %98 = fadd fast float %97, 5.000000e-01
  %99 = insertelement <2 x float> undef, float %98, i64 0
  %100 = extractelement <3 x float> %95, i64 2
  %101 = fmul fast float %100, 5.000000e-01
  %102 = fsub fast float 5.000000e-01, %101
  %103 = insertelement <2 x float> %99, float %102, i64 1
  br label %116

104:                                              ; preds = %20
  %105 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 23
  %106 = load <4 x float>, <4 x float> addrspace(2)* %105, align 16, !alias.scope !191, !noalias !194
  %107 = shufflevector <4 x float> %106, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %108 = tail call fast float @air.dot.v3f32(<3 x float> %4, <3 x float> %107) #20
  %109 = insertelement <2 x float> undef, float %108, i64 0
  %110 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 24
  %111 = load <4 x float>, <4 x float> addrspace(2)* %110, align 16, !alias.scope !191, !noalias !194
  %112 = shufflevector <4 x float> %111, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %113 = tail call fast float @air.dot.v3f32(<3 x float> %4, <3 x float> %112) #20
  %114 = insertelement <2 x float> %109, float %113, i64 1
  br label %116

115:                                              ; preds = %20
  br label %116

116:                                              ; preds = %20, %104, %115, %73
  %117 = phi <2 x float> [ %103, %73 ], [ %114, %104 ], [ %2, %115 ], [ %1, %20 ]
  %118 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 1
  %119 = load i32, i32 addrspace(2)* %118, align 4, !tbaa !205, !alias.scope !191, !noalias !194
  %120 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 9
  %121 = load <4 x float>, <4 x float> addrspace(2)* %120, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %122 = fadd fast <4 x float> %121, <float 5.000000e-01, float 5.000000e-01, float 5.000000e-01, float 5.000000e-01>
  %123 = tail call <4 x i32> @air.convert.s.v4i32.f.v4f32(<4 x float> %122) #20
  %124 = icmp sgt i32 %119, 0
  br i1 %124, label %125, label %132

125:                                              ; preds = %116
  %126 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 5
  %127 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 10
  %128 = extractelement <4 x i32> %123, i64 0
  %129 = load <4 x float>, <4 x float> addrspace(2)* %127, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %130 = load float, float addrspace(2)* %126, align 4, !tbaa !178, !alias.scope !191, !noalias !194
  %131 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %117, <3 x float> noundef %4, i32 noundef %128, <4 x float> noundef %129, float noundef %130) #23
  br label %132

132:                                              ; preds = %125, %116
  %133 = phi <2 x float> [ %131, %125 ], [ %117, %116 ]
  %134 = icmp sgt i32 %119, 1
  br i1 %134, label %135, label %142

135:                                              ; preds = %132
  %136 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 5
  %137 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 11
  %138 = extractelement <4 x i32> %123, i64 1
  %139 = load <4 x float>, <4 x float> addrspace(2)* %137, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %140 = load float, float addrspace(2)* %136, align 4, !tbaa !178, !alias.scope !191, !noalias !194
  %141 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %133, <3 x float> noundef %4, i32 noundef %138, <4 x float> noundef %139, float noundef %140) #23
  br label %142

142:                                              ; preds = %135, %132
  %143 = phi <2 x float> [ %141, %135 ], [ %133, %132 ]
  %144 = icmp sgt i32 %119, 2
  br i1 %144, label %145, label %152

145:                                              ; preds = %142
  %146 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 5
  %147 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 12
  %148 = extractelement <4 x i32> %123, i64 2
  %149 = load <4 x float>, <4 x float> addrspace(2)* %147, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %150 = load float, float addrspace(2)* %146, align 4, !tbaa !178, !alias.scope !191, !noalias !194
  %151 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %143, <3 x float> noundef %4, i32 noundef %148, <4 x float> noundef %149, float noundef %150) #23
  br label %152

152:                                              ; preds = %145, %142
  %153 = phi <2 x float> [ %151, %145 ], [ %143, %142 ]
  %154 = icmp sgt i32 %119, 3
  br i1 %154, label %155, label %162

155:                                              ; preds = %152
  %156 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 5
  %157 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 13
  %158 = extractelement <4 x i32> %123, i64 3
  %159 = load <4 x float>, <4 x float> addrspace(2)* %157, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %160 = load float, float addrspace(2)* %156, align 4, !tbaa !178, !alias.scope !191, !noalias !194
  %161 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %153, <3 x float> noundef %4, i32 noundef %158, <4 x float> noundef %159, float noundef %160) #23
  br label %162

162:                                              ; preds = %155, %152
  %163 = phi <2 x float> [ %161, %155 ], [ %153, %152 ]
  %164 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 21
  %165 = load <4 x float>, <4 x float> addrspace(2)* %164, align 16, !alias.scope !191, !noalias !194
  %166 = extractelement <4 x float> %165, i64 0
  %167 = fcmp fast ogt float %166, 5.000000e-01
  br i1 %167, label %168, label %192

168:                                              ; preds = %162
  %169 = extractelement <4 x float> %165, i64 1
  %170 = extractelement <4 x float> %165, i64 2
  %171 = fmul fast float %166, %169
  %172 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 5
  %173 = load float, float addrspace(2)* %172, align 4, !tbaa !178, !alias.scope !191, !noalias !194
  %174 = fmul fast float %173, %170
  %175 = tail call fast float @air.fast_floor.f32(float %174) #20
  %176 = tail call fast float @air.fast_fmod.f32(float %175, float %171) #20
  %177 = fcmp fast olt float %176, 0.000000e+00
  %178 = select i1 %177, float %171, float -0.000000e+00
  %179 = fadd fast float %178, %176
  %180 = tail call fast float @air.fast_fmod.f32(float %179, float %166) #20
  %181 = fdiv fast float %179, %166
  %182 = tail call fast float @air.fast_floor.f32(float %181) #20
  %183 = tail call fast <2 x float> @___metal_fract_v2float(<2 x float> %163, i32 0) #25
  %184 = extractelement <2 x float> %183, i64 0
  %185 = fadd fast float %184, %180
  %186 = fdiv fast float %185, %166
  %187 = insertelement <2 x float> undef, float %186, i64 0
  %188 = extractelement <2 x float> %183, i64 1
  %189 = fadd fast float %188, %182
  %190 = fdiv fast float %189, %169
  %191 = insertelement <2 x float> %187, float %190, i64 1
  br label %192

192:                                              ; preds = %168, %162
  %193 = phi <2 x float> [ %191, %168 ], [ %163, %162 ]
  %194 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %11, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %193, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %195 = extractvalue { <4 x float>, i8 } %194, 0
  %196 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 41
  %197 = load float, float addrspace(2)* %196, align 16, !tbaa !208, !alias.scope !191, !noalias !194
  %198 = fadd fast float %197, 5.000000e-01
  %199 = tail call i32 @air.convert.s.i32.f.f32(float %198) #20
  switch i32 %199, label %215 [
    i32 1, label %200
    i32 2, label %202
    i32 3, label %206
    i32 4, label %213
  ]

200:                                              ; preds = %192
  %201 = insertelement <4 x float> %195, float 1.000000e+00, i64 3
  br label %740

202:                                              ; preds = %192
  %203 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %12, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %2, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %204 = extractvalue { <4 x float>, i8 } %203, 0
  %205 = insertelement <4 x float> %204, float 1.000000e+00, i64 3
  br label %740

206:                                              ; preds = %192
  %207 = extractelement <2 x float> %2, i64 0
  %208 = tail call fast float @air.fast_fract.f32(float %207) #20
  %209 = extractelement <2 x float> %2, i64 1
  %210 = tail call fast float @air.fast_fract.f32(float %209) #20
  %211 = insertelement <4 x float> <float poison, float poison, float 0.000000e+00, float 1.000000e+00>, float %208, i64 0
  %212 = insertelement <4 x float> %211, float %210, i64 1
  br label %740

213:                                              ; preds = %192
  %214 = insertelement <4 x float> %3, float 1.000000e+00, i64 3
  br label %740

215:                                              ; preds = %192
  %216 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 44
  %217 = load float, float addrspace(2)* %216, align 4, !tbaa !209, !alias.scope !191, !noalias !194
  %218 = fcmp fast ogt float %217, 5.000000e-01
  br i1 %218, label %219, label %306

219:                                              ; preds = %215
  %220 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 18
  %221 = load <4 x float>, <4 x float> addrspace(2)* %220, align 16, !alias.scope !191, !noalias !194
  %222 = extractelement <4 x float> %221, i64 3
  %223 = fcmp fast ugt float %222, 0.000000e+00
  br i1 %223, label %224, label %740

224:                                              ; preds = %219
  %225 = tail call %struct.Q3FogTexCoord @_Z14q3FogTexCoordsDv3_fRU11MTLconstantK13WorldUniformsRU11MTLconstantK17WorldDrawUniforms(<3 x float> noundef %4, %struct.WorldUniforms addrspace(2)* noundef align 16 dereferenceable(112) %8, %struct.WorldDrawUniforms addrspace(2)* noundef align 16 dereferenceable(432) %7) #26
  %226 = extractvalue %struct.Q3FogTexCoord %225, 0
  %227 = extractvalue %struct.Q3FogTexCoord %225, 1
  %228 = fcmp fast olt float %226, 0.000000e+00
  %229 = fcmp fast olt float %227, 3.125000e-02
  %230 = select i1 %228, i1 true, i1 %229
  br i1 %230, label %234, label %231

231:                                              ; preds = %224
  %232 = tail call fast float @_Z16q3FogImageFactorff(float noundef %226, float noundef %227) #26
  %233 = tail call fast float @air.fast_saturate.f32(float %232) #20
  br label %234

234:                                              ; preds = %224, %231
  %235 = phi float [ %233, %231 ], [ 0.000000e+00, %224 ]
  %236 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 49
  %237 = load float, float addrspace(2)* %236, align 16, !tbaa !210, !alias.scope !191, !noalias !194
  %238 = fcmp fast ogt float %237, 5.000000e-01
  br i1 %238, label %239, label %297

239:                                              ; preds = %234
  %240 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 19
  %241 = load <4 x float>, <4 x float> addrspace(2)* %240, align 16, !alias.scope !191, !noalias !194
  %242 = extractelement <4 x float> %241, i64 1
  %243 = fcmp fast ogt float %242, 5.000000e-01
  br i1 %243, label %244, label %294

244:                                              ; preds = %239
  %245 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 20
  %246 = load <4 x float>, <4 x float> addrspace(2)* %245, align 16, !alias.scope !191, !noalias !194
  %247 = shufflevector <4 x float> %246, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %248 = tail call fast float @air.dot.v3f32(<3 x float> %247, <3 x float> %247) #20
  %249 = tail call fast float @air.fast_sqrt.f32(float %248) #20
  %250 = fcmp fast ogt float %249, 0x3F1A36E2E0000000
  br i1 %250, label %251, label %294

251:                                              ; preds = %244
  %252 = insertelement <3 x float> poison, float %249, i64 0
  %253 = shufflevector <3 x float> %252, <3 x float> poison, <3 x i32> zeroinitializer
  %254 = fdiv fast <3 x float> %247, %253
  %255 = tail call fast float @air.dot.v3f32(<3 x float> %5, <3 x float> %5) #20
  %256 = tail call fast float @air.fast_sqrt.f32(float %255) #20
  %257 = fcmp fast ogt float %256, 0x3F1A36E2E0000000
  br i1 %257, label %258, label %262

258:                                              ; preds = %251
  %259 = insertelement <3 x float> poison, float %256, i64 0
  %260 = shufflevector <3 x float> %259, <3 x float> poison, <3 x i32> zeroinitializer
  %261 = fdiv fast <3 x float> %5, %260
  br label %288

262:                                              ; preds = %251
  %263 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %4) #24
  %264 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %4) #24
  %265 = extractelement <3 x float> %263, i64 1
  %266 = extractelement <3 x float> %264, i64 2
  %267 = fmul fast float %266, %265
  %268 = extractelement <3 x float> %264, i64 1
  %269 = extractelement <3 x float> %263, i64 2
  %270 = fmul fast float %268, %269
  %271 = fsub fast float %267, %270
  %272 = insertelement <3 x float> undef, float %271, i64 0
  %273 = extractelement <3 x float> %264, i64 0
  %274 = fmul fast float %273, %269
  %275 = extractelement <3 x float> %263, i64 0
  %276 = fmul fast float %266, %275
  %277 = fsub fast float %274, %276
  %278 = insertelement <3 x float> %272, float %277, i64 1
  %279 = fmul fast float %268, %275
  %280 = fmul fast float %273, %265
  %281 = fsub fast float %279, %280
  %282 = insertelement <3 x float> %278, float %281, i64 2
  %283 = tail call fast float @air.dot.v3f32(<3 x float> %282, <3 x float> %282) #20
  %284 = tail call fast float @air.fast_rsqrt.f32(float %283) #20
  %285 = insertelement <3 x float> poison, float %284, i64 0
  %286 = shufflevector <3 x float> %285, <3 x float> poison, <3 x i32> zeroinitializer
  %287 = fmul fast <3 x float> %282, %286
  br label %288

288:                                              ; preds = %262, %258
  %289 = phi <3 x float> [ %261, %258 ], [ %287, %262 ]
  %290 = tail call fast float @air.dot.v3f32(<3 x float> %289, <3 x float> %254) #20
  %291 = tail call fast float @air.fast_fabs.f32(float %290) #20
  %292 = fcmp fast ogt float %291, 0x3FE6666660000000
  %293 = select fast i1 %292, float 0x3FCEB851E0000000, float 0.000000e+00
  br label %294

294:                                              ; preds = %239, %244, %288
  %295 = phi float [ %293, %288 ], [ 0.000000e+00, %244 ], [ 0x3FC70A3D80000000, %239 ]
  %296 = tail call fast float @air.fast_fmax.f32(float %235, float %295) #20
  br label %297

297:                                              ; preds = %294, %234
  %298 = phi float [ %296, %294 ], [ %235, %234 ]
  %299 = shufflevector <4 x float> %221, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %300 = tail call fast float @air.dot.v3f32(<3 x float> %299, <3 x float> %299) #20
  %301 = fcmp fast olt float %300, 0x3F50624DE0000000
  %302 = select i1 %301, <3 x float> <float 0x3FD70A3D80000000, float 0x3FD70A3D80000000, float 0x3FD70A3D80000000>, <3 x float> %299
  %303 = shufflevector <3 x float> %302, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %304 = tail call fast float @air.fast_saturate.f32(float %298) #20
  %305 = insertelement <4 x float> %303, float %304, i64 3
  br label %740

306:                                              ; preds = %215
  %307 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 43
  %308 = load float, float addrspace(2)* %307, align 8, !tbaa !211, !alias.scope !191, !noalias !194
  %309 = fcmp fast ogt float %308, 0.000000e+00
  br i1 %309, label %310, label %314

310:                                              ; preds = %306
  %311 = extractelement <4 x float> %195, i64 3
  %312 = fcmp fast olt float %311, %308
  br i1 %312, label %313, label %321

313:                                              ; preds = %310
  tail call void @air.discard_fragment() #27
  br label %321

314:                                              ; preds = %306
  %315 = fcmp fast uge float %308, 0.000000e+00
  %316 = extractelement <4 x float> %195, i64 3
  %317 = fneg fast float %308
  %318 = fcmp fast ult float %316, %317
  %319 = select i1 %315, i1 true, i1 %318
  br i1 %319, label %321, label %320

320:                                              ; preds = %314
  tail call void @air.discard_fragment() #27
  br label %321

321:                                              ; preds = %314, %320, %310, %313
  %322 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 14
  %323 = load <4 x float>, <4 x float> addrspace(2)* %322, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %324 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 6
  %325 = load i32, i32 addrspace(2)* %324, align 8, !tbaa !212, !alias.scope !191, !noalias !194
  %326 = extractelement <4 x float> %323, i64 0
  %327 = extractelement <4 x float> %323, i64 1
  %328 = extractelement <4 x float> %323, i64 2
  %329 = extractelement <4 x float> %323, i64 3
  %330 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 5
  %331 = load float, float addrspace(2)* %330, align 4, !tbaa !178, !alias.scope !191, !noalias !194
  %332 = fmul fast float %331, %329
  %333 = fadd fast float %332, %328
  %334 = tail call fast float @air.fast_fract.f32(float %333) #20
  switch i32 %325, label %356 [
    i32 3, label %335
    i32 4, label %359
    i32 5, label %338
    i32 2, label %340
  ]

335:                                              ; preds = %321
  %336 = fcmp fast olt float %334, 5.000000e-01
  %337 = select fast i1 %336, float 1.000000e+00, float -1.000000e+00
  br label %359

338:                                              ; preds = %321
  %339 = fsub fast float 1.000000e+00, %334
  br label %359

340:                                              ; preds = %321
  %341 = fcmp fast olt float %334, 2.500000e-01
  br i1 %341, label %342, label %344

342:                                              ; preds = %340
  %343 = fmul fast float %334, 4.000000e+00
  br label %359

344:                                              ; preds = %340
  %345 = fcmp fast olt float %334, 5.000000e-01
  br i1 %345, label %346, label %349

346:                                              ; preds = %344
  %347 = fmul fast float %334, 4.000000e+00
  %348 = fsub fast float 2.000000e+00, %347
  br label %359

349:                                              ; preds = %344
  %350 = fcmp fast olt float %334, 7.500000e-01
  %351 = fmul fast float %334, 4.000000e+00
  br i1 %350, label %352, label %354

352:                                              ; preds = %349
  %353 = fsub fast float 2.000000e+00, %351
  br label %359

354:                                              ; preds = %349
  %355 = fadd fast float %351, -4.000000e+00
  br label %359

356:                                              ; preds = %321
  %357 = fmul fast float %334, 0x401921FB60000000
  %358 = tail call fast float @air.fast_sin.f32(float %357) #20
  br label %359

359:                                              ; preds = %321, %335, %338, %342, %346, %352, %354, %356
  %360 = phi float [ %337, %335 ], [ %339, %338 ], [ %358, %356 ], [ %334, %321 ], [ %343, %342 ], [ %348, %346 ], [ %353, %352 ], [ %355, %354 ]
  %361 = fmul fast float %360, %327
  %362 = fadd fast float %361, %326
  %363 = tail call fast float @air.fast_clamp.f32(float %362, float 0.000000e+00, float 1.000000e+00) #20
  %364 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 15
  %365 = load <4 x float>, <4 x float> addrspace(2)* %364, align 16, !tbaa !123, !alias.scope !191, !noalias !194
  %366 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 7
  %367 = load i32, i32 addrspace(2)* %366, align 4, !tbaa !213, !alias.scope !191, !noalias !194
  %368 = extractelement <4 x float> %365, i64 0
  %369 = extractelement <4 x float> %365, i64 1
  %370 = extractelement <4 x float> %365, i64 2
  %371 = extractelement <4 x float> %365, i64 3
  %372 = fmul fast float %371, %331
  %373 = fadd fast float %372, %370
  %374 = tail call fast float @air.fast_fract.f32(float %373) #20
  switch i32 %367, label %396 [
    i32 3, label %375
    i32 4, label %399
    i32 5, label %378
    i32 2, label %380
  ]

375:                                              ; preds = %359
  %376 = fcmp fast olt float %374, 5.000000e-01
  %377 = select fast i1 %376, float 1.000000e+00, float -1.000000e+00
  br label %399

378:                                              ; preds = %359
  %379 = fsub fast float 1.000000e+00, %374
  br label %399

380:                                              ; preds = %359
  %381 = fcmp fast olt float %374, 2.500000e-01
  br i1 %381, label %382, label %384

382:                                              ; preds = %380
  %383 = fmul fast float %374, 4.000000e+00
  br label %399

384:                                              ; preds = %380
  %385 = fcmp fast olt float %374, 5.000000e-01
  br i1 %385, label %386, label %389

386:                                              ; preds = %384
  %387 = fmul fast float %374, 4.000000e+00
  %388 = fsub fast float 2.000000e+00, %387
  br label %399

389:                                              ; preds = %384
  %390 = fcmp fast olt float %374, 7.500000e-01
  %391 = fmul fast float %374, 4.000000e+00
  br i1 %390, label %392, label %394

392:                                              ; preds = %389
  %393 = fsub fast float 2.000000e+00, %391
  br label %399

394:                                              ; preds = %389
  %395 = fadd fast float %391, -4.000000e+00
  br label %399

396:                                              ; preds = %359
  %397 = fmul fast float %374, 0x401921FB60000000
  %398 = tail call fast float @air.fast_sin.f32(float %397) #20
  br label %399

399:                                              ; preds = %359, %375, %378, %382, %386, %392, %394, %396
  %400 = phi float [ %377, %375 ], [ %379, %378 ], [ %398, %396 ], [ %374, %359 ], [ %383, %382 ], [ %388, %386 ], [ %393, %392 ], [ %395, %394 ]
  %401 = fmul fast float %400, %369
  %402 = fadd fast float %401, %368
  %403 = tail call fast float @air.fast_clamp.f32(float %402, float 0.000000e+00, float 1.000000e+00) #20
  %404 = shufflevector <4 x float> %3, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %405 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 16
  %406 = load <4 x float>, <4 x float> addrspace(2)* %405, align 16, !alias.scope !191, !noalias !194
  %407 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 17
  %408 = load <4 x float>, <4 x float> addrspace(2)* %407, align 16, !alias.scope !191, !noalias !194
  %409 = shufflevector <4 x float> %408, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  switch i32 %24, label %419 [
    i32 1, label %420
    i32 2, label %410
    i32 3, label %411
    i32 4, label %414
    i32 5, label %416
    i32 6, label %417
  ]

410:                                              ; preds = %399
  br label %420

411:                                              ; preds = %399
  %412 = insertelement <3 x float> poison, float %363, i64 0
  %413 = shufflevector <3 x float> %412, <3 x float> poison, <3 x i32> zeroinitializer
  br label %420

414:                                              ; preds = %399
  %415 = shufflevector <4 x float> %406, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  br label %420

416:                                              ; preds = %399
  br label %420

417:                                              ; preds = %399
  %418 = fsub fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %409
  br label %420

419:                                              ; preds = %399
  br label %420

420:                                              ; preds = %399, %410, %411, %414, %416, %417, %419
  %421 = phi <3 x float> [ <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %419 ], [ %418, %417 ], [ %409, %416 ], [ %415, %414 ], [ %413, %411 ], [ %6, %410 ], [ %404, %399 ]
  %422 = extractelement <4 x float> %3, i64 3
  %423 = extractelement <4 x float> %408, i64 3
  switch i32 %28, label %430 [
    i32 1, label %431
    i32 3, label %424
    i32 4, label %425
    i32 5, label %427
    i32 6, label %428
  ]

424:                                              ; preds = %420
  br label %431

425:                                              ; preds = %420
  %426 = extractelement <4 x float> %406, i64 3
  br label %431

427:                                              ; preds = %420
  br label %431

428:                                              ; preds = %420
  %429 = fsub fast float 1.000000e+00, %423
  br label %431

430:                                              ; preds = %420
  br label %431

431:                                              ; preds = %420, %424, %425, %427, %428, %430
  %432 = phi float [ 1.000000e+00, %430 ], [ %429, %428 ], [ %423, %427 ], [ %426, %425 ], [ %403, %424 ], [ %422, %420 ]
  %433 = shufflevector <4 x float> %195, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %434 = fmul fast <3 x float> %421, %433
  %435 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 49
  %436 = load float, float addrspace(2)* %435, align 16, !tbaa !210, !alias.scope !191, !noalias !194
  %437 = fcmp fast ogt float %436, 5.000000e-01
  br i1 %437, label %438, label %443

438:                                              ; preds = %431
  %439 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %12, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %2, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %440 = extractvalue { <4 x float>, i8 } %439, 0
  %441 = shufflevector <4 x float> %440, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %442 = fmul fast <3 x float> %441, %434
  br label %443

443:                                              ; preds = %438, %431
  %444 = phi <3 x float> [ %442, %438 ], [ %434, %431 ]
  br i1 %34, label %478, label %445

445:                                              ; preds = %443
  %446 = tail call fast float @air.dot.v3f32(<3 x float> %5, <3 x float> %5) #20
  %447 = tail call fast float @air.fast_sqrt.f32(float %446) #20
  %448 = fcmp fast ugt float %447, 0x3F1A36E2E0000000
  br i1 %448, label %475, label %449

449:                                              ; preds = %445
  %450 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %4) #24
  %451 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %4) #24
  %452 = extractelement <3 x float> %450, i64 1
  %453 = extractelement <3 x float> %451, i64 2
  %454 = fmul fast float %453, %452
  %455 = extractelement <3 x float> %451, i64 1
  %456 = extractelement <3 x float> %450, i64 2
  %457 = fmul fast float %455, %456
  %458 = fsub fast float %454, %457
  %459 = insertelement <3 x float> undef, float %458, i64 0
  %460 = extractelement <3 x float> %451, i64 0
  %461 = fmul fast float %460, %456
  %462 = extractelement <3 x float> %450, i64 0
  %463 = fmul fast float %453, %462
  %464 = fsub fast float %461, %463
  %465 = insertelement <3 x float> %459, float %464, i64 1
  %466 = fmul fast float %455, %462
  %467 = fmul fast float %460, %452
  %468 = fsub fast float %466, %467
  %469 = insertelement <3 x float> %465, float %468, i64 2
  %470 = tail call fast float @air.dot.v3f32(<3 x float> %469, <3 x float> %469) #20
  %471 = tail call fast float @air.fast_rsqrt.f32(float %470) #20
  %472 = insertelement <3 x float> poison, float %471, i64 0
  %473 = shufflevector <3 x float> %472, <3 x float> poison, <3 x i32> zeroinitializer
  %474 = fmul fast <3 x float> %469, %473
  br label %475

475:                                              ; preds = %449, %445
  %476 = phi <3 x float> [ %474, %449 ], [ %5, %445 ]
  %477 = tail call fast <3 x float> @_Z12applyDlightsDv3_fS_S_RU11MTLconstantK11DLightBlock(<3 x float> noundef %444, <3 x float> noundef %4, <3 x float> noundef %476, %struct.DLightBlock addrspace(2)* noundef align 4 dereferenceable(1040) %9) #23
  br label %478

478:                                              ; preds = %475, %443
  %479 = phi <3 x float> [ %444, %443 ], [ %477, %475 ]
  %480 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %13) #22, !alias.scope !214, !noalias !215
  br i1 %480, label %720, label %481

481:                                              ; preds = %478
  %482 = fmul fast <2 x float> %1, <float 5.000000e-01, float 5.000000e-01>
  %483 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %13, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %482, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %484 = extractvalue { <4 x float>, i8 } %483, 0
  %485 = shufflevector <4 x float> %484, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %486 = fmul fast <3 x float> %485, <float 2.000000e+00, float 2.000000e+00, float 2.000000e+00>
  %487 = fadd fast <3 x float> %486, <float -1.000000e+00, float -1.000000e+00, float -1.000000e+00>
  %488 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %4) #24
  %489 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %4) #24
  %490 = tail call fast float @air.dot.v3f32(<3 x float> %5, <3 x float> %5) #20
  %491 = tail call fast float @air.fast_sqrt.f32(float %490) #20
  %492 = fcmp fast olt float %491, 0x3F1A36E2E0000000
  br i1 %492, label %493, label %517

493:                                              ; preds = %481
  %494 = extractelement <3 x float> %488, i64 1
  %495 = extractelement <3 x float> %489, i64 2
  %496 = fmul fast float %495, %494
  %497 = extractelement <3 x float> %489, i64 1
  %498 = extractelement <3 x float> %488, i64 2
  %499 = fmul fast float %497, %498
  %500 = fsub fast float %496, %499
  %501 = insertelement <3 x float> undef, float %500, i64 0
  %502 = extractelement <3 x float> %489, i64 0
  %503 = fmul fast float %502, %498
  %504 = extractelement <3 x float> %488, i64 0
  %505 = fmul fast float %495, %504
  %506 = fsub fast float %503, %505
  %507 = insertelement <3 x float> %501, float %506, i64 1
  %508 = fmul fast float %497, %504
  %509 = fmul fast float %502, %494
  %510 = fsub fast float %508, %509
  %511 = insertelement <3 x float> %507, float %510, i64 2
  %512 = tail call fast float @air.dot.v3f32(<3 x float> %511, <3 x float> %511) #20
  %513 = tail call fast float @air.fast_rsqrt.f32(float %512) #20
  %514 = insertelement <3 x float> poison, float %513, i64 0
  %515 = shufflevector <3 x float> %514, <3 x float> poison, <3 x i32> zeroinitializer
  %516 = fmul fast <3 x float> %515, %511
  br label %528

517:                                              ; preds = %481
  %518 = tail call fast float @air.fast_rsqrt.f32(float %490) #20
  %519 = insertelement <3 x float> poison, float %518, i64 0
  %520 = shufflevector <3 x float> %519, <3 x float> poison, <3 x i32> zeroinitializer
  %521 = fmul fast <3 x float> %520, %5
  %522 = extractelement <3 x float> %489, i64 1
  %523 = extractelement <3 x float> %489, i64 2
  %524 = extractelement <3 x float> %489, i64 0
  %525 = extractelement <3 x float> %488, i64 2
  %526 = extractelement <3 x float> %488, i64 1
  %527 = extractelement <3 x float> %488, i64 0
  br label %528

528:                                              ; preds = %517, %493
  %529 = phi float [ %527, %517 ], [ %504, %493 ]
  %530 = phi float [ %526, %517 ], [ %494, %493 ]
  %531 = phi float [ %525, %517 ], [ %498, %493 ]
  %532 = phi float [ %524, %517 ], [ %502, %493 ]
  %533 = phi float [ %523, %517 ], [ %495, %493 ]
  %534 = phi float [ %522, %517 ], [ %497, %493 ]
  %535 = phi <3 x float> [ %521, %517 ], [ %516, %493 ]
  %536 = tail call fast <2 x float> @air.dfdx.v2f32(<2 x float> %1) #24
  %537 = tail call fast <2 x float> @air.dfdy.v2f32(<2 x float> %1) #24
  %538 = extractelement <3 x float> %535, i64 2
  %539 = fmul fast float %538, %534
  %540 = extractelement <3 x float> %535, i64 1
  %541 = fmul fast float %540, %533
  %542 = fsub fast float %539, %541
  %543 = insertelement <3 x float> undef, float %542, i64 0
  %544 = extractelement <3 x float> %535, i64 0
  %545 = fmul fast float %544, %533
  %546 = fmul fast float %538, %532
  %547 = fsub fast float %545, %546
  %548 = insertelement <3 x float> %543, float %547, i64 1
  %549 = fmul fast float %540, %532
  %550 = fmul fast float %544, %534
  %551 = fsub fast float %549, %550
  %552 = insertelement <3 x float> %548, float %551, i64 2
  %553 = fmul fast float %540, %531
  %554 = fmul fast float %538, %530
  %555 = fsub fast float %553, %554
  %556 = insertelement <3 x float> undef, float %555, i64 0
  %557 = fmul fast float %538, %529
  %558 = fmul fast float %544, %531
  %559 = fsub fast float %557, %558
  %560 = insertelement <3 x float> %556, float %559, i64 1
  %561 = fmul fast float %544, %530
  %562 = fmul fast float %540, %529
  %563 = fsub fast float %561, %562
  %564 = insertelement <3 x float> %560, float %563, i64 2
  %565 = shufflevector <2 x float> %536, <2 x float> undef, <3 x i32> zeroinitializer
  %566 = fmul fast <3 x float> %552, %565
  %567 = shufflevector <2 x float> %537, <2 x float> undef, <3 x i32> zeroinitializer
  %568 = fmul fast <3 x float> %564, %567
  %569 = fadd fast <3 x float> %566, %568
  %570 = shufflevector <2 x float> %536, <2 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %571 = fmul fast <3 x float> %552, %570
  %572 = shufflevector <2 x float> %537, <2 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %573 = fmul fast <3 x float> %564, %572
  %574 = fadd fast <3 x float> %571, %573
  %575 = tail call fast float @air.dot.v3f32(<3 x float> %569, <3 x float> %569) #20
  %576 = tail call fast float @air.dot.v3f32(<3 x float> %574, <3 x float> %574) #20
  %577 = tail call fast float @air.fast_fmax.f32(float %575, float %576) #20
  %578 = fadd fast float %577, 0x3F1A36E2E0000000
  %579 = tail call fast float @air.fast_rsqrt.f32(float %578) #20
  %580 = insertelement <3 x float> poison, float %579, i64 0
  %581 = shufflevector <3 x float> %580, <3 x float> poison, <3 x i32> zeroinitializer
  %582 = shufflevector <3 x float> %487, <3 x float> poison, <3 x i32> zeroinitializer
  %583 = fmul fast <3 x float> %569, %582
  %584 = shufflevector <3 x float> %487, <3 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %585 = fmul fast <3 x float> %574, %584
  %586 = shufflevector <3 x float> %487, <3 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %587 = fmul fast <3 x float> %535, %586
  %588 = fadd fast <3 x float> %583, %585
  %589 = fmul fast <3 x float> %588, %581
  %590 = fadd fast <3 x float> %589, %587
  %591 = tail call fast float @air.dot.v3f32(<3 x float> %590, <3 x float> %590) #20
  %592 = tail call fast float @air.fast_rsqrt.f32(float %591) #20
  %593 = insertelement <3 x float> poison, float %592, i64 0
  %594 = shufflevector <3 x float> %593, <3 x float> poison, <3 x i32> zeroinitializer
  %595 = fmul fast <3 x float> %590, %594
  %596 = tail call fast float @air.dot.v3f32(<3 x float> <float 0x3FD99999A0000000, float 5.000000e-01, float 0x3FE3333340000000>, <3 x float> <float 0x3FD99999A0000000, float 5.000000e-01, float 0x3FE3333340000000>) #20
  %597 = tail call fast float @air.fast_rsqrt.f32(float %596) #20
  %598 = insertelement <3 x float> poison, float %597, i64 0
  %599 = shufflevector <3 x float> %598, <3 x float> poison, <3 x i32> zeroinitializer
  %600 = fmul fast <3 x float> %599, <float 0x3FD99999A0000000, float 5.000000e-01, float 0x3FE3333340000000>
  %601 = tail call fast float @air.dot.v3f32(<3 x float> %595, <3 x float> %600) #20
  %602 = fmul fast float %601, 5.000000e-01
  %603 = fadd fast float %602, 5.000000e-01
  %604 = fmul fast float %603, %603
  %605 = fmul fast float %604, 0x3FE6666660000000
  %606 = fadd fast float %605, 0x3FE4CCCCC0000000
  %607 = insertelement <3 x float> poison, float %606, i64 0
  %608 = shufflevector <3 x float> %607, <3 x float> poison, <3 x i32> zeroinitializer
  %609 = fmul fast <3 x float> %608, %479
  %610 = load <4 x float>, <4 x float> addrspace(2)* %10, align 16, !alias.scope !216, !noalias !217
  %611 = extractelement <4 x float> %610, i64 0
  %612 = fcmp fast ogt float %611, 5.000000e-01
  br i1 %612, label %613, label %720

613:                                              ; preds = %528
  %614 = tail call i1 @air.is_null_texture_cube(%struct._texture_cube_t addrspace(1)* nocapture readonly %14) #22, !alias.scope !214, !noalias !215
  %615 = xor i1 %614, true
  %616 = icmp ne i32 %38, 1
  %617 = select i1 %615, i1 %616, i1 false
  br i1 %617, label %618, label %720

618:                                              ; preds = %613
  %619 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %8, i64 0, i32 1, i64 0
  %620 = load float, float addrspace(2)* %619, align 16, !alias.scope !203, !noalias !204
  %621 = insertelement <3 x float> undef, float %620, i64 0
  %622 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %8, i64 0, i32 1, i64 1
  %623 = load float, float addrspace(2)* %622, align 4, !alias.scope !203, !noalias !204
  %624 = insertelement <3 x float> %621, float %623, i64 1
  %625 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %8, i64 0, i32 1, i64 2
  %626 = load float, float addrspace(2)* %625, align 8, !alias.scope !203, !noalias !204
  %627 = insertelement <3 x float> %624, float %626, i64 2
  %628 = fsub fast <3 x float> %627, %4
  %629 = tail call fast float @air.dot.v3f32(<3 x float> %628, <3 x float> %628) #20
  %630 = tail call fast float @air.fast_rsqrt.f32(float %629) #20
  %631 = insertelement <3 x float> poison, float %630, i64 0
  %632 = shufflevector <3 x float> %631, <3 x float> poison, <3 x i32> zeroinitializer
  %633 = fmul fast <3 x float> %632, %628
  %634 = tail call fast float @air.dot.v3f32(<3 x float> %595, <3 x float> %633) #20
  %635 = tail call fast float @air.fast_fmax.f32(float %634, float 0.000000e+00) #20
  %636 = extractelement <4 x float> %610, i64 3
  %637 = fcmp fast ogt float %636, 5.000000e-01
  %638 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 47
  %639 = load float, float addrspace(2)* %638, align 8, !alias.scope !191, !noalias !194
  %640 = select fast i1 %637, float %639, float 0x3FDCCCCCC0000000
  %641 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 48
  %642 = load float, float addrspace(2)* %641, align 4, !alias.scope !191, !noalias !194
  %643 = select fast i1 %637, float %642, float 0x3FD3333340000000
  %644 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %15) #22, !alias.scope !214, !noalias !215
  br i1 %644, label %649, label %645

645:                                              ; preds = %618
  %646 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %15, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %193, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %647 = extractvalue { <4 x float>, i8 } %646, 0
  %648 = extractelement <4 x float> %647, i64 0
  br label %649

649:                                              ; preds = %645, %618
  %650 = phi float [ %640, %618 ], [ %648, %645 ]
  %651 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %16) #22, !alias.scope !214, !noalias !215
  br i1 %651, label %656, label %652

652:                                              ; preds = %649
  %653 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %16, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %193, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %654 = extractvalue { <4 x float>, i8 } %653, 0
  %655 = extractelement <4 x float> %654, i64 0
  br label %656

656:                                              ; preds = %652, %649
  %657 = phi float [ %643, %649 ], [ %655, %652 ]
  %658 = fmul fast float %650, 0x3FEA3D70A0000000
  %659 = tail call fast float @air.fast_clamp.f32(float %658, float 0x3FC47AE140000000, float 0x3FEC28F5C0000000) #20
  %660 = tail call fast float @air.fast_clamp.f32(float %657, float 0.000000e+00, float 1.000000e+00) #20
  %661 = tail call i32 @air.get_num_mip_levels_texture_cube(%struct._texture_cube_t addrspace(1)* nocapture readonly %14) #22, !alias.scope !214, !noalias !215
  %662 = add i32 %661, -1
  %663 = tail call fast float @air.convert.f.f32.u.i32(i32 %662) #20
  %664 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(%struct._texture_cube_t addrspace(1)* nocapture readonly %14, %struct._sampler_t addrspace(2)* nocapture readonly %19, <3 x float> %595, i1 true, float %663, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %665 = extractvalue { <4 x float>, i8 } %664, 0
  %666 = shufflevector <4 x float> %665, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %667 = fneg fast <3 x float> %633
  %668 = tail call fast float @air.dot.v3f32(<3 x float> %595, <3 x float> %667) #20
  %669 = fmul fast float %668, 2.000000e+00
  %670 = insertelement <3 x float> poison, float %669, i64 0
  %671 = shufflevector <3 x float> %670, <3 x float> poison, <3 x i32> zeroinitializer
  %672 = fmul fast <3 x float> %671, %595
  %673 = fsub fast <3 x float> %667, %672
  %674 = fmul fast float %663, %659
  %675 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(%struct._texture_cube_t addrspace(1)* nocapture readonly %14, %struct._sampler_t addrspace(2)* nocapture readonly %19, <3 x float> %673, i1 true, float %674, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %676 = extractvalue { <4 x float>, i8 } %675, 0
  %677 = shufflevector <4 x float> %676, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %678 = fsub fast float 1.000000e+00, %635
  %679 = insertelement <3 x float> poison, float %660, i64 0
  %680 = shufflevector <3 x float> %679, <3 x float> poison, <3 x i32> zeroinitializer
  %681 = tail call fast <3 x float> @air.mix.v3f32(<3 x float> <float 0x3FA47AE140000000, float 0x3FA47AE140000000, float 0x3FA47AE140000000>, <3 x float> %609, <3 x float> %680) #20
  %682 = fsub fast float 1.000000e+00, %659
  %683 = insertelement <3 x float> poison, float %682, i64 0
  %684 = shufflevector <3 x float> %683, <3 x float> poison, <3 x i32> zeroinitializer
  %685 = tail call fast <3 x float> @air.fast_fmax.v3f32(<3 x float> %684, <3 x float> %681) #20
  %686 = fsub fast <3 x float> %685, %681
  %687 = tail call fast float @air.fast_pow.f32(float %678, float 5.000000e+00) #20
  %688 = insertelement <3 x float> poison, float %687, i64 0
  %689 = shufflevector <3 x float> %688, <3 x float> poison, <3 x i32> zeroinitializer
  %690 = fmul fast <3 x float> %689, %686
  %691 = fadd fast <3 x float> %690, %681
  %692 = fsub fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %691
  %693 = fsub fast float 1.000000e+00, %660
  %694 = insertelement <3 x float> poison, float %693, i64 0
  %695 = shufflevector <3 x float> %694, <3 x float> poison, <3 x i32> zeroinitializer
  %696 = extractelement <4 x float> %610, i64 1
  %697 = extractelement <4 x float> %610, i64 2
  %698 = tail call fast float @air.dot.v3f32(<3 x float> %609, <3 x float> <float 0x3FCB367A00000000, float 0x3FE6E2EB20000000, float 0x3FB27BB300000000>) #20
  %699 = tail call fast float @air.fast_saturate.f32(float %698) #20
  %700 = fsub fast float 1.000000e+00, %699
  %701 = tail call fast float @air.fast_pow.f32(float %678, float 0x3FF59999A0000000) #20
  %702 = fmul fast float %700, %696
  %703 = fmul fast float %700, 0x3FD6666660000000
  %704 = fadd fast float %703, 0x3FE4CCCCC0000000
  %705 = fmul fast float %704, %697
  %706 = fmul fast float %701, 0x3FE19999A0000000
  %707 = fadd fast float %706, 0x3FDCCCCCC0000000
  %708 = fmul fast float %705, %707
  %709 = insertelement <3 x float> poison, float %702, i64 0
  %710 = shufflevector <3 x float> %709, <3 x float> poison, <3 x i32> zeroinitializer
  %711 = fmul fast <3 x float> %666, %695
  %712 = fmul fast <3 x float> %711, %692
  %713 = fmul fast <3 x float> %712, %710
  %714 = fadd fast <3 x float> %713, %609
  %715 = fmul fast <3 x float> %691, %677
  %716 = insertelement <3 x float> poison, float %708, i64 0
  %717 = shufflevector <3 x float> %716, <3 x float> poison, <3 x i32> zeroinitializer
  %718 = fmul fast <3 x float> %715, %717
  %719 = fadd fast <3 x float> %714, %718
  br label %720

720:                                              ; preds = %528, %613, %656, %478
  %721 = phi <3 x float> [ %479, %478 ], [ %719, %656 ], [ %609, %613 ], [ %609, %528 ]
  %722 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %7, i64 0, i32 22
  %723 = load <4 x float>, <4 x float> addrspace(2)* %722, align 16, !alias.scope !191, !noalias !194
  %724 = extractelement <4 x float> %723, i64 3
  %725 = fcmp fast ogt float %724, 0.000000e+00
  br i1 %725, label %726, label %734

726:                                              ; preds = %720
  %727 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %17, %struct._sampler_t addrspace(2)* nocapture readonly %18, <2 x float> %193, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !206, !noalias !207
  %728 = extractvalue { <4 x float>, i8 } %727, 0
  %729 = fmul fast <4 x float> %728, %723
  %730 = shufflevector <4 x float> %729, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %731 = shufflevector <4 x float> %723, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %732 = fmul fast <3 x float> %730, %731
  %733 = fadd fast <3 x float> %732, %721
  br label %734

734:                                              ; preds = %726, %720
  %735 = phi <3 x float> [ %733, %726 ], [ %721, %720 ]
  %736 = shufflevector <3 x float> %735, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %737 = extractelement <4 x float> %195, i64 3
  %738 = fmul fast float %432, %737
  %739 = insertelement <4 x float> %736, float %738, i64 3
  br label %740

740:                                              ; preds = %219, %734, %297, %213, %206, %202, %200
  %741 = phi <4 x float> [ %201, %200 ], [ %205, %202 ], [ %212, %206 ], [ %214, %213 ], [ %305, %297 ], [ %739, %734 ], [ zeroinitializer, %219 ]
  ret <4 x float> %741
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare i32 @air.convert.s.i32.f.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <4 x i32> @air.convert.s.v4i32.f.v4f32(<4 x float>) local_unnamed_addr #6

; Function Attrs: argmemonly mustprogress nofree nosync nounwind readonly willreturn
define <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> @q3_entity_vertex(%struct.EntityVertexIn addrspace(1)* nocapture noundef readonly "air-buffer-no-alias" %0, %struct.EntityUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(384) "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #11 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds %struct.EntityVertexIn, %struct.EntityVertexIn addrspace(1)* %0, i64 %4, i32 0
  %6 = load <3 x float>, <3 x float> addrspace(1)* %5, align 16, !tbaa.struct !218, !alias.scope !219, !noalias !222
  %7 = getelementptr inbounds %struct.EntityVertexIn, %struct.EntityVertexIn addrspace(1)* %0, i64 %4, i32 1
  %8 = load <2 x float>, <2 x float> addrspace(1)* %7, align 16, !tbaa.struct !224, !alias.scope !219, !noalias !222
  %9 = getelementptr inbounds %struct.EntityVertexIn, %struct.EntityVertexIn addrspace(1)* %0, i64 %4, i32 2
  %10 = load <4 x float>, <4 x float> addrspace(1)* %9, align 16, !tbaa.struct !168, !alias.scope !219, !noalias !222
  %11 = getelementptr inbounds %struct.EntityVertexIn, %struct.EntityVertexIn addrspace(1)* %0, i64 %4, i32 3
  %12 = load <3 x float>, <3 x float> addrspace(1)* %11, align 16, !tbaa.struct !132, !alias.scope !219, !noalias !222
  %13 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 25
  %14 = load i32, i32 addrspace(2)* %13, align 8, !tbaa !225, !alias.scope !222, !noalias !219
  %15 = icmp eq i32 %14, 0
  br i1 %15, label %79, label %16

16:                                               ; preds = %3
  %17 = tail call fast float @air.dot.v3f32(<3 x float> %12, <3 x float> %12) #20
  %18 = tail call fast float @air.fast_sqrt.f32(float %17) #20
  %19 = fcmp fast ogt float %18, 0x3F1A36E2E0000000
  br i1 %19, label %20, label %79

20:                                               ; preds = %16
  %21 = insertelement <3 x float> poison, float %18, i64 0
  %22 = shufflevector <3 x float> %21, <3 x float> poison, <3 x i32> zeroinitializer
  %23 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 26
  %24 = load float, float addrspace(2)* %23, align 4, !tbaa !228, !alias.scope !222, !noalias !219
  %25 = tail call fast float @air.fast_fmax.f32(float %24, float 0x3F1A36E2E0000000) #20
  %26 = extractelement <3 x float> %6, i64 0
  %27 = extractelement <3 x float> %6, i64 1
  %28 = fadd fast float %26, %27
  %29 = extractelement <3 x float> %6, i64 2
  %30 = fadd fast float %28, %29
  %31 = fdiv fast float %30, %25
  %32 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 27
  %33 = load float, float addrspace(2)* %32, align 16, !tbaa !229, !alias.scope !222, !noalias !219
  %34 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 28
  %35 = load float, float addrspace(2)* %34, align 4, !tbaa !230, !alias.scope !222, !noalias !219
  %36 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 29
  %37 = load float, float addrspace(2)* %36, align 8, !tbaa !231, !alias.scope !222, !noalias !219
  %38 = fadd fast float %37, %31
  %39 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 30
  %40 = load float, float addrspace(2)* %39, align 4, !tbaa !232, !alias.scope !222, !noalias !219
  %41 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 4
  %42 = load float, float addrspace(2)* %41, align 4, !tbaa !233, !alias.scope !222, !noalias !219
  %43 = fmul fast float %42, %40
  %44 = fadd fast float %38, %43
  %45 = tail call fast float @air.fast_fract.f32(float %44) #20
  switch i32 %14, label %67 [
    i32 3, label %46
    i32 4, label %70
    i32 5, label %49
    i32 2, label %51
  ]

46:                                               ; preds = %20
  %47 = fcmp fast olt float %45, 5.000000e-01
  %48 = select fast i1 %47, float 1.000000e+00, float -1.000000e+00
  br label %70

49:                                               ; preds = %20
  %50 = fsub fast float 1.000000e+00, %45
  br label %70

51:                                               ; preds = %20
  %52 = fcmp fast olt float %45, 2.500000e-01
  br i1 %52, label %53, label %55

53:                                               ; preds = %51
  %54 = fmul fast float %45, 4.000000e+00
  br label %70

55:                                               ; preds = %51
  %56 = fcmp fast olt float %45, 5.000000e-01
  br i1 %56, label %57, label %60

57:                                               ; preds = %55
  %58 = fmul fast float %45, 4.000000e+00
  %59 = fsub fast float 2.000000e+00, %58
  br label %70

60:                                               ; preds = %55
  %61 = fcmp fast olt float %45, 7.500000e-01
  %62 = fmul fast float %45, 4.000000e+00
  br i1 %61, label %63, label %65

63:                                               ; preds = %60
  %64 = fsub fast float 2.000000e+00, %62
  br label %70

65:                                               ; preds = %60
  %66 = fadd fast float %62, -4.000000e+00
  br label %70

67:                                               ; preds = %20
  %68 = fmul fast float %45, 0x401921FB60000000
  %69 = tail call fast float @air.fast_sin.f32(float %68) #20
  br label %70

70:                                               ; preds = %20, %46, %49, %53, %57, %63, %65, %67
  %71 = phi float [ %48, %46 ], [ %50, %49 ], [ %69, %67 ], [ %45, %20 ], [ %54, %53 ], [ %59, %57 ], [ %64, %63 ], [ %66, %65 ]
  %72 = fmul fast float %71, %35
  %73 = fadd fast float %72, %33
  %74 = insertelement <3 x float> poison, float %73, i64 0
  %75 = shufflevector <3 x float> %74, <3 x float> poison, <3 x i32> zeroinitializer
  %76 = fmul fast <3 x float> %75, %12
  %77 = fdiv fast <3 x float> %76, %22
  %78 = fadd fast <3 x float> %77, %6
  br label %79

79:                                               ; preds = %16, %70, %3
  %80 = phi <3 x float> [ %6, %3 ], [ %78, %70 ], [ %6, %16 ]
  %81 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 0
  %82 = load <4 x float>, <4 x float> addrspace(2)* %81, align 16, !tbaa !123, !alias.scope !222, !noalias !219
  %83 = shufflevector <3 x float> %80, <3 x float> undef, <4 x i32> zeroinitializer
  %84 = fmul fast <4 x float> %82, %83
  %85 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 1
  %86 = load <4 x float>, <4 x float> addrspace(2)* %85, align 16, !tbaa !123, !alias.scope !222, !noalias !219
  %87 = shufflevector <3 x float> %80, <3 x float> undef, <4 x i32> <i32 1, i32 1, i32 1, i32 1>
  %88 = fmul fast <4 x float> %86, %87
  %89 = fadd fast <4 x float> %88, %84
  %90 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 2
  %91 = load <4 x float>, <4 x float> addrspace(2)* %90, align 16, !tbaa !123, !alias.scope !222, !noalias !219
  %92 = shufflevector <3 x float> %80, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 2, i32 2>
  %93 = fmul fast <4 x float> %91, %92
  %94 = fadd fast <4 x float> %89, %93
  %95 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 3
  %96 = load <4 x float>, <4 x float> addrspace(2)* %95, align 16, !tbaa !123, !alias.scope !222, !noalias !219
  %97 = fadd fast <4 x float> %94, %96
  %98 = insertvalue <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> undef, <4 x float> %97, 0
  %99 = insertvalue <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> %98, <2 x float> %8, 1
  %100 = insertvalue <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> %99, <4 x float> %10, 2
  %101 = insertvalue <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> %100, <3 x float> %80, 3
  %102 = insertvalue <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> %101, <3 x float> %12, 4
  ret <{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> %102
}

; Function Attrs: convergent nounwind
define <4 x float> @q3_entity_fragment(<4 x float> %0, <2 x float> %1, <4 x float> %2, <3 x float> %3, <3 x float> %4, %struct.EntityUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(384) "air-buffer-no-alias" %5, %struct.DLightBlock addrspace(2)* nocapture noundef readnone align 4 dereferenceable(1040) "air-buffer-no-alias" %6, float addrspace(2)* nocapture noundef readonly align 4 dereferenceable(4) "air-buffer-no-alias" %7, <2 x float> addrspace(2)* nocapture noundef readonly align 8 dereferenceable(8) "air-buffer-no-alias" %8, %struct._texture_2d_t addrspace(1)* %9, %struct._texture_2d_t addrspace(1)* %10, %struct._texture_2d_t addrspace(1)* %11, %struct._texture_2d_t addrspace(1)* %12, %struct._texture_cube_t addrspace(1)* %13, %struct._texture_2d_t addrspace(1)* %14, %struct._sampler_t addrspace(2)* nocapture readonly %15, %struct._sampler_t addrspace(2)* nocapture readonly %16) local_unnamed_addr #12 {
  %18 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 3
  %19 = load float, float addrspace(2)* %18, align 16, !tbaa !234, !alias.scope !235, !noalias !238
  %20 = fadd fast float %19, 5.000000e-01
  %21 = tail call i32 @air.convert.s.i32.f.f32(float %20) #20
  %22 = icmp eq i32 %21, 1
  br i1 %22, label %23, label %81

23:                                               ; preds = %17
  %24 = tail call fast float @air.dot.v3f32(<3 x float> %4, <3 x float> %4) #20
  %25 = fcmp fast ogt float %24, 0x3F1A36E2E0000000
  br i1 %25, label %26, label %31

26:                                               ; preds = %23
  %27 = tail call fast float @air.fast_rsqrt.f32(float %24) #20
  %28 = insertelement <3 x float> poison, float %27, i64 0
  %29 = shufflevector <3 x float> %28, <3 x float> poison, <3 x i32> zeroinitializer
  %30 = fmul fast <3 x float> %29, %4
  br label %57

31:                                               ; preds = %23
  %32 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %3) #24
  %33 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %3) #24
  %34 = extractelement <3 x float> %32, i64 1
  %35 = extractelement <3 x float> %33, i64 2
  %36 = fmul fast float %35, %34
  %37 = extractelement <3 x float> %33, i64 1
  %38 = extractelement <3 x float> %32, i64 2
  %39 = fmul fast float %37, %38
  %40 = fsub fast float %36, %39
  %41 = insertelement <3 x float> undef, float %40, i64 0
  %42 = extractelement <3 x float> %33, i64 0
  %43 = fmul fast float %42, %38
  %44 = extractelement <3 x float> %32, i64 0
  %45 = fmul fast float %35, %44
  %46 = fsub fast float %43, %45
  %47 = insertelement <3 x float> %41, float %46, i64 1
  %48 = fmul fast float %37, %44
  %49 = fmul fast float %42, %34
  %50 = fsub fast float %48, %49
  %51 = insertelement <3 x float> %47, float %50, i64 2
  %52 = tail call fast float @air.dot.v3f32(<3 x float> %51, <3 x float> %51) #20
  %53 = tail call fast float @air.fast_rsqrt.f32(float %52) #20
  %54 = insertelement <3 x float> poison, float %53, i64 0
  %55 = shufflevector <3 x float> %54, <3 x float> poison, <3 x i32> zeroinitializer
  %56 = fmul fast <3 x float> %51, %55
  br label %57

57:                                               ; preds = %31, %26
  %58 = phi <3 x float> [ %30, %26 ], [ %56, %31 ]
  %59 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 1
  %60 = load <3 x float>, <3 x float> addrspace(2)* %59, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %61 = fsub fast <3 x float> %60, %3
  %62 = tail call fast float @air.dot.v3f32(<3 x float> %61, <3 x float> %61) #20
  %63 = tail call fast float @air.fast_rsqrt.f32(float %62) #20
  %64 = insertelement <3 x float> poison, float %63, i64 0
  %65 = shufflevector <3 x float> %64, <3 x float> poison, <3 x i32> zeroinitializer
  %66 = fmul fast <3 x float> %65, %61
  %67 = tail call fast float @air.dot.v3f32(<3 x float> %66, <3 x float> %58) #20
  %68 = fmul fast float %67, 2.000000e+00
  %69 = insertelement <3 x float> poison, float %68, i64 0
  %70 = shufflevector <3 x float> %69, <3 x float> poison, <3 x i32> <i32 undef, i32 0, i32 0>
  %71 = fmul fast <3 x float> %70, %58
  %72 = fsub fast <3 x float> %71, %66
  %73 = extractelement <3 x float> %72, i64 1
  %74 = fmul fast float %73, 5.000000e-01
  %75 = fadd fast float %74, 5.000000e-01
  %76 = insertelement <2 x float> undef, float %75, i64 0
  %77 = extractelement <3 x float> %72, i64 2
  %78 = fmul fast float %77, 5.000000e-01
  %79 = fsub fast float 5.000000e-01, %78
  %80 = insertelement <2 x float> %76, float %79, i64 1
  br label %81

81:                                               ; preds = %57, %17
  %82 = phi <2 x float> [ %80, %57 ], [ %1, %17 ]
  %83 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 5
  %84 = load i32, i32 addrspace(2)* %83, align 8, !tbaa !244, !alias.scope !235, !noalias !238
  %85 = icmp sgt i32 %84, 0
  br i1 %85, label %86, label %97

86:                                               ; preds = %81
  %87 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 7
  %88 = load <4 x float>, <4 x float> addrspace(2)* %87, align 16, !alias.scope !235, !noalias !238
  %89 = extractelement <4 x float> %88, i64 0
  %90 = fadd fast float %89, 5.000000e-01
  %91 = tail call i32 @air.convert.s.i32.f.f32(float %90) #20
  %92 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 8
  %93 = load <4 x float>, <4 x float> addrspace(2)* %92, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %94 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %95 = load float, float addrspace(2)* %94, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %96 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %82, <3 x float> noundef %3, i32 noundef %91, <4 x float> noundef %93, float noundef %95) #23
  br label %97

97:                                               ; preds = %86, %81
  %98 = phi <2 x float> [ %96, %86 ], [ %82, %81 ]
  %99 = icmp sgt i32 %84, 1
  br i1 %99, label %100, label %111

100:                                              ; preds = %97
  %101 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 7
  %102 = load <4 x float>, <4 x float> addrspace(2)* %101, align 16, !alias.scope !235, !noalias !238
  %103 = extractelement <4 x float> %102, i64 1
  %104 = fadd fast float %103, 5.000000e-01
  %105 = tail call i32 @air.convert.s.i32.f.f32(float %104) #20
  %106 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 9
  %107 = load <4 x float>, <4 x float> addrspace(2)* %106, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %108 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %109 = load float, float addrspace(2)* %108, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %110 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %98, <3 x float> noundef %3, i32 noundef %105, <4 x float> noundef %107, float noundef %109) #23
  br label %111

111:                                              ; preds = %100, %97
  %112 = phi <2 x float> [ %110, %100 ], [ %98, %97 ]
  %113 = icmp sgt i32 %84, 2
  br i1 %113, label %114, label %125

114:                                              ; preds = %111
  %115 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 7
  %116 = load <4 x float>, <4 x float> addrspace(2)* %115, align 16, !alias.scope !235, !noalias !238
  %117 = extractelement <4 x float> %116, i64 2
  %118 = fadd fast float %117, 5.000000e-01
  %119 = tail call i32 @air.convert.s.i32.f.f32(float %118) #20
  %120 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 10
  %121 = load <4 x float>, <4 x float> addrspace(2)* %120, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %122 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %123 = load float, float addrspace(2)* %122, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %124 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %112, <3 x float> noundef %3, i32 noundef %119, <4 x float> noundef %121, float noundef %123) #23
  br label %125

125:                                              ; preds = %114, %111
  %126 = phi <2 x float> [ %124, %114 ], [ %112, %111 ]
  %127 = icmp sgt i32 %84, 3
  br i1 %127, label %128, label %139

128:                                              ; preds = %125
  %129 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 7
  %130 = load <4 x float>, <4 x float> addrspace(2)* %129, align 16, !alias.scope !235, !noalias !238
  %131 = extractelement <4 x float> %130, i64 3
  %132 = fadd fast float %131, 5.000000e-01
  %133 = tail call i32 @air.convert.s.i32.f.f32(float %132) #20
  %134 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 11
  %135 = load <4 x float>, <4 x float> addrspace(2)* %134, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %136 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %137 = load float, float addrspace(2)* %136, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %138 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %126, <3 x float> noundef %3, i32 noundef %133, <4 x float> noundef %135, float noundef %137) #23
  br label %139

139:                                              ; preds = %128, %125
  %140 = phi <2 x float> [ %138, %128 ], [ %126, %125 ]
  %141 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 31
  %142 = load <4 x float>, <4 x float> addrspace(2)* %141, align 16, !alias.scope !235, !noalias !238
  %143 = extractelement <4 x float> %142, i64 0
  %144 = fcmp fast ogt float %143, 5.000000e-01
  br i1 %144, label %145, label %169

145:                                              ; preds = %139
  %146 = extractelement <4 x float> %142, i64 1
  %147 = extractelement <4 x float> %142, i64 2
  %148 = fmul fast float %143, %146
  %149 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %150 = load float, float addrspace(2)* %149, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %151 = fmul fast float %150, %147
  %152 = tail call fast float @air.fast_floor.f32(float %151) #20
  %153 = tail call fast float @air.fast_fmod.f32(float %152, float %148) #20
  %154 = fcmp fast olt float %153, 0.000000e+00
  %155 = select i1 %154, float %148, float -0.000000e+00
  %156 = fadd fast float %155, %153
  %157 = tail call fast float @air.fast_fmod.f32(float %156, float %143) #20
  %158 = fdiv fast float %156, %143
  %159 = tail call fast float @air.fast_floor.f32(float %158) #20
  %160 = tail call fast <2 x float> @___metal_fract_v2float(<2 x float> %140, i32 0) #25
  %161 = extractelement <2 x float> %160, i64 0
  %162 = fadd fast float %161, %157
  %163 = fdiv fast float %162, %143
  %164 = insertelement <2 x float> undef, float %163, i64 0
  %165 = extractelement <2 x float> %160, i64 1
  %166 = fadd fast float %165, %159
  %167 = fdiv fast float %166, %146
  %168 = insertelement <2 x float> %164, float %167, i64 1
  br label %169

169:                                              ; preds = %145, %139
  %170 = phi <2 x float> [ %168, %145 ], [ %140, %139 ]
  %171 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %9, %struct._sampler_t addrspace(2)* nocapture readonly %15, <2 x float> %170, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %172 = extractvalue { <4 x float>, i8 } %171, 0
  %173 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 24
  %174 = load i32, i32 addrspace(2)* %173, align 4, !tbaa !247, !alias.scope !235, !noalias !238
  %175 = icmp eq i32 %174, 0
  br i1 %175, label %176, label %189

176:                                              ; preds = %169
  %177 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 23
  %178 = load i32, i32 addrspace(2)* %177, align 16, !tbaa !248, !alias.scope !235, !noalias !238
  %179 = icmp eq i32 %178, 0
  br i1 %179, label %180, label %189

180:                                              ; preds = %176
  %181 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 6
  %182 = load float, float addrspace(2)* %181, align 4, !tbaa !249, !alias.scope !235, !noalias !238
  %183 = fcmp fast une float %182, 0.000000e+00
  br i1 %183, label %189, label %184

184:                                              ; preds = %180
  %185 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 13
  %186 = load i32, i32 addrspace(2)* %185, align 4, !tbaa !250, !alias.scope !235, !noalias !238
  %187 = add i32 %186, -5
  %188 = icmp ult i32 %187, 2
  br i1 %188, label %189, label %237

189:                                              ; preds = %184, %169, %176, %180
  %190 = icmp ne i32 %174, 0
  %191 = extractelement <4 x float> %172, i64 3
  %192 = fcmp fast oge float %191, 0x3FEFD70A40000000
  %193 = select i1 %190, i1 true, i1 %192
  br i1 %193, label %194, label %237

194:                                              ; preds = %189
  %195 = extractelement <4 x float> %172, i64 0
  %196 = extractelement <4 x float> %172, i64 1
  %197 = tail call fast float @air.fast_fmax.f32(float %195, float %196) #20
  %198 = extractelement <4 x float> %172, i64 2
  %199 = tail call fast float @air.fast_fmax.f32(float %197, float %198) #20
  %200 = fadd fast <2 x float> %170, <float -5.000000e-01, float -5.000000e-01>
  %201 = tail call fast float @air.dot.v2f32(<2 x float> %200, <2 x float> %200) #20
  %202 = fmul fast float %201, 2.000000e+00
  %203 = fsub fast float 1.000000e+00, %202
  %204 = tail call fast float @air.fast_saturate.f32(float %203) #20
  %205 = fmul fast float %204, %204
  %206 = fmul fast float %204, 2.000000e+00
  %207 = fsub fast float 3.000000e+00, %206
  %208 = fmul fast float %205, %207
  %209 = icmp eq i32 %174, 2
  %210 = fsub fast float 1.000000e+00, %199
  %211 = select fast i1 %209, float %210, float %199
  br i1 %209, label %212, label %224

212:                                              ; preds = %194
  %213 = fmul fast float %211, 0x3FFA666660000000
  %214 = tail call fast float @air.fast_saturate.f32(float %213) #20
  %215 = tail call fast float @air.fast_fmax.f32(float %196, float %198) #20
  %216 = tail call fast float @air.fast_fmax.f32(float %195, float %215) #20
  %217 = tail call fast float @air.fast_fmin.f32(float %196, float %198) #20
  %218 = tail call fast float @air.fast_fmin.f32(float %195, float %217) #20
  %219 = fsub fast float %216, %218
  %220 = fcmp fast ogt float %199, 0x3FED70A3E0000000
  %221 = fcmp fast olt float %219, 0x3FC1EB8520000000
  %222 = select i1 %220, i1 %221, i1 false
  %223 = select i1 %222, float 0.000000e+00, float %214
  br label %228

224:                                              ; preds = %194
  %225 = fmul fast float %211, %211
  %226 = fmul fast float %225, 0x3FF59999A0000000
  %227 = tail call fast float @air.fast_saturate.f32(float %226) #20
  br label %228

228:                                              ; preds = %224, %212
  %229 = phi float [ %223, %212 ], [ %227, %224 ]
  %230 = fmul fast float %208, %229
  %231 = insertelement <3 x float> poison, float %230, i64 0
  %232 = shufflevector <3 x float> %231, <3 x float> poison, <3 x i32> zeroinitializer
  %233 = shufflevector <4 x float> %172, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %234 = fmul fast <3 x float> %232, %233
  %235 = shufflevector <3 x float> %234, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %236 = insertelement <4 x float> %235, float %230, i64 3
  br label %237

237:                                              ; preds = %184, %189, %228
  %238 = phi <4 x float> [ %236, %228 ], [ %172, %189 ], [ %172, %184 ]
  %239 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 6
  %240 = load float, float addrspace(2)* %239, align 4, !tbaa !249, !alias.scope !235, !noalias !238
  %241 = fcmp fast ogt float %240, 0.000000e+00
  br i1 %241, label %242, label %246

242:                                              ; preds = %237
  %243 = extractelement <4 x float> %238, i64 3
  %244 = fcmp fast olt float %243, %240
  br i1 %244, label %245, label %256

245:                                              ; preds = %242
  tail call void @air.discard_fragment() #27
  br label %256

246:                                              ; preds = %237
  %247 = fcmp fast olt float %240, 0.000000e+00
  %248 = extractelement <4 x float> %238, i64 3
  br i1 %247, label %249, label %253

249:                                              ; preds = %246
  %250 = fneg fast float %240
  %251 = fcmp fast ult float %248, %250
  br i1 %251, label %256, label %252

252:                                              ; preds = %249
  tail call void @air.discard_fragment() #27
  br label %256

253:                                              ; preds = %246
  %254 = fcmp fast ugt float %248, 0x3F999999A0000000
  br i1 %254, label %256, label %255

255:                                              ; preds = %253
  tail call void @air.discard_fragment() #27
  br label %256

256:                                              ; preds = %252, %249, %255, %253, %242, %245
  %257 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 12
  %258 = load i32, i32 addrspace(2)* %257, align 16, !tbaa !251, !alias.scope !235, !noalias !238
  switch i32 %258, label %326 [
    i32 0, label %259
    i32 3, label %262
    i32 4, label %309
    i32 5, label %314
    i32 6, label %319
  ]

259:                                              ; preds = %256
  %260 = fmul fast <4 x float> %238, %2
  %261 = shufflevector <4 x float> %260, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  br label %329

262:                                              ; preds = %256
  %263 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 16
  %264 = load <4 x float>, <4 x float> addrspace(2)* %263, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %265 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 14
  %266 = load i32, i32 addrspace(2)* %265, align 8, !tbaa !252, !alias.scope !235, !noalias !238
  %267 = extractelement <4 x float> %264, i64 0
  %268 = extractelement <4 x float> %264, i64 1
  %269 = extractelement <4 x float> %264, i64 2
  %270 = extractelement <4 x float> %264, i64 3
  %271 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %272 = load float, float addrspace(2)* %271, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %273 = fmul fast float %272, %270
  %274 = fadd fast float %273, %269
  %275 = tail call fast float @air.fast_fract.f32(float %274) #20
  switch i32 %266, label %297 [
    i32 3, label %276
    i32 4, label %300
    i32 5, label %279
    i32 2, label %281
  ]

276:                                              ; preds = %262
  %277 = fcmp fast olt float %275, 5.000000e-01
  %278 = select fast i1 %277, float 1.000000e+00, float -1.000000e+00
  br label %300

279:                                              ; preds = %262
  %280 = fsub fast float 1.000000e+00, %275
  br label %300

281:                                              ; preds = %262
  %282 = fcmp fast olt float %275, 2.500000e-01
  br i1 %282, label %283, label %285

283:                                              ; preds = %281
  %284 = fmul fast float %275, 4.000000e+00
  br label %300

285:                                              ; preds = %281
  %286 = fcmp fast olt float %275, 5.000000e-01
  br i1 %286, label %287, label %290

287:                                              ; preds = %285
  %288 = fmul fast float %275, 4.000000e+00
  %289 = fsub fast float 2.000000e+00, %288
  br label %300

290:                                              ; preds = %285
  %291 = fcmp fast olt float %275, 7.500000e-01
  %292 = fmul fast float %275, 4.000000e+00
  br i1 %291, label %293, label %295

293:                                              ; preds = %290
  %294 = fsub fast float 2.000000e+00, %292
  br label %300

295:                                              ; preds = %290
  %296 = fadd fast float %292, -4.000000e+00
  br label %300

297:                                              ; preds = %262
  %298 = fmul fast float %275, 0x401921FB60000000
  %299 = tail call fast float @air.fast_sin.f32(float %298) #20
  br label %300

300:                                              ; preds = %262, %276, %279, %283, %287, %293, %295, %297
  %301 = phi float [ %278, %276 ], [ %280, %279 ], [ %299, %297 ], [ %275, %262 ], [ %284, %283 ], [ %289, %287 ], [ %294, %293 ], [ %296, %295 ]
  %302 = fmul fast float %301, %268
  %303 = fadd fast float %302, %267
  %304 = tail call fast float @air.fast_clamp.f32(float %303, float 0.000000e+00, float 1.000000e+00) #20
  %305 = shufflevector <4 x float> %238, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %306 = insertelement <3 x float> poison, float %304, i64 0
  %307 = shufflevector <3 x float> %306, <3 x float> poison, <3 x i32> zeroinitializer
  %308 = fmul fast <3 x float> %307, %305
  br label %329

309:                                              ; preds = %256
  %310 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 18
  %311 = load <4 x float>, <4 x float> addrspace(2)* %310, align 16, !alias.scope !235, !noalias !238
  %312 = fmul fast <4 x float> %311, %238
  %313 = shufflevector <4 x float> %312, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  br label %329

314:                                              ; preds = %256
  %315 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 19
  %316 = load <4 x float>, <4 x float> addrspace(2)* %315, align 16, !alias.scope !235, !noalias !238
  %317 = fmul fast <4 x float> %316, %238
  %318 = shufflevector <4 x float> %317, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  br label %329

319:                                              ; preds = %256
  %320 = shufflevector <4 x float> %238, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %321 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 19
  %322 = load <4 x float>, <4 x float> addrspace(2)* %321, align 16, !alias.scope !235, !noalias !238
  %323 = shufflevector <4 x float> %322, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %324 = fsub fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %323
  %325 = fmul fast <3 x float> %324, %320
  br label %329

326:                                              ; preds = %256
  %327 = fmul fast <4 x float> %238, %2
  %328 = shufflevector <4 x float> %327, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  br label %329

329:                                              ; preds = %300, %314, %326, %319, %309, %259
  %330 = phi <3 x float> [ %261, %259 ], [ %308, %300 ], [ %313, %309 ], [ %318, %314 ], [ %325, %319 ], [ %328, %326 ]
  %331 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 13
  %332 = load i32, i32 addrspace(2)* %331, align 4, !tbaa !250, !alias.scope !235, !noalias !238
  switch i32 %332, label %399 [
    i32 0, label %333
    i32 3, label %335
    i32 4, label %380
    i32 5, label %386
    i32 6, label %392
  ]

333:                                              ; preds = %329
  %334 = extractelement <4 x float> %238, i64 3
  br label %403

335:                                              ; preds = %329
  %336 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 17
  %337 = load <4 x float>, <4 x float> addrspace(2)* %336, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %338 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 15
  %339 = load i32, i32 addrspace(2)* %338, align 4, !tbaa !253, !alias.scope !235, !noalias !238
  %340 = extractelement <4 x float> %337, i64 0
  %341 = extractelement <4 x float> %337, i64 1
  %342 = extractelement <4 x float> %337, i64 2
  %343 = extractelement <4 x float> %337, i64 3
  %344 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 4
  %345 = load float, float addrspace(2)* %344, align 4, !tbaa !233, !alias.scope !235, !noalias !238
  %346 = fmul fast float %345, %343
  %347 = fadd fast float %346, %342
  %348 = tail call fast float @air.fast_fract.f32(float %347) #20
  switch i32 %339, label %370 [
    i32 3, label %349
    i32 4, label %373
    i32 5, label %352
    i32 2, label %354
  ]

349:                                              ; preds = %335
  %350 = fcmp fast olt float %348, 5.000000e-01
  %351 = select fast i1 %350, float 1.000000e+00, float -1.000000e+00
  br label %373

352:                                              ; preds = %335
  %353 = fsub fast float 1.000000e+00, %348
  br label %373

354:                                              ; preds = %335
  %355 = fcmp fast olt float %348, 2.500000e-01
  br i1 %355, label %356, label %358

356:                                              ; preds = %354
  %357 = fmul fast float %348, 4.000000e+00
  br label %373

358:                                              ; preds = %354
  %359 = fcmp fast olt float %348, 5.000000e-01
  br i1 %359, label %360, label %363

360:                                              ; preds = %358
  %361 = fmul fast float %348, 4.000000e+00
  %362 = fsub fast float 2.000000e+00, %361
  br label %373

363:                                              ; preds = %358
  %364 = fcmp fast olt float %348, 7.500000e-01
  %365 = fmul fast float %348, 4.000000e+00
  br i1 %364, label %366, label %368

366:                                              ; preds = %363
  %367 = fsub fast float 2.000000e+00, %365
  br label %373

368:                                              ; preds = %363
  %369 = fadd fast float %365, -4.000000e+00
  br label %373

370:                                              ; preds = %335
  %371 = fmul fast float %348, 0x401921FB60000000
  %372 = tail call fast float @air.fast_sin.f32(float %371) #20
  br label %373

373:                                              ; preds = %335, %349, %352, %356, %360, %366, %368, %370
  %374 = phi float [ %351, %349 ], [ %353, %352 ], [ %372, %370 ], [ %348, %335 ], [ %357, %356 ], [ %362, %360 ], [ %367, %366 ], [ %369, %368 ]
  %375 = fmul fast float %374, %341
  %376 = fadd fast float %375, %340
  %377 = tail call fast float @air.fast_clamp.f32(float %376, float 0.000000e+00, float 1.000000e+00) #20
  %378 = extractelement <4 x float> %238, i64 3
  %379 = fmul fast float %377, %378
  br label %403

380:                                              ; preds = %329
  %381 = extractelement <4 x float> %238, i64 3
  %382 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 18
  %383 = load <4 x float>, <4 x float> addrspace(2)* %382, align 16, !alias.scope !235, !noalias !238
  %384 = extractelement <4 x float> %383, i64 3
  %385 = fmul fast float %384, %381
  br label %403

386:                                              ; preds = %329
  %387 = extractelement <4 x float> %238, i64 3
  %388 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 19
  %389 = load <4 x float>, <4 x float> addrspace(2)* %388, align 16, !alias.scope !235, !noalias !238
  %390 = extractelement <4 x float> %389, i64 3
  %391 = fmul fast float %390, %387
  br label %403

392:                                              ; preds = %329
  %393 = extractelement <4 x float> %238, i64 3
  %394 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 19
  %395 = load <4 x float>, <4 x float> addrspace(2)* %394, align 16, !alias.scope !235, !noalias !238
  %396 = extractelement <4 x float> %395, i64 3
  %397 = fsub fast float 1.000000e+00, %396
  %398 = fmul fast float %397, %393
  br label %403

399:                                              ; preds = %329
  %400 = extractelement <4 x float> %238, i64 3
  %401 = extractelement <4 x float> %2, i64 3
  %402 = fmul fast float %400, %401
  br label %403

403:                                              ; preds = %373, %386, %399, %392, %380, %333
  %404 = phi float [ %334, %333 ], [ %379, %373 ], [ %385, %380 ], [ %391, %386 ], [ %398, %392 ], [ %402, %399 ]
  %405 = shufflevector <3 x float> %330, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %406 = insertelement <4 x float> %405, float %404, i64 3
  %407 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 23
  %408 = load i32, i32 addrspace(2)* %407, align 16, !tbaa !248, !alias.scope !235, !noalias !238
  %409 = icmp eq i32 %408, 0
  br i1 %409, label %410, label %445

410:                                              ; preds = %403
  %411 = tail call fast float @air.dot.v3f32(<3 x float> %4, <3 x float> %4) #20
  %412 = tail call fast float @air.fast_sqrt.f32(float %411) #20
  %413 = fcmp fast ugt float %412, 0x3F1A36E2E0000000
  br i1 %413, label %440, label %414

414:                                              ; preds = %410
  %415 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %3) #24
  %416 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %3) #24
  %417 = extractelement <3 x float> %415, i64 1
  %418 = extractelement <3 x float> %416, i64 2
  %419 = fmul fast float %418, %417
  %420 = extractelement <3 x float> %416, i64 1
  %421 = extractelement <3 x float> %415, i64 2
  %422 = fmul fast float %420, %421
  %423 = fsub fast float %419, %422
  %424 = insertelement <3 x float> undef, float %423, i64 0
  %425 = extractelement <3 x float> %416, i64 0
  %426 = fmul fast float %425, %421
  %427 = extractelement <3 x float> %415, i64 0
  %428 = fmul fast float %418, %427
  %429 = fsub fast float %426, %428
  %430 = insertelement <3 x float> %424, float %429, i64 1
  %431 = fmul fast float %420, %427
  %432 = fmul fast float %425, %417
  %433 = fsub fast float %431, %432
  %434 = insertelement <3 x float> %430, float %433, i64 2
  %435 = tail call fast float @air.dot.v3f32(<3 x float> %434, <3 x float> %434) #20
  %436 = tail call fast float @air.fast_rsqrt.f32(float %435) #20
  %437 = insertelement <3 x float> poison, float %436, i64 0
  %438 = shufflevector <3 x float> %437, <3 x float> poison, <3 x i32> zeroinitializer
  %439 = fmul fast <3 x float> %434, %438
  br label %440

440:                                              ; preds = %414, %410
  %441 = phi <3 x float> [ %439, %414 ], [ %4, %410 ]
  %442 = tail call fast <3 x float> @_Z12applyDlightsDv3_fS_S_RU11MTLconstantK11DLightBlock(<3 x float> noundef %330, <3 x float> noundef %3, <3 x float> noundef %441, %struct.DLightBlock addrspace(2)* noundef align 4 dereferenceable(1040) %6) #23
  %443 = shufflevector <3 x float> %442, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %444 = insertelement <4 x float> %443, float %404, i64 3
  br label %445

445:                                              ; preds = %440, %403
  %446 = phi <4 x float> [ %444, %440 ], [ %406, %403 ]
  %447 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 20
  %448 = load <4 x float>, <4 x float> addrspace(2)* %447, align 16, !alias.scope !235, !noalias !238
  %449 = extractelement <4 x float> %448, i64 3
  %450 = fcmp fast ogt float %449, 0.000000e+00
  br i1 %450, label %451, label %463

451:                                              ; preds = %445
  %452 = tail call fast float @_Z17q3EntityFogFactorDv3_fRU11MTLconstantK14EntityUniforms(<3 x float> noundef %3, %struct.EntityUniforms addrspace(2)* noundef align 16 dereferenceable(384) %5) #28
  %453 = shufflevector <4 x float> %446, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %454 = shufflevector <4 x float> %448, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %455 = tail call fast float @air.dot.v3f32(<3 x float> %454, <3 x float> %454) #20
  %456 = fcmp fast olt float %455, 0x3F50624DE0000000
  %457 = select i1 %456, <3 x float> <float 0x3FD70A3D80000000, float 0x3FD70A3D80000000, float 0x3FD70A3D80000000>, <3 x float> %454
  %458 = insertelement <3 x float> poison, float %452, i64 0
  %459 = shufflevector <3 x float> %458, <3 x float> poison, <3 x i32> zeroinitializer
  %460 = tail call fast <3 x float> @air.mix.v3f32(<3 x float> %453, <3 x float> %457, <3 x float> %459) #20
  %461 = shufflevector <3 x float> %460, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %462 = shufflevector <4 x float> %461, <4 x float> %446, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %463

463:                                              ; preds = %451, %445
  %464 = phi <4 x float> [ %462, %451 ], [ %446, %445 ]
  %465 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %10) #22, !alias.scope !254, !noalias !255
  br i1 %465, label %776, label %466

466:                                              ; preds = %463
  %467 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %10, %struct._sampler_t addrspace(2)* nocapture readonly %15, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %468 = extractvalue { <4 x float>, i8 } %467, 0
  %469 = shufflevector <4 x float> %468, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %470 = fmul fast <3 x float> %469, <float 2.000000e+00, float 2.000000e+00, float 2.000000e+00>
  %471 = fadd fast <3 x float> %470, <float -1.000000e+00, float -1.000000e+00, float -1.000000e+00>
  %472 = tail call fast float @air.dot.v3f32(<3 x float> %4, <3 x float> %4) #20
  %473 = tail call fast float @air.fast_sqrt.f32(float %472) #20
  %474 = fcmp fast olt float %473, 0x3F1A36E2E0000000
  br i1 %474, label %475, label %501

475:                                              ; preds = %466
  %476 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %3) #24
  %477 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %3) #24
  %478 = extractelement <3 x float> %476, i64 1
  %479 = extractelement <3 x float> %477, i64 2
  %480 = fmul fast float %479, %478
  %481 = extractelement <3 x float> %477, i64 1
  %482 = extractelement <3 x float> %476, i64 2
  %483 = fmul fast float %481, %482
  %484 = fsub fast float %480, %483
  %485 = insertelement <3 x float> undef, float %484, i64 0
  %486 = extractelement <3 x float> %477, i64 0
  %487 = fmul fast float %486, %482
  %488 = extractelement <3 x float> %476, i64 0
  %489 = fmul fast float %479, %488
  %490 = fsub fast float %487, %489
  %491 = insertelement <3 x float> %485, float %490, i64 1
  %492 = fmul fast float %481, %488
  %493 = fmul fast float %486, %478
  %494 = fsub fast float %492, %493
  %495 = insertelement <3 x float> %491, float %494, i64 2
  %496 = tail call fast float @air.dot.v3f32(<3 x float> %495, <3 x float> %495) #20
  %497 = tail call fast float @air.fast_rsqrt.f32(float %496) #20
  %498 = insertelement <3 x float> poison, float %497, i64 0
  %499 = shufflevector <3 x float> %498, <3 x float> poison, <3 x i32> zeroinitializer
  %500 = fmul fast <3 x float> %495, %499
  br label %506

501:                                              ; preds = %466
  %502 = tail call fast float @air.fast_rsqrt.f32(float %472) #20
  %503 = insertelement <3 x float> poison, float %502, i64 0
  %504 = shufflevector <3 x float> %503, <3 x float> poison, <3 x i32> zeroinitializer
  %505 = fmul fast <3 x float> %504, %4
  br label %506

506:                                              ; preds = %501, %475
  %507 = phi <3 x float> [ %500, %475 ], [ %505, %501 ]
  %508 = tail call fast <3 x float> @air.dfdx.v3f32(<3 x float> %3) #24
  %509 = tail call fast <3 x float> @air.dfdy.v3f32(<3 x float> %3) #24
  %510 = tail call fast <2 x float> @air.dfdx.v2f32(<2 x float> %1) #24
  %511 = tail call fast <2 x float> @air.dfdy.v2f32(<2 x float> %1) #24
  %512 = extractelement <3 x float> %509, i64 1
  %513 = extractelement <3 x float> %507, i64 2
  %514 = fmul fast float %512, %513
  %515 = extractelement <3 x float> %507, i64 1
  %516 = extractelement <3 x float> %509, i64 2
  %517 = fmul fast float %516, %515
  %518 = fsub fast float %514, %517
  %519 = insertelement <3 x float> undef, float %518, i64 0
  %520 = extractelement <3 x float> %507, i64 0
  %521 = fmul fast float %516, %520
  %522 = extractelement <3 x float> %509, i64 0
  %523 = fmul fast float %522, %513
  %524 = fsub fast float %521, %523
  %525 = insertelement <3 x float> %519, float %524, i64 1
  %526 = fmul fast float %522, %515
  %527 = fmul fast float %512, %520
  %528 = fsub fast float %526, %527
  %529 = insertelement <3 x float> %525, float %528, i64 2
  %530 = extractelement <3 x float> %508, i64 2
  %531 = fmul fast float %530, %515
  %532 = extractelement <3 x float> %508, i64 1
  %533 = fmul fast float %532, %513
  %534 = fsub fast float %531, %533
  %535 = insertelement <3 x float> undef, float %534, i64 0
  %536 = extractelement <3 x float> %508, i64 0
  %537 = fmul fast float %536, %513
  %538 = fmul fast float %530, %520
  %539 = fsub fast float %537, %538
  %540 = insertelement <3 x float> %535, float %539, i64 1
  %541 = fmul fast float %532, %520
  %542 = fmul fast float %536, %515
  %543 = fsub fast float %541, %542
  %544 = insertelement <3 x float> %540, float %543, i64 2
  %545 = shufflevector <2 x float> %510, <2 x float> undef, <3 x i32> zeroinitializer
  %546 = fmul fast <3 x float> %529, %545
  %547 = shufflevector <2 x float> %511, <2 x float> undef, <3 x i32> zeroinitializer
  %548 = fmul fast <3 x float> %544, %547
  %549 = fadd fast <3 x float> %546, %548
  %550 = shufflevector <2 x float> %510, <2 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %551 = fmul fast <3 x float> %529, %550
  %552 = shufflevector <2 x float> %511, <2 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %553 = fmul fast <3 x float> %544, %552
  %554 = fadd fast <3 x float> %551, %553
  %555 = tail call fast float @air.dot.v3f32(<3 x float> %549, <3 x float> %549) #20
  %556 = tail call fast float @air.dot.v3f32(<3 x float> %554, <3 x float> %554) #20
  %557 = tail call fast float @air.fast_fmax.f32(float %555, float %556) #20
  %558 = fadd fast float %557, 0x3F1A36E2E0000000
  %559 = tail call fast float @air.fast_rsqrt.f32(float %558) #20
  %560 = insertelement <3 x float> poison, float %559, i64 0
  %561 = shufflevector <3 x float> %560, <3 x float> poison, <3 x i32> zeroinitializer
  %562 = shufflevector <3 x float> %471, <3 x float> poison, <3 x i32> zeroinitializer
  %563 = fmul fast <3 x float> %549, %562
  %564 = shufflevector <3 x float> %471, <3 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %565 = fmul fast <3 x float> %554, %564
  %566 = shufflevector <3 x float> %471, <3 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %567 = fmul fast <3 x float> %507, %566
  %568 = fadd fast <3 x float> %563, %565
  %569 = fmul fast <3 x float> %568, %561
  %570 = fadd fast <3 x float> %569, %567
  %571 = tail call fast float @air.dot.v3f32(<3 x float> %570, <3 x float> %570) #20
  %572 = tail call fast float @air.fast_rsqrt.f32(float %571) #20
  %573 = insertelement <3 x float> poison, float %572, i64 0
  %574 = shufflevector <3 x float> %573, <3 x float> poison, <3 x i32> zeroinitializer
  %575 = fmul fast <3 x float> %570, %574
  %576 = tail call fast float @air.dot.v3f32(<3 x float> <float 0x3FD3333340000000, float 5.000000e-01, float 0x3FE6666660000000>, <3 x float> <float 0x3FD3333340000000, float 5.000000e-01, float 0x3FE6666660000000>) #20
  %577 = tail call fast float @air.fast_rsqrt.f32(float %576) #20
  %578 = insertelement <3 x float> poison, float %577, i64 0
  %579 = shufflevector <3 x float> %578, <3 x float> poison, <3 x i32> zeroinitializer
  %580 = fmul fast <3 x float> %579, <float 0x3FD3333340000000, float 5.000000e-01, float 0x3FE6666660000000>
  %581 = tail call fast float @air.dot.v3f32(<3 x float> %575, <3 x float> %580) #20
  %582 = fmul fast float %581, 5.000000e-01
  %583 = fadd fast float %582, 5.000000e-01
  %584 = fmul fast float %583, %583
  %585 = load float, float addrspace(2)* %7, align 4, !tbaa !146, !alias.scope !256, !noalias !257
  %586 = tail call fast float @air.mix.f32(float 0x3FE8F5C280000000, float 0x3FE3333340000000, float %585) #20
  %587 = tail call fast float @air.mix.f32(float 0x3FF2E147A0000000, float 0x3FF3333340000000, float %585) #20
  %588 = tail call fast float @air.mix.f32(float %586, float %587, float %584) #20
  %589 = insertelement <3 x float> poison, float %588, i64 0
  %590 = shufflevector <3 x float> %589, <3 x float> poison, <3 x i32> zeroinitializer
  %591 = shufflevector <4 x float> %464, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %592 = fmul fast <3 x float> %590, %591
  %593 = shufflevector <3 x float> %592, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %594 = shufflevector <4 x float> %593, <4 x float> %464, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  %595 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %11) #22, !alias.scope !254, !noalias !255
  br i1 %595, label %599, label %596

596:                                              ; preds = %506
  %597 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %12) #22, !alias.scope !254, !noalias !255
  %598 = xor i1 %597, true
  br label %599

599:                                              ; preds = %596, %506
  %600 = phi i1 [ false, %506 ], [ %598, %596 ]
  br i1 %595, label %605, label %601

601:                                              ; preds = %599
  %602 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %11, %struct._sampler_t addrspace(2)* nocapture readonly %15, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %603 = extractvalue { <4 x float>, i8 } %602, 0
  %604 = extractelement <4 x float> %603, i64 0
  br label %605

605:                                              ; preds = %601, %599
  %606 = phi float [ 0x3FE19999A0000000, %599 ], [ %604, %601 ]
  %607 = tail call i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly %12) #22, !alias.scope !254, !noalias !255
  br i1 %607, label %612, label %608

608:                                              ; preds = %605
  %609 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %12, %struct._sampler_t addrspace(2)* nocapture readonly %15, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %610 = extractvalue { <4 x float>, i8 } %609, 0
  %611 = extractelement <4 x float> %610, i64 0
  br label %612

612:                                              ; preds = %608, %605
  %613 = phi float [ 5.000000e-01, %605 ], [ %611, %608 ]
  %614 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 1
  %615 = load <3 x float>, <3 x float> addrspace(2)* %614, align 16, !tbaa !123, !alias.scope !235, !noalias !238
  %616 = fsub fast <3 x float> %615, %3
  %617 = tail call fast float @air.dot.v3f32(<3 x float> %616, <3 x float> %616) #20
  %618 = tail call fast float @air.fast_rsqrt.f32(float %617) #20
  %619 = insertelement <3 x float> poison, float %618, i64 0
  %620 = shufflevector <3 x float> %619, <3 x float> poison, <3 x i32> zeroinitializer
  %621 = fmul fast <3 x float> %620, %616
  %622 = tail call fast float @air.dot.v3f32(<3 x float> %575, <3 x float> %621) #20
  %623 = tail call fast float @air.fast_fmax.f32(float %622, float 0.000000e+00) #20
  br i1 %600, label %628, label %624

624:                                              ; preds = %612
  %625 = fsub fast float 1.000000e+00, %623
  %626 = insertelement <3 x float> poison, float %613, i64 0
  %627 = shufflevector <3 x float> %626, <3 x float> poison, <3 x i32> zeroinitializer
  br label %752

628:                                              ; preds = %612
  %629 = fadd fast <3 x float> %621, %580
  %630 = tail call fast float @air.dot.v3f32(<3 x float> %629, <3 x float> %629) #20
  %631 = tail call fast float @air.fast_rsqrt.f32(float %630) #20
  %632 = insertelement <3 x float> poison, float %631, i64 0
  %633 = shufflevector <3 x float> %632, <3 x float> poison, <3 x i32> zeroinitializer
  %634 = fmul fast <3 x float> %633, %629
  %635 = tail call fast float @air.fast_fmax.f32(float %581, float 0.000000e+00) #20
  %636 = tail call fast float @air.dot.v3f32(<3 x float> %575, <3 x float> %634) #20
  %637 = tail call fast float @air.fast_fmax.f32(float %636, float 0.000000e+00) #20
  %638 = tail call fast float @air.dot.v3f32(<3 x float> %621, <3 x float> %634) #20
  %639 = tail call fast float @air.fast_fmax.f32(float %638, float 0.000000e+00) #20
  %640 = tail call fast float @air.dot.v3f32(<3 x float> %580, <3 x float> %634) #20
  %641 = tail call fast float @air.fast_fmax.f32(float %640, float 0.000000e+00) #20
  %642 = fmul fast float %606, %606
  %643 = tail call fast float @air.fast_fmax.f32(float %642, float 6.250000e-02) #20
  %644 = fmul fast float %643, %643
  %645 = fmul fast float %644, %637
  %646 = fsub fast float %645, %637
  %647 = fmul fast float %646, %637
  %648 = fadd fast float %647, 1.000000e+00
  %649 = fmul fast float %648, %648
  %650 = fmul fast float %649, 0x400921FB60000000
  %651 = fadd fast float %650, 0x3EB0C6F7A0000000
  %652 = fdiv fast float %644, %651
  %653 = tail call fast float @air.fast_fmax.f32(float %623, float 0x3F50624DE0000000) #20
  %654 = fsub fast float 1.000000e+00, %643
  %655 = fmul fast float %653, %654
  %656 = fadd fast float %655, %643
  %657 = fmul fast float %656, %635
  %658 = fmul fast float %654, %635
  %659 = fadd fast float %658, %643
  %660 = fmul fast float %659, %623
  %661 = fadd fast float %657, %660
  %662 = tail call fast float @air.fast_fmax.f32(float %661, float 0x3EB0C6F7A0000000) #20
  %663 = fdiv fast float 5.000000e-01, %662
  %664 = insertelement <3 x float> poison, float %613, i64 0
  %665 = shufflevector <3 x float> %664, <3 x float> poison, <3 x i32> zeroinitializer
  %666 = tail call fast <3 x float> @air.mix.v3f32(<3 x float> <float 0x3FA47AE140000000, float 0x3FA47AE140000000, float 0x3FA47AE140000000>, <3 x float> %592, <3 x float> %665) #20
  %667 = fsub fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %666
  %668 = fsub fast float 1.000000e+00, %639
  %669 = tail call fast float @air.fast_pow.f32(float %668, float 5.000000e+00) #20
  %670 = insertelement <3 x float> poison, float %669, i64 0
  %671 = shufflevector <3 x float> %670, <3 x float> poison, <3 x i32> zeroinitializer
  %672 = fmul fast <3 x float> %671, %667
  %673 = fadd fast <3 x float> %672, %666
  %674 = insertelement <3 x float> poison, float %652, i64 0
  %675 = shufflevector <3 x float> %674, <3 x float> poison, <3 x i32> zeroinitializer
  %676 = insertelement <3 x float> poison, float %663, i64 0
  %677 = shufflevector <3 x float> %676, <3 x float> poison, <3 x i32> zeroinitializer
  %678 = fmul fast <3 x float> %673, %677
  %679 = fmul fast <3 x float> %678, %675
  %680 = fmul fast float %606, 2.000000e+00
  %681 = fmul fast float %641, %641
  %682 = fmul fast float %681, %680
  %683 = fadd fast float %682, -5.000000e-01
  %684 = fsub fast float 1.000000e+00, %635
  %685 = tail call fast float @air.fast_pow.f32(float %684, float 5.000000e+00) #20
  %686 = fmul fast float %685, %683
  %687 = fadd fast float %686, 1.000000e+00
  %688 = fsub fast float 1.000000e+00, %623
  %689 = tail call fast float @air.fast_pow.f32(float %688, float 5.000000e+00) #20
  %690 = fmul fast float %689, %683
  %691 = fadd fast float %690, 1.000000e+00
  %692 = insertelement <3 x float> poison, float %687, i64 0
  %693 = shufflevector <3 x float> %692, <3 x float> poison, <3 x i32> zeroinitializer
  %694 = insertelement <3 x float> poison, float %691, i64 0
  %695 = shufflevector <3 x float> %694, <3 x float> poison, <3 x i32> zeroinitializer
  %696 = fsub fast <3 x float> <float 1.000000e+00, float 1.000000e+00, float 1.000000e+00>, %673
  %697 = fsub fast float 1.000000e+00, %613
  %698 = insertelement <3 x float> poison, float %697, i64 0
  %699 = shufflevector <3 x float> %698, <3 x float> poison, <3 x i32> zeroinitializer
  %700 = fmul fast <3 x float> %699, %592
  %701 = fmul fast <3 x float> %700, <float 0x3FD45F3060000000, float 0x3FD45F3060000000, float 0x3FD45F3060000000>
  %702 = fmul fast <3 x float> %701, %696
  %703 = fmul fast <3 x float> %702, %693
  %704 = fmul fast <3 x float> %703, %695
  %705 = fadd fast <3 x float> %679, %704
  %706 = insertelement <3 x float> poison, float %635, i64 0
  %707 = shufflevector <3 x float> %706, <3 x float> poison, <3 x i32> zeroinitializer
  %708 = fmul fast <3 x float> %707, <float 0x4003333340000000, float 0x40019999A0000000, float 0x3FFE666660000000>
  %709 = fmul fast <3 x float> %708, %705
  %710 = tail call i1 @air.is_null_texture_cube(%struct._texture_cube_t addrspace(1)* nocapture readonly %13) #22, !alias.scope !254, !noalias !255
  %711 = xor i1 %710, true
  %712 = icmp ne i32 %21, 1
  %713 = select i1 %711, i1 %712, i1 false
  br i1 %713, label %714, label %745

714:                                              ; preds = %628
  %715 = tail call i32 @air.get_num_mip_levels_texture_cube(%struct._texture_cube_t addrspace(1)* nocapture readonly %13) #22, !alias.scope !254, !noalias !255
  %716 = add i32 %715, -1
  %717 = tail call fast float @air.convert.f.f32.u.i32(i32 %716) #20
  %718 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(%struct._texture_cube_t addrspace(1)* nocapture readonly %13, %struct._sampler_t addrspace(2)* nocapture readonly %16, <3 x float> %575, i1 true, float %717, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %719 = extractvalue { <4 x float>, i8 } %718, 0
  %720 = shufflevector <4 x float> %719, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %721 = fneg fast <3 x float> %621
  %722 = tail call fast float @air.dot.v3f32(<3 x float> %575, <3 x float> %721) #20
  %723 = fmul fast float %722, 2.000000e+00
  %724 = insertelement <3 x float> poison, float %723, i64 0
  %725 = shufflevector <3 x float> %724, <3 x float> poison, <3 x i32> zeroinitializer
  %726 = fmul fast <3 x float> %725, %575
  %727 = fsub fast <3 x float> %721, %726
  %728 = fmul fast float %717, %606
  %729 = tail call { <4 x float>, i8 } @air.sample_texture_cube.v4f32(%struct._texture_cube_t addrspace(1)* nocapture readonly %13, %struct._sampler_t addrspace(2)* nocapture readonly %16, <3 x float> %727, i1 true, float %728, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %730 = extractvalue { <4 x float>, i8 } %729, 0
  %731 = shufflevector <4 x float> %730, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %732 = fsub fast float 1.000000e+00, %606
  %733 = insertelement <3 x float> poison, float %732, i64 0
  %734 = shufflevector <3 x float> %733, <3 x float> poison, <3 x i32> zeroinitializer
  %735 = tail call fast <3 x float> @air.fast_fmax.v3f32(<3 x float> %734, <3 x float> %666) #20
  %736 = fsub fast <3 x float> %735, %666
  %737 = insertelement <3 x float> poison, float %689, i64 0
  %738 = shufflevector <3 x float> %737, <3 x float> poison, <3 x i32> zeroinitializer
  %739 = fmul fast <3 x float> %736, %738
  %740 = fadd fast <3 x float> %739, %666
  %741 = fmul fast <3 x float> %700, %720
  %742 = fsub fast <3 x float> %731, %741
  %743 = fmul fast <3 x float> %740, %742
  %744 = fadd fast <3 x float> %741, %743
  br label %747

745:                                              ; preds = %628
  %746 = fmul fast <3 x float> %592, <float 0x3FD6666660000000, float 0x3FD6666660000000, float 0x3FD6666660000000>
  br label %747

747:                                              ; preds = %745, %714
  %748 = phi <3 x float> [ %744, %714 ], [ %746, %745 ]
  %749 = fadd fast <3 x float> %748, %709
  %750 = shufflevector <3 x float> %749, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %751 = shufflevector <4 x float> %750, <4 x float> %594, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %752

752:                                              ; preds = %624, %747
  %753 = phi <3 x float> [ %627, %624 ], [ %665, %747 ]
  %754 = phi float [ %625, %624 ], [ %688, %747 ]
  %755 = phi float [ 1.000000e+00, %624 ], [ 0x3FD6666660000000, %747 ]
  %756 = phi <4 x float> [ %594, %624 ], [ %751, %747 ]
  %757 = load <2 x float>, <2 x float> addrspace(2)* %8, align 8, !alias.scope !258, !noalias !259
  %758 = extractelement <2 x float> %757, i64 1
  %759 = tail call fast float @air.fast_pow.f32(float %754, float %758) #20
  %760 = shufflevector <4 x float> %756, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %761 = fmul fast <3 x float> %760, <float 1.250000e+00, float 1.250000e+00, float 1.250000e+00>
  %762 = fadd fast <3 x float> %761, <float 0x3FC3333340000000, float 0x3FC3333340000000, float 0x3FC3333340000000>
  %763 = tail call fast <3 x float> @air.mix.v3f32(<3 x float> <float 7.500000e-01, float 7.500000e-01, float 0x3FE8F5C280000000>, <3 x float> %762, <3 x float> %753) #20
  %764 = extractelement <2 x float> %757, i64 0
  %765 = fsub fast float 1.000000e+00, %606
  %766 = tail call fast float @air.mix.f32(float 0x3FD6666660000000, float 1.000000e+00, float %765) #20
  %767 = fmul fast float %764, %755
  %768 = fmul fast float %767, %759
  %769 = fmul fast float %768, %766
  %770 = tail call fast float @air.fast_saturate.f32(float %769) #20
  %771 = insertelement <3 x float> poison, float %770, i64 0
  %772 = shufflevector <3 x float> %771, <3 x float> poison, <3 x i32> zeroinitializer
  %773 = tail call fast <3 x float> @air.mix.v3f32(<3 x float> %760, <3 x float> %763, <3 x float> %772) #20
  %774 = shufflevector <3 x float> %773, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %775 = shufflevector <4 x float> %774, <4 x float> %756, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %776

776:                                              ; preds = %752, %463
  %777 = phi <4 x float> [ %464, %463 ], [ %775, %752 ]
  %778 = getelementptr inbounds %struct.EntityUniforms, %struct.EntityUniforms addrspace(2)* %5, i64 0, i32 32
  %779 = load <4 x float>, <4 x float> addrspace(2)* %778, align 16, !alias.scope !235, !noalias !238
  %780 = extractelement <4 x float> %779, i64 3
  %781 = fcmp fast ogt float %780, 0.000000e+00
  br i1 %781, label %782, label %793

782:                                              ; preds = %776
  %783 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %14, %struct._sampler_t addrspace(2)* nocapture readonly %15, <2 x float> %1, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !245, !noalias !246
  %784 = extractvalue { <4 x float>, i8 } %783, 0
  %785 = fmul fast <4 x float> %784, %779
  %786 = shufflevector <4 x float> %785, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %787 = shufflevector <4 x float> %779, <4 x float> undef, <3 x i32> <i32 3, i32 3, i32 3>
  %788 = fmul fast <3 x float> %786, %787
  %789 = shufflevector <4 x float> %777, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %790 = fadd fast <3 x float> %788, %789
  %791 = shufflevector <3 x float> %790, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %792 = shufflevector <4 x float> %791, <4 x float> %777, <4 x i32> <i32 0, i32 1, i32 2, i32 7>
  br label %793

793:                                              ; preds = %782, %776
  %794 = phi <4 x float> [ %792, %782 ], [ %777, %776 ]
  ret <4 x float> %794
}

; Function Attrs: argmemonly mustprogress nofree norecurse nosync nounwind readonly willreturn
define <{ <4 x float>, <3 x float>, <2 x float> }> @q3_sky_vertex(%struct.WorldVertexIn addrspace(1)* nocapture noundef readonly "air-buffer-no-alias" %0, %struct.WorldUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(112) "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %4, i32 0
  %6 = load <3 x float>, <3 x float> addrspace(1)* %5, align 16, !tbaa.struct !156, !alias.scope !260, !noalias !263
  %7 = getelementptr inbounds %struct.WorldVertexIn, %struct.WorldVertexIn addrspace(1)* %0, i64 %4, i32 1
  %8 = load <2 x float>, <2 x float> addrspace(1)* %7, align 16, !tbaa.struct !163, !alias.scope !260, !noalias !263
  %9 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 0
  %10 = load <4 x float>, <4 x float> addrspace(2)* %9, align 16, !tbaa !123, !alias.scope !263, !noalias !260
  %11 = shufflevector <3 x float> %6, <3 x float> undef, <4 x i32> <i32 0, i32 0, i32 undef, i32 0>
  %12 = fmul fast <4 x float> %10, %11
  %13 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 1
  %14 = load <4 x float>, <4 x float> addrspace(2)* %13, align 16, !tbaa !123, !alias.scope !263, !noalias !260
  %15 = shufflevector <3 x float> %6, <3 x float> undef, <4 x i32> <i32 1, i32 1, i32 undef, i32 1>
  %16 = fmul fast <4 x float> %14, %15
  %17 = fadd fast <4 x float> %16, %12
  %18 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 2
  %19 = load <4 x float>, <4 x float> addrspace(2)* %18, align 16, !tbaa !123, !alias.scope !263, !noalias !260
  %20 = shufflevector <3 x float> %6, <3 x float> undef, <4 x i32> <i32 2, i32 2, i32 undef, i32 2>
  %21 = fmul fast <4 x float> %19, %20
  %22 = fadd fast <4 x float> %17, %21
  %23 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %1, i64 0, i32 0, i32 0, i64 3
  %24 = load <4 x float>, <4 x float> addrspace(2)* %23, align 16, !tbaa !123, !alias.scope !263, !noalias !260
  %25 = fadd fast <4 x float> %22, %24
  %26 = shufflevector <4 x float> %25, <4 x float> poison, <4 x i32> <i32 0, i32 1, i32 3, i32 3>
  %27 = insertvalue <{ <4 x float>, <3 x float>, <2 x float> }> undef, <4 x float> %26, 0
  %28 = insertvalue <{ <4 x float>, <3 x float>, <2 x float> }> %27, <3 x float> %6, 1
  %29 = insertvalue <{ <4 x float>, <3 x float>, <2 x float> }> %28, <2 x float> %8, 2
  ret <{ <4 x float>, <3 x float>, <2 x float> }> %29
}

; Function Attrs: convergent mustprogress nofree nounwind readonly willreturn
define <4 x float> @q3_sky_fragment(<4 x float> %0, <3 x float> %1, <2 x float> %2, %struct.WorldUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(112) "air-buffer-no-alias" %3, %struct.WorldDrawUniforms addrspace(2)* nocapture noundef readonly align 16 dereferenceable(432) "air-buffer-no-alias" %4, %struct._texture_2d_t addrspace(1)* %5, %struct._sampler_t addrspace(2)* nocapture readonly %6) local_unnamed_addr #13 {
  %8 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %3, i64 0, i32 1, i64 0
  %9 = load float, float addrspace(2)* %8, align 16, !alias.scope !265, !noalias !268
  %10 = insertelement <3 x float> undef, float %9, i64 0
  %11 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %3, i64 0, i32 1, i64 1
  %12 = load float, float addrspace(2)* %11, align 4, !alias.scope !265, !noalias !268
  %13 = insertelement <3 x float> %10, float %12, i64 1
  %14 = getelementptr inbounds %struct.WorldUniforms, %struct.WorldUniforms addrspace(2)* %3, i64 0, i32 1, i64 2
  %15 = load float, float addrspace(2)* %14, align 8, !alias.scope !265, !noalias !268
  %16 = insertelement <3 x float> %13, float %15, i64 2
  %17 = fsub fast <3 x float> %1, %16
  %18 = tail call fast float @air.dot.v3f32(<3 x float> %17, <3 x float> %17) #20
  %19 = tail call fast float @air.fast_rsqrt.f32(float %18) #20
  %20 = insertelement <3 x float> poison, float %19, i64 0
  %21 = shufflevector <3 x float> %20, <3 x float> poison, <3 x i32> zeroinitializer
  %22 = fmul fast <3 x float> %21, %17
  %23 = tail call fast <3 x float> @air.fast_fabs.v3f32(<3 x float> %22) #20
  %24 = extractelement <3 x float> %22, i64 1
  %25 = fneg fast float %24
  %26 = insertelement <2 x float> undef, float %25, i64 0
  %27 = extractelement <3 x float> %22, i64 2
  %28 = insertelement <2 x float> %26, float %27, i64 1
  %29 = extractelement <3 x float> %23, i64 0
  %30 = tail call fast float @air.fast_fmax.f32(float %29, float 0x3F1A36E2E0000000) #20
  %31 = insertelement <2 x float> poison, float %30, i64 0
  %32 = shufflevector <2 x float> %31, <2 x float> poison, <2 x i32> zeroinitializer
  %33 = fmul fast <2 x float> %28, <float 5.000000e-01, float 5.000000e-01>
  %34 = fdiv fast <2 x float> %33, %32
  %35 = fadd fast <2 x float> %34, <float 5.000000e-01, float 5.000000e-01>
  %36 = shufflevector <3 x float> %22, <3 x float> undef, <2 x i32> <i32 0, i32 undef>
  %37 = insertelement <2 x float> %36, float %27, i64 1
  %38 = extractelement <3 x float> %23, i64 1
  %39 = tail call fast float @air.fast_fmax.f32(float %38, float 0x3F1A36E2E0000000) #20
  %40 = insertelement <2 x float> poison, float %39, i64 0
  %41 = shufflevector <2 x float> %40, <2 x float> poison, <2 x i32> zeroinitializer
  %42 = fmul fast <2 x float> %37, <float 5.000000e-01, float 5.000000e-01>
  %43 = fdiv fast <2 x float> %42, %41
  %44 = fadd fast <2 x float> %43, <float 5.000000e-01, float 5.000000e-01>
  %45 = insertelement <2 x float> %36, float %25, i64 1
  %46 = extractelement <3 x float> %23, i64 2
  %47 = tail call fast float @air.fast_fmax.f32(float %46, float 0x3F1A36E2E0000000) #20
  %48 = insertelement <2 x float> poison, float %47, i64 0
  %49 = shufflevector <2 x float> %48, <2 x float> poison, <2 x i32> zeroinitializer
  %50 = fmul fast <2 x float> %45, <float 5.000000e-01, float 5.000000e-01>
  %51 = fdiv fast <2 x float> %50, %49
  %52 = fadd fast <2 x float> %51, <float 5.000000e-01, float 5.000000e-01>
  %53 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 1
  %54 = load i32, i32 addrspace(2)* %53, align 4, !tbaa !205, !alias.scope !272, !noalias !273
  %55 = icmp sgt i32 %54, 0
  br i1 %55, label %56, label %69

56:                                               ; preds = %7
  %57 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 9
  %58 = load <4 x float>, <4 x float> addrspace(2)* %57, align 16, !alias.scope !272, !noalias !273
  %59 = extractelement <4 x float> %58, i64 0
  %60 = fadd fast float %59, 5.000000e-01
  %61 = tail call i32 @air.convert.s.i32.f.f32(float %60) #20
  %62 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 10
  %63 = load <4 x float>, <4 x float> addrspace(2)* %62, align 16, !tbaa !123, !alias.scope !272, !noalias !273
  %64 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 5
  %65 = load float, float addrspace(2)* %64, align 4, !tbaa !178, !alias.scope !272, !noalias !273
  %66 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %35, <3 x float> noundef %1, i32 noundef %61, <4 x float> noundef %63, float noundef %65) #23
  %67 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %44, <3 x float> noundef %1, i32 noundef %61, <4 x float> noundef %63, float noundef %65) #23
  %68 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %52, <3 x float> noundef %1, i32 noundef %61, <4 x float> noundef %63, float noundef %65) #23
  br label %69

69:                                               ; preds = %56, %7
  %70 = phi <2 x float> [ %68, %56 ], [ %52, %7 ]
  %71 = phi <2 x float> [ %67, %56 ], [ %44, %7 ]
  %72 = phi <2 x float> [ %66, %56 ], [ %35, %7 ]
  %73 = icmp sgt i32 %54, 1
  br i1 %73, label %74, label %87

74:                                               ; preds = %69
  %75 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 9
  %76 = load <4 x float>, <4 x float> addrspace(2)* %75, align 16, !alias.scope !272, !noalias !273
  %77 = extractelement <4 x float> %76, i64 1
  %78 = fadd fast float %77, 5.000000e-01
  %79 = tail call i32 @air.convert.s.i32.f.f32(float %78) #20
  %80 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 11
  %81 = load <4 x float>, <4 x float> addrspace(2)* %80, align 16, !tbaa !123, !alias.scope !272, !noalias !273
  %82 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 5
  %83 = load float, float addrspace(2)* %82, align 4, !tbaa !178, !alias.scope !272, !noalias !273
  %84 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %72, <3 x float> noundef %1, i32 noundef %79, <4 x float> noundef %81, float noundef %83) #23
  %85 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %71, <3 x float> noundef %1, i32 noundef %79, <4 x float> noundef %81, float noundef %83) #23
  %86 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %70, <3 x float> noundef %1, i32 noundef %79, <4 x float> noundef %81, float noundef %83) #23
  br label %87

87:                                               ; preds = %74, %69
  %88 = phi <2 x float> [ %86, %74 ], [ %70, %69 ]
  %89 = phi <2 x float> [ %85, %74 ], [ %71, %69 ]
  %90 = phi <2 x float> [ %84, %74 ], [ %72, %69 ]
  %91 = icmp sgt i32 %54, 2
  br i1 %91, label %92, label %105

92:                                               ; preds = %87
  %93 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 9
  %94 = load <4 x float>, <4 x float> addrspace(2)* %93, align 16, !alias.scope !272, !noalias !273
  %95 = extractelement <4 x float> %94, i64 2
  %96 = fadd fast float %95, 5.000000e-01
  %97 = tail call i32 @air.convert.s.i32.f.f32(float %96) #20
  %98 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 12
  %99 = load <4 x float>, <4 x float> addrspace(2)* %98, align 16, !tbaa !123, !alias.scope !272, !noalias !273
  %100 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 5
  %101 = load float, float addrspace(2)* %100, align 4, !tbaa !178, !alias.scope !272, !noalias !273
  %102 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %90, <3 x float> noundef %1, i32 noundef %97, <4 x float> noundef %99, float noundef %101) #23
  %103 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %89, <3 x float> noundef %1, i32 noundef %97, <4 x float> noundef %99, float noundef %101) #23
  %104 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %88, <3 x float> noundef %1, i32 noundef %97, <4 x float> noundef %99, float noundef %101) #23
  br label %105

105:                                              ; preds = %92, %87
  %106 = phi <2 x float> [ %104, %92 ], [ %88, %87 ]
  %107 = phi <2 x float> [ %103, %92 ], [ %89, %87 ]
  %108 = phi <2 x float> [ %102, %92 ], [ %90, %87 ]
  %109 = icmp sgt i32 %54, 3
  br i1 %109, label %110, label %123

110:                                              ; preds = %105
  %111 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 9
  %112 = load <4 x float>, <4 x float> addrspace(2)* %111, align 16, !alias.scope !272, !noalias !273
  %113 = extractelement <4 x float> %112, i64 3
  %114 = fadd fast float %113, 5.000000e-01
  %115 = tail call i32 @air.convert.s.i32.f.f32(float %114) #20
  %116 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 13
  %117 = load <4 x float>, <4 x float> addrspace(2)* %116, align 16, !tbaa !123, !alias.scope !272, !noalias !273
  %118 = getelementptr inbounds %struct.WorldDrawUniforms, %struct.WorldDrawUniforms addrspace(2)* %4, i64 0, i32 5
  %119 = load float, float addrspace(2)* %118, align 4, !tbaa !178, !alias.scope !272, !noalias !273
  %120 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %108, <3 x float> noundef %1, i32 noundef %115, <4 x float> noundef %117, float noundef %119) #23
  %121 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %107, <3 x float> noundef %1, i32 noundef %115, <4 x float> noundef %117, float noundef %119) #23
  %122 = tail call fast <2 x float> @_Z10applyTcModDv2_fDv3_fiDv4_ff(<2 x float> noundef %106, <3 x float> noundef %1, i32 noundef %115, <4 x float> noundef %117, float noundef %119) #23
  br label %123

123:                                              ; preds = %110, %105
  %124 = phi <2 x float> [ %122, %110 ], [ %106, %105 ]
  %125 = phi <2 x float> [ %121, %110 ], [ %107, %105 ]
  %126 = phi <2 x float> [ %120, %110 ], [ %108, %105 ]
  %127 = tail call fast <3 x float> @air.fast_pow.v3f32(<3 x float> %23, <3 x float> <float 4.000000e+00, float 4.000000e+00, float 4.000000e+00>) #20
  %128 = extractelement <3 x float> %127, i64 0
  %129 = extractelement <3 x float> %127, i64 1
  %130 = fadd fast float %128, %129
  %131 = extractelement <3 x float> %127, i64 2
  %132 = fadd fast float %130, %131
  %133 = tail call fast float @air.fast_fmax.f32(float %132, float 0x3F1A36E2E0000000) #20
  %134 = insertelement <3 x float> poison, float %133, i64 0
  %135 = shufflevector <3 x float> %134, <3 x float> poison, <3 x i32> zeroinitializer
  %136 = fdiv fast <3 x float> %127, %135
  %137 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %5, %struct._sampler_t addrspace(2)* nocapture readonly %6, <2 x float> %126, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !274, !noalias !275
  %138 = extractvalue { <4 x float>, i8 } %137, 0
  %139 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %5, %struct._sampler_t addrspace(2)* nocapture readonly %6, <2 x float> %125, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !274, !noalias !275
  %140 = extractvalue { <4 x float>, i8 } %139, 0
  %141 = tail call { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly %5, %struct._sampler_t addrspace(2)* nocapture readonly %6, <2 x float> %124, i1 true, <2 x i32> zeroinitializer, i1 false, float 0.000000e+00, float 0.000000e+00, i32 0) #19, !alias.scope !274, !noalias !275
  %142 = extractvalue { <4 x float>, i8 } %141, 0
  %143 = shufflevector <4 x float> %138, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %144 = shufflevector <3 x float> %136, <3 x float> poison, <3 x i32> zeroinitializer
  %145 = fmul fast <3 x float> %144, %143
  %146 = shufflevector <4 x float> %140, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %147 = shufflevector <3 x float> %136, <3 x float> undef, <3 x i32> <i32 1, i32 1, i32 1>
  %148 = fmul fast <3 x float> %146, %147
  %149 = fadd fast <3 x float> %145, %148
  %150 = shufflevector <4 x float> %142, <4 x float> poison, <3 x i32> <i32 0, i32 1, i32 2>
  %151 = shufflevector <3 x float> %136, <3 x float> undef, <3 x i32> <i32 2, i32 2, i32 2>
  %152 = fmul fast <3 x float> %150, %151
  %153 = fadd fast <3 x float> %149, %152
  %154 = shufflevector <3 x float> %153, <3 x float> poison, <4 x i32> <i32 0, i32 1, i32 2, i32 undef>
  %155 = insertelement <4 x float> %154, float 1.000000e+00, i64 3
  ret <4 x float> %155
}

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.dot.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <2 x float> @air.fast_fmax.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_fmax.f32(float, float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <3 x float> @air.fast_fabs.v3f32(<3 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <3 x float> @air.fast_fmin.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <3 x float> @air.fast_fmax.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_fmin.f32(float, float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_saturate.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_exp.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare i32 @air.min.u.i32(i32, i32) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_sqrt.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_fract.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_sin.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <2 x float> @air.fast_floor.v2f32(<2 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_fmod.f32(float, float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_cos.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_fabs.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_clamp.f32(float, float, float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_floor.f32(float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.mix.f32(float, float, float) local_unnamed_addr #6

; Function Attrs: convergent mustprogress nounwind willreturn
declare <3 x float> @air.dfdx.v3f32(<3 x float>) local_unnamed_addr #14

; Function Attrs: convergent mustprogress nounwind willreturn
declare <3 x float> @air.dfdy.v3f32(<3 x float>) local_unnamed_addr #14

; Function Attrs: convergent
declare <2 x float> @___metal_fract_v2float(<2 x float>, i32) local_unnamed_addr #15

; Function Attrs: mustprogress nounwind willreturn
declare void @air.discard_fragment() local_unnamed_addr #16

; Function Attrs: convergent mustprogress nounwind willreturn
declare <2 x float> @air.dfdx.v2f32(<2 x float>) local_unnamed_addr #14

; Function Attrs: convergent mustprogress nounwind willreturn
declare <2 x float> @air.dfdy.v2f32(<2 x float>) local_unnamed_addr #14

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <3 x float> @air.mix.v3f32(<3 x float>, <3 x float>, <3 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.fast_pow.f32(float, float) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare float @air.dot.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #6

; Function Attrs: mustprogress nofree nosync nounwind readnone willreturn
declare <3 x float> @air.fast_pow.v3f32(<3 x float>, <3 x float>) local_unnamed_addr #6

; Function Attrs: argmemonly convergent mustprogress nofree nounwind readonly willreturn
declare { <4 x float>, i8 } @air.sample_texture_2d.v4f32(%struct._texture_2d_t addrspace(1)* nocapture readonly, %struct._sampler_t addrspace(2)* nocapture readonly, <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #17

; Function Attrs: argmemonly mustprogress nofree nounwind readonly willreturn
declare i32 @air.get_width_depth_2d(%struct._depth_2d_t addrspace(1)* nocapture readonly, i32) local_unnamed_addr #18

; Function Attrs: argmemonly mustprogress nofree nounwind readonly willreturn
declare i32 @air.get_height_depth_2d(%struct._depth_2d_t addrspace(1)* nocapture readonly, i32) local_unnamed_addr #18

; Function Attrs: argmemonly convergent mustprogress nofree nounwind readonly willreturn
declare { float, i8 } @air.sample_depth_2d.f32(%struct._depth_2d_t addrspace(1)* nocapture readonly, %struct._sampler_t addrspace(2)* nocapture readonly, i32, <2 x float>, i1, <2 x i32>, i1, float, float, i32) local_unnamed_addr #17

; Function Attrs: argmemonly mustprogress nofree nounwind readonly willreturn
declare i1 @air.is_null_texture_2d(%struct._texture_2d_t addrspace(1)* nocapture readonly) local_unnamed_addr #18

; Function Attrs: argmemonly mustprogress nofree nounwind readonly willreturn
declare i1 @air.is_null_texture_cube(%struct._texture_cube_t addrspace(1)* nocapture readonly) local_unnamed_addr #18

; Function Attrs: argmemonly mustprogress nofree nounwind readonly willreturn
declare i32 @air.get_num_mip_levels_texture_cube(%struct._texture_cube_t addrspace(1)* nocapture readonly) local_unnamed_addr #18

; Function Attrs: argmemonly convergent mustprogress nofree nounwind readonly willreturn
declare { <4 x float>, i8 } @air.sample_texture_cube.v4f32(%struct._texture_cube_t addrspace(1)* nocapture readonly, %struct._sampler_t addrspace(2)* nocapture readonly, <3 x float>, i1, float, float, i32) local_unnamed_addr #17

attributes #0 = { argmemonly mustprogress nofree norecurse nosync nounwind readonly willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #1 = { argmemonly mustprogress nocallback nofree nosync nounwind willreturn }
attributes #2 = { argmemonly convergent mustprogress nofree nounwind readonly willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #3 = { mustprogress nofree nosync nounwind readnone willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="96" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #4 = { mustprogress nofree nosync nounwind readnone willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #5 = { convergent mustprogress nofree nounwind readonly willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #6 = { mustprogress nofree nosync nounwind readnone willreturn }
attributes #7 = { mustprogress nofree norecurse nosync nounwind readnone willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #8 = { mustprogress nofree norecurse nosync nounwind readnone willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #9 = { mustprogress nofree nosync nounwind readnone willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #10 = { convergent mustprogress nofree nosync nounwind readnone willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="96" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #11 = { argmemonly mustprogress nofree nosync nounwind readonly willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #12 = { convergent nounwind "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #13 = { convergent mustprogress nofree nounwind readonly willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }
attributes #14 = { convergent mustprogress nounwind willreturn }
attributes #15 = { convergent }
attributes #16 = { mustprogress nounwind willreturn }
attributes #17 = { argmemonly convergent mustprogress nofree nounwind readonly willreturn }
attributes #18 = { argmemonly mustprogress nofree nounwind readonly willreturn }
attributes #19 = { argmemonly convergent nounwind readonly willreturn }
attributes #20 = { nounwind readnone willreturn }
attributes #21 = { nounwind }
attributes #22 = { argmemonly nounwind readonly willreturn }
attributes #23 = { nobuiltin "no-builtins" }
attributes #24 = { convergent nounwind willreturn }
attributes #25 = { convergent nounwind }
attributes #26 = { nobuiltin nounwind "no-builtins" }
attributes #27 = { nounwind willreturn }
attributes #28 = { convergent nobuiltin "no-builtins" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.vertex = !{!9, !20, !27, !41, !49}
!air.fragment = !{!53, !62, !68, !90, !106}
!air.compile_options = !{!114, !115, !116}
!air.sampler_states = !{!117}
!llvm.ident = !{!118}
!air.version = !{!119}
!air.language_version = !{!120}
!air.source_file_name = !{!121}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 26, i32 5]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{<{ <4 x float>, <2 x float>, <4 x float> }> (%struct.VertexIn addrspace(1)*, %struct.Uniforms addrspace(2)*, i32)* @q3_ui_vertex, !10, !14}
!10 = !{!11, !12, !13}
!11 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!12 = !{!"air.vertex_output", !"generated(8texCoordDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"texCoord"}
!13 = !{!"air.vertex_output", !"generated(5colorDv4_f)", !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!14 = !{!15, !17, !19}
!15 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.struct_type_info", !16, !"air.arg_type_size", i32 32, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"VertexIn", !"air.arg_name", !"vertices"}
!16 = !{i32 0, i32 8, i32 0, !"float2", !"position", i32 8, i32 8, i32 0, !"float2", !"texCoord", i32 16, i32 16, i32 0, !"float4", !"color"}
!17 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 64, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !18, !"air.arg_type_size", i32 64, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"Uniforms", !"air.arg_name", !"uniforms"}
!18 = !{i32 0, i32 64, i32 0, !"float4x4", !"projection"}
!19 = !{i32 2, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vertexID"}
!20 = !{<{ <4 x float>, <2 x float> }> (i32, %struct.FogVolumeUniforms addrspace(2)*)* @q3_fog_volume_vertex, !21, !23}
!21 = !{!11, !22}
!22 = !{!"air.vertex_output", !"generated(3ndcDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"ndc"}
!23 = !{!24, !25}
!24 = !{i32 0, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vertexID"}
!25 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 224, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !26, !"air.arg_type_size", i32 224, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"FogVolumeUniforms", !"air.arg_name", !"uniforms", !"air.arg_unused"}
!26 = !{i32 0, i32 64, i32 0, !"float4x4", !"viewProjection", i32 64, i32 64, i32 0, !"float4x4", !"inverseViewProjection", i32 128, i32 12, i32 0, !"packed_float3", !"cameraPos", i32 140, i32 4, i32 0, !"float", !"_pad", i32 144, i32 16, i32 0, !"float4", !"fogColorDistance", i32 160, i32 16, i32 0, !"float4", !"boundsMin", i32 176, i32 16, i32 0, !"float4", !"boundsMax", i32 192, i32 16, i32 0, !"float4", !"fogSurface", i32 208, i32 16, i32 0, !"float4", !"fogParams"}
!27 = !{<{ <4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float> }> (%struct.WorldVertexIn addrspace(1)*, %struct.WorldUniforms addrspace(2)*, %struct.WorldDrawUniforms addrspace(2)*, i32)* @q3_world_vertex, !28, !33}
!28 = !{!11, !12, !29, !13, !30, !31, !32}
!29 = !{!"air.vertex_output", !"generated(16lightmapTexCoordDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"lightmapTexCoord"}
!30 = !{!"air.vertex_output", !"generated(8worldPosDv3_f)", !"air.arg_type_name", !"float3", !"air.arg_name", !"worldPos"}
!31 = !{!"air.vertex_output", !"generated(11worldNormalDv3_f)", !"air.arg_type_name", !"float3", !"air.arg_name", !"worldNormal"}
!32 = !{!"air.vertex_output", !"generated(15lightingDiffuseDv3_f)", !"air.arg_type_name", !"float3", !"air.arg_name", !"lightingDiffuse"}
!33 = !{!34, !36, !38, !40}
!34 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.struct_type_info", !35, !"air.arg_type_size", i32 112, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldVertexIn", !"air.arg_name", !"vertices"}
!35 = !{i32 0, i32 16, i32 0, !"float3", !"position", i32 16, i32 8, i32 0, !"float2", !"texCoord", i32 24, i32 8, i32 0, !"float2", !"lightmapTexCoord", i32 32, i32 16, i32 0, !"float3", !"normal", i32 48, i32 16, i32 0, !"float4", !"color", i32 64, i32 16, i32 0, !"float4", !"autospriteCenter", i32 80, i32 16, i32 0, !"float4", !"autospriteLongAxis", i32 96, i32 16, i32 0, !"float3", !"lightingDiffuse"}
!36 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !37, !"air.arg_type_size", i32 112, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldUniforms", !"air.arg_name", !"uniforms"}
!37 = !{i32 0, i32 64, i32 0, !"float4x4", !"viewProjection", i32 64, i32 12, i32 0, !"packed_float3", !"cameraPos", i32 76, i32 4, i32 0, !"float", !"_pad", i32 80, i32 12, i32 0, !"packed_float3", !"cameraRight", i32 92, i32 4, i32 0, !"float", !"_padR", i32 96, i32 12, i32 0, !"packed_float3", !"cameraUp", i32 108, i32 4, i32 0, !"float", !"_padU"}
!38 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 432, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !39, !"air.arg_type_size", i32 432, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldDrawUniforms", !"air.arg_name", !"drawUniforms"}
!39 = !{i32 0, i32 4, i32 0, !"float", !"tcGen", i32 4, i32 4, i32 0, !"int", !"tcModCount", i32 8, i32 4, i32 0, !"float", !"rgbGen", i32 12, i32 4, i32 0, !"float", !"alphaGen", i32 16, i32 4, i32 0, !"float", !"blendMode", i32 20, i32 4, i32 0, !"float", !"timeSeconds", i32 24, i32 4, i32 0, !"uint", !"rgbWaveFunc", i32 28, i32 4, i32 0, !"uint", !"alphaWaveFunc", i32 32, i32 4, i32 0, !"uint", !"_wavePad", i32 48, i32 16, i32 0, !"float4", !"tcModType", i32 64, i32 16, i32 0, !"float4", !"tcModParams0", i32 80, i32 16, i32 0, !"float4", !"tcModParams1", i32 96, i32 16, i32 0, !"float4", !"tcModParams2", i32 112, i32 16, i32 0, !"float4", !"tcModParams3", i32 128, i32 16, i32 0, !"float4", !"rgbWaveParams", i32 144, i32 16, i32 0, !"float4", !"alphaWaveParams", i32 160, i32 16, i32 0, !"float4", !"rgbConstColor", i32 176, i32 16, i32 0, !"float4", !"entityColor", i32 192, i32 16, i32 0, !"float4", !"fogColorDistance", i32 208, i32 16, i32 0, !"float4", !"fogParams", i32 224, i32 16, i32 0, !"float4", !"fogSurface", i32 240, i32 16, i32 0, !"float4", !"spriteAtlasParams", i32 256, i32 16, i32 0, !"float4", !"emissiveParams", i32 272, i32 16, i32 0, !"float4", !"tcGenVec0", i32 288, i32 16, i32 0, !"float4", !"tcGenVec1", i32 304, i32 4, i32 0, !"uint", !"deformWaveFunc", i32 308, i32 4, i32 0, !"float", !"deformWaveDiv", i32 312, i32 4, i32 0, !"float", !"deformWaveBase", i32 316, i32 4, i32 0, !"float", !"deformWaveAmp", i32 320, i32 4, i32 0, !"float", !"deformWavePhase", i32 324, i32 4, i32 0, !"float", !"deformWaveFreq", i32 328, i32 4, i32 0, !"uint", !"deformMoveFunc", i32 336, i32 16, i32 0, !"float3", !"deformMoveVector", i32 352, i32 4, i32 0, !"float", !"deformMoveBase", i32 356, i32 4, i32 0, !"float", !"deformMoveAmp", i32 360, i32 4, i32 0, !"float", !"deformMovePhase", i32 364, i32 4, i32 0, !"float", !"deformMoveFreq", i32 368, i32 4, i32 0, !"float", !"deformBulgeWidth", i32 372, i32 4, i32 0, !"float", !"deformBulgeHeight", i32 376, i32 4, i32 0, !"float", !"deformBulgeSpeed", i32 380, i32 4, i32 0, !"uint", !"autospriteMode", i32 384, i32 4, i32 0, !"float", !"debugMode", i32 388, i32 4, i32 0, !"float", !"forceWhiteVertColor", i32 392, i32 4, i32 0, !"float", !"alphaTestThreshold", i32 396, i32 4, i32 0, !"float", !"fogOnly", i32 400, i32 4, i32 0, !"float", !"stageUsesLightmap", i32 404, i32 4, i32 0, !"float", !"drawHasLightmapStage", i32 408, i32 4, i32 0, !"float", !"pbrRoughness", i32 412, i32 4, i32 0, !"float", !"pbrMetallic", i32 416, i32 4, i32 0, !"float", !"_pad0"}
!40 = !{i32 3, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"vertexID"}
!41 = !{<{ <4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float> }> (%struct.EntityVertexIn addrspace(1)*, %struct.EntityUniforms addrspace(2)*, i32)* @q3_entity_vertex, !42, !44}
!42 = !{!11, !12, !13, !30, !43}
!43 = !{!"air.vertex_output", !"generated(6normalDv3_f)", !"air.arg_type_name", !"float3", !"air.arg_name", !"normal"}
!44 = !{!45, !47, !19}
!45 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.struct_type_info", !46, !"air.arg_type_size", i32 64, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"EntityVertexIn", !"air.arg_name", !"vertices"}
!46 = !{i32 0, i32 16, i32 0, !"float3", !"position", i32 16, i32 8, i32 0, !"float2", !"texCoord", i32 32, i32 16, i32 0, !"float4", !"color", i32 48, i32 16, i32 0, !"float3", !"normal"}
!47 = !{i32 1, !"air.buffer", !"air.buffer_size", i32 384, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !48, !"air.arg_type_size", i32 384, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"EntityUniforms", !"air.arg_name", !"uniforms"}
!48 = !{i32 0, i32 64, i32 0, !"float4x4", !"viewProjection", i32 64, i32 16, i32 0, !"float3", !"cameraPos", i32 80, i32 16, i32 0, !"float3", !"cameraForward", i32 96, i32 4, i32 0, !"float", !"tcGen", i32 100, i32 4, i32 0, !"float", !"timeSeconds", i32 104, i32 4, i32 0, !"int", !"tcModCount", i32 108, i32 4, i32 0, !"float", !"alphaTestThreshold", i32 112, i32 16, i32 0, !"float4", !"tcModType", i32 128, i32 16, i32 0, !"float4", !"tcModParams0", i32 144, i32 16, i32 0, !"float4", !"tcModParams1", i32 160, i32 16, i32 0, !"float4", !"tcModParams2", i32 176, i32 16, i32 0, !"float4", !"tcModParams3", i32 192, i32 4, i32 0, !"uint", !"rgbGenMode", i32 196, i32 4, i32 0, !"uint", !"alphaGenMode", i32 200, i32 4, i32 0, !"uint", !"rgbWaveFunc", i32 204, i32 4, i32 0, !"uint", !"alphaWaveFunc", i32 208, i32 16, i32 0, !"float4", !"rgbGenWaveParams", i32 224, i32 16, i32 0, !"float4", !"alphaGenWaveParams", i32 240, i32 16, i32 0, !"float4", !"rgbConstColor", i32 256, i32 16, i32 0, !"float4", !"entityColor", i32 272, i32 16, i32 0, !"float4", !"fogColorDistance", i32 288, i32 16, i32 0, !"float4", !"fogParams", i32 304, i32 16, i32 0, !"float4", !"fogSurface", i32 320, i32 4, i32 0, !"uint", !"suppressDlights", i32 324, i32 4, i32 0, !"uint", !"forceLuminanceAlpha", i32 328, i32 4, i32 0, !"uint", !"deformWaveFunc", i32 332, i32 4, i32 0, !"float", !"deformWaveDiv", i32 336, i32 4, i32 0, !"float", !"deformWaveBase", i32 340, i32 4, i32 0, !"float", !"deformWaveAmp", i32 344, i32 4, i32 0, !"float", !"deformWavePhase", i32 348, i32 4, i32 0, !"float", !"deformWaveFreq", i32 352, i32 16, i32 0, !"float4", !"spriteAtlasParams", i32 368, i32 16, i32 0, !"float4", !"emissiveParams"}
!49 = !{<{ <4 x float>, <3 x float>, <2 x float> }> (%struct.WorldVertexIn addrspace(1)*, %struct.WorldUniforms addrspace(2)*, i32)* @q3_sky_vertex, !50, !52}
!50 = !{!11, !30, !51}
!51 = !{!"air.vertex_output", !"generated(9scrollTexDv2_f)", !"air.arg_type_name", !"float2", !"air.arg_name", !"scrollTex"}
!52 = !{!34, !36, !19}
!53 = !{<4 x float> (<4 x float>, <2 x float>, <4 x float>, %struct._texture_2d_t addrspace(1)*, %struct._sampler_t addrspace(2)*)* @q3_ui_fragment, !54, !56}
!54 = !{!55}
!55 = !{!"air.render_target", i32 0, i32 0, !"air.arg_type_name", !"float4"}
!56 = !{!57, !58, !59, !60, !61}
!57 = !{i32 0, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"position", !"air.arg_unused"}
!58 = !{i32 1, !"air.fragment_input", !"generated(8texCoordDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"texCoord"}
!59 = !{i32 2, !"air.fragment_input", !"generated(5colorDv4_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!60 = !{i32 3, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"colorTexture"}
!61 = !{i32 4, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"textureSampler"}
!62 = !{<4 x float> (<4 x float>, <2 x float>, %struct.FogVolumeUniforms addrspace(2)*, %struct._depth_2d_t addrspace(1)*)* @q3_fog_volume_fragment, !54, !63}
!63 = !{!64, !65, !66, !67}
!64 = !{i32 0, !"air.position", !"air.center", !"air.no_perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"position"}
!65 = !{i32 1, !"air.fragment_input", !"generated(3ndcDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"ndc"}
!66 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 224, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !26, !"air.arg_type_size", i32 224, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"FogVolumeUniforms", !"air.arg_name", !"uniforms"}
!67 = !{i32 3, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"depth2d<float, sample>", !"air.arg_name", !"sceneDepth"}
!68 = !{<4 x float> (<4 x float>, <2 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, <3 x float>, %struct.WorldDrawUniforms addrspace(2)*, %struct.WorldUniforms addrspace(2)*, %struct.DLightBlock addrspace(2)*, <4 x float> addrspace(2)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_cube_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._sampler_t addrspace(2)*, %struct._sampler_t addrspace(2)*)* @q3_world_fragment, !54, !69}
!69 = !{!57, !58, !70, !71, !72, !73, !74, !75, !76, !77, !80, !81, !82, !83, !84, !85, !86, !87, !88, !89}
!70 = !{i32 2, !"air.fragment_input", !"generated(16lightmapTexCoordDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"lightmapTexCoord"}
!71 = !{i32 3, !"air.fragment_input", !"generated(5colorDv4_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float4", !"air.arg_name", !"color"}
!72 = !{i32 4, !"air.fragment_input", !"generated(8worldPosDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"worldPos"}
!73 = !{i32 5, !"air.fragment_input", !"generated(11worldNormalDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"worldNormal"}
!74 = !{i32 6, !"air.fragment_input", !"generated(15lightingDiffuseDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"lightingDiffuse"}
!75 = !{i32 7, !"air.buffer", !"air.buffer_size", i32 432, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !39, !"air.arg_type_size", i32 432, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldDrawUniforms", !"air.arg_name", !"drawUniforms"}
!76 = !{i32 8, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !37, !"air.arg_type_size", i32 112, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldUniforms", !"air.arg_name", !"uniforms"}
!77 = !{i32 9, !"air.buffer", !"air.buffer_size", i32 1040, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !78, !"air.arg_type_size", i32 1040, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"DLightBlock", !"air.arg_name", !"dlights"}
!78 = !{i32 0, i32 4, i32 0, !"uint", !"count", i32 4, i32 4, i32 0, !"uint", !"_pad0", i32 8, i32 4, i32 0, !"uint", !"_pad1", i32 12, i32 4, i32 0, !"uint", !"_pad2", !"air.struct_type_info", !79, i32 16, i32 32, i32 32, !"MSLLight", !"lights"}
!79 = !{i32 0, i32 12, i32 0, !"packed_float3", !"origin", i32 12, i32 4, i32 0, !"float", !"radius", i32 16, i32 12, i32 0, !"packed_float3", !"color", i32 28, i32 4, i32 0, !"float", !"_pad"}
!80 = !{i32 10, !"air.buffer", !"air.buffer_size", i32 16, !"air.location_index", i32 3, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 16, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"float4", !"air.arg_name", !"pbrWorldParams"}
!81 = !{i32 11, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"colorTexture"}
!82 = !{i32 12, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"lightmapTexture"}
!83 = !{i32 13, !"air.texture", !"air.location_index", i32 2, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"worldNormalMap"}
!84 = !{i32 14, !"air.texture", !"air.location_index", i32 3, i32 1, !"air.sample", !"air.arg_type_name", !"texturecube<float, sample>", !"air.arg_name", !"envCube"}
!85 = !{i32 15, !"air.texture", !"air.location_index", i32 4, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"roughnessMap"}
!86 = !{i32 16, !"air.texture", !"air.location_index", i32 5, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"metallicMap"}
!87 = !{i32 17, !"air.texture", !"air.location_index", i32 6, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"emissiveTexture"}
!88 = !{i32 18, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"textureSampler"}
!89 = !{i32 19, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"envSampler"}
!90 = !{<4 x float> (<4 x float>, <2 x float>, <4 x float>, <3 x float>, <3 x float>, %struct.EntityUniforms addrspace(2)*, %struct.DLightBlock addrspace(2)*, float addrspace(2)*, <2 x float> addrspace(2)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._texture_cube_t addrspace(1)*, %struct._texture_2d_t addrspace(1)*, %struct._sampler_t addrspace(2)*, %struct._sampler_t addrspace(2)*)* @q3_entity_fragment, !54, !91}
!91 = !{!57, !58, !59, !92, !93, !94, !95, !96, !97, !98, !99, !100, !101, !102, !103, !104, !105}
!92 = !{i32 3, !"air.fragment_input", !"generated(8worldPosDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"worldPos"}
!93 = !{i32 4, !"air.fragment_input", !"generated(6normalDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"normal"}
!94 = !{i32 5, !"air.buffer", !"air.buffer_size", i32 384, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !48, !"air.arg_type_size", i32 384, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"EntityUniforms", !"air.arg_name", !"uniforms"}
!95 = !{i32 6, !"air.buffer", !"air.buffer_size", i32 1040, !"air.location_index", i32 2, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !78, !"air.arg_type_size", i32 1040, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"DLightBlock", !"air.arg_name", !"dlights"}
!96 = !{i32 7, !"air.buffer", !"air.buffer_size", i32 4, !"air.location_index", i32 3, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"pbrNormalScale"}
!97 = !{i32 8, !"air.buffer", !"air.buffer_size", i32 8, !"air.location_index", i32 4, i32 1, !"air.read", !"air.address_space", i32 2, !"air.arg_type_size", i32 8, !"air.arg_type_align_size", i32 8, !"air.arg_type_name", !"float2", !"air.arg_name", !"pbrRimParams"}
!98 = !{i32 9, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"colorTexture"}
!99 = !{i32 10, !"air.texture", !"air.location_index", i32 1, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"normalTexture"}
!100 = !{i32 11, !"air.texture", !"air.location_index", i32 3, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"roughnessTexture"}
!101 = !{i32 12, !"air.texture", !"air.location_index", i32 4, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"metallicTexture"}
!102 = !{i32 13, !"air.texture", !"air.location_index", i32 5, i32 1, !"air.sample", !"air.arg_type_name", !"texturecube<float, sample>", !"air.arg_name", !"envCube"}
!103 = !{i32 14, !"air.texture", !"air.location_index", i32 6, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"emissiveTexture"}
!104 = !{i32 15, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"textureSampler"}
!105 = !{i32 16, !"air.sampler", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"envSampler"}
!106 = !{<4 x float> (<4 x float>, <3 x float>, <2 x float>, %struct.WorldUniforms addrspace(2)*, %struct.WorldDrawUniforms addrspace(2)*, %struct._texture_2d_t addrspace(1)*, %struct._sampler_t addrspace(2)*)* @q3_sky_fragment, !54, !107}
!107 = !{!57, !108, !109, !110, !111, !112, !113}
!108 = !{i32 1, !"air.fragment_input", !"generated(8worldPosDv3_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float3", !"air.arg_name", !"worldPos"}
!109 = !{i32 2, !"air.fragment_input", !"generated(9scrollTexDv2_f)", !"air.center", !"air.perspective", !"air.arg_type_name", !"float2", !"air.arg_name", !"scrollTex", !"air.arg_unused"}
!110 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 1, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !37, !"air.arg_type_size", i32 112, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldUniforms", !"air.arg_name", !"uniforms"}
!111 = !{i32 4, !"air.buffer", !"air.buffer_size", i32 432, !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !39, !"air.arg_type_size", i32 432, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"WorldDrawUniforms", !"air.arg_name", !"drawUniforms"}
!112 = !{i32 5, !"air.texture", !"air.location_index", i32 0, i32 1, !"air.sample", !"air.arg_type_name", !"texture2d<float, sample>", !"air.arg_name", !"skyTexture"}
!113 = !{i32 6, !"air.sampler", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"sampler", !"air.arg_name", !"textureSampler"}
!114 = !{!"air.compile.denorms_disable"}
!115 = !{!"air.compile.fast_math_enable"}
!116 = !{!"air.compile.framebuffer_fetch_enable"}
!117 = !{!"air.sampler_state", [2 x i64] addrspace(2)* @__air_sampler_state.1}
!118 = !{!"Apple metal version 32023.883 (metalfe-32023.883)"}
!119 = !{i32 2, i32 7, i32 0}
!120 = !{!"Metal", i32 3, i32 2, i32 0}
!121 = !{!"/Users/targus/Documents/Quake_IoS_Phase9_Fork/scripts/shader_dump/world.metal"}
!122 = !{i64 0, i64 8, !123, i64 8, i64 8, !123, i64 16, i64 16, !123}
!123 = !{!124, !124, i64 0}
!124 = !{!"omnipotent char", !125, i64 0}
!125 = !{!"Simple C++ TBAA"}
!126 = !{!127}
!127 = distinct !{!127, !128, !"air-alias-scope-arg(0)"}
!128 = distinct !{!128, !"air-alias-scopes(q3_ui_vertex)"}
!129 = !{!130}
!130 = distinct !{!130, !128, !"air-alias-scope-arg(1)"}
!131 = !{i64 0, i64 8, !123, i64 8, i64 16, !123}
!132 = !{i64 0, i64 16, !123}
!133 = !{!134, !136}
!134 = distinct !{!134, !135, !"air-alias-scope-textures"}
!135 = distinct !{!135, !"air-alias-scopes(q3_ui_fragment)"}
!136 = distinct !{!136, !135, !"air-alias-scope-samplers"}
!137 = !{!138}
!138 = distinct !{!138, !139, !"air-alias-scope-textures"}
!139 = distinct !{!139, !"air-alias-scopes(q3_fog_volume_fragment)"}
!140 = !{!141}
!141 = distinct !{!141, !139, !"air-alias-scope-arg(2)"}
!142 = !{!143, !144, i64 0}
!143 = !{!"_ZTS11DLightBlock", !144, i64 0, !144, i64 4, !144, i64 8, !144, i64 12, !124, i64 16}
!144 = !{!"int", !124, i64 0}
!145 = !{i64 0, i64 12, !123, i64 12, i64 4, !146, i64 16, i64 12, !123, i64 28, i64 4, !146}
!146 = !{!147, !147, i64 0}
!147 = !{!"float", !124, i64 0}
!148 = !{i64 0, i64 8, !123, i64 8, i64 4, !146, i64 12, i64 12, !123, i64 24, i64 4, !146}
!149 = !{i64 0, i64 4, !123, i64 4, i64 4, !146, i64 8, i64 12, !123, i64 20, i64 4, !146}
!150 = !{i64 0, i64 4, !146, i64 4, i64 12, !123, i64 16, i64 4, !146}
!151 = !{i64 0, i64 12, !123, i64 12, i64 4, !146}
!152 = !{i64 0, i64 8, !123, i64 8, i64 4, !146}
!153 = !{i64 0, i64 4, !123, i64 4, i64 4, !146}
!154 = distinct !{!154, !155}
!155 = !{!"llvm.loop.mustprogress"}
!156 = !{i64 0, i64 16, !123, i64 16, i64 8, !123, i64 24, i64 8, !123, i64 32, i64 16, !123, i64 48, i64 16, !123, i64 64, i64 16, !123, i64 80, i64 16, !123, i64 96, i64 16, !123}
!157 = !{!158}
!158 = distinct !{!158, !159, !"air-alias-scope-arg(0)"}
!159 = distinct !{!159, !"air-alias-scopes(q3_world_vertex)"}
!160 = !{!161, !162}
!161 = distinct !{!161, !159, !"air-alias-scope-arg(1)"}
!162 = distinct !{!162, !159, !"air-alias-scope-arg(2)"}
!163 = !{i64 0, i64 8, !123, i64 8, i64 8, !123, i64 16, i64 16, !123, i64 32, i64 16, !123, i64 48, i64 16, !123, i64 64, i64 16, !123, i64 80, i64 16, !123}
!164 = !{i64 0, i64 8, !123, i64 8, i64 16, !123, i64 24, i64 16, !123, i64 40, i64 16, !123, i64 56, i64 16, !123, i64 72, i64 16, !123}
!165 = !{i64 0, i64 16, !123, i64 16, i64 16, !123, i64 32, i64 16, !123, i64 48, i64 16, !123, i64 64, i64 16, !123}
!166 = !{i64 0, i64 16, !123, i64 16, i64 16, !123, i64 32, i64 16, !123, i64 48, i64 16, !123}
!167 = !{i64 0, i64 16, !123, i64 16, i64 16, !123, i64 32, i64 16, !123}
!168 = !{i64 0, i64 16, !123, i64 16, i64 16, !123}
!169 = !{!170, !144, i64 304}
!170 = !{!"_ZTS17WorldDrawUniforms", !147, i64 0, !144, i64 4, !147, i64 8, !147, i64 12, !147, i64 16, !147, i64 20, !144, i64 24, !144, i64 28, !144, i64 32, !124, i64 48, !124, i64 64, !124, i64 80, !124, i64 96, !124, i64 112, !124, i64 128, !124, i64 144, !124, i64 160, !124, i64 176, !124, i64 192, !124, i64 208, !124, i64 224, !124, i64 240, !124, i64 256, !124, i64 272, !124, i64 288, !144, i64 304, !147, i64 308, !147, i64 312, !147, i64 316, !147, i64 320, !147, i64 324, !144, i64 328, !124, i64 336, !147, i64 352, !147, i64 356, !147, i64 360, !147, i64 364, !147, i64 368, !147, i64 372, !147, i64 376, !144, i64 380, !147, i64 384, !147, i64 388, !147, i64 392, !147, i64 396, !147, i64 400, !147, i64 404, !147, i64 408, !147, i64 412, !147, i64 416}
!171 = !{!162}
!172 = !{!158, !161}
!173 = !{!170, !147, i64 308}
!174 = !{!170, !147, i64 312}
!175 = !{!170, !147, i64 316}
!176 = !{!170, !147, i64 320}
!177 = !{!170, !147, i64 324}
!178 = !{!170, !147, i64 20}
!179 = !{!170, !147, i64 368}
!180 = !{!170, !147, i64 372}
!181 = !{!170, !147, i64 376}
!182 = !{!170, !144, i64 328}
!183 = !{!170, !147, i64 352}
!184 = !{!170, !147, i64 356}
!185 = !{!170, !147, i64 360}
!186 = !{!170, !147, i64 364}
!187 = !{!170, !144, i64 380}
!188 = !{!161}
!189 = !{!158, !162}
!190 = !{!170, !147, i64 8}
!191 = !{!192}
!192 = distinct !{!192, !193, !"air-alias-scope-arg(7)"}
!193 = distinct !{!193, !"air-alias-scopes(q3_world_fragment)"}
!194 = !{!195, !196, !197, !198, !199}
!195 = distinct !{!195, !193, !"air-alias-scope-arg(8)"}
!196 = distinct !{!196, !193, !"air-alias-scope-arg(9)"}
!197 = distinct !{!197, !193, !"air-alias-scope-arg(10)"}
!198 = distinct !{!198, !193, !"air-alias-scope-textures"}
!199 = distinct !{!199, !193, !"air-alias-scope-samplers"}
!200 = !{!170, !147, i64 12}
!201 = !{!170, !147, i64 16}
!202 = !{!170, !147, i64 0}
!203 = !{!195}
!204 = !{!192, !196, !197, !198, !199}
!205 = !{!170, !144, i64 4}
!206 = !{!198, !199}
!207 = !{!192, !195, !196, !197}
!208 = !{!170, !147, i64 384}
!209 = !{!170, !147, i64 396}
!210 = !{!170, !147, i64 416}
!211 = !{!170, !147, i64 392}
!212 = !{!170, !144, i64 24}
!213 = !{!170, !144, i64 28}
!214 = !{!198}
!215 = !{!192, !195, !196, !197, !199}
!216 = !{!197}
!217 = !{!192, !195, !196, !198, !199}
!218 = !{i64 0, i64 16, !123, i64 16, i64 8, !123, i64 32, i64 16, !123, i64 48, i64 16, !123}
!219 = !{!220}
!220 = distinct !{!220, !221, !"air-alias-scope-arg(0)"}
!221 = distinct !{!221, !"air-alias-scopes(q3_entity_vertex)"}
!222 = !{!223}
!223 = distinct !{!223, !221, !"air-alias-scope-arg(1)"}
!224 = !{i64 0, i64 8, !123, i64 16, i64 16, !123, i64 32, i64 16, !123}
!225 = !{!226, !144, i64 328}
!226 = !{!"_ZTS14EntityUniforms", !227, i64 0, !124, i64 64, !124, i64 80, !147, i64 96, !147, i64 100, !144, i64 104, !147, i64 108, !124, i64 112, !124, i64 128, !124, i64 144, !124, i64 160, !124, i64 176, !144, i64 192, !144, i64 196, !144, i64 200, !144, i64 204, !124, i64 208, !124, i64 224, !124, i64 240, !124, i64 256, !124, i64 272, !124, i64 288, !124, i64 304, !144, i64 320, !144, i64 324, !144, i64 328, !147, i64 332, !147, i64 336, !147, i64 340, !147, i64 344, !147, i64 348, !124, i64 352, !124, i64 368}
!227 = !{!"_ZTSN5metal6matrixIfLi4ELi4EvEE", !124, i64 0}
!228 = !{!226, !147, i64 332}
!229 = !{!226, !147, i64 336}
!230 = !{!226, !147, i64 340}
!231 = !{!226, !147, i64 344}
!232 = !{!226, !147, i64 348}
!233 = !{!226, !147, i64 100}
!234 = !{!226, !147, i64 96}
!235 = !{!236}
!236 = distinct !{!236, !237, !"air-alias-scope-arg(5)"}
!237 = distinct !{!237, !"air-alias-scopes(q3_entity_fragment)"}
!238 = !{!239, !240, !241, !242, !243}
!239 = distinct !{!239, !237, !"air-alias-scope-arg(6)"}
!240 = distinct !{!240, !237, !"air-alias-scope-arg(7)"}
!241 = distinct !{!241, !237, !"air-alias-scope-arg(8)"}
!242 = distinct !{!242, !237, !"air-alias-scope-textures"}
!243 = distinct !{!243, !237, !"air-alias-scope-samplers"}
!244 = !{!226, !144, i64 104}
!245 = !{!242, !243}
!246 = !{!236, !239, !240, !241}
!247 = !{!226, !144, i64 324}
!248 = !{!226, !144, i64 320}
!249 = !{!226, !147, i64 108}
!250 = !{!226, !144, i64 196}
!251 = !{!226, !144, i64 192}
!252 = !{!226, !144, i64 200}
!253 = !{!226, !144, i64 204}
!254 = !{!242}
!255 = !{!236, !239, !240, !241, !243}
!256 = !{!240}
!257 = !{!236, !239, !241, !242, !243}
!258 = !{!241}
!259 = !{!236, !239, !240, !242, !243}
!260 = !{!261}
!261 = distinct !{!261, !262, !"air-alias-scope-arg(0)"}
!262 = distinct !{!262, !"air-alias-scopes(q3_sky_vertex)"}
!263 = !{!264}
!264 = distinct !{!264, !262, !"air-alias-scope-arg(1)"}
!265 = !{!266}
!266 = distinct !{!266, !267, !"air-alias-scope-arg(3)"}
!267 = distinct !{!267, !"air-alias-scopes(q3_sky_fragment)"}
!268 = !{!269, !270, !271}
!269 = distinct !{!269, !267, !"air-alias-scope-arg(4)"}
!270 = distinct !{!270, !267, !"air-alias-scope-textures"}
!271 = distinct !{!271, !267, !"air-alias-scope-samplers"}
!272 = !{!269}
!273 = !{!266, !270, !271}
!274 = !{!270, !271}
!275 = !{!266, !269}
