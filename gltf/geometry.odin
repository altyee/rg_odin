package gltf

import d3d12ma "../d3d12ma"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import rg "../rg"
import "core:mem"
import "core:math/linalg"

InstanceData :: struct {
    color:        [4]f32,
    // emissive:     [4]f32, // xyz used, w unused
    index_offset: u32,    // where this mesh's triangles start in the global index buffer
}

MeshColor :: struct {
    base_color: [4]f32,
    emission: [3]f32,
}

create_mesh_color_buffer :: proc(scene: ^Scene, allocator: d3d12ma.Allocator) -> (allocation: d3d12ma.Allocation, ok: bool) {
    colors := make([]MeshColor, len(scene.meshes))
    defer delete(colors)
    for mesh, i in scene.meshes { colors[i] = {mesh.color, mesh.emission} }
    return upload_structured_buffer(allocator, colors)
}

// Matches the five float4 fields in nee_rt.hlsl.
LightTriangle :: struct {
    p0, p1, p2: [4]f32,
    normal_area: [4]f32,
    emissive_cumarea: [4]f32,
}
#assert(size_of(LightTriangle) == 80)

// A nil allocation with ok=true means the scene has no sampleable lights.
create_light_triangle_buffer :: proc(scene: ^Scene, allocator: d3d12ma.Allocator) -> (allocation: d3d12ma.Allocation, ok: bool) {
    lights: [dynamic]LightTriangle
    defer delete(lights)
    total_area: f32
    for mesh in scene.meshes {
        e := mesh.emission
        if e.x <= 0 && e.y <= 0 && e.z <= 0 { continue }
        if len(mesh.indices) % 3 != 0 { return nil, false }
        for t := 0; t < len(mesh.indices); t += 3 {
            p: [3][3]f32
            for &v, j in p {
                base := int(mesh.indices[t+j]) * FLOATS_PER_VERTEX
                if base + 2 >= len(mesh.vertices) { return nil, false }
                v = {mesh.vertices[base], mesh.vertices[base+1], mesh.vertices[base+2]}
            }
            n := linalg.cross(p[1]-p[0], p[2]-p[0])
            length := linalg.length(n)
            if length == 0 { continue }
            n /= length
            area := length * 0.5
            total_area += area
            append(&lights, LightTriangle{
                p0 = {p[0].x, p[0].y, p[0].z, 1},
                p1 = {p[1].x, p[1].y, p[1].z, 1},
                p2 = {p[2].x, p[2].y, p[2].z, 1},
                normal_area = {n.x, n.y, n.z, area},
                emissive_cumarea = {e.x, e.y, e.z, total_area},
            })
        }
    }
    if len(lights) == 0 { return nil, true }
    return upload_structured_buffer(allocator, lights[:])
}

create_face_normal_buffers :: proc(scene: ^Scene, allocator: d3d12ma.Allocator) -> (d3d12ma.Allocation, d3d12ma.Allocation, bool) {
    normals: [dynamic][4]f32
    defer delete(normals)
    offsets := make([]u32, len(scene.meshes))
    defer delete(offsets)
    for mesh, i in scene.meshes {
        offsets[i] = u32(len(normals))
        if len(mesh.indices) % 3 != 0 { return nil, nil, false }
        for t := 0; t < len(mesh.indices); t += 3 {
            p: [3][3]f32
            for &v, j in p {
                base := int(mesh.indices[t+j]) * FLOATS_PER_VERTEX
                if base + 2 >= len(mesh.vertices) { return nil, nil, false }
                v = {mesh.vertices[base], mesh.vertices[base+1], mesh.vertices[base+2]}
            }
            n := linalg.cross(p[1]-p[0], p[2]-p[0])
            length := linalg.length(n)
            if length > 0 { n /= length }
            append(&normals, [4]f32{n.x, n.y, n.z, 0})
        }
    }
    normal_buffer, ok := upload_structured_buffer(allocator, normals[:])
    if !ok { return nil, nil, false }
    offset_buffer, offsets_ok := upload_structured_buffer(allocator, offsets)
    if !offsets_ok {
        d3d12ma.Allocation_Release(normal_buffer)
        return nil, nil, false
    }
    return normal_buffer, offset_buffer, true
}

upload_structured_buffer :: proc(allocator: d3d12ma.Allocator, data: []$T) -> (allocation: d3d12ma.Allocation, ok: bool) {
    if len(data) == 0 { return nil, false }
    props := d3d12ma.ALLOCATION_DESC{HeapType = .UPLOAD}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER, Width = u64(len(data)) * size_of(T), Height = 1,
        DepthOrArraySize = 1, MipLevels = 1, SampleDesc = {Count = 1}, Layout = .ROW_MAJOR,
    }
    hr := d3d12ma.Allocator_CreateResource(allocator, &props, &desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, &allocation, d3d12.IResource_UUID, nil)
    if hr < 0 { return nil, false }
    resource := d3d12ma.Allocation_GetD3D12Resource(allocation)
    mapped: rawptr
    read_range: d3d12.RANGE
    if resource->Map(0, &read_range, &mapped) < 0 {
        d3d12ma.Allocation_Release(allocation)
        return nil, false
    }
    mem.copy(mapped, raw_data(data), len(data) * size_of(T))
    resource->Unmap(0, nil)
    return allocation, true
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

SceneBLAS :: struct {
    geometry_pool: GeometryPool,
    blas_pool: d3d12ma.Pool,
    blas_list: []d3d12ma.Allocation,
}

// Records one build per mesh in scene order. Keep the pools and mesh buffers
// alive until the GPU has finished using their allocations.
build_scene_blas :: proc(ctx: ^rg.D3D12Context, cmdlist: ^d3d12.IGraphicsCommandList4, scene: ^Scene) -> (result: SceneBLAS, ok: bool) {
    if len(scene.meshes) == 0 { return result, false }
    result.geometry_pool = init_geometry_pool(ctx.allocator)
    desc := d3d12ma.POOL_DESC{HeapProperties = {Type = .DEFAULT}, BlockSize = 64 * 1024 * 1024}
    if d3d12ma.Allocator_CreatePool(ctx.allocator, &desc, &result.blas_pool) < 0 { return result, false }

    result.blas_list = make([]d3d12ma.Allocation, len(scene.meshes))
    for &mesh, i in scene.meshes {
        if !allocate_mesh(ctx.allocator, &result.geometry_pool, &mesh) { return result, false }
        set_allocation_data(&mesh)
        blas, built := rg.build_blas(ctx, cmdlist, mesh.vertex_buffer, u32(len(mesh.vertices) / rg.FLOATS_PER_VERTEX),
                                     mesh.index_buffer, u32(len(mesh.indices)), result.blas_pool)
        if !built { return result, false }
        result.blas_list[i] = blas
    }
    return result, true
}

SceneTLAS :: struct {
    allocation: d3d12ma.Allocation,
}

// Keep the referenced BLAS alive for as long as the GPU uses the TLAS.
build_scene_tlas :: proc(ctx: ^rg.D3D12Context, cmdlist: ^d3d12.IGraphicsCommandList4, scene_blas: ^SceneBLAS) -> (result: SceneTLAS, ok: bool) {
    if len(scene_blas.blas_list) == 0 { return result, false }
    for blas in scene_blas.blas_list {
        if blas == nil { return result, false }
    }
    result.allocation, ok = rg.build_tlas(ctx.device, cmdlist, ctx.allocator, scene_blas.blas_list)
    return result, ok
}
