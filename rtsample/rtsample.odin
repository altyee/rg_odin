package rtsample

import rg "../rg"
import gltf "../gltf"
import sdl "vendor:sdl3"
import "core:fmt"
import "vendor:directx/dxgi"

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

    // Geo pool
    geo_pool := gltf.init_geometry_pool(ctx.allocator)
    for &mesh in scene.meshes {
        gltf.allocate_mesh(ctx.allocator, &geo_pool, &mesh)
    }

    // Resources: Vertex/Index/Instance Buffer, BLAS, TLAS
    vertex_buffer, index_buffer, instance_buffer, v_count, i_count, buffer_ok := gltf.create_global_geometry_buffers(&scene, &ctx)
    blas_list, _ := rg.build_blas()
}
