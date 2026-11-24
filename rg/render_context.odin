package rg

import "core:fmt"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import sdl "vendor:sdl3"
import d3d12ma "../d3d12ma"
import utils "../utils"

NUM_RENDERTARGETS :: 2

D3D12Context :: struct {
    adapter: ^dxgi.IAdapter1,
    device: ^d3d12.IDevice5,
    swapchain: ^dxgi.ISwapChain3,
    cmd_queue: ^d3d12.ICommandQueue,
    cmd_allocator: ^d3d12.ICommandAllocator,
    cmd_list: ^d3d12.IGraphicsCommandList4,
    allocator: d3d12ma.Allocator,
    descriptor_heap: ^d3d12.IDescriptorHeap,
    rtv_descriptor_heap: ^d3d12.IDescriptorHeap,
    targets: [NUM_RENDERTARGETS]^d3d12.IResource,
    camera_cbv: d3d12ma.Allocation,
    present_target: ^d3d12.IResource,
}

init_render_context :: proc(ctx: ^D3D12Context, window_handle: dxgi.HWND, wx: u32, wy: u32) -> () {
    hr: d3d12.HRESULT

    factory: ^dxgi.IFactory4
    {
        flags: dxgi.CREATE_FACTORY = {}
        when ODIN_DEBUG {
            flags += {.DEBUG}
        }
        hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, cast(^rawptr)&factory)
        utils.check(hr, "Failed creating factory")
    }

    // adapter: ^dxgi.IAdapter1
    error_not_found := dxgi.HRESULT(-142213123)

    for i: u32 = 0; factory->EnumAdapters1(i, &ctx.adapter) != error_not_found; i += 1 {
        desc: dxgi.ADAPTER_DESC1
        ctx.adapter->GetDesc1(&desc)
        if .SOFTWARE in desc.Flags {
            continue
        }

        if d3d12.CreateDevice((^dxgi.IUnknown)(ctx.adapter), ._12_0, dxgi.IDevice_UUID, nil) >= 0 {
            break
        } else {
            fmt.println("Failed to create device")
        }
    }

    when ODIN_DEBUG {
        debug: ^d3d12.IDebug
        if d3d12.GetDebugInterface(d3d12.IDebug_UUID, (^rawptr)(&debug)) >= 0 {
            debug->EnableDebugLayer()
            debug->Release()
        }
    }

    // device: ^d3d12.IDevice5
    hr = d3d12.CreateDevice((^dxgi.IUnknown)(ctx.adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&ctx.device))
    utils.check(hr, "Failed to create device")

    when ODIN_DEBUG {
        info_queue: ^d3d12.IInfoQueue
        hr = device->QueryInterface(d3d12.IInfoQueue_UUID, (^rawptr)(&info_queue))
        check(hr, "Failed to create debug info queue")
        info_queue->SetBreakOnSeverity(.CORRUPTION, true)
        info_queue->SetBreakOnSeverity(.ERROR, true)
    }

    // queue: ^d3d12.ICommandQueue
    {
        desc := d3d12.COMMAND_QUEUE_DESC {
            Type = .DIRECT,
        }

        hr = ctx.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&ctx.cmd_queue))
        utils.check(hr, "Failed creating command queue")
    }

    // swapchain: ^dxgi.ISwapChain3
    {
        desc := dxgi.SWAP_CHAIN_DESC1 {
            Width = u32(wx),
            Height = u32(wy),
            Format = .R16G16B16A16_FLOAT,
            SampleDesc = { Count = 1, Quality = 0 },
            BufferUsage = {.RENDER_TARGET_OUTPUT},
            BufferCount = NUM_RENDERTARGETS,
            Scaling = .NONE,
            SwapEffect = .FLIP_DISCARD,
            AlphaMode = .UNSPECIFIED,
        }
        hr = factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(ctx.cmd_queue), window_handle, &desc, nil, nil, (^^dxgi.ISwapChain1)(&ctx.swapchain))
        utils.check(hr, "Failed to create swap chain")
    }

    // command_allocator: ^d3d12.ICommandAllocator
    hr = ctx.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&ctx.cmd_allocator))
    utils.check(hr, "Failed creating command allocator")

    cmdlist: ^d3d12.IGraphicsCommandList
    hr = ctx.device->CreateCommandList(0, .DIRECT, ctx.cmd_allocator, nil, d3d12.ICommandList_UUID, (^rawptr)(&cmdlist))
    utils.check(hr, "Failed to create command list")
    hr = cmdlist->Close()
    utils.check(hr, "Failed to close command list")
    // cmdlist4: ^d3d12.IGraphicsCommandList4
    hr = cmdlist->QueryInterface(d3d12.IGraphicsCommandList4_UUID, (^rawptr)(&ctx.cmd_list))
    utils.check(hr, "Failed to query IGraphicsCommandList4")

    // allocator: d3d12ma.Allocator
    // defer d3d12ma.Allocator_Release(allocator)
    {
        alloc_desc := d3d12ma.ALLOCATOR_DESC{
            Flags = {},
            pDevice = rawptr(ctx.device),
            pAdapter = rawptr(ctx.adapter),
            PreferredBlockSize = 0, // 0 defaults to the library standard (usually 64MB or 256MB clusters)
            pAllocationCallbacks = nil,
        }
        hr = d3d12ma.CreateAllocator(&alloc_desc, &ctx.allocator)
        utils.check(hr, "Failed creating allocator")
    }

    // rtv_descriptor_heap: ^d3d12.IDescriptorHeap
    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = NUM_RENDERTARGETS,
            Type = .RTV,
            Flags = {},
        }
        hr = ctx.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&ctx.rtv_descriptor_heap))
        utils.check(hr, "Failed creating RTV descriptor heap")
    }

    // targets: [NUM_RENDERTARGETS]^d3d12.IResource
    {
        rtv_descriptor_size: u32 = ctx.device->GetDescriptorHandleIncrementSize(.RTV)
        rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        ctx.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

        for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
            hr = ctx.swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&ctx.targets[i]))
            utils.check(hr, "Failed getting render target")
            ctx.device->CreateRenderTargetView(ctx.targets[i], nil, rtv_descriptor_handle)
            rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
        }
    }
}

release_render_context :: proc(ctx: ^D3D12Context) {
    // Resources
    if ctx.present_target != nil {
        ctx.present_target->Release()
        ctx.present_target = nil
    }

    // Allocations go before the allocator that owns them
    if ctx.camera_cbv != nil {
        d3d12ma.Allocation_Release(ctx.camera_cbv) // see note 2
        ctx.camera_cbv = nil
    }

    // Swapchain back buffers must be released before the swapchain
    for i in 0..<NUM_RENDERTARGETS {
        if ctx.targets[i] != nil {
            ctx.targets[i]->Release()
            ctx.targets[i] = nil
        }
    }

    // Descriptor heaps
    if ctx.rtv_descriptor_heap != nil {
        ctx.rtv_descriptor_heap->Release()
        ctx.rtv_descriptor_heap = nil
    }
    if ctx.descriptor_heap != nil {
        ctx.descriptor_heap->Release()
        ctx.descriptor_heap = nil
    }

    // Command objects: list, then allocator, then queue
    if ctx.cmd_list != nil {
        ctx.cmd_list->Release()
        ctx.cmd_list = nil
    }
    if ctx.cmd_allocator != nil {
        ctx.cmd_allocator->Release()
        ctx.cmd_allocator = nil
    }
    if ctx.cmd_queue != nil {
        ctx.cmd_queue->Release()
        ctx.cmd_queue = nil
    }

    if ctx.swapchain != nil {
        ctx.swapchain->Release()
        ctx.swapchain = nil
    }

    // Memory allocator must go before the device
    if ctx.allocator != nil {
        d3d12ma.Allocator_Release(ctx.allocator) // see note 2
        ctx.allocator = nil
    }

    if ctx.device != nil {
        ctx.device->Release()
        ctx.device = nil
    }
    if ctx.adapter != nil {
        ctx.adapter->Release()
        ctx.adapter = nil
    }
}
