#!/usr/bin/env python3
# Extract the actual Swift/MSL structs and verify every field via a GPU sentinel round trip.
from pathlib import Path
import re,sys,subprocess
import tempfile
root=Path(tempfile.mkdtemp(prefix='q3-metal-layout-'))
variant='candidate'
source_path=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'Quake3-iOS/MetalView.swift'
s=source_path.read_text()
def block(name,n):
 a=-1
 for _ in range(n+1):a=s.index('struct '+name+' {',a+1)
 b=s.index('\n        }',a)+10
 return s[a:b]+(';' if n else '')
structs=['WorldUniforms','EntityUniforms'];sw='';ms='#include <metal_stdlib>\nusing namespace metal;\n';tests=''
for name in structs:
 swift=block(name,0);metal=block(name,1);sw+=swift+'\n';ms+=metal+'\n'
 fields=re.findall(r'^\s*var (\w+):\s*(simd_float4x4|SIMD[234]<Float>|Float|UInt32|Int32)',swift,re.M)
 assert len(fields)==len(re.findall(r'^\s*var \w+:',swift,re.M)), 'New uniform field type needs probe support'
 assigns=[];reads=[];expect=[];off=[];counter=1
 for field,typ in fields:
  n=16 if typ=='simd_float4x4' else int(typ[4]) if typ.startswith('SIMD') else 1
  val=counter;counter+=n
  if n==16:
   assigns.append(f'u.{field} = simd_float4x4(columns: (SIMD4<Float>({",".join(str(val+i) for i in range(4))}),SIMD4<Float>({",".join(str(val+4+i) for i in range(4))}),SIMD4<Float>({",".join(str(val+8+i) for i in range(4))}),SIMD4<Float>({",".join(str(val+12+i) for i in range(4))})))')
   reads += [f'float(u.{field}[{i//4}][{i%4}])' for i in range(n)]
  elif n>1:
   assigns.append(f'u.{field} = {typ}({",".join(str(val+i) for i in range(n))})'); reads += [f'float(u.{field}[{i}])' for i in range(n)]
  else:assigns.append(f'u.{field} = {val}');reads.append(f'float(u.{field})')
  expect+=list(range(val,val+n));off.append(f'"{field}": MemoryLayout<{name}>.offset(of: \\.{field})!')
 ms+=f'kernel void probe{name}(constant {name}& u [[buffer(0)]], device float* o [[buffer(1)]]) {{ o[0]=sizeof({name}); '+''.join(f'o[{i+1}]={v};' for i,v in enumerate(reads))+'}\n'
 init='viewProjection:matrix_identity_float4x4'+(', cameraPos: SIMD3<Float>(0,0,0)' if name=='WorldUniforms' else '')
 tests+='''do {
'''+f'var u = {name}({init})\n'+'\n'.join(assigns)+f'''
let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"probe{name}")!)
let output = device.makeBuffer(length:{len(expect)+1}*4, options:.storageModeShared)!
let command = queue.makeCommandBuffer()!; let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline);encoder.setBytes(&u,length:MemoryLayout<{name}>.stride,index:0);encoder.setBuffer(output,offset:0,index:1)
encoder.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
let expected:[Float] = [Float(MemoryLayout<{name}>.stride),{','.join(map(str,expect))}]
let actual=Array(UnsafeBufferPointer(start:output.contents().assumingMemoryBound(to:Float.self),count:expected.count))
let mismatches=expected.indices.filter{{actual[$0] != expected[$0]}}
print("{name}","Swift stride",MemoryLayout<{name}>.stride,"MSL size",actual[0],"components",expected.count-1,"mismatches",mismatches.count,"status",command.status.rawValue)
print("Offsets",[{','.join(off)}])
for i in mismatches {{print("mismatch",i,"expected",expected[i],"actual",actual[i])}}
if !mismatches.isEmpty || command.status != .completed {{ failures += 1 }}
}}
'''
code='import Foundation\nimport Metal\nimport simd\n'+sw+'\nlet source = #"""\n'+ms+'\n"""#\nlet device = MTLCreateSystemDefaultDevice()!\nlet queue = device.makeCommandQueue()!\nlet library = try device.makeLibrary(source: source, options:nil)\nvar failures=0\n'+tests+'\nprint("FAILED_STRUCTS",failures)\nexit(failures == 0 ? 0 : 1)\n'
p=root/('layout-'+variant+'.swift');p.write_text(code)
subprocess.run(['xcrun','swiftc',str(p),'-o',str(p.with_suffix(''))],check=True)
res=subprocess.run([str(p.with_suffix(''))],capture_output=True,text=True);(root/('layout-'+variant+'.log')).write_text(res.stdout+res.stderr)
print(res.stdout)
print('Probe source and log:',root)
sys.exit(res.returncode)
