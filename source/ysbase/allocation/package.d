module ysbase.allocation;

/* version (YSBase_GC) {}
else version = YSBase_Manual_Free; */

public import ysbase.allocation.source_reexport;

public import ysbase.allocation.building_blocks;

import ysbase.allocation.building_blocks.shared_bucketizer;

import std.algorithm : max;

// based on jemalloc
// https://jemalloc.net/jemalloc.3.html#size_classes
// should be pretty good for general purpose application use
alias YSBGeneralAllocator(BA) = Segregator!(
	// small size extents, kept forever and reused.
	// TODO: freelist forces this to not be `shared`
	// (segregator supports shared if all allocators in it are shared)
	8, /* Shared */FreeList!(BA, 0, 8),
	128, /* Shared */Bucketizer!(/* Shared */FreeList!(BA, 0, unbounded), 1, 128, 16),
	256, /* Shared */Bucketizer!(/* Shared */FreeList!(BA, 0, unbounded), 129, 256, 32),
	512, /* Shared */Bucketizer!(/* Shared */FreeList!(BA, 0, unbounded), 257, 512, 64),
	1024, /* Shared */Bucketizer!(/* Shared */FreeList!(BA, 0, unbounded), 513, 1024, 128),
	2048, /* Shared */Bucketizer!(/* Shared */FreeList!(BA, 0, unbounded), 1025, 2048, 256),
	3584, /* Shared */Bucketizer!(/* Shared */FreeList!(BA, 0, unbounded), 2049, 3584, 512),
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

	version (YSBase_NoGlobalAlloc) {}
	else
		static this()
		{
			// this will run in newly created threads as well.
			// this also gives each thread its own memory which makes
			// deallocating it from the wrong thread *spicy*

			// TODO: implement shared FreeList, Bucketizer, AllocatorList, Region such that YSBAllocator may be shared.
			// this will allow us to deallocate memory allocated by other threads' theAllocator.
			//shared YSBAllocator alloc;
			//processAllocator = sharedAllocatorObject(alloc); // must pass by ref
			theAllocator = allocatorObject(YSBAllocator());
		}
}

unittest
{
	import std.experimental.allocator : theAllocator;
	import core.memory : GC;
	import std.stdio;

	YSBGeneralAllocator!GCAllocator gca;

	// allocate a bunch of stuff
	writeln("           (used, freed, N/A)");
	writeln("baseline:   ", GC.stats);

	auto arr1 = gca.makeArray!int(500);

	GC.collect();
	writeln("alloc 2k:   ", GC.stats);

	gca.dispose(arr1);

	GC.collect();
	writeln("dealloc 2k: ", GC.stats);

	auto arr2 = gca.makeArray!int(250);
	GC.collect();
	writeln("alloc 1k:   ", GC.stats);

	auto arr3 = gca.makeArray!int(250);
	GC.collect();
	writeln("alloc 1k:   ", GC.stats);

	auto arr4 = gca.makeArray!int(500);
	GC.collect();
	writeln("alloc 2k:   ", GC.stats);
}

private import std.traits : isSafe;

private enum isUnsafe(alias F) = !isSafe!F;

// allocate() is safe
static assert(isSafe!({ Mallocator.instance.make!int; }));

static assert(isSafe!({ Mallocator.instance.makeArray!int(5); }));

static assert(isSafe!({ Mallocator.instance.makeMultidimensionalArray!int(5, 5, 6, 8); }));

// reallocate() isn't safe
static assert(isUnsafe!({ int[] arr; Mallocator.instance.expandArray(arr, 5); }));

static assert(isUnsafe!({ int[] arr; Mallocator.instance.shrinkArray(arr, 5); }));

// destroying objects isn't safe.
static assert(isUnsafe!({ int* x; Mallocator.instance.dispose(x); }));
