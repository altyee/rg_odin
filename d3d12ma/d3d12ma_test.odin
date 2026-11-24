package d3d12ma

import "core:testing"
import "core:log"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Helper procedure to spin up a minimal, headless D3D12 context for testing
create_test_d3d12_device :: proc() -> (p_adapter: ^dxgi.IAdapter, p_device: ^d3d12.IDevice, success: bool) {
	// 1. Create a DXGI Factory
	factory: ^dxgi.IFactory4
	if !win.SUCCEEDED(dxgi.CreateDXGIFactory1(dxgi.IFactory4_UUID, (^rawptr)(&factory))) {
		return nil, nil, false
	}
	defer factory->Release()

	// 2. Try to grab a hardware adapter, fall back to WARP (software rasterizer) if unavailable
	if !win.SUCCEEDED(factory->EnumAdapters1(0, (^^dxgi.IAdapter1)(&p_adapter))) {
		if !win.SUCCEEDED(factory->EnumWarpAdapter(dxgi.IAdapter_UUID, (^rawptr)(&p_adapter))) {
			return nil, nil, false
		}
	}

	// 3. Create the actual D3D12 core device
	if !win.SUCCEEDED(d3d12.CreateDevice((^dxgi.IUnknown)(p_adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&p_device))) {
		if p_adapter != nil do p_adapter->Release()
		return nil, nil, false
	}

	return p_adapter, p_device, true
}

// Test size and alignment layouts to ensure they mirror C++ structures exactly
@test
test_struct_sizes :: proc(t: ^testing.T) {
	log.info("Verifying layout structure sizes...")

	// Test basic structures
	testing.expect_value(t, size_of(Allocation_Callbacks), size_of(rawptr) * 3)
	testing.expect_value(t, size_of(ALLOCATOR_DESC), 32) // Flags(4) + pDevice(8) + BlockSize(8) + pCallbacks(8) + pAdapter(8) with alignment padding
	testing.expect_value(t, size_of(ALLOCATION_DESC), 32) // Flags(4) + HeapType(4) + ExtraFlags(4) + Pool(8) + PrivateData(8) with alignment padding
}

// Test flag and bit_set underlying sizes for safe FFI boundaries
@test
test_bit_set_sizes :: proc(t: ^testing.T) {
	log.info("Verifying bit_set FFI sizes...")

	testing.expect_value(t, size_of(Allocator_Flags), size_of(win.UINT))
	testing.expect_value(t, size_of(Allocation_Flags), size_of(win.UINT))
	testing.expect_value(t, size_of(Pool_Flags), size_of(win.UINT))
	testing.expect_value(t, size_of(Defragmentation_Flags), size_of(win.UINT))
}

// Test the execution flow with null/mock pointers to verify no panic during linkage evaluation
@test
test_invalid_allocator_creation_returns_error :: proc(t: ^testing.T) {
	log.info("Verifying foreign linkage error handling behavior...")

	// An empty/null descriptor should fail gracefully via HRESULT rather than crashing Odin
	desc: ALLOCATOR_DESC
	desc.Flags = {}
	desc.pDevice = nil // Passing null intentionally to check foreign linkage execution
	desc.pAdapter = nil

	allocator: Allocator = nil

	// D3D12MA_CreateAllocator should safely return E_INVALIDARG or E_NOINTERFACE if the device is null
	hr := CreateAllocator(&desc, &allocator)

	testing.expect(t, hr != win.S_OK, "Expected CreateAllocator to fail with null D3D12 Device context")
	testing.expect_value(t, allocator, nil)
}

// Simple test targeting local structure flag bit manipulation
@test
test_flag_bit_set_manipulation :: proc(t: ^testing.T) {
	log.info("Testing flag manipulations...")

	flags: Allocator_Flags = {.SINGLETHREADED, .ALWAYS_COMMITTED}

	testing.expect(t, .SINGLETHREADED in flags, "Expected SINGLETHREADED flag to be present")
	testing.expect(t, .ALWAYS_COMMITTED in flags, "Expected ALWAYS_COMMITTED flag to be present")
	testing.expect(t, !(.MSAA_TEXTURES_ALWAYS_COMMITTED in flags), "Did not expect unassigned flag to be present")
}

@test
test_actual_buffer_allocation :: proc(t: ^testing.T) {
	log.info("Starting actual D3D12 memory allocation integration test...")

	// 1. Initialize our headless D3D12 runtime context
	p_adapter, p_device, ok := create_test_d3d12_device()
	if !ok {
		testing.fail_now(t, "Skipping test: Could not initialize a local D3D12 test device environment.")
	}
	defer p_device->Release()
	defer p_adapter->Release()

	// 2. Set up the D3D12MA Allocator configuration
	alloc_desc := ALLOCATOR_DESC{
		Flags = {},
		pDevice = rawptr(p_device),
		pAdapter = rawptr(p_adapter),
		PreferredBlockSize = 1024,
		pAllocationCallbacks = nil,
	}

	allocator: Allocator
	hr := CreateAllocator(&alloc_desc, &allocator)
	testing.expect(t, win.SUCCEEDED(hr), "Failed to initialize D3D12MA Allocator instance.")
	defer Allocator_Release(allocator)

	// 3. Configure our Allocation properties (Placing it in the Default GPU Heap)
	alloc_props := ALLOCATION_DESC{
		Flags = {},
		HeapType = .DEFAULT,
		ExtraHeapFlags = {},
		CustomPool = nil,
		pPrivateData = nil,
	}

	// 4. Configure the virtual structural parameters of the Resource (a 64KB Raw Buffer)
	res_desc := d3d12.RESOURCE_DESC{
		Dimension = .BUFFER,
		Alignment = 0,
		Width = 64 * 1024, // 64 Kilobytes allocation footprint
		Height = 1,
		DepthOrArraySize = 1,
		MipLevels = 1,
		Format = .UNKNOWN,
		SampleDesc = dxgi.SAMPLE_DESC{Count = 1, Quality = 0},
		Layout = .ROW_MAJOR,
		Flags = {},
	}

	allocation: Allocation
	p_resource: ^d3d12.IResource = nil

	// 5. Fire off the live allocation through the bound foreign library interface
	hr = Allocator_CreateResource(
		allocator,
		&alloc_props,
		&res_desc,
		{.VERTEX_AND_CONSTANT_BUFFER}, // Initial resource state tracker position
		nil,     // No optimized clear value needed for a raw storage buffer
		&allocation,
		d3d12.IResource_UUID,
		(^rawptr)(&p_resource),
	)

	// 6. Run structural pipeline assertions against our allocations
	testing.expect(t, win.SUCCEEDED(hr), "CreateResource failed to allocate underlying physical hardware memory.")
	testing.expect(t, allocation != nil, "Allocation context returned a null tracking reference handle.")
	testing.expect(t, p_resource != nil, "Composed target ID3D12Resource pointer was returned as null.")

	if allocation != nil && p_resource != nil {
		// Verify structural property queries behave normally via memory boundaries
		offset := Allocation_GetOffset(allocation)
		log.infof("Memory Allocation success! Assigned GPU Heap block offset: %d bytes", offset)

		heap_ptr := Allocation_GetHeap(allocation)
		testing.expect(t, heap_ptr != nil, "Allocation_GetHeap failed to return its parent ID3D12Heap structural pointer.")

		resource_ptr := Allocation_GetResource(allocation)
		testing.expect_value(t, resource_ptr, rawptr(p_resource))

		// 7. Cleanup and tear down cleanly to track memory leak boundaries
		p_resource->Release()
		ref_count := Allocation_Release(allocation)
		log.infof("Allocation handle released safely. Remaining internal ref-count: %d", ref_count)
	}
}
