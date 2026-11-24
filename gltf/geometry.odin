package gltf

import d3d12ma "../d3d12ma"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import rg "../rg"
import "core:mem"

InstanceData :: struct {
    color:        [4]f32,
    // emissive:     [4]f32, // xyz used, w unused
    index_offset: u32,    // where this mesh's triangles start in the global index buffer
}

create_global_geometry_buffers :: proc(
    scene: ^Scene,
    ctx: ^rg.D3D12Context,
) -> (
    vertex_buffer: d3d12ma.Allocation,
    index_buffer: d3d12ma.Allocation,
    instance_data_buffer: d3d12ma.Allocation,
    vertex_float_count: u32,
    index_count: u32,
    ok: bool,
) {

    allocator := ctx.allocator
    device := ctx.device

    all_vertices: [dynamic]f32
    all_indices:  [dynamic]u32
    instance_data := make([]InstanceData, len(scene.meshes))
    defer delete(instance_data)

    for mesh, i in scene.meshes {
        index_offset := u32(len(all_indices))
        vertex_offset := u32(len(all_vertices) / FLOATS_PER_VERTEX)

        for v in mesh.vertices {
            append(&all_vertices, v)
        }
        for idx in mesh.indices {
            append(&all_indices, idx + vertex_offset)
        }

        instance_data[i] = InstanceData{
            color        = mesh.color,
            // emissive     = { mesh.emissive.x, mesh.emissive.y, mesh.emissive.z, 0 },
            index_offset = index_offset,
        }
    }

    // heap_props := d3d12.HEAP_PROPERTIES{ Type = .UPLOAD }
    alloc_props := d3d12ma.ALLOCATION_DESC { HeapType = .UPLOAD }

    vb_size := len(all_vertices) * size_of(f32)
    vb_desc := d3d12.RESOURCE_DESC {
        Dimension = .BUFFER, Width = u64(vb_size), Height = 1,
        DepthOrArraySize = 1, MipLevels = 1, Format = .UNKNOWN,
        SampleDesc = {Count = 1, Quality = 0}, Layout = .ROW_MAJOR,
    }

    hr := d3d12ma.Allocator_CreateResource(allocator, &alloc_props, &vb_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, &vertex_buffer, d3d12.IResource_UUID, nil)

    // hr := device->CreateCommittedResource(&heap_props, {}, &vb_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&vertex_buffer))
    //
    if hr < 0 { return nil, nil, nil, 0, 0, false }
    {
        mapped: rawptr
        read_range: d3d12.RANGE
        d3d12ma.Allocation_GetD3D12Resource(vertex_buffer)->Map(0, &read_range, &mapped)
        mem.copy(mapped, &all_vertices[0], vb_size)
        d3d12ma.Allocation_GetD3D12Resource(vertex_buffer)->Unmap(0, nil)
    }

    ib_size := len(all_indices) * size_of(u32)
    ib_desc := d3d12.RESOURCE_DESC {
        Dimension = .BUFFER, Width = u64(ib_size), Height = 1,
        DepthOrArraySize = 1, MipLevels = 1, Format = .UNKNOWN,
        SampleDesc = {Count = 1, Quality = 0}, Layout = .ROW_MAJOR,
    }
    hr = d3d12ma.Allocator_CreateResource(allocator, &alloc_props, &ib_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, &index_buffer, d3d12.IResource_UUID, nil)
    // hr = device->CreateCommittedResource(&heap_props, {}, &ib_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&index_buffer))
    if hr < 0 { return nil, nil, nil, 0, 0, false }
    {
        mapped: rawptr
        read_range: d3d12.RANGE
        d3d12ma.Allocation_GetD3D12Resource(index_buffer)->Map(0, &read_range, &mapped)
        mem.copy(mapped, &all_indices[0], ib_size)
        d3d12ma.Allocation_GetD3D12Resource(index_buffer)->Unmap(0, nil)
    }

    id_size := len(instance_data) * size_of(InstanceData)
    id_desc := d3d12.RESOURCE_DESC {
        Dimension = .BUFFER, Width = u64(id_size), Height = 1,
        DepthOrArraySize = 1, MipLevels = 1, Format = .UNKNOWN,
        SampleDesc = {Count = 1, Quality = 0}, Layout = .ROW_MAJOR,
    }
    hr = d3d12ma.Allocator_CreateResource(allocator, &alloc_props, &id_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, &instance_data_buffer, d3d12.IResource_UUID, nil)
    // hr = device->CreateCommittedResource(&heap_props, {}, &id_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&instance_data_buffer))
    if hr < 0 { return nil, nil, nil, 0, 0, false }
    {
        mapped: rawptr
        read_range: d3d12.RANGE
        d3d12ma.Allocation_GetD3D12Resource(instance_data_buffer)->Map(0, &read_range, &mapped)
        mem.copy(mapped, &instance_data[0], id_size)
        d3d12ma.Allocation_GetD3D12Resource(instance_data_buffer)->Unmap(0, nil)
    }

    return vertex_buffer, index_buffer, instance_data_buffer, u32(len(all_vertices)), u32(len(all_indices)), true
}
