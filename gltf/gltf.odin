package gltf

import cgltf "vendor:cgltf"
import "core:math/linalg"
import "core:math"
import "core:fmt"

FLOATS_PER_VERTEX :: 3
FLOATS_PER_NORMAL :: 3

GltfCamera :: struct {
    position: [3]f32,
    forward:  [3]f32,
    right:    [3]f32,
    up:       [3]f32,
    yfov:     f32,
    found:    bool,
}

Scene :: struct {
    meshes: []Mesh,
    camera: GltfCamera,
}

// Call this alongside walk_node during load_gltf_scene, or fold the camera
// check directly into walk_node's existing node.mesh != nil branch:
extract_camera_from_node :: proc(node: ^cgltf.node, world: matrix[4,4]f32, camera: ^GltfCamera) {
    if node.camera == nil {
        return
    }
    if node.camera.type != .perspective {
        return // only handling perspective cameras for now
    }

    // Camera looks down -Z in its own local space (glTF convention);
    // world-transform that basis to get the real view direction.
    world_forward := (world * [4]f32{0, 0, -1, 0}).xyz
    world_up       := (world * [4]f32{0, 1, 0, 0}).xyz
    world_right     := (world * [4]f32{1, 0, 0, 0}).xyz
    world_pos       := (world * [4]f32{0, 0, 0, 1}).xyz

    camera.position = world_pos
    camera.forward  = linalg.normalize(world_forward)
    camera.up       = linalg.normalize(world_up)
    camera.right    = linalg.normalize(world_right)
    camera.yfov     = node.camera.data.perspective.yfov
    camera.found    = true
}

// Loads every mesh primitive reachable from the glTF's default scene,
// flattening the node hierarchy (applying each node's world transform to
// its vertex positions) into a simple list of drawable meshes.
load_gltf_scene :: proc(path: cstring) -> (scene: Scene, ok: bool) {
    options: cgltf.options
    // data: ^cgltf.data
    data, result := cgltf.parse_file(options, path)
    if result != .success {
        return {}, false
    }
    defer cgltf.free(data)

    result = cgltf.load_buffers(options, data, path)
    if result != .success {
        return {}, false
    }

    if data.scene == nil {
        // No default scene declared — fall back to the first one, if any.
        if len(data.scenes) == 0 {
            return {}, false
        }
    }
    root_scene := data.scene != nil ? data.scene : &data.scenes[0]

    meshes: [dynamic]Mesh
    for node in root_scene.nodes {
   		walk_node(node, linalg.MATRIX4F32_IDENTITY, &meshes, &scene.camera)
    }

    scene.meshes = meshes[:]

    return scene, true
}

free_scene :: proc(scene: ^Scene) {
    for mesh in scene.meshes {
        delete(mesh.vertices)
        delete(mesh.indices)
    }
    delete(scene.meshes)
}

walk_node :: proc(node: ^cgltf.node, parent_transform: matrix[4,4]f32, meshes: ^[dynamic]Mesh, camera: ^GltfCamera) {
    local := node_local_matrix(node)
    world := parent_transform * local

    if node.mesh != nil {
        for primitive in node.mesh.primitives {
            mesh, mesh_ok := extract_primitive(primitive, world)
            if mesh_ok {
                mesh.name = node.name != "" ? string(node.name) : "unnamed"
                append(meshes, mesh)
            }
        }
    }

    extract_camera_from_node(node, world, camera) // <-- added here, same world transform

    for child in node.children {
        walk_node(child, world, meshes, camera) // <-- camera threaded through recursion too
    }
}

// Computes a node's local transform, handling both the "matrix" form and
// the decomposed TRS (translation/rotation/scale) form glTF allows.
node_local_matrix :: proc(node: ^cgltf.node) -> matrix[4,4]f32 {
	if node.has_matrix {
        m := node.matrix_
        return matrix[4,4]f32{
            m[0], m[4], m[8],  m[12],
            m[1], m[5], m[9],  m[13],
            m[2], m[6], m[10], m[14],
            m[3], m[7], m[11], m[15],
        }
    }

    t := linalg.matrix4_translate_f32({node.translation[0], node.translation[1], node.translation[2]})
    r := linalg.matrix4_from_quaternion_f32(quaternion(
        x = node.rotation[0], y = node.rotation[1],
        z = node.rotation[2], w = node.rotation[3],
    ))
    s := linalg.matrix4_scale_f32({node.scale[0], node.scale[1], node.scale[2]})
    return t * r * s
}

// Reads POSITION/NORMAL/indices for one primitive and bakes the node's
// world transform into the positions, so the renderer never has to think
// about hierarchy — every Mesh it receives is already in world space.
extract_primitive :: proc(primitive: cgltf.primitive, world: matrix[4,4]f32) -> (mesh: Mesh, ok: bool) {
    pos_accessor: ^cgltf.accessor
    normal_accessor: ^cgltf.accessor
    uv_accessor: ^cgltf.accessor

    for attrib in primitive.attributes {
        if attrib.type == .position {
            pos_accessor = attrib.data
        } else if attrib.type == .normal {
            normal_accessor = attrib.data
        } else if attrib.type == .texcoord {
        	uv_accessor = attrib.data
        }
    }
    if pos_accessor == nil {
        return {}, false
    }

    // Extract vertices pos and normals
    vertex_count := int(pos_accessor.count)
    vertices := make([]f32, vertex_count * FLOATS_PER_VERTEX)

    // Transforming Normals: A Detailed Examination
    // https://www.scratchapixel.com/lessons/mathematics-physics-for-computer-graphics/geometry//transforming-normals.html
    normal_world := linalg.matrix4_inverse_transpose_f32(world)

    normals := make([]f32, vertex_count * FLOATS_PER_NORMAL)

    for i in 0 ..< vertex_count {
        p: [3]f32
        _ = cgltf.accessor_read_float(pos_accessor, uint(i), &p[0], 3)
        world_pos := world * [4]f32{p.x, p.y, p.z, 1}

        base := i * FLOATS_PER_VERTEX
        vertices[base + 0] = world_pos.x
        vertices[base + 1] = world_pos.y
        vertices[base + 2] = world_pos.z

        // color: [4]f32 = {1, 1, 1, 0}
        if normal_accessor != nil {
            n: [3]f32
            if cgltf.accessor_read_float(normal_accessor, uint(i), &n[0], 3) {
                world_n := (normal_world * [4]f32{n.x, n.y, n.z, 0}).xyz
            //     world_n = linalg.normalize(world_n)
            //     color = { world_n.x * 0.5 + 0.5, world_n.y * 0.5 + 0.5, world_n.z * 0.5 + 0.5, 0 }
	           	base_n := i * FLOATS_PER_NORMAL
	            normals[base_n + 0] = world_n.x
	            normals[base_n + 1] = world_n.y
	            normals[base_n + 2] = world_n.z
            }
        }
    }

    // Extract indices
    indices: []u32
    if primitive.indices != nil {
        idx_accessor := primitive.indices
        index_count := int(idx_accessor.count)
        indices = make([]u32, index_count)
        for i in 0 ..< index_count {
            v: u32
            _ = cgltf.accessor_read_uint(idx_accessor, uint(i), &v, 1)
            indices[i] = v
        }
    } else {
        // No index buffer in the source — synthesize a trivial 0..N one so
        // the renderer can always assume indexed draws.
        indices = make([]u32, vertex_count)
        for i in 0 ..< vertex_count {
            indices[i] = u32(i)
        }
    }

    // Set data
    mesh.vertices = vertices
    mesh.indices = indices
    mesh.normals = normals

    mesh.color = extract_material_color(primitive)

    return mesh, true
}

extract_material_color :: proc(primitive: cgltf.primitive) -> [4]f32 {
    if primitive.material == nil {
        return {1, 1, 1, 1}
    }
    pbr := primitive.material.pbr_metallic_roughness
    return {
        pbr.base_color_factor[0],
        pbr.base_color_factor[1],
        pbr.base_color_factor[2],
        pbr.base_color_factor[3],
    }
}
