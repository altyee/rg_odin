package rg

// This file contains helper functions to create PSOs

import d3d12 "vendor:directx/d3d12"
import "core:sys/windows"
import "core:fmt"

create_rt_pso :: proc(
    device5: ^d3d12.IDevice5,
    dxil_bytecode: []u8,
    global_root_signature: ^d3d12.IRootSignature,
) -> (state_object: ^d3d12.IStateObject, ok: bool) {
    raygen_name      := windows.utf8_to_wstring("RayGen")
    closesthit_name  := windows.utf8_to_wstring("ClosestHit")
    miss_name        := windows.utf8_to_wstring("Miss")
    hitgroup_name    := windows.utf8_to_wstring("HitGroup")

    exports := [3]d3d12.EXPORT_DESC{
        { Name = raygen_name },
        { Name = closesthit_name },
        { Name = miss_name },
    }

    dxil_lib_desc := d3d12.DXIL_LIBRARY_DESC{
        DXILLibrary = { pShaderBytecode = raw_data(dxil_bytecode), BytecodeLength = uint(len(dxil_bytecode)) },
        NumExports  = len(exports),
        pExports    = &exports[0],
    }

    hit_group_desc := d3d12.HIT_GROUP_DESC{
        HitGroupExport         = hitgroup_name,
        Type                   = .TRIANGLES,
        ClosestHitShaderImport = closesthit_name,
    }

    shader_config := d3d12.RAYTRACING_SHADER_CONFIG{
        MaxPayloadSizeInBytes   = 48,
        MaxAttributeSizeInBytes = 8,
    }

    pipeline_config := d3d12.RAYTRACING_PIPELINE_CONFIG{
        MaxTraceRecursionDepth = 1,
    }

    global_rs_desc := d3d12.GLOBAL_ROOT_SIGNATURE{
        pGlobalRootSignature = global_root_signature,
    }

    subobjects := [5]d3d12.STATE_SUBOBJECT{
        { Type = .DXIL_LIBRARY,               pDesc = &dxil_lib_desc },
        { Type = .HIT_GROUP,                  pDesc = &hit_group_desc },
        { Type = .RAYTRACING_SHADER_CONFIG,   pDesc = &shader_config },
        { Type = .RAYTRACING_PIPELINE_CONFIG, pDesc = &pipeline_config },
        { Type = .GLOBAL_ROOT_SIGNATURE,      pDesc = &global_rs_desc },
    }

    state_object_desc := d3d12.STATE_OBJECT_DESC{
        Type          = .RAYTRACING_PIPELINE,
        NumSubobjects = len(subobjects),
        pSubobjects   = &subobjects[0],
    }

    hr := device5->CreateStateObject(&state_object_desc, d3d12.IStateObject_UUID, (^rawptr)(&state_object))
    if hr < 0 {
        fmt.println("CreateStateObject failed:", hr)
        return nil, false
    }

    return state_object, true
}
