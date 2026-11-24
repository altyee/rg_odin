package rg

import "core:fmt"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3d12ma "../d3d12ma"
import utils "../utils"


ResourceHandle :: distinct u32

RenderGraph :: struct {
	// Structural Data (Populated during Setup Phase)
	passes: [dynamic]RenderNode,
	resources: [dynamic]ResourceNode,

	// Compiled Execution Order (Populated during Compile Phase)
	sorted_pass_ids: [dynamic]u32,         // The final, safe execution timeline

	// Had to use a pointer here for building descriptor heap in rg_compile
	// descriptor_heap: ^d3d12.IDescriptorHeap,

	// SBT and SBT regions
	// These are specialised structures for RT render passes
	// They may be left empty for raster pipelines
	// sbt_buffer: d3d12ma.Allocation,
	// sbt_regions: SBTRegions,

	// Camera to render to
	// camera_cbv: d3d12ma.Allocation,

	// Present target
	// present_target: ^d3d12.IResource,

	// d12_ctx: ^D3D12Context,
}

// Helper Emum for DFS the graph
DFS_State :: enum u8 {
	Unvisited = 0,
	Visiting = 1,
	Visited = 2,
}

// TODO: Check if name already exist

rg_add_resource :: proc { rg_add_resource_by_desc, rg_add_resource_by_allocation }

rg_add_resource_by_desc :: proc(rg: ^RenderGraph, name: string, desc: d3d12.RESOURCE_DESC) -> ResourceHandle {
    node := ResourceNode {
		name = name,
		desc = desc,
		first_pass_id = INT_MAX,
		last_pass_id = -1,
		allocation = nil,
		srv_cpu_handle = d3d12.CPU_DESCRIPTOR_HANDLE { ptr = 0 },
		uav_cpu_handle = d3d12.CPU_DESCRIPTOR_HANDLE { ptr = 0 },
	}
    append(&rg.resources, node)
    idx := len(rg.resources) - 1
    return ResourceHandle(idx)
}

rg_add_resource_by_allocation :: proc(rg: ^RenderGraph, name: string, allocation: d3d12ma.Allocation) -> ResourceHandle {
    node := ResourceNode {
		name = name,
		first_pass_id = INT_MAX,
		last_pass_id = -1,
		allocation = allocation,
		srv_cpu_handle = d3d12.CPU_DESCRIPTOR_HANDLE { ptr = 0 },
		uav_cpu_handle = d3d12.CPU_DESCRIPTOR_HANDLE { ptr = 0 },
	}
	append(&rg.resources, node)
    idx := len(rg.resources) - 1
    return ResourceHandle(idx)
}

rg_init :: proc(rg: ^RenderGraph, ctx: ^D3D12Context) {

    device := ctx.device
    adapter := ctx.adapter

	// alloc_desc := d3d12ma.ALLOCATOR_DESC {
	// 	Flags = {},
	// 	pDevice = device, // Pointer to your ID3D12Device
	// 	PreferredBlockSize = 0, // 0 = default
	// 	pAllocationCallbacks = nil,
	// 	pAdapter = adapter, // Pointer to your IDXGIAdapter
	// }

	{
		rg.passes = make([dynamic]RenderNode)
		rg.resources = make([dynamic]ResourceNode)
		rg.sorted_pass_ids = make([dynamic]u32)
	}
}

rg_compile :: proc(graph: ^RenderGraph, ctx: ^D3D12Context) -> bool {

    allocator := ctx.allocator
    cmdlist := ctx.cmd_list
    device := ctx.device
    descriptor_heap := ctx.descriptor_heap

	num_nodes := len(graph.passes)
	state_tracker := make([]DFS_State, num_nodes)
	defer delete(state_tracker)
	clear(&graph.sorted_pass_ids)

	// has_cycle (DFS equivalent) on every node
	for i in 0 ..< len(graph.passes) {
		// If not visited, do DFS
		if state_tracker[i] != .Visited {
			if has_cycle(graph, u32(i), &state_tracker) {
				fmt.eprintf("Cycle in Render Graph!")
				return false
			}
		}
	}
	// Reverse sorted pass
	for i in 0 ..< len(graph.sorted_pass_ids) / 2 {
		j := len(graph.sorted_pass_ids) - 1 - i
		graph.sorted_pass_ids[i], graph.sorted_pass_ids[j] = graph.sorted_pass_ids[j], graph.sorted_pass_ids[i]
	}

	fmt.println("Execution order sorted")
	fmt.println(graph.sorted_pass_ids[:])

	// Determine Resource lifetime
	// Assign out of bound first/last pass ids to resources first
	for i in 0 ..< len(graph.resources) {
		graph.resources[i].first_pass_id = INT_MAX
		graph.resources[i].last_pass_id = -1
	}

	// Linear search through sorted pass
	for i in 0 ..< len(graph.sorted_pass_ids) {
		node_id := graph.sorted_pass_ids[i]
		node := &graph.passes[node_id]
		for j in 0 ..< len(node.reads) {
			// Cast back to u32
			read_idx := u32(node.reads[j])
			if graph.resources[read_idx].first_pass_id > i32(i) {
				graph.resources[read_idx].first_pass_id = i32(i)
			}
			if graph.resources[read_idx].last_pass_id < i32(i) {
				graph.resources[read_idx].last_pass_id = i32(i)
			}
		}

		for j in 0 ..< len(node.writes) {
			write_idx := u32(node.writes[j])
			if graph.resources[write_idx].first_pass_id > i32(i) {
				graph.resources[write_idx].first_pass_id = i32(i)
			}
			if graph.resources[write_idx].last_pass_id < i32(i) {
				graph.resources[write_idx].last_pass_id = i32(i)
			}
		}
	}

	fmt.println("Resource lifetime set")

	// ============================================= FIX HERE =============================================
	// Allocate if node is written/read and not allocated
	// for &resource in graph.resources {
	//     if (resource.first_pass_id != INT_MAX || resource.last_pass_id != -1) {
	// 		if (resource.allocation == nil || d3d12ma.Allocation_GetD3D12Resource(resource.allocation) == nil) {
	// 		    allocate_resource(allocator, &resource)
	// 		}
	// 	}
	// }
	// ====================================================================================================

	// fmt.println("Allocated resources")

	// Build descriptor heap
	// TODO: optimise the double loop for checking resource is read/written (add a bool pair in the ResourceNode stuct?)

	// Count Heap size
	descriptor_count := u32(0)

	fmt.printfln("Total number of resources: %d", len(graph.resources))

	for i in 0 ..< len(graph.resources) {
		if resource_is_read_by_any(graph, u32(i)) {
		    fmt.printfln("Resource [%s] determined read by pass node", graph.resources[i].name)
			descriptor_count += 1
		}
		if resource_is_written_by_any(graph, u32(i)) {
		fmt.printfln("Resource [%s] determined written by pass node", graph.resources[i].name)
			descriptor_count += 1
		}
	}

	// Build the actual heap and insert descriptors
	heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        Type = .CBV_SRV_UAV, NumDescriptors = descriptor_count, Flags = {.SHADER_VISIBLE},
    }

	hr := device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&descriptor_heap))
	utils.check(hr, "Failure: CreateDescriptorHeap() in rg_compile")
	descriptor_size := device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)

	fmt.printfln("Created descriptor heap")

	descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
	descriptor_heap->GetCPUDescriptorHandleForHeapStart(&descriptor_handle)

	current_slot := u32(0)

	for &resource, i in graph.resources {
		if resource_is_read_by_any(graph, u32(i)) {
		    fmt.printfln("Init srv on slot %d for node [%s]", current_slot, resource.name)
			if resource.name == "tlas" {
			    init_tlas_srv(&resource, device, descriptor_handle)
			} else {
			    dimension: d3d12.SRV_DIMENSION
				dimension = d3d12.SRV_DIMENSION.TEXTURE2D if resource.desc.Dimension == .TEXTURE2D else d3d12.SRV_DIMENSION.BUFFER
				srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
				    Format = resource.desc.Format,
					ViewDimension = dimension,
					Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
				}
				srv_desc.Texture2D.MostDetailedMip = 0
				srv_desc.Texture2D.MipLevels = 0xFFFFFFFF
				init_srv(&resource, device, &srv_desc, descriptor_handle)
			}
			descriptor_handle.ptr += uint(descriptor_size)
			resource.srv_idx = current_slot
			current_slot += 1
		}
		if resource_is_written_by_any(graph, u32(i)) {
		    fmt.printfln("Init uav on slot %d for node [%s]", current_slot, resource.name)
			{
			    dimension: d3d12.UAV_DIMENSION
			    dimension = d3d12.UAV_DIMENSION.TEXTURE2D if resource.desc.Dimension == .TEXTURE2D else d3d12.UAV_DIMENSION.BUFFER
			    uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC { Format = resource.desc.Format, ViewDimension = dimension }
				init_uav(&resource, device, &uav_desc, descriptor_handle)
			}
			descriptor_handle.ptr += uint(descriptor_size)
			resource.uav_idx = current_slot
			current_slot += 1
		}
	}

	fmt.println("Resource handles created")

	// Invoke init_callback of all in graph render pass nodes
	for pass_idx in graph.sorted_pass_ids {
	    render_node := &graph.passes[pass_idx]
		if render_node.init_callback != nil {
		    render_node.init_callback(device, cmdlist, render_node)
		}
	}

	fmt.println("Pass nodes initiated")

	return true
}

init_tlas_srv :: proc(resource_node: ^ResourceNode, device: ^d3d12.IDevice5, desc_handle: d3d12.CPU_DESCRIPTOR_HANDLE) {
    resource := d3d12ma.Allocation_GetD3D12Resource(resource_node.allocation)

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format                  = .UNKNOWN,
        ViewDimension           = .RAYTRACING_ACCELERATION_STRUCTURE,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.RaytracingAccelerationStructure.Location = resource->GetGPUVirtualAddress()

    device->CreateShaderResourceView(nil, &srv_desc, desc_handle)   // resource must be nil
    resource_node.srv_cpu_handle = desc_handle
}

// Graph Execution
rg_execute :: proc(rg: ^RenderGraph, cmd_list: ^d3d12.IGraphicsCommandList4, command_allocator: ^d3d12.ICommandAllocator) {

    // per frame, inside main_loop, replacing the rasterization draw block:
    hr := command_allocator->Reset()
    utils.check(hr, "Failed resetting command allocator")
    hr = cmd_list->Reset(command_allocator, nil)
    utils.check(hr, "Failed resetting command list")

	for render_node_id in rg.sorted_pass_ids {
		render_node := &rg.passes[render_node_id]
		// In the callback, each node need to set its own pso and rs
		if render_node.execute_callback != nil {
		    render_node.execute_callback(render_node, rg, cmd_list)
		}
	}
}

// Helper functions

has_cycle :: proc(graph: ^RenderGraph, idx: u32, states: ^[]DFS_State) -> bool {
	if states[idx] == .Visiting {
		return true
	}
	if states[idx] == .Visited {
		return false
	}

	// Otherwise start DFS from the idx node
	states[idx] = .Visiting
	// graph.passes[idx] is the reference to this node
	for next_node_idx in &graph.passes[idx].out_edges {
		if has_cycle(graph, next_node_idx, states) {
			return true
		}
	}

	// No loop found, push this node into the sorted execution array (reversed order)
	states[idx] = .Visited
	append(&graph.sorted_pass_ids, idx)
	return false
}

resource_is_written_by_any :: proc(graph: ^RenderGraph, resource_idx: u32) -> bool {
	for node_idx in graph.sorted_pass_ids {
		node := graph.passes[node_idx]
		for write_handle in node.writes {
			if u32(write_handle) == resource_idx {
				return true
			}
		}
	}
	return false
}

resource_is_read_by_any :: proc(graph: ^RenderGraph, resource_idx: u32) -> bool {
	for node_idx in graph.sorted_pass_ids {
		node := graph.passes[node_idx]
		for write_handle in node.reads {
			if u32(write_handle) == resource_idx {
				return true
			}
		}
	}
	return false
}

pass_add_write :: proc(rg: ^RenderGraph, pass_idx: u32, write_name: string) {
    for &resource, idx in rg.resources {
        if resource.name == write_name {
            append(&rg.passes[pass_idx].writes, ResourceHandle(idx))
            // return
        }
    }
}

pass_add_read :: proc(rg: ^RenderGraph, pass_idx: u32, read_name: string) {
    for &resource, idx in rg.resources {
        if resource.name == read_name {
            append(&rg.passes[pass_idx].reads, ResourceHandle(idx))
            // return
        }
    }
}
