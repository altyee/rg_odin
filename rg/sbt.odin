package rg

import d3d12 "vendor:directx/d3d12"
import d3d12ma "../d3d12ma"
import "core:fmt"
import "core:mem"
import "core:sys/windows"
import utils "../utils"

SBTRegions :: struct {
    raygen_address:  d3d12.GPU_VIRTUAL_ADDRESS,
    raygen_size:     u64,
    miss_address:    d3d12.GPU_VIRTUAL_ADDRESS,
    miss_size:       u64,
    miss_stride:     u64,
    hitgroup_address: d3d12.GPU_VIRTUAL_ADDRESS,
    hitgroup_size:    u64,
    hitgroup_stride:  u64,
}

create_shader_binding_table :: proc(
    device: ^d3d12.IDevice,
    rtpso: ^d3d12.IStateObject,
    allocator: d3d12ma.Allocator,
) -> (sbt_buffer: d3d12ma.Allocation, regions: SBTRegions, ok: bool) {
    props: ^d3d12.IStateObjectProperties
    hr := rtpso->QueryInterface(d3d12.IStateObjectProperties_IID, (^rawptr)(&props))
    if hr < 0 {
        fmt.println("Failed to query IStateObjectProperties:", hr)
        return nil, {}, false
    }
    defer props->Release()

    raygen_name   := windows.utf8_to_wstring("RayGen")
    miss_name     := windows.utf8_to_wstring("Miss")
    hitgroup_name := windows.utf8_to_wstring("HitGroup")

    raygen_id   := props->GetShaderIdentifier(raygen_name)
    miss_id     := props->GetShaderIdentifier(miss_name)
    hitgroup_id := props->GetShaderIdentifier(hitgroup_name)

    if raygen_id == nil || miss_id == nil || hitgroup_id == nil {
        fmt.println("One or more shader identifiers came back nil - export name mismatch?")
        return nil, {}, false
    }

    record_size := u64(d3d12.SHADER_IDENTIFIER_SIZE_IN_BYTES)

    raygen_offset   := u64(0)
    miss_offset     := utils.align_up(raygen_offset + record_size, u64(d3d12.RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT))
    hitgroup_offset := utils.align_up(miss_offset + record_size, u64(d3d12.RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT))
    total_size      := hitgroup_offset + record_size

    {
        alloc_desc := d3d12ma.ALLOCATION_DESC {
            HeapType = .UPLOAD
        }
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER, Width = total_size, Height = 1,
            DepthOrArraySize = 1, MipLevels = 1, Format = .UNKNOWN,
            SampleDesc = {Count = 1, Quality = 0}, Layout = .ROW_MAJOR,
        }
        hr = d3d12ma.Allocator_CreateResource(allocator, &alloc_desc, &desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil,
                                             &sbt_buffer, d3d12.IResource_UUID, nil)
        if hr < 0 { return nil, {}, false }
    }

    sub_buffer_resc := d3d12ma.Allocation_GetD3D12Resource(sbt_buffer)

    mapped: rawptr
    read_range: d3d12.RANGE
    hr = sub_buffer_resc->Map(0, &read_range, &mapped)
    if hr < 0 {
        fmt.println("Failed mapping SBT buffer:", hr)
        return nil, {}, false
    }

    mem.copy(rawptr(uintptr(mapped) + uintptr(raygen_offset)),   raygen_id,   int(d3d12.SHADER_IDENTIFIER_SIZE_IN_BYTES))
    mem.copy(rawptr(uintptr(mapped) + uintptr(miss_offset)),     miss_id,     int(d3d12.SHADER_IDENTIFIER_SIZE_IN_BYTES))
    mem.copy(rawptr(uintptr(mapped) + uintptr(hitgroup_offset)), hitgroup_id, int(d3d12.SHADER_IDENTIFIER_SIZE_IN_BYTES))

    sub_buffer_resc->Unmap(0, nil)

    base_address := sub_buffer_resc->GetGPUVirtualAddress()

    regions = SBTRegions{
        raygen_address   = base_address + raygen_offset,
        raygen_size      = record_size,
        miss_address     = base_address + miss_offset,
        miss_size        = record_size,
        miss_stride      = record_size,
        hitgroup_address = base_address + hitgroup_offset,
        hitgroup_size    = record_size,
        hitgroup_stride  = record_size,
    }

    return sbt_buffer, regions, true
}
