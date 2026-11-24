package dxc_compile

import "core:testing"
import "core:log"

// Define a minimal, valid compute shader string with an embedded root signature macro.
// We use a raw string literal (using backticks ``) to format the HLSL cleanly.
TEST_HLSL_SOURCE :: `
#define TestRS "RootFlags(0), DescriptorTable(UAV(u0, numDescriptors = 1))"

RWTexture2D<float4> OutputTarget : register(u0);

[RootSignature(TestRS)]
[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID) {
    OutputTarget[dispatchThreadID.xy] = float4(1.0, 0.5, 0.0, 1.0);
}
`

@(test)
test_compile_shader_with_embedded_rootsig :: proc(t: ^testing.T) {
	// Execute your compilation function
	// We target a Compute Shader profile ('cs_6_5' or 'cs_6_6')
	shader_bytes, rootsig_bytes, ok := compile_dxr_library_rs(TEST_HLSL_SOURCE, "main", "cs_6_6")

	// Defer freeing the memory generated inside the compilation pass
	defer {
		if shader_bytes != nil do delete(shader_bytes)
		if rootsig_bytes != nil do delete(rootsig_bytes)
	}

	// Test Assertion 1: Verify the compiler succeeded completely
	testing.expect(t, ok == true, "Expected DXC shader compilation to succeed.")

	// Test Assertion 2: Verify that we successfully got DXIL shader instructions
	testing.expect(t, len(shader_bytes) > 0, "Expected compiled shader bytecode size to be greater than 0.")
	if len(shader_bytes) > 0 {
		log.infof("[TEST LOG] Shader bytecode compiled successfully. Size: %d bytes.\n", len(shader_bytes))
	}

	// Test Assertion 3: Verify if the root signature was extracted
	testing.expect(t, len(rootsig_bytes) > 0, "Expected embedded root signature blob to be extracted, but size was 0.")
	if len(rootsig_bytes) > 0 {
		log.infof("[TEST LOG] Embedded root signature extracted successfully! Size: %d bytes.\n", len(rootsig_bytes))
	}
}

@(test)
test_compile_shader_from_disk :: proc(t: ^testing.T) {
	// 1. Fetch the shader text from your assets folder
	shader_source, load_ok := load_hlsl_file("./test/test_shader.hlsl")
	if !load_ok {
		testing.fail_now(t, "Aborting test: Could not load the shader file from disk.")
	}
	// Make sure we free the allocated file string when this test scope exits
	defer delete(shader_source)

	// 2. Pass the loaded string directly into your existing DXC compiler pipeline
	shader_bytes, compile_ok := compile_dxr_library(shader_source, "", "lib_6_6")
	defer {
		if shader_bytes != nil do delete(shader_bytes)
	}

	// 3. Verify the pipeline integrity
	testing.expect(t, compile_ok == true, "Expected shader compilation to succeed.")
	testing.expect(t, len(shader_bytes) > 0, "Expected valid DXIL bytecode.")
	if len(shader_bytes) > 0 {
		log.infof("[TEST LOG] Shader bytecode compiled successfully. Size: %d bytes.\n", len(shader_bytes))
	}
}
