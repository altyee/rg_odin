package rg

FLOATS_PER_VERTEX :: 3

// Contains code for building ray tracing acceleration structures (BLAS/TLAS)
// Requires d3d12ma since the allocation is based on it

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3d12ma "../d3d12ma"
import "core:mem"

/*
build_blas_ctx :: proc(
    ctx: ^D3D12Context,
    // device: ^d3d12.IDevice5,
    // cmdlist: ^d3d12.IGraphicsCommandList4,
    vertex_buffer: ^d3d12.IResource,
    vertex_count: u32,
    index_buffer: ^d3d12.IResource,
    index_count: u32,
    // allocator: d3d12ma.Allocator,
    pool: d3d12ma.Pool,
) -> (blas: d3d12ma.Allocation, ok: bool) {
    geom_desc := d3d12.RAYTRACING_GEOMETRY_DESC{
        Type = .TRIANGLES,
        Flags = {.OPAQUE},
    }
    geom_desc.Triangles = {
        VertexBuffer = { StartAddress = vertex_buffer->GetGPUVirtualAddress(), StrideInBytes = u64(FLOATS_PER_VERTEX * size_of(f32)) },
        VertexFormat = .R32G32B32_FLOAT,
        VertexCount  = vertex_count,
        IndexBuffer  = index_buffer->GetGPUVirtualAddress(),
        IndexFormat  = .R32_UINT,
        IndexCount   = index_count,
    }

    inputs := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS{
        Type  = .BOTTOM_LEVEL,
        Flags = {.PREFER_FAST_TRACE},
        NumDescs = 1,
        DescsLayout = .ARRAY,
        pGeometryDescs = &geom_desc,
    }

    prebuild_info: d3d12.RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO
    device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &prebuild_info)

    scratch: ^d3d12.IResource
    {
        heap_props := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER,
            Width = prebuild_info.ScratchDataSizeInBytes,
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR, Flags = {.ALLOW_UNORDERED_ACCESS, .RAYTRACING_ACCELERATION_STRUCTURE},
        }
        hr := device->CreateCommittedResource(&heap_props, {}, &desc, {.UNORDERED_ACCESS}, nil, d3d12.IResource_UUID, (^rawptr)(&scratch))
        if hr < 0 { return nil, false }
    }

    {
        heap_props := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
        alloc_desc := d3d12ma.ALLOCATION_DESC{
      		Flags = {},
      		HeapType = .DEFAULT,
      		ExtraHeapFlags = {},
      		CustomPool = pool,
      		pPrivateData = nil,
       	}
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER,
            Width = prebuild_info.ResultDataMaxSizeInBytes,
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR, Flags = {.ALLOW_UNORDERED_ACCESS},
        }
        d3d12ma.Allocator_CreateResource(allocator, &alloc_desc, &desc, {.RAYTRACING_ACCELERATION_STRUCTURE}, nil, &blas, d3d12.IResource_UUID, nil)
        // hr := device->CreateCommittedResource(&heap_props, {}, &desc, {.RAYTRACING_ACCELERATION_STRUCTURE}, nil, d3d12.IResource_UUID, (^rawptr)(&blas))
        // if hr < 0 { return nil, false }
    }

    blas_resource := d3d12ma.Allocation_GetD3D12Resource(blas)

    build_desc := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC{
        DestAccelerationStructureData = blas_resource->GetGPUVirtualAddress(),
        Inputs = inputs,
        ScratchAccelerationStructureData = scratch->GetGPUVirtualAddress(),
    }
    cmdlist->BuildRaytracingAccelerationStructure(&build_desc, 0, nil)

    // UAV barrier needed before the BLAS can be used to build the TLAS
    barrier := d3d12.RESOURCE_BARRIER{ Type = .UAV }
    barrier.UAV.pResource = blas_resource
    cmdlist->ResourceBarrier(1, &barrier)

    return blas, true
}

*/

build_blas :: proc(
    ctx: ^D3D12Context,
    cmdlist: ^d3d12.IGraphicsCommandList4,
    vertices: d3d12ma.Allocation,
    vertex_count: u32,
    indices: d3d12ma.Allocation,
    index_count: u32,
    pool: d3d12ma.Pool,
) -> (blas: d3d12ma.Allocation, ok: bool) {
    device := ctx.device
    allocator := ctx.allocator
    vertex_buffer := d3d12ma.Allocation_GetD3D12Resource(vertices)
    index_buffer := d3d12ma.Allocation_GetD3D12Resource(indices)
    geom_desc := d3d12.RAYTRACING_GEOMETRY_DESC{
        Type = .TRIANGLES,
        Flags = {.OPAQUE},
    }
    geom_desc.Triangles = {
        VertexBuffer = { StartAddress = vertex_buffer->GetGPUVirtualAddress(), StrideInBytes = u64(FLOATS_PER_VERTEX * size_of(f32)) },
        VertexFormat = .R32G32B32_FLOAT,
        VertexCount  = vertex_count,
        IndexBuffer  = index_buffer->GetGPUVirtualAddress(),
        IndexFormat  = .R32_UINT,
        IndexCount   = index_count,
    }

    inputs := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS{
        Type  = .BOTTOM_LEVEL,
        Flags = {.PREFER_FAST_TRACE},
        NumDescs = 1,
        DescsLayout = .ARRAY,
        pGeometryDescs = &geom_desc,
    }

    prebuild_info: d3d12.RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO
    device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &prebuild_info)

    scratch: ^d3d12.IResource
    {
        heap_props := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER,
            Width = prebuild_info.ScratchDataSizeInBytes,
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR, Flags = {.ALLOW_UNORDERED_ACCESS, .RAYTRACING_ACCELERATION_STRUCTURE},
        }
        hr := device->CreateCommittedResource(&heap_props, {}, &desc, {.UNORDERED_ACCESS}, nil, d3d12.IResource_UUID, (^rawptr)(&scratch))
        if hr < 0 { return nil, false }
    }

    {
        heap_props := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
        alloc_desc := d3d12ma.ALLOCATION_DESC{
      		Flags = {},
      		HeapType = .DEFAULT,
      		ExtraHeapFlags = {},
      		CustomPool = pool,
      		pPrivateData = nil,
       	}
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER,
            Width = prebuild_info.ResultDataMaxSizeInBytes,
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR, Flags = {.ALLOW_UNORDERED_ACCESS},
        }
        d3d12ma.Allocator_CreateResource(allocator, &alloc_desc, &desc, {.RAYTRACING_ACCELERATION_STRUCTURE}, nil, &blas, d3d12.IResource_UUID, nil)
        // hr := device->CreateCommittedResource(&heap_props, {}, &desc, {.RAYTRACING_ACCELERATION_STRUCTURE}, nil, d3d12.IResource_UUID, (^rawptr)(&blas))
        // if hr < 0 { return nil, false }
    }

    blas_resource := d3d12ma.Allocation_GetD3D12Resource(blas)

    build_desc := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC{
        DestAccelerationStructureData = blas_resource->GetGPUVirtualAddress(),
        Inputs = inputs,
        ScratchAccelerationStructureData = scratch->GetGPUVirtualAddress(),
    }
    cmdlist->BuildRaytracingAccelerationStructure(&build_desc, 0, nil)

    // UAV barrier needed before the BLAS can be used to build the TLAS
    barrier := d3d12.RESOURCE_BARRIER{ Type = .UAV }
    barrier.UAV.pResource = blas_resource
    cmdlist->ResourceBarrier(1, &barrier)

    return blas, true
}

build_tlas :: proc(
    device: ^d3d12.IDevice5,
    cmdlist: ^d3d12.IGraphicsCommandList4,
    allocator: d3d12ma.Allocator,
    blas_list: []d3d12ma.Allocation) -> (tlas: d3d12ma.Allocation, ok: bool) {

    instance_count := len(blas_list)
    instance_descs := make([]d3d12.RAYTRACING_INSTANCE_DESC, instance_count)
    defer delete(instance_descs)

    for blas, i in blas_list {
        blas_resource := d3d12ma.Allocation_GetD3D12Resource(blas)
       	id_and_mask := (u32(i) & 0xFFFFFF) | (u32(0xFF) << 24) // low 24 bits = instance ID, high 8 = mask (0xFF = visible to all rays)
        instance_descs[i] = d3d12.RAYTRACING_INSTANCE_DESC{
            Transform = {
                {1, 0, 0, 0},
                {0, 1, 0, 0},
                {0, 0, 1, 0},
            },
            InstanceID = id_and_mask,
            InstanceContributionToHitGroupIndex = u32(0),
            AccelerationStructure = blas_resource->GetGPUVirtualAddress(),
        }
    }

    instance_buffer: ^d3d12.IResource
    {
        heap_props := d3d12.HEAP_PROPERTIES{ Type = .UPLOAD }
        buffer_size := instance_count * size_of(d3d12.RAYTRACING_INSTANCE_DESC)
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER, Width = u64(buffer_size),
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR,
        }
        hr := device->CreateCommittedResource(&heap_props, {}, &desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&instance_buffer))
        if hr < 0 { return nil, false }

        mapped: rawptr
        read_range: d3d12.RANGE
        instance_buffer->Map(0, &read_range, &mapped)
        mem.copy(mapped, &instance_descs[0], buffer_size)
        instance_buffer->Unmap(0, nil)
    }

    inputs := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS{
        Type = .TOP_LEVEL,
        Flags = {.PREFER_FAST_TRACE},
        NumDescs = u32(instance_count),
        DescsLayout = .ARRAY,
        InstanceDescs = instance_buffer->GetGPUVirtualAddress(),
    }

    prebuild_info: d3d12.RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO
    device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &prebuild_info)

    scratch: ^d3d12.IResource
    {
        heap_props := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER, Width = prebuild_info.ScratchDataSizeInBytes,
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR, Flags = {.ALLOW_UNORDERED_ACCESS},
        }
        hr := device->CreateCommittedResource(&heap_props, {}, &desc, {.UNORDERED_ACCESS}, nil, d3d12.IResource_UUID, (^rawptr)(&scratch))
        if hr < 0 { return nil, false }
    }

    {
        // heap_props := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER, Width = prebuild_info.ResultDataMaxSizeInBytes,
            Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR, Flags = {.ALLOW_UNORDERED_ACCESS},
        }
        alloc_desc := d3d12ma.ALLOCATION_DESC{
      		Flags = {},
      		HeapType = .DEFAULT,
      		ExtraHeapFlags = {},
      		CustomPool = nil,
      		pPrivateData = nil,
       	}
        hr := d3d12ma.Allocator_CreateResource(allocator, &alloc_desc, &desc, {.RAYTRACING_ACCELERATION_STRUCTURE}, nil, &tlas, d3d12.IResource_UUID, nil)
        if hr < 0 { return nil, false }
    }

    build_desc := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC{
        DestAccelerationStructureData = d3d12ma.Allocation_GetD3D12Resource(tlas)->GetGPUVirtualAddress(),
        Inputs = inputs,
        ScratchAccelerationStructureData = scratch->GetGPUVirtualAddress(),
    }
    cmdlist->BuildRaytracingAccelerationStructure(&build_desc, 0, nil)

    return tlas, true
}
