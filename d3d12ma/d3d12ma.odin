package d3d12ma

import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Odin bindings for D3D12 Memory Allocator (D3D12MemAlloc.h v3.2.0), going through the C
// wrapper in native/d3d12ma_c.{h,cpp}. Procedure names follow the C++ method names:
//     Allocator::CreatePool   ->  Allocator_CreatePool(allocator, ...)
// Every handle is reference counted; call the matching *_Release when you are done.
//
// COM pointers (ID3D12Device, ID3D12Resource, ...) are kept as rawptr in the raw bindings,
// as in the original file. The helpers in section 6 give typed variants.

// ---------------------------------------------------------------------------
// 1. Library Import
// ---------------------------------------------------------------------------
// Odin resolves this path relative to the location of this source file.
// native/build.bat produces it.
foreign import d3d12ma_lib {
	"lib/d3d12ma.lib",
}

// The functions that need ID3D12Device8 / ID3D12Device10 only exist in the native library
// when it was built with a Windows SDK that defines those interfaces. If your build lacks
// them, compile with -define:D3D12MA_HAS_DEVICE8=false and/or -define:D3D12MA_HAS_DEVICE10=false.
HAS_DEVICE8  :: #config(D3D12MA_HAS_DEVICE8, true)
HAS_DEVICE10 :: #config(D3D12MA_HAS_DEVICE10, true)

// ---------------------------------------------------------------------------
// 2. Opaque Handles (representing C++ instances safely as raw pointers)
// ---------------------------------------------------------------------------
Allocator              :: distinct rawptr
Allocation             :: distinct rawptr
Pool                   :: distinct rawptr
DefragmentationContext :: distinct rawptr
VirtualBlock           :: distinct rawptr

// ---------------------------------------------------------------------------
// 3. Enums and Bit Sets (Idiomatic Odin Translations)
// ---------------------------------------------------------------------------
Allocator_Flags :: bit_set[Allocator_Flag; win.UINT]
Allocator_Flag  :: enum win.UINT {
	SINGLETHREADED                      = 0, // Maps to 0x1
	ALWAYS_COMMITTED                    = 1, // Maps to 0x2
	DEFAULT_POOLS_NOT_ZEROED            = 2, // Maps to 0x4
	MSAA_TEXTURES_ALWAYS_COMMITTED      = 3, // Maps to 0x8
	DONT_PREFER_SMALL_BUFFERS_COMMITTED = 4, // Maps to 0x10
	DONT_USE_TIGHT_ALIGNMENT            = 5, // Maps to 0x20
}

Allocation_Flags :: bit_set[Allocation_Flag; win.UINT]
Allocation_Flag  :: enum win.UINT {
	COMMITTED           = 0,  // Maps to 0x1
	NEVER_ALLOCATE      = 1,  // Maps to 0x2
	WITHIN_BUDGET       = 2,  // Maps to 0x4
	UPPER_ADDRESS       = 3,  // Maps to 0x8
	CAN_ALIAS           = 4,  // Maps to 0x10
	// NOTE: D3D12MemAlloc.h really defines STRATEGY_MIN_OFFSET as 0x0004000 (seven digits), i.e. 0x4000.
	STRATEGY_MIN_OFFSET = 14, // Maps to 0x4000
	STRATEGY_MIN_MEMORY = 16, // Maps to 0x00010000
	STRATEGY_MIN_TIME   = 17, // Maps to 0x00020000
}

// Aliases and masks from the header (bit_set enums cannot hold duplicate values).
ALLOCATION_FLAGS_STRATEGY_BEST_FIT  :: Allocation_Flags{.STRATEGY_MIN_MEMORY}
ALLOCATION_FLAGS_STRATEGY_FIRST_FIT :: Allocation_Flags{.STRATEGY_MIN_TIME}
ALLOCATION_FLAGS_STRATEGY_MASK      :: Allocation_Flags{.STRATEGY_MIN_MEMORY, .STRATEGY_MIN_TIME, .STRATEGY_MIN_OFFSET}

Pool_Flags :: bit_set[Pool_Flag; win.UINT]
Pool_Flag  :: enum win.UINT {
	ALGORITHM_LINEAR               = 0, // Maps to 0x1
	MSAA_TEXTURES_ALWAYS_COMMITTED = 1, // Maps to 0x2
	ALWAYS_COMMITTED               = 2, // Maps to 0x4
	DONT_USE_TIGHT_ALIGNMENT       = 3, // Maps to 0x8
}

POOL_FLAGS_ALGORITHM_MASK :: Pool_Flags{.ALGORITHM_LINEAR}

Defragmentation_Flags :: bit_set[Defragmentation_Flag; win.UINT]
Defragmentation_Flag  :: enum win.UINT {
	ALGORITHM_FAST     = 0, // Maps to 0x1
	ALGORITHM_BALANCED = 1, // Maps to 0x2
	ALGORITHM_FULL     = 2, // Maps to 0x4
}

DEFRAGMENTATION_FLAGS_ALGORITHM_MASK :: Defragmentation_Flags{.ALGORITHM_FAST, .ALGORITHM_BALANCED, .ALGORITHM_FULL}

Defragmentation_Move_Operation :: enum win.UINT {
	COPY    = 0,
	IGNORE  = 1,
	DESTROY = 2,
}

Virtual_Block_Flags :: bit_set[Virtual_Block_Flag; win.UINT]
Virtual_Block_Flag  :: enum win.UINT {
	ALGORITHM_LINEAR = 0, // Maps to 0x1
}

VIRTUAL_BLOCK_FLAGS_ALGORITHM_MASK :: Virtual_Block_Flags{.ALGORITHM_LINEAR}

Virtual_Allocation_Flags :: bit_set[Virtual_Allocation_Flag; win.UINT]
Virtual_Allocation_Flag  :: enum win.UINT {
	UPPER_ADDRESS       = 3,  // Maps to 0x8
	STRATEGY_MIN_OFFSET = 14, // Maps to 0x4000
	STRATEGY_MIN_MEMORY = 16, // Maps to 0x00010000
	STRATEGY_MIN_TIME   = 17, // Maps to 0x00020000
}

VIRTUAL_ALLOCATION_FLAGS_STRATEGY_MASK :: Virtual_Allocation_Flags{.STRATEGY_MIN_MEMORY, .STRATEGY_MIN_TIME, .STRATEGY_MIN_OFFSET}

// Values for Allocator_GetMemoryCapacity and the index into TotalStatistics.MemorySegmentGroup.
MEMORY_SEGMENT_GROUP_LOCAL     :: 0 // DXGI_MEMORY_SEGMENT_GROUP_LOCAL
MEMORY_SEGMENT_GROUP_NON_LOCAL :: 1 // DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL

// Recommended defaults (mirror the D3D12MA_RECOMMENDED_* macros).
RECOMMENDED_ALLOCATOR_FLAGS :: Allocator_Flags{.DEFAULT_POOLS_NOT_ZEROED, .MSAA_TEXTURES_ALWAYS_COMMITTED}
RECOMMENDED_POOL_FLAGS      :: Pool_Flags{.MSAA_TEXTURES_ALWAYS_COMMITTED}
RECOMMENDED_HEAP_FLAGS      :: d3d12.HEAP_FLAGS{.CREATE_NOT_ZEROED}

// ---------------------------------------------------------------------------
// 4. Mirror Struct Layouts (Must perfectly align with C layouts)
// ---------------------------------------------------------------------------
ALLOCATE_FUNC_PTR :: #type proc "c" (size: win.SIZE_T, alignment: win.SIZE_T, private_data: rawptr) -> rawptr
FREE_FUNC_PTR     :: #type proc "c" (memory: rawptr, private_data: rawptr) // memory may be nil

Allocation_Callbacks :: struct {
	pAllocate:    ALLOCATE_FUNC_PTR,
	pFree:        FREE_FUNC_PTR,
	pPrivateData: rawptr,
}

ALLOCATOR_DESC :: struct {
	Flags:                Allocator_Flags,
	pDevice:              rawptr, // Pointer to your ID3D12Device
	PreferredBlockSize:   win.UINT64, // 0 = default
	pAllocationCallbacks: ^Allocation_Callbacks,
	pAdapter:             rawptr, // Pointer to your IDXGIAdapter
}

ALLOCATION_DESC :: struct {
	Flags:          Allocation_Flags,
	HeapType:       d3d12.HEAP_TYPE,  // Ignored when CustomPool != nil
	ExtraHeapFlags: d3d12.HEAP_FLAGS, // Ignored when CustomPool != nil
	CustomPool:     Pool,
	pPrivateData:   rawptr,
}

POOL_DESC :: struct {
	Flags:                  Pool_Flags,
	HeapProperties:         d3d12.HEAP_PROPERTIES,
	HeapFlags:              d3d12.HEAP_FLAGS,
	BlockSize:              win.UINT64, // 0 = default
	MinBlockCount:          win.UINT,
	MaxBlockCount:          win.UINT,   // max(u32) = unlimited
	MinAllocationAlignment: win.UINT64, // 0 = default
	pProtectedSession:      rawptr, // Pointer to ID3D12ProtectedResourceSession
	ResidencyPriority:      d3d12.RESIDENCY_PRIORITY, // 0 = do not set
}

// Fast to calculate. See Allocator_GetBudget, Pool_GetStatistics.
Statistics :: struct {
	BlockCount:      win.UINT,
	AllocationCount: win.UINT,
	BlockBytes:      win.UINT64,
	AllocationBytes: win.UINT64,
}

// Slower to calculate; for debugging. See Allocator_CalculateStatistics, Pool_CalculateStatistics.
DetailedStatistics :: struct {
	Stats:              Statistics,
	UnusedRangeCount:   win.UINT,
	AllocationSizeMin:  win.UINT64,
	AllocationSizeMax:  win.UINT64,
	UnusedRangeSizeMin: win.UINT64,
	UnusedRangeSizeMax: win.UINT64,
}

TotalStatistics :: struct {
	// Index: 0 = DEFAULT, 1 = UPLOAD, 2 = READBACK, 3 = CUSTOM, 4 = GPU_UPLOAD
	HeapType:           [5]DetailedStatistics,
	// Index: MEMORY_SEGMENT_GROUP_LOCAL / MEMORY_SEGMENT_GROUP_NON_LOCAL
	MemorySegmentGroup: [2]DetailedStatistics,
	Total:              DetailedStatistics,
}

Budget :: struct {
	Stats:       Statistics,
	UsageBytes:  win.UINT64,
	BudgetBytes: win.UINT64,
}

DEFRAGMENTATION_DESC :: struct {
	Flags:                 Defragmentation_Flags,
	MaxBytesPerPass:       win.UINT64, // 0 = no limit
	MaxAllocationsPerPass: win.UINT32, // 0 = no limit
}

DEFRAGMENTATION_MOVE :: struct {
	Operation:         Defragmentation_Move_Operation,
	pSrcAllocation:    Allocation,
	pDstTmpAllocation: Allocation,
}

DEFRAGMENTATION_PASS_MOVE_INFO :: struct {
	MoveCount: win.UINT32,
	pMoves:    [^]DEFRAGMENTATION_MOVE, // Multi-pointer mapping to array; owned by D3D12MA until EndPass
}

DEFRAGMENTATION_STATS :: struct {
	BytesMoved:       win.UINT64,
	BytesFreed:       win.UINT64,
	AllocationsMoved: win.UINT32,
	HeapsFreed:       win.UINT32,
}

// Handle of an allocation made inside a VirtualBlock. Passed by value.
VirtualAllocation :: struct {
	AllocHandle: win.UINT64,
}

VIRTUAL_BLOCK_DESC :: struct {
	Flags:                Virtual_Block_Flags,
	Size:                 win.UINT64,
	pAllocationCallbacks: ^Allocation_Callbacks,
}

VIRTUAL_ALLOCATION_DESC :: struct {
	Flags:        Virtual_Allocation_Flags,
	Size:         win.UINT64,
	Alignment:    win.UINT64, // 0 = 1
	pPrivateData: rawptr,
}

VIRTUAL_ALLOCATION_INFO :: struct {
	Offset:       win.UINT64,
	Size:         win.UINT64,
	pPrivateData: rawptr,
}

// Layout checks, verified against the C structs of native/d3d12ma_c.h on Windows x64.
#assert(size_of(Allocation_Callbacks)             == 24)
#assert(size_of(ALLOCATOR_DESC)                   == 40)
#assert(size_of(ALLOCATION_DESC)                  == 32)
#assert(size_of(POOL_DESC)                        == 72)
#assert(size_of(Statistics)                       == 24)
#assert(size_of(DetailedStatistics)               == 64)
#assert(size_of(TotalStatistics)                  == 512)
#assert(size_of(Budget)                           == 40)
#assert(size_of(DEFRAGMENTATION_DESC)             == 24)
#assert(size_of(DEFRAGMENTATION_MOVE)             == 24)
#assert(size_of(DEFRAGMENTATION_PASS_MOVE_INFO)   == 16)
#assert(size_of(DEFRAGMENTATION_STATS)            == 24)
#assert(size_of(VirtualAllocation)                == 8)
#assert(size_of(VIRTUAL_BLOCK_DESC)               == 24)
#assert(size_of(VIRTUAL_ALLOCATION_DESC)          == 32)
#assert(size_of(VIRTUAL_ALLOCATION_INFO)          == 24)

// ---------------------------------------------------------------------------
// 5. Foreign Link Declarations
// ---------------------------------------------------------------------------
@(default_calling_convention="c")
foreign d3d12ma_lib {
	// ---- Factories ----
	@(link_name="D3D12MA_CreateAllocator")
	CreateAllocator :: proc(pDesc: ^ALLOCATOR_DESC, ppAllocator: ^Allocator) -> win.HRESULT ---

	@(link_name="D3D12MA_CreateVirtualBlock")
	CreateVirtualBlock :: proc(pDesc: ^VIRTUAL_BLOCK_DESC, ppVirtualBlock: ^VirtualBlock) -> win.HRESULT ---

	// ---- Allocator ----
	@(link_name="D3D12MA_Allocator_AddRef")
	Allocator_AddRef :: proc(allocator: Allocator) -> win.ULONG ---

	@(link_name="D3D12MA_Allocator_Release")
	Allocator_Release :: proc(allocator: Allocator) -> win.ULONG ---

	// The returned pointer is owned by the allocator.
	@(link_name="D3D12MA_Allocator_GetD3D12Options")
	Allocator_GetD3D12Options :: proc(allocator: Allocator) -> ^d3d12.FEATURE_DATA_OPTIONS ---

	@(link_name="D3D12MA_Allocator_IsUMA")
	Allocator_IsUMA :: proc(allocator: Allocator) -> win.BOOL ---

	@(link_name="D3D12MA_Allocator_IsCacheCoherentUMA")
	Allocator_IsCacheCoherentUMA :: proc(allocator: Allocator) -> win.BOOL ---

	@(link_name="D3D12MA_Allocator_IsGPUUploadHeapSupported")
	Allocator_IsGPUUploadHeapSupported :: proc(allocator: Allocator) -> win.BOOL ---

	@(link_name="D3D12MA_Allocator_IsTightAlignmentSupported")
	Allocator_IsTightAlignmentSupported :: proc(allocator: Allocator) -> win.BOOL ---

	// memorySegmentGroup: MEMORY_SEGMENT_GROUP_LOCAL or MEMORY_SEGMENT_GROUP_NON_LOCAL
	@(link_name="D3D12MA_Allocator_GetMemoryCapacity")
	Allocator_GetMemoryCapacity :: proc(allocator: Allocator, memorySegmentGroup: win.UINT) -> win.UINT64 ---

	// ppvResource is optional (nil: you only get the allocation). riidResource is only read
	// when ppvResource is not nil. If ppvResource is set you receive an extra reference.
	@(link_name="D3D12MA_Allocator_CreateResource")
	Allocator_CreateResource :: proc(
		allocator:            Allocator,
		pAllocDesc:           ^ALLOCATION_DESC,
		pResourceDesc:        ^d3d12.RESOURCE_DESC,
		InitialResourceState: d3d12.RESOURCE_STATES,
		pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
		ppAllocation:         ^Allocation,
		riidResource:         ^win.GUID,
		ppvResource:          ^rawptr,
	) -> win.HRESULT ---

	@(link_name="D3D12MA_Allocator_AllocateMemory")
	Allocator_AllocateMemory :: proc(
		allocator:    Allocator,
		pAllocDesc:   ^ALLOCATION_DESC,
		pAllocInfo:   ^d3d12.RESOURCE_ALLOCATION_INFO,
		ppAllocation: ^Allocation,
	) -> win.HRESULT ---

	@(link_name="D3D12MA_Allocator_CreateAliasingResource")
	Allocator_CreateAliasingResource :: proc(
		allocator:            Allocator,
		pAllocation:          Allocation,
		AllocationLocalOffset: win.UINT64,
		pResourceDesc:        ^d3d12.RESOURCE_DESC,
		InitialResourceState: d3d12.RESOURCE_STATES,
		pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
		riidResource:         ^win.GUID,
		ppvResource:          ^rawptr,
	) -> win.HRESULT ---

	@(link_name="D3D12MA_Allocator_CreatePool")
	Allocator_CreatePool :: proc(allocator: Allocator, pPoolDesc: ^POOL_DESC, ppPool: ^Pool) -> win.HRESULT ---

	@(link_name="D3D12MA_Allocator_SetCurrentFrameIndex")
	Allocator_SetCurrentFrameIndex :: proc(allocator: Allocator, frameIndex: win.UINT) ---

	// Either output pointer may be nil.
	@(link_name="D3D12MA_Allocator_GetBudget")
	Allocator_GetBudget :: proc(allocator: Allocator, pLocalBudget: ^Budget, pNonLocalBudget: ^Budget) ---

	@(link_name="D3D12MA_Allocator_CalculateStatistics")
	Allocator_CalculateStatistics :: proc(allocator: Allocator, pStats: ^TotalStatistics) ---

	// Free the returned string with Allocator_FreeStatsString.
	@(link_name="D3D12MA_Allocator_BuildStatsString")
	Allocator_BuildStatsString :: proc(allocator: Allocator, ppStatsString: ^win.LPWSTR, DetailedMap: win.BOOL) ---

	@(link_name="D3D12MA_Allocator_FreeStatsString")
	Allocator_FreeStatsString :: proc(allocator: Allocator, pStatsString: win.LPWSTR) ---

	@(link_name="D3D12MA_Allocator_BeginDefragmentation")
	Allocator_BeginDefragmentation :: proc(allocator: Allocator, pDesc: ^DEFRAGMENTATION_DESC, ppContext: ^DefragmentationContext) ---

	// ---- Allocation ----
	@(link_name="D3D12MA_Allocation_AddRef")
	Allocation_AddRef :: proc(allocation: Allocation) -> win.ULONG ---

	@(link_name="D3D12MA_Allocation_Release")
	Allocation_Release :: proc(allocation: Allocation) -> win.ULONG ---

	@(link_name="D3D12MA_Allocation_GetOffset")
	Allocation_GetOffset :: proc(allocation: Allocation) -> win.UINT64 ---

	@(link_name="D3D12MA_Allocation_GetAlignment")
	Allocation_GetAlignment :: proc(allocation: Allocation) -> win.UINT64 ---

	@(link_name="D3D12MA_Allocation_GetSize")
	Allocation_GetSize :: proc(allocation: Allocation) -> win.UINT64 ---

	// Does NOT add a reference to the returned resource.
	@(link_name="D3D12MA_Allocation_GetResource")
	Allocation_GetResource :: proc(allocation: Allocation) -> rawptr --- // Returns ID3D12Resource

	// Releases the current resource, stores the new one and adds a reference to it. Advanced use only.
	@(link_name="D3D12MA_Allocation_SetResource")
	Allocation_SetResource :: proc(allocation: Allocation, pResource: rawptr) --- // ID3D12Resource

	// nil for committed resources with an implicit heap.
	@(link_name="D3D12MA_Allocation_GetHeap")
	Allocation_GetHeap :: proc(allocation: Allocation) -> rawptr --- // Returns ID3D12Heap

	@(link_name="D3D12MA_Allocation_SetPrivateData")
	Allocation_SetPrivateData :: proc(allocation: Allocation, pPrivateData: rawptr) ---

	@(link_name="D3D12MA_Allocation_GetPrivateData")
	Allocation_GetPrivateData :: proc(allocation: Allocation) -> rawptr ---

	// D3D12MA keeps its own copy of Name. Name may be nil.
	@(link_name="D3D12MA_Allocation_SetName")
	Allocation_SetName :: proc(allocation: Allocation, Name: win.LPCWSTR) ---

	// Returns nil if no name was set. Points to an internal copy.
	@(link_name="D3D12MA_Allocation_GetName")
	Allocation_GetName :: proc(allocation: Allocation) -> win.LPCWSTR ---

	// ---- Pool ----
	@(link_name="D3D12MA_Pool_AddRef")
	Pool_AddRef :: proc(pool: Pool) -> win.ULONG ---

	@(link_name="D3D12MA_Pool_Release")
	Pool_Release :: proc(pool: Pool) -> win.ULONG ---

	@(link_name="D3D12MA_Pool_GetDesc")
	Pool_GetDesc :: proc(pool: Pool, pDesc: ^POOL_DESC) ---

	@(link_name="D3D12MA_Pool_GetStatistics")
	Pool_GetStatistics :: proc(pool: Pool, pStats: ^Statistics) ---

	@(link_name="D3D12MA_Pool_CalculateStatistics")
	Pool_CalculateStatistics :: proc(pool: Pool, pStats: ^DetailedStatistics) ---

	@(link_name="D3D12MA_Pool_SetName")
	Pool_SetName :: proc(pool: Pool, Name: win.LPCWSTR) ---

	@(link_name="D3D12MA_Pool_GetName")
	Pool_GetName :: proc(pool: Pool) -> win.LPCWSTR ---

	@(link_name="D3D12MA_Pool_BeginDefragmentation")
	Pool_BeginDefragmentation :: proc(pool: Pool, pDesc: ^DEFRAGMENTATION_DESC, ppContext: ^DefragmentationContext) -> win.HRESULT ---

	// ---- DefragmentationContext ----
	@(link_name="D3D12MA_DefragmentationContext_AddRef")
	DefragmentationContext_AddRef :: proc(ctx: DefragmentationContext) -> win.ULONG ---

	// Releasing the context ends defragmentation.
	@(link_name="D3D12MA_DefragmentationContext_Release")
	DefragmentationContext_Release :: proc(ctx: DefragmentationContext) -> win.ULONG ---

	// S_OK: no more moves are possible (EndPass may be skipped).
	// S_FALSE: moves are pending in pPassInfo; perform them, then call EndPass.
	@(link_name="D3D12MA_DefragmentationContext_BeginPass")
	DefragmentationContext_BeginPass :: proc(ctx: DefragmentationContext, pPassInfo: ^DEFRAGMENTATION_PASS_MOVE_INFO) -> win.HRESULT ---

	// S_OK: no more moves are possible. S_FALSE: more defragmentation is possible (try another pass).
	@(link_name="D3D12MA_DefragmentationContext_EndPass")
	DefragmentationContext_EndPass :: proc(ctx: DefragmentationContext, pPassInfo: ^DEFRAGMENTATION_PASS_MOVE_INFO) -> win.HRESULT ---

	@(link_name="D3D12MA_DefragmentationContext_GetStats")
	DefragmentationContext_GetStats :: proc(ctx: DefragmentationContext, pStats: ^DEFRAGMENTATION_STATS) ---

	// ---- VirtualBlock ----
	@(link_name="D3D12MA_VirtualBlock_AddRef")
	VirtualBlock_AddRef :: proc(block: VirtualBlock) -> win.ULONG ---

	@(link_name="D3D12MA_VirtualBlock_Release")
	VirtualBlock_Release :: proc(block: VirtualBlock) -> win.ULONG ---

	@(link_name="D3D12MA_VirtualBlock_IsEmpty")
	VirtualBlock_IsEmpty :: proc(block: VirtualBlock) -> win.BOOL ---

	@(link_name="D3D12MA_VirtualBlock_GetAllocationInfo")
	VirtualBlock_GetAllocationInfo :: proc(block: VirtualBlock, allocation: VirtualAllocation, pInfo: ^VIRTUAL_ALLOCATION_INFO) ---

	@(link_name="D3D12MA_VirtualBlock_Allocate")
	VirtualBlock_Allocate :: proc(block: VirtualBlock, pDesc: ^VIRTUAL_ALLOCATION_DESC, pAllocation: ^VirtualAllocation, pOffset: ^win.UINT64) -> win.HRESULT ---

	@(link_name="D3D12MA_VirtualBlock_FreeAllocation")
	VirtualBlock_FreeAllocation :: proc(block: VirtualBlock, allocation: VirtualAllocation) ---

	@(link_name="D3D12MA_VirtualBlock_Clear")
	VirtualBlock_Clear :: proc(block: VirtualBlock) ---

	@(link_name="D3D12MA_VirtualBlock_SetAllocationPrivateData")
	VirtualBlock_SetAllocationPrivateData :: proc(block: VirtualBlock, allocation: VirtualAllocation, pPrivateData: rawptr) ---

	@(link_name="D3D12MA_VirtualBlock_GetStatistics")
	VirtualBlock_GetStatistics :: proc(block: VirtualBlock, pStats: ^Statistics) ---

	@(link_name="D3D12MA_VirtualBlock_CalculateStatistics")
	VirtualBlock_CalculateStatistics :: proc(block: VirtualBlock, pStats: ^DetailedStatistics) ---

	// Free the returned string with VirtualBlock_FreeStatsString.
	@(link_name="D3D12MA_VirtualBlock_BuildStatsString")
	VirtualBlock_BuildStatsString :: proc(block: VirtualBlock, ppStatsString: ^win.LPWSTR) ---

	@(link_name="D3D12MA_VirtualBlock_FreeStatsString")
	VirtualBlock_FreeStatsString :: proc(block: VirtualBlock, pStatsString: win.LPWSTR) ---
}

// Needs ID3D12Device8 (D3D12_RESOURCE_DESC1).
when HAS_DEVICE8 {
	@(default_calling_convention="c")
	foreign d3d12ma_lib {
		@(link_name="D3D12MA_Allocator_CreateResource2")
		Allocator_CreateResource2 :: proc(
			allocator:            Allocator,
			pAllocDesc:           ^ALLOCATION_DESC,
			pResourceDesc:        ^d3d12.RESOURCE_DESC1,
			InitialResourceState: d3d12.RESOURCE_STATES,
			pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
			ppAllocation:         ^Allocation,
			riidResource:         ^win.GUID,
			ppvResource:          ^rawptr,
		) -> win.HRESULT ---

		@(link_name="D3D12MA_Allocator_CreateAliasingResource1")
		Allocator_CreateAliasingResource1 :: proc(
			allocator:             Allocator,
			pAllocation:           Allocation,
			AllocationLocalOffset: win.UINT64,
			pResourceDesc:         ^d3d12.RESOURCE_DESC1,
			InitialResourceState:  d3d12.RESOURCE_STATES,
			pOptimizedClearValue:  ^d3d12.CLEAR_VALUE,
			riidResource:          ^win.GUID,
			ppvResource:           ^rawptr,
		) -> win.HRESULT ---
	}
}

// Needs ID3D12Device10 (enhanced barriers, D3D12_BARRIER_LAYOUT).
when HAS_DEVICE10 {
	@(default_calling_convention="c")
	foreign d3d12ma_lib {
		@(link_name="D3D12MA_Allocator_CreateResource3")
		Allocator_CreateResource3 :: proc(
			allocator:            Allocator,
			pAllocDesc:           ^ALLOCATION_DESC,
			pResourceDesc:        ^d3d12.RESOURCE_DESC1,
			InitialLayout:        d3d12.BARRIER_LAYOUT,
			pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
			NumCastableFormats:   win.UINT32,
			pCastableFormats:     [^]dxgi.FORMAT,
			ppAllocation:         ^Allocation,
			riidResource:         ^win.GUID,
			ppvResource:          ^rawptr,
		) -> win.HRESULT ---

		@(link_name="D3D12MA_Allocator_CreateAliasingResource2")
		Allocator_CreateAliasingResource2 :: proc(
			allocator:             Allocator,
			pAllocation:           Allocation,
			AllocationLocalOffset: win.UINT64,
			pResourceDesc:         ^d3d12.RESOURCE_DESC1,
			InitialLayout:         d3d12.BARRIER_LAYOUT,
			pOptimizedClearValue:  ^d3d12.CLEAR_VALUE,
			NumCastableFormats:    win.UINT32,
			pCastableFormats:      [^]dxgi.FORMAT,
			riidResource:          ^win.GUID,
			ppvResource:           ^rawptr,
		) -> win.HRESULT ---
	}
}

// ---------------------------------------------------------------------------
// 6. Convenience helpers (pure Odin, no extra native code)
// ---------------------------------------------------------------------------

// ---- Descriptor constructors (equivalents of the C++ CALLOCATION_DESC, CPOOL_DESC, ...) ----

// Allocation in a custom pool.
MakeAllocationDesc_Pool :: proc(pool: Pool, flags: Allocation_Flags = {}, private_data: rawptr = nil) -> ALLOCATION_DESC {
	return {Flags = flags, CustomPool = pool, pPrivateData = private_data}
}

// Allocation in one of the default pools (DEFAULT, UPLOAD or READBACK).
MakeAllocationDesc_HeapType :: proc(
	heap_type: d3d12.HEAP_TYPE,
	flags: Allocation_Flags = {},
	private_data: rawptr = nil,
	extra_heap_flags: d3d12.HEAP_FLAGS = RECOMMENDED_HEAP_FLAGS,
) -> ALLOCATION_DESC {
	return {Flags = flags, HeapType = heap_type, ExtraHeapFlags = extra_heap_flags, pPrivateData = private_data}
}

MakeAllocationDesc :: proc{MakeAllocationDesc_Pool, MakeAllocationDesc_HeapType}

MakePoolDesc_HeapType :: proc(
	heap_type: d3d12.HEAP_TYPE,
	heap_flags: d3d12.HEAP_FLAGS,
	flags: Pool_Flags = RECOMMENDED_POOL_FLAGS,
	block_size: win.UINT64 = 0,
	min_block_count: win.UINT = 0,
	max_block_count: win.UINT = max(win.UINT),
	residency_priority: d3d12.RESIDENCY_PRIORITY = .NORMAL,
) -> (desc: POOL_DESC) {
	desc.Flags = flags
	desc.HeapProperties.Type = heap_type
	desc.HeapFlags = heap_flags
	desc.BlockSize = block_size
	desc.MinBlockCount = min_block_count
	desc.MaxBlockCount = max_block_count
	desc.ResidencyPriority = residency_priority
	return
}

MakePoolDesc_HeapProperties :: proc(
	heap_properties: d3d12.HEAP_PROPERTIES,
	heap_flags: d3d12.HEAP_FLAGS,
	flags: Pool_Flags = RECOMMENDED_POOL_FLAGS,
	block_size: win.UINT64 = 0,
	min_block_count: win.UINT = 0,
	max_block_count: win.UINT = max(win.UINT),
	residency_priority: d3d12.RESIDENCY_PRIORITY = .NORMAL,
) -> POOL_DESC {
	desc := MakePoolDesc_HeapType(heap_properties.Type, heap_flags, flags, block_size, min_block_count, max_block_count, residency_priority)
	desc.HeapProperties = heap_properties
	return desc
}

MakePoolDesc :: proc{MakePoolDesc_HeapType, MakePoolDesc_HeapProperties}

MakeVirtualBlockDesc :: proc(
	size: win.UINT64,
	flags: Virtual_Block_Flags = {},
	allocation_callbacks: ^Allocation_Callbacks = nil,
) -> VIRTUAL_BLOCK_DESC {
	return {Flags = flags, Size = size, pAllocationCallbacks = allocation_callbacks}
}

MakeVirtualAllocationDesc :: proc(
	size: win.UINT64,
	alignment: win.UINT64,
	flags: Virtual_Allocation_Flags = {},
	private_data: rawptr = nil,
) -> VIRTUAL_ALLOCATION_DESC {
	return {Flags = flags, Size = size, Alignment = alignment, pPrivateData = private_data}
}

// ---- Typed access to the COM objects held by an Allocation ----

// Does not add a reference.
Allocation_GetD3D12Resource :: proc(allocation: Allocation) -> ^d3d12.IResource {
	return (^d3d12.IResource)(Allocation_GetResource(allocation))
}

// Does not add a reference. nil for committed resources with an implicit heap.
Allocation_GetD3D12Heap :: proc(allocation: Allocation) -> ^d3d12.IHeap {
	return (^d3d12.IHeap)(Allocation_GetHeap(allocation))
}

// ---- Typed resource creation: fills in the IID and casts the out pointer ----
// ppResource is optional (nil: only the allocation is returned). If set, you receive an
// extra reference to the resource that you must Release.

Allocator_CreateResourceTyped :: proc(
	allocator: Allocator,
	pAllocDesc: ^ALLOCATION_DESC,
	pResourceDesc: ^d3d12.RESOURCE_DESC,
	InitialResourceState: d3d12.RESOURCE_STATES,
	pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
	ppAllocation: ^Allocation,
	ppResource: ^^d3d12.IResource,
) -> win.HRESULT {
	return Allocator_CreateResource(
		allocator, pAllocDesc, pResourceDesc, InitialResourceState, pOptimizedClearValue,
		ppAllocation, d3d12.IResource_UUID, (^rawptr)(ppResource),
	)
}

Allocator_CreateAliasingResourceTyped :: proc(
	allocator: Allocator,
	pAllocation: Allocation,
	AllocationLocalOffset: win.UINT64,
	pResourceDesc: ^d3d12.RESOURCE_DESC,
	InitialResourceState: d3d12.RESOURCE_STATES,
	pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
	ppResource: ^^d3d12.IResource, // required
) -> win.HRESULT {
	return Allocator_CreateAliasingResource(
		allocator, pAllocation, AllocationLocalOffset, pResourceDesc, InitialResourceState,
		pOptimizedClearValue, d3d12.IResource_UUID, (^rawptr)(ppResource),
	)
}

when HAS_DEVICE8 {
	Allocator_CreateResource2Typed :: proc(
		allocator: Allocator,
		pAllocDesc: ^ALLOCATION_DESC,
		pResourceDesc: ^d3d12.RESOURCE_DESC1,
		InitialResourceState: d3d12.RESOURCE_STATES,
		pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
		ppAllocation: ^Allocation,
		ppResource: ^^d3d12.IResource,
	) -> win.HRESULT {
		return Allocator_CreateResource2(
			allocator, pAllocDesc, pResourceDesc, InitialResourceState, pOptimizedClearValue,
			ppAllocation, d3d12.IResource_UUID, (^rawptr)(ppResource),
		)
	}

	Allocator_CreateAliasingResource1Typed :: proc(
		allocator: Allocator,
		pAllocation: Allocation,
		AllocationLocalOffset: win.UINT64,
		pResourceDesc: ^d3d12.RESOURCE_DESC1,
		InitialResourceState: d3d12.RESOURCE_STATES,
		pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
		ppResource: ^^d3d12.IResource, // required
	) -> win.HRESULT {
		return Allocator_CreateAliasingResource1(
			allocator, pAllocation, AllocationLocalOffset, pResourceDesc, InitialResourceState,
			pOptimizedClearValue, d3d12.IResource_UUID, (^rawptr)(ppResource),
		)
	}
}

when HAS_DEVICE10 {
	Allocator_CreateResource3Typed :: proc(
		allocator: Allocator,
		pAllocDesc: ^ALLOCATION_DESC,
		pResourceDesc: ^d3d12.RESOURCE_DESC1,
		InitialLayout: d3d12.BARRIER_LAYOUT,
		pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
		castable_formats: []dxgi.FORMAT,
		ppAllocation: ^Allocation,
		ppResource: ^^d3d12.IResource,
	) -> win.HRESULT {
		return Allocator_CreateResource3(
			allocator, pAllocDesc, pResourceDesc, InitialLayout, pOptimizedClearValue,
			win.UINT32(len(castable_formats)), raw_data(castable_formats),
			ppAllocation, d3d12.IResource_UUID, (^rawptr)(ppResource),
		)
	}

	Allocator_CreateAliasingResource2Typed :: proc(
		allocator: Allocator,
		pAllocation: Allocation,
		AllocationLocalOffset: win.UINT64,
		pResourceDesc: ^d3d12.RESOURCE_DESC1,
		InitialLayout: d3d12.BARRIER_LAYOUT,
		pOptimizedClearValue: ^d3d12.CLEAR_VALUE,
		castable_formats: []dxgi.FORMAT,
		ppResource: ^^d3d12.IResource, // required
	) -> win.HRESULT {
		return Allocator_CreateAliasingResource2(
			allocator, pAllocation, AllocationLocalOffset, pResourceDesc, InitialLayout,
			pOptimizedClearValue, win.UINT32(len(castable_formats)), raw_data(castable_formats),
			d3d12.IResource_UUID, (^rawptr)(ppResource),
		)
	}
}

// ---- Names: UTF-8 <-> UTF-16 (D3D12MA copies the name, so a temporary buffer is fine) ----

Allocation_SetNameString :: proc(allocation: Allocation, name: string) {
	Allocation_SetName(allocation, win.utf8_to_wstring(name, context.temp_allocator))
}

Pool_SetNameString :: proc(pool: Pool, name: string) {
	Pool_SetName(pool, win.utf8_to_wstring(name, context.temp_allocator))
}

// Returns "" when no name is set. The result is allocated with str_allocator.
Allocation_GetNameString :: proc(allocation: Allocation, str_allocator := context.allocator) -> string {
	return wide_to_string(Allocation_GetName(allocation), str_allocator)
}

Pool_GetNameString :: proc(pool: Pool, str_allocator := context.allocator) -> string {
	return wide_to_string(Pool_GetName(pool), str_allocator)
}

@(private)
wide_to_string :: proc(w: win.LPCWSTR, str_allocator := context.allocator) -> string {
	if w == nil {
		return ""
	}
	s, _ := win.wstring_to_utf8(w, -1, str_allocator)
	return s
}

// ---- Stats strings: JSON dump of the allocator / virtual block, as UTF-8 ----

Allocator_BuildStatsStringUTF8 :: proc(allocator: Allocator, detailed_map := false, str_allocator := context.allocator) -> string {
	w: win.LPWSTR
	Allocator_BuildStatsString(allocator, &w, win.BOOL(detailed_map))
	defer Allocator_FreeStatsString(allocator, w)
	return wide_to_string(win.wstring(rawptr(w)), str_allocator)
}

VirtualBlock_BuildStatsStringUTF8 :: proc(block: VirtualBlock, str_allocator := context.allocator) -> string {
	w: win.LPWSTR
	VirtualBlock_BuildStatsString(block, &w)
	defer VirtualBlock_FreeStatsString(block, w)
	return wide_to_string(win.wstring(rawptr(w)), str_allocator)
}
