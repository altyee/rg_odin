package rtsample

import rg "../rg"
import dxc "../dxc_compile"
import d3d12ma "../d3d12ma"

import gltf "../gltf"
import sdl "vendor:sdl3"
import "core:fmt"
import "vendor:directx/dxgi"
import d3d12 "vendor:directx/d3d12"

create_output_texture :: proc(graph: ^rg.RenderGraph, ctx: ^rg.D3D12Context) -> (rg.ResourceHandle, bool) {
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = 1920, Height = 1080,
        DepthOrArraySize = 1, MipLevels = 1,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Layout = .UNKNOWN,
        Flags = {.ALLOW_UNORDERED_ACCESS},
    }
    allocation: d3d12ma.Allocation
    props := d3d12ma.ALLOCATION_DESC{HeapType = .DEFAULT}
    hr := d3d12ma.Allocator_CreateResource(ctx.allocator, &props, &desc, {.UNORDERED_ACCESS}, nil, &allocation, d3d12.IResource_UUID, nil)
    if hr < 0 { return 0, false }
    return rg.rg_add_resource(graph, "rt_output", allocation), true
}

transition :: proc(resource: ^d3d12.IResource, before, after: d3d12.RESOURCE_STATES) -> d3d12.RESOURCE_BARRIER {
    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {pResource = resource, Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                          StateBefore = before, StateAfter = after}
    return barrier
}

copy_to_back_buffer :: proc(node: ^rg.RenderNode, graph: ^rg.RenderGraph, ctx: ^rg.D3D12Context) {
    src := d3d12ma.Allocation_GetD3D12Resource(graph.resources[node.reads[0]].allocation)
    dst := ctx.targets[ctx.swapchain->GetCurrentBackBufferIndex()]
    // PRESENT is the zero-valued D3D12 resource state.
    before := [2]d3d12.RESOURCE_BARRIER{transition(src, {.UNORDERED_ACCESS}, {.COPY_SOURCE}), transition(dst, {}, {.COPY_DEST})}
    after := [2]d3d12.RESOURCE_BARRIER{transition(src, {.COPY_SOURCE}, {.UNORDERED_ACCESS}), transition(dst, {.COPY_DEST}, {})}
    ctx.cmd_list->ResourceBarrier(2, &before[0])
    ctx.cmd_list->CopyResource(dst, src)
    ctx.cmd_list->ResourceBarrier(2, &after[0])
}

init_rt_bindings :: proc(node: ^rg.RenderNode, ctx: ^rg.D3D12Context) {
    node.root_signature = get_rs(ctx.device, 6) // TLAS, output, mesh colors, face normals, triangle offsets, lights
    dxil, compiled := dxc.dxc_compile_from_path("./shaders/rt.hlsl", "", "lib_6_6")
    if !compiled { panic("Failed to compile rt.hlsl") }
    node.pso, compiled = rg.create_rt_pso(ctx.device, dxil, node.root_signature)
    if !compiled { panic("Failed to create RT pipeline") }
    node.sbt_buffer, node.sbt_regions, compiled = rg.create_shader_binding_table(cast(^d3d12.IDevice)ctx.device, node.pso, ctx.allocator)
    if !compiled { panic("Failed to create RT shader table") }
}

execute_rt_pass :: proc(node: ^rg.RenderNode, graph: ^rg.RenderGraph, ctx: ^rg.D3D12Context) {
    lights_srv := u32(0xffff_ffff)
    if len(node.reads) > 4 {
        lights_srv = graph.resources[node.reads[4]].srv_idx
    }
    indices := [6]u32{
        graph.resources[node.reads[0]].srv_idx,
        graph.resources[node.writes[0]].uav_idx,
        graph.resources[node.reads[1]].srv_idx,
        graph.resources[node.reads[2]].srv_idx,
        graph.resources[node.reads[3]].srv_idx,
        lights_srv,
    }
    ctx.cmd_list->SetPipelineState1(node.pso)
    ctx.cmd_list->SetComputeRootSignature(node.root_signature)
    ctx.cmd_list->SetComputeRoot32BitConstants(0, len(indices), &indices[0], 0)
    if ctx.camera_cbv != nil {
        camera := d3d12ma.Allocation_GetD3D12Resource(ctx.camera_cbv)
        ctx.cmd_list->SetComputeRootConstantBufferView(1, camera->GetGPUVirtualAddress())
    }
    sbt := node.sbt_regions
    output := graph.resources[node.writes[0]].desc
    dispatch := d3d12.DISPATCH_RAYS_DESC{
        RayGenerationShaderRecord = {sbt.raygen_address, sbt.raygen_size},
        MissShaderTable = {sbt.miss_address, sbt.miss_size, sbt.miss_stride},
        HitGroupTable = {sbt.hitgroup_address, sbt.hitgroup_size, sbt.hitgroup_stride},
        Width = u32(output.Width), Height = output.Height, Depth = 1,
    }
    ctx.cmd_list->DispatchRays(&dispatch)
}

main :: proc() {

    if !sdl.Init({.VIDEO}) {
        fmt.panicf("Failed to init SDL: %s", sdl.GetError())
    }
    defer sdl.Quit()

    window := init_sdl_window(1920, 1080)

    prop := sdl.GetWindowProperties(window)
    window_handle := cast(dxgi.HWND)sdl.GetPointerProperty(prop, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)

    ctx: rg.D3D12Context
    rg.init_render_context(&ctx, window_handle, 1920, 1080)

    graph: rg.RenderGraph
    rg.rg_init(&graph, &ctx)

    // Load gltf
    scene, gltf_ok := gltf.load_gltf_scene("./assets/cornell_box_core.glb")

    if !gltf_ok { return }
    if !scene.camera.found { panic("Ray generation requires a scene camera") }
    ctx.camera_cbv = gltf.create_camera_buffer(ctx.allocator, scene.camera, 1920.0 / 1080.0)

    if ctx.cmd_list->Reset(ctx.cmd_allocator, nil) < 0 { panic("Failed to open scene setup command list") }
    scene_blas, ok := gltf.build_scene_blas(&ctx, ctx.cmd_list, &scene)
    if !ok { return }
    scene_tlas, tlas_ok := gltf.build_scene_tlas(&ctx, ctx.cmd_list, &scene_blas)
    if !tlas_ok { return }

    // Render graph construction
    tlas_resource := rg.rg_add_resource(&graph, "tlas", scene_tlas.allocation, kind = .TLAS)

    mesh_colors, colors_ok := gltf.create_mesh_color_buffer(&scene, ctx.allocator)
    if !colors_ok { return }
    mesh_colors_resource := rg.rg_add_resource(&graph, "mesh_colors", mesh_colors, kind = .Buffer, element_stride = size_of(gltf.MeshColor))

    normals, offsets, normals_ok := gltf.create_face_normal_buffers(&scene, ctx.allocator)
    if !normals_ok { return }
    normals_resource := rg.rg_add_resource(&graph, "face_normals", normals, kind = .Buffer, element_stride = size_of([4]f32))
    offsets_resource := rg.rg_add_resource(&graph, "triangle_offsets", offsets, kind = .Buffer, element_stride = size_of(u32))


    output_texture, texture_ok := create_output_texture(&graph, &ctx)
    if !texture_ok { return }
    rt_pass := rg.RenderNode{init_callback = init_rt_bindings, execute_callback = execute_rt_pass}
    append(&rt_pass.reads, tlas_resource)
    append(&rt_pass.reads, mesh_colors_resource)
    append(&rt_pass.reads, normals_resource)
    append(&rt_pass.reads, offsets_resource)
    lights, lights_ok := gltf.create_light_triangle_buffer(&scene, ctx.allocator)
    if !lights_ok { return }
    if lights != nil {
        lights_resource := rg.rg_add_resource(&graph, "light_triangles", lights, kind = .Buffer, element_stride = size_of(gltf.LightTriangle))
        append(&rt_pass.reads, lights_resource)
    }

    append(&rt_pass.writes, output_texture)
    rt_pass_id := len(graph.passes)
    append(&graph.passes, rt_pass)

    copy_pass := rg.RenderNode{execute_callback = copy_to_back_buffer}
    append(&copy_pass.reads, output_texture)
    copy_pass_id := u32(len(graph.passes))
    append(&graph.passes, copy_pass)
    append(&graph.passes[rt_pass_id].out_edges, copy_pass_id)
    if !rg.rg_compile(&graph, &ctx) { return }

    fence: ^d3d12.IFence
    if ctx.device->CreateFence(0, {}, d3d12.IFence_UUID, (^rawptr)(&fence)) < 0 { panic("Failed to create submission fence") }
    defer fence->Release()
    // rg_execute resets the same allocator used for the scene builds.
    submit_and_wait(&ctx, fence, 1)
    fence_value := u64(1)
    for {
        for event: sdl.Event; sdl.PollEvent(&event); {
            if event.type == .QUIT { return }
        }
        rg.rg_execute(&graph, &ctx)
        fence_value += 1
        submit_and_wait(&ctx, fence, fence_value)
        if ctx.swapchain->Present(1, {}) < 0 { panic("Failed to present sample frame") }
    }
}

submit_and_wait :: proc(ctx: ^rg.D3D12Context, fence: ^d3d12.IFence, value: u64) {
    if ctx.cmd_list->Close() < 0 { panic("Failed to close command list") }
    list := cast(^d3d12.ICommandList)ctx.cmd_list
    ctx.cmd_queue->ExecuteCommandLists(1, &list)
    if ctx.cmd_queue->Signal(fence, value) < 0 { panic("Failed to signal submission fence") }
    // A null event makes SetEventOnCompletion wait synchronously.
    if fence->SetEventOnCompletion(value, nil) < 0 { panic("Failed to wait for submission") }
}

get_rs :: proc(device: ^d3d12.IDevice5, dwords: u32) -> ^d3d12.IRootSignature {
    params := [2]d3d12.ROOT_PARAMETER1{}
    params[0].ParameterType = ._32BIT_CONSTANTS
    params[0].Constants = {ShaderRegister = 0, RegisterSpace = 0, Num32BitValues = dwords}
    params[0].ShaderVisibility = .ALL

    params[1].ParameterType = .CBV
    params[1].Descriptor = {ShaderRegister = 1, RegisterSpace = 0, Flags = {}}
    params[1].ShaderVisibility = .ALL

    desc := d3d12.ROOT_SIGNATURE_DESC1{
        NumParameters = len(params),
        pParameters   = &params[0],
        NumStaticSamplers = 0,
        pStaticSamplers   = nil,
        Flags = {.CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED},
    }

    versioned_desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC{
        Version = ._1_1,
        Desc_1_1 = desc,
    }

    blob, err_blob: ^d3d12.IBlob
    hr := d3d12.SerializeVersionedRootSignature(&versioned_desc, &blob, &err_blob)
    if hr < 0 {
        if err_blob != nil {
            fmt.eprintln(cstring(err_blob->GetBufferPointer()))
        }
        panic("root signature serialization failed")
    }
    defer blob->Release()

    rs: ^d3d12.IRootSignature
    hr = device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                        d3d12.IRootSignature_UUID, (^rawptr)(&rs))
    if hr < 0 {
        fmt.eprintf("CreateRootSignature failed with HRESULT: 0x%X\n", u32(hr))
        reason := device->GetDeviceRemovedReason()
        fmt.printf("device removed reason: 0x%x\n", u32(reason))
        panic("CreateRootSignature assertion failed")
    }
    return rs
}
