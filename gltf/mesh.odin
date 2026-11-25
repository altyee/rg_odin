package gltf

import d3d12ma "../d3d12ma"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import "core:sys/windows"
import "core:mem"
import utils "../utils"

Vertex :: struct {
	coord: [3]f32, // x, y, z
	uv_0: [2]f32, // tex_coord 0
	uv_1: [2]f32, // tex_coord 1
}

Mesh :: struct {
	name: string,
	vertices: []f32, // v_stride = 3 * f32: x, y, z
	normals: []f32, // n_stride = 3 * f32: nx, ny, nz
	uvs: []f32, // uv_stride = 2 * f32: uv0_x, uv0_y, uv1_x, uv1_y
	indices: []u32,
	color: [4]f32, // rgba colour defined in gltf
	emission: [3]f32,
	vertex_buffer: d3d12ma.Allocation,
	index_buffer: d3d12ma.Allocation,
}

GeometryPool :: struct {
    upload: d3d12ma.Pool,
}

init_geometry_pool :: proc(allocator: d3d12ma.Allocator) -> (g_pool: GeometryPool) {
    desc := d3d12ma.POOL_DESC{
        HeapProperties = d3d12.HEAP_PROPERTIES {Type = .UPLOAD},
        BlockSize = 64 * 1024 * 1024,
    }
    hr := d3d12ma.Allocator_CreatePool(allocator, &desc, &g_pool.upload)
    utils.check(hr, "Mesh: Failed creating geometry upload pool")

    return g_pool
}

allocate_mesh :: proc(allocator: d3d12ma.Allocator, pool: ^GeometryPool, m: ^Mesh) -> (ok:bool) {

    v_size := u64(size_of(m.vertices[0]) * len(m.vertices))
    i_size := u64(size_of(m.indices[0]) * len(m.indices))

	alloc_props := d3d12ma.ALLOCATION_DESC{
		Flags = {},
		HeapType = .UPLOAD,
		CustomPool = pool.upload,
		ExtraHeapFlags = {},
		pPrivateData = nil,
	}

	res_desc := d3d12.RESOURCE_DESC{
		Dimension = .BUFFER,
		Alignment = 0,
		Height = 1,
		DepthOrArraySize = 1,
		MipLevels = 1,
		Format = .UNKNOWN,
		SampleDesc = dxgi.SAMPLE_DESC{Count = 1, Quality = 0},
		Layout = .ROW_MAJOR,
		Flags = {},
	}

	res_desc.Width = v_size

	hr := d3d12ma.Allocator_CreateResource(
		allocator,
		&alloc_props,
		&res_desc,
		d3d12.RESOURCE_STATE_GENERIC_READ,
		nil,
		&m.vertex_buffer,
		d3d12.IResource_UUID,
		nil
	)
	utils.check(hr, "Mesh: Failed creating vertex buffer")

	res_desc.Width = i_size

	hr = d3d12ma.Allocator_CreateResource(
		allocator,
		&alloc_props,
		&res_desc,
		d3d12.RESOURCE_STATE_GENERIC_READ,
		nil,
		&m.index_buffer,
		d3d12.IResource_UUID,
		nil
	)
	utils.check(hr, "Mesh: Failed creating index buffer")

	return true
}

set_allocation_data :: proc(m: ^Mesh) {
	v_resource := d3d12ma.Allocation_GetD3D12Resource(m.vertex_buffer)
	vb_size := len(m.vertices) * size_of(f32)
	vb_gpu_data: rawptr
	read_range: d3d12.RANGE
	hr := v_resource->Map(0, &read_range, &vb_gpu_data)
	utils.check(hr, "Failed mapping vertex buffer")
    mem.copy(vb_gpu_data, &m.vertices[0], vb_size)
    v_resource->Unmap(0, nil)

	i_resource := d3d12ma.Allocation_GetD3D12Resource(m.index_buffer)
	ib_size := len(m.indices) * size_of(u32)
	ib_gpu_data: rawptr
    hr = i_resource->Map(0, &read_range, &ib_gpu_data)
    utils.check(hr, "Failed mapping index buffer")
    mem.copy(ib_gpu_data, &m.indices[0], ib_size)
    i_resource->Unmap(0, nil)
}
