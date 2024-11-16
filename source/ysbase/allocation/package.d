module ysbase.allocation;

/* version (YSBase_GC) {}
else version = YSBase_Manual_Free; */

version (YSBase_StdxAlloc)
	public import stdx.allocator;
else
	public import std.experimental.allocator;

public import ysbase.allocation.building_blocks;

import std.algorithm : max;

// based on jemalloc
// https://jemalloc.net/jemalloc.3.html#size_classes
// should be pretty good for general purpose application use
alias YSBGeneralAllocator(BA) = Segregator!(
	// small size extents, kept forever and reused.
	8, FreeList!(BA, 0, 8),
	128, Bucketizer!(FreeList!(BA, 0, unbounded), 1, 128, 16),
	256, Bucketizer!(FreeList!(BA, 0, unbounded), 129, 256, 32),
	512, Bucketizer!(FreeList!(BA, 0, unbounded), 257, 512, 64),
	1024, Bucketizer!(FreeList!(BA, 0, unbounded), 513, 1024, 128),
	2048, Bucketizer!(FreeList!(BA, 0, unbounded), 1025, 2048, 256),
	3584, Bucketizer!(FreeList!(BA, 0, unbounded), 2049, 3584, 512),
	/*
		medium sizes (3.6K~4072Ki), just serve each alloc with its own region, rounded up to 4MB for efficiency.
		note that allocatorlist will free regions if at least two of them are empty
		but it will reuse the empty one its holding if asked for an allocation, sorta like a freelist but not quite.
	 */
	4072 * 1024, AllocatorList!(n => Region!BA(max(n, 1024 * 4096)), NullAllocator),

	// above ~4MB, just pass allocations direct to the backing allocator
	BA
);


version (YSBase_GC)
	// `GCAllocator` must be used as the user has disabled all automatic free() calls in this library
	alias YSBAllocator = GCAllocator;
else
{
	// use the general allocator on top of c malloc() by default
	alias YSBAllocator = YSBGeneralAllocator!Mallocator;

	// TODO: this throws a "No GC was initialized" error.
	/* version (YSBase_NoGlobalAlloc) {}
	else
		// `theAllocator` will be created on top of `processAllocator` if it does not exist, when first accessed.
		// without this set, `processAllocator` would be automatically set to a `GCAllocator` when first accessed.
		pragma(crt_constructor)
		private extern (C) void setGlobalAllocators()
		{
			processAllocator = sharedAllocatorObject(YSBAllocator());
		} */
}

// TODO: once I've got a way to forward attributes, redefine make, etc.
