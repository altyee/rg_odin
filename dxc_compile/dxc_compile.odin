package dxc_compile
import "core:fmt"
import "core:mem"
import d3d12 "vendor:directx/d3d12"
import dxc "vendor:directx/dxc"
import "core:sys/windows"
import "core:os"

// Loads an HLSL file from disk and returns it as a string.
// The caller is responsible for freeing the string data when done using `delete(content)`.
load_hlsl_file :: proc(file_path: string) -> (content: string, ok: bool) {
	// 1. Read the raw bytes from the file system
	data, err := os.read_entire_file_from_path(file_path, context.allocator)
	if err != nil {
		fmt.eprintf("Error: Failed to open or read HLSL file at path: '%s'\n", file_path)
		return "", false
	}

	// 2. Cast the raw byte array ([]u8) directly into an Odin string
	// In Odin, a string is structurally just a slice of bytes under the hood,
	// so this conversion is safe and instant.
	content = string(data)
	return content, true
}

dxc_compile_from_path :: proc(shader_path: string, entry_point: string, target_profile: string) -> (dxil_bytecode: []u8, OK: bool) {
	shader_source, load_ok := load_hlsl_file(shader_path)
	if !load_ok {
		fmt.printf("Aborting test: Could not load the shader file from disk.")
		return nil, false
	}
	defer delete(shader_source)

	shader_bytes, compile_ok := compile_dxr_library(shader_source, entry_point, target_profile)
	return shader_bytes, compile_ok
}

// Compiles an HLSL source string containing multiple shader exports
// (raygeneration/closesthit/miss) into a DXIL library blob, using DXC.
// This replaces d3dc.Compile (FXC) for DXR shaders, which FXC cannot target.
compile_dxr_library_rs :: proc(source: string, entry_point: string, target_profile: string) -> (dxil_bytecode: []u8, rootsig_blob: []u8, OK: bool) {
    compiler3: ^dxc.ICompiler3
    hr := dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler3_UUID, &compiler3)
    if hr < 0 { return nil, nil, false }
    defer compiler3->Release()

    utils: ^dxc.IUtils
    hr = dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, &utils)
    if hr < 0 { return nil, nil, false }
    defer utils->Release()

    include_handler: ^dxc.IIncludeHandler
    hr = utils->CreateDefaultIncludeHandler(&include_handler)
    if hr < 0 { return nil, nil, false }
    defer include_handler->Release()

    entry_w: windows.wstring = nil
    if entry_point != "" {
        entry_w = windows.utf8_to_wstring(entry_point)
    }
    profile_w := windows.utf8_to_wstring(target_profile)

    compiler_args: ^dxc.ICompilerArgs
    hr = utils->BuildArguments(nil, entry_w, profile_w, nil, 0, nil, 0, &compiler_args)
    if hr < 0 { return nil, nil, false }
    defer compiler_args->Release()

    source_buffer := dxc.Buffer{
        Ptr      = raw_data(source),
        Size     = len(source),
        Encoding = dxc.CP_UTF8,
    }

    result: ^dxc.IResult
    hr = compiler3->Compile(
        &source_buffer,
        compiler_args->GetArguments(),
        compiler_args->GetCount(),
        include_handler,
        dxc.IResult_UUID,
        &result,
    )
    if hr < 0 { return nil, nil, false }
    defer result->Release()

    status: d3d12.HRESULT
    result->GetStatus(&status)

    if result->HasOutput(.ERRORS) {
        errors: ^dxc.IBlobUtf8
        result->GetOutput(.ERRORS, dxc.IBlobUtf8_UUID, &errors, nil)
        if errors != nil && errors->GetStringLength() > 0 {
            fmt.println("DXC output:", errors->GetStringPointer())
        }
        errors->Release()
    }

    if status < 0 {
        fmt.println("Shader compilation failed")
        return nil, nil, false
    }

    object_blob: ^dxc.IBlob
    hr = result->GetOutput(.OBJECT, dxc.IBlob_UUID, &object_blob, nil)
    if hr < 0 { return nil, nil, false }
    defer object_blob->Release()

    size := int(object_blob->GetBufferSize())
    ptr := object_blob->GetBufferPointer()
    dxil_bytecode = make([]u8, size)
    mem.copy(&dxil_bytecode[0], ptr, size)

    // Root signature based on compiler reflection

    container_reflection: ^dxc.IContainerReflection
	hr = dxc.CreateInstance(dxc.ContainerReflection_CLSID, dxc.IContainerReflection_UUID, (^rawptr)(&container_reflection))
	if hr >= 0 {
		defer container_reflection->Release()

		// 1. Load the compiled shader object container into the reflection engine
		if container_reflection->Load(object_blob) == 0 {
			part_idx: u32

			// 2. Scan the container layout matching the explicit Root Signature tag
			// Note: Vendor bindings may use dxc.PART_ROOT_SIGNATURE or a direct four-cc cast
			// FourCC for 'R', 'T', 'S', '0' represents DXIL_FOURCC for Root Signatures
			four_cc_rootsig := u32('R') | (u32('T') << 8) | (u32('S') << 16) | (u32('0') << 24)

			if container_reflection->FindFirstPartKind(four_cc_rootsig, &part_idx) == 0 {
				rootsig_blob_dxc: ^dxc.IBlob

				// 3. Extract the clean binary content of the root signature slice
				if container_reflection->GetPartContent(part_idx, &rootsig_blob_dxc) == 0 {
					defer rootsig_blob_dxc->Release()

					rs_size := int(rootsig_blob_dxc->GetBufferSize())
					rs_ptr  := rootsig_blob_dxc->GetBufferPointer()

					rootsig_blob = make([]u8, rs_size)
					mem.copy(&rootsig_blob[0], rs_ptr, rs_size)
				}
			}
		}
	}

    return dxil_bytecode, rootsig_blob, true
}

compile_dxr_library :: proc(source: string, entry_point: string, target_profile: string) -> (dxil_bytecode: []u8, OK: bool) {
    compiler3: ^dxc.ICompiler3
    hr := dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler3_UUID, &compiler3)
    if hr < 0 { return nil, false }
    defer compiler3->Release()

    utils: ^dxc.IUtils
    hr = dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, &utils)
    if hr < 0 { return nil, false }
    defer utils->Release()

    include_handler: ^dxc.IIncludeHandler
    hr = utils->CreateDefaultIncludeHandler(&include_handler)
    if hr < 0 { return nil, false }
    defer include_handler->Release()

    entry_w: windows.wstring = nil
    if entry_point != "" {
        entry_w = windows.utf8_to_wstring(entry_point)
    }
    profile_w := windows.utf8_to_wstring(target_profile)

    compiler_args: ^dxc.ICompilerArgs
    hr = utils->BuildArguments(nil, entry_w, profile_w, nil, 0, nil, 0, &compiler_args)
    if hr < 0 { return nil, false }
    defer compiler_args->Release()

    source_buffer := dxc.Buffer{
        Ptr      = raw_data(source),
        Size     = len(source),
        Encoding = dxc.CP_UTF8,
    }

    result: ^dxc.IResult
    hr = compiler3->Compile(
        &source_buffer,
        compiler_args->GetArguments(),
        compiler_args->GetCount(),
        include_handler,
        dxc.IResult_UUID,
        &result,
    )
    if hr < 0 { return nil,  false }
    defer result->Release()

    status: d3d12.HRESULT
    result->GetStatus(&status)

    if result->HasOutput(.ERRORS) {
        errors: ^dxc.IBlobUtf8
        result->GetOutput(.ERRORS, dxc.IBlobUtf8_UUID, &errors, nil)
        if errors != nil && errors->GetStringLength() > 0 {
            fmt.println("DXC output:", errors->GetStringPointer())
        }
        errors->Release()
    }

    if status < 0 {
        fmt.println("Shader compilation failed")
        return nil, false
    }

    object_blob: ^dxc.IBlob
    hr = result->GetOutput(.OBJECT, dxc.IBlob_UUID, &object_blob, nil)
    if hr < 0 { return nil, false }
    defer object_blob->Release()

    size := int(object_blob->GetBufferSize())
    ptr := object_blob->GetBufferPointer()
    dxil_bytecode = make([]u8, size)
    mem.copy(&dxil_bytecode[0], ptr, size)

    return dxil_bytecode, true
}
