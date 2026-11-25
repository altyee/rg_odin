package rg

import d3d12ma "../d3d12ma"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

INT_MAX :: i32(1 << 31 - 1)

// A piece of resource represents a piece of data that is read/written by one or multiple render pass nodes

ResourceKind :: enum {
    Texture,
    Buffer,
    BLAS,
    TLAS,
}

Resource_Desc :: struct {
    kind:       ResourceKind,
    format:     dxgi.FORMAT,
    width: u64,
    height: u32,
    depth, mip_levels: u16,
}

ResourceNode :: struct {
	name: string,
    	desc: d3d12.RESOURCE_DESC,
        kind: ResourceKind,
        element_stride: u32,

    // Graph Compiler Metadata:
    first_pass_id: i32,         // Index of the first pass that uses this
    last_pass_id: i32,          // Index of the last pass that uses this

    // Physical resource pointers
    // Using d3d12 memory allocator to manage allocation
    // https://forum.odin-lang.org/t/chaining-or-else-struct-member-visibility/784
    // "Opaque data structures which must be a pointer are sometimes better treated as just Handle :: distinct rawptr"
    allocation: d3d12ma.Allocation,
    srv_cpu_handle: d3d12.CPU_DESCRIPTOR_HANDLE,
    uav_cpu_handle: d3d12.CPU_DESCRIPTOR_HANDLE,
    // GPU visible index for locating the descriptor in the global heap
    srv_idx: u32,
    uav_idx: u32,
}

allocate_resource :: proc(allocator: d3d12ma.Allocator, resource: ^ResourceNode) {
	// Allocate physical resource through d3d12ma
	alloc_props := d3d12ma.ALLOCATION_DESC{
		Flags = {},
		HeapType = .DEFAULT,
		ExtraHeapFlags = {},
		CustomPool = nil,
		pPrivateData = nil,
	}
	// VERTEX_AND_CONSTANT_BUFFER shares the prop value with .COMMON (?)
	d3d12ma.Allocator_CreateResource(allocator, &alloc_props, &resource.desc, {}, nil, &resource.allocation, d3d12.IResource_UUID, nil)
}

init_srv :: proc(resource_node: ^ResourceNode, device: ^d3d12.IDevice5, srv_desc: ^d3d12.SHADER_RESOURCE_VIEW_DESC, desc_handle: d3d12.CPU_DESCRIPTOR_HANDLE) {
	// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-createshaderresourceview
	// A null pDesc is used to initialize a default descriptor, if possible.
	// This behavior is identical to the D3D11 null descriptor behavior,
	// where defaults are filled in. This behavior inherits the resource format
	// and dimension (if not typeless) and for buffers SRVs
	// target a full buffer and are typed (not raw or structured),
	// and for textures SRVs target a full texture, all mips and all array slices.
	// Not all resources support null descriptor initialization.
	resource := d3d12ma.Allocation_GetD3D12Resource(resource_node.allocation)
	device->CreateShaderResourceView(resource, srv_desc, desc_handle)
	resource_node.srv_cpu_handle = desc_handle
}

init_uav :: proc(resource_node: ^ResourceNode, device: ^d3d12.IDevice5, uav_desc: ^d3d12.UNORDERED_ACCESS_VIEW_DESC, desc_handle: d3d12.CPU_DESCRIPTOR_HANDLE) {
	resource := d3d12ma.Allocation_GetD3D12Resource(resource_node.allocation)
	// 2nd argument: The ID3D12Resource for the counter (if any) associated with the UAV.
	// Set to nil for now
	device->CreateUnorderedAccessView(resource, nil, uav_desc, desc_handle)
	resource_node.uav_cpu_handle = desc_handle
}

// Pipeline_State :: union {
//     ^d3d12.IPipelineState,  // For Graphics and Compute
//     ^d3d12.IStateObject,    // For Raytracing (DXR)
// }

// A pass node can be a compute, rt, or raster node
RenderNode :: struct {
	// Dependency Tracking:
    reads: [dynamic]ResourceHandle,
    writes: [dynamic]ResourceHandle,

    // Edges (next nodes)
    out_edges: [dynamic]u32,

    // PSO and RS
    pso: ^d3d12.IStateObject,
    // ps_rt: ^d3d12.IPipelineState,
    sbt_buffer: d3d12ma.Allocation,
    sbt_regions: SBTRegions,
    root_signature: ^d3d12.IRootSignature,

    // Initialization Hook, compile shaders etc.
    init_callback: proc(^RenderNode, ^D3D12Context),

    // Execution Hook:
    // A procedure pointer that knows how to record the actual DX12 draw commands
    execute_callback: proc(^RenderNode, ^RenderGraph, ^D3D12Context),
}

// create_render_node :: proc() -> RenderNode {
//     node := RenderNode {
//         reads = make([dynamic]ResourceHandle),
//         writes = make([dynamic]ResourceHandle),
//         out_edges = make([dynamic]u32),
//     }
//     return node
// }

// create_rt_render_node :: proc(rt_shader_path: string) {

// }
