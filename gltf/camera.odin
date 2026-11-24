package gltf

import d3d12ma "../d3d12ma"
import d3d12 "vendor:directx/d3d12"
import "core:mem"
import "core:math"
import utils "../utils"

Camera_CB :: struct {
    position: [4]f32, // xyz, w = tan(yfov/2)
    forward:  [4]f32, // xyz, w = aspect
    right:    [4]f32,
    up:       [4]f32,
}

create_camera_buffer :: proc(allocator: d3d12ma.Allocator, cam: GltfCamera, aspect: f32) -> (alloc: d3d12ma.Allocation) {
    alloc_desc := d3d12ma.ALLOCATION_DESC{ HeapType = .UPLOAD }
    desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER, Width = 256, Height = 1,
        DepthOrArraySize = 1, MipLevels = 1, Format = .UNKNOWN,
        SampleDesc = {Count = 1, Quality = 0}, Layout = .ROW_MAJOR,
    }
    hr := d3d12ma.Allocator_CreateResource(allocator, &alloc_desc, &desc,
        d3d12.RESOURCE_STATE_GENERIC_READ, nil, &alloc, d3d12.IResource_UUID, nil)
    utils.check(hr, "Failed creating camera buffer")

    data := Camera_CB{
        position = {cam.position.x, cam.position.y, cam.position.z, math.tan(cam.yfov * 0.5)},
        forward  = {cam.forward.x,  cam.forward.y,  cam.forward.z,  aspect},
        right    = {cam.right.x,    cam.right.y,    cam.right.z,    0},
        up       = {cam.up.x,       cam.up.y,       cam.up.z,       0},
    }

    res := d3d12ma.Allocation_GetD3D12Resource(alloc)
    mapped: rawptr
    read_range: d3d12.RANGE
    hr = res->Map(0, &read_range, &mapped)
    utils.check(hr, "Failed mapping camera buffer")
    mem.copy(mapped, &data, size_of(data))
    res->Unmap(0, nil)
    return
}
