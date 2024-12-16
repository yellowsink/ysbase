/++
This module contains composable building blocks and utilities for memory allocation.

It re-exports all members of `std.experimental.allocator` or `stdx.allocator`, and the `.building_blocks` package.
It also contains YSBase's own allocation tools, such the `YSBGeneralAllocator` allocator, the `YSBAllocator` alias,
and the static constructor that sets the global `theAllocator` and `processAllocator` to `YSBAllocator`.

It also contains some additional building blocks, notably shared version of the standard building blocks.
The standard library's building blocks only allow themselves to be `shared` when they are stateless, whereas these ones
will allow the inner state to be `shared`.

When `version (YSBase_GC)` is defined, `YSBAllocator` will be `GCAllocator`.

All allocators and allocation functions (`make` etc.) are `@safe`, `nothrow`, `pure`, etc. if and only
if the template arguments they have been given allow them to be so.

$(SRCL ysbase/allocation/package.d)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.allocation;

/* version (YSBase_GC) {}
else version = YSBase_Manual_Free; */

public import ysbase.allocation.source_reexport;

public import ysbase.allocation.building_blocks;

import ysbase.allocation.building_blocks.shared_bucketizer;

import std.algorithm : max;

version (D_Ddoc)
	mixin template EncapsulatedMallocator() { Mallocator alloc; alias alloc this; }

/**
* A general purpose allocator designed for general-purpose use.
* It is modelled after jemalloc.
* It is `shared`-safe (if desired), so you may pass memory to another thread and `deallocate` it there.
*
* Params:
* 	BA = The $(U b)acking $(U a)llocator to obtain memory from.
*/
version (D_Ddoc)
	struct YSBGeneralAllocator(BA) { mixin EncapsulatedMallocator; }
else
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
	/// The default allocator used internally $(I by default) by YSBase, and is automatically assigned to `theAllocator`.
	version (D_Ddoc)
		struct YSBAllocator { mixin EncapsulatedMallocator; }
	else
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
