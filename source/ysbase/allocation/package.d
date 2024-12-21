/++
This module contains composable building blocks and utilities for memory allocation.

It re-exports all members of `std.experimental.allocator` or `stdx.allocator`, and the `.building_blocks` package.
It also contains YSBase's own allocation tools, such the `YSBGeneralAllocator` allocator, the `YSBAllocator` alias,
and the static constructor that sets the global `theAllocator` and `processAllocator` to `YSBAllocator`.

It also contains some additional building blocks, notably shared version of the standard building blocks.
The standard library's building blocks only allow themselves to be `shared` when they are stateless, whereas these ones
will allow the inner state to be `shared`.

When `version (YSBase_GC)` is defined, `YSBAllocator` will be `GCAllocator`, else it is a
$(D YSBGeneralAllocator!Mallocator).

All allocators and allocation functions (`make` etc.) are `@safe`, `nothrow`, `pure`, etc. if and only
if the template arguments they have been given allow them to be so.

<h2>New Building Blocks:</h2>
$(UL
	$(LI $(LINK2 allocation/building_blocks/parametric_mallocator.html, $(D ParametricMallocator) (and $(D Mallocator))))
	$(LI $(LINK2 allocation/building_blocks/shared_bucketizer/SharedBucketizer.html, $(D SharedBucketizer)))
	$(LI $(LINK2 allocation/building_blocks/shared_segregator/SharedSegregator.html, $(D SharedSegregator)))
	$(LI $(LINK2 allocation/building_blocks/shared_region.html, $(D SharedRegion), $(D SharedBorrowedRegion), $(D SharedInSituRegion)))
)

<h2>Other Re-Exports:</h2>
$(UL
	$(LI $(LINK2 https://dlang.org/phobos/std_experimental_allocator.html, $(D std.experimental.allocator)))
	$(LI $(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks.html, $(D std.experimental.allocator.building_blocks)))
)

(or `stdx.allocator` equivalents).

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

import std.algorithm : max;

version (D_Ddoc)
	mixin template EncapsulatedMallocator() {
		Mallocator alloc;
		// sigh.
		enum alignment = Mallocator.alignment;
		auto allocate(size_t s) => alloc.allocate(s);
		auto allocateZeroed(size_t s) => alloc.allocateZeroed(s);
		auto deallocate(void[] p) => alloc.deallocate(p);
		auto reallocate(ref void[] p, size_t s) => alloc.reallocate(p, s);
	}

/**
* A general purpose allocator designed for general-purpose use.
* It is modelled after jemalloc.
* It is `shared`-safe (if desired), so you may pass memory to another thread and `deallocate` it there.
*
* $(SRCLL ysbase/allocation/package.d, 78)
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
alias YSBGeneralAllocator(BA) = SharedSegregator!(
	// small size extents, kept forever and reused.
	8, SharedFreeList!(BA, 0, 8),
	128, SharedBucketizer!(SharedFreeList!(BA, 0, unbounded), 1, 128, 16),
	256, SharedBucketizer!(SharedFreeList!(BA, 0, unbounded), 129, 256, 32),
	512, SharedBucketizer!(SharedFreeList!(BA, 0, unbounded), 257, 512, 64),
	1024, SharedBucketizer!(SharedFreeList!(BA, 0, unbounded), 513, 1024, 128),
	2048, SharedBucketizer!(SharedFreeList!(BA, 0, unbounded), 1025, 2048, 256),
	3584, SharedBucketizer!(SharedFreeList!(BA, 0, unbounded), 2049, 3584, 512),
	/*
		medium sizes (3.6K~4072Ki), just serve each alloc with its own region, rounded up to 4MB for efficiency.
		note that allocatorlist will free regions if at least two of them are empty
		but it will reuse the empty one its holding if asked for an allocation, sorta like a freelist but not quite.
	 */
	// temporarily disabled while i get a shared allocator list working
	//4072 * 1024, AllocatorList!(n => Region!BA(max(n, 1024 * 4096)), NullAllocator),

	// above ~4MB, just pass allocations direct to the backing allocator
	BA
);


version (YSBase_GC)
	// `GCAllocator` must be used as the user has disabled all automatic free() calls in this library
	alias YSBAllocator = GCAllocator;
else
{
	/// The allocator used internally $(I by default) by YSBase, automatically assigned to `processAllocator`.
	version (D_Ddoc)
		shared struct YSBAllocator { mixin EncapsulatedMallocator; }
	else
		// use the general allocator on top of c malloc() by default
		alias YSBAllocator = YSBGeneralAllocator!Mallocator;

	version (YSBase_NoGlobalAlloc) {}
	else
	{
		private shared YSBAllocator _global_process_allocator;
		private shared bool _global_procalloc_inited = false;

		static this()
		{
			import core.atomic : atomicLoad, atomicStore;

			// this will run in newly created threads as well.
			// this also gives each thread its own memory which makes
			// deallocating it from the wrong thread *spicy*

			// set the global process allocator to an instance of YSBAllocator if not already done so
			if (!atomicLoad(_global_procalloc_inited))
				processAllocator = sharedAllocatorObject(_global_process_allocator); // must pass by ref

			atomicStore(_global_procalloc_inited, true);

			// by default theAllocator is automatically initialized to defer to the global one,
			// but while this works, it is not ideal to share the allocator state among threads,
			// and in fact it is more efficient to give each thread its own new instance of the allocator
			// TODO
			//theAllocator = allocatorObject(talloc);
		}
	}
}

/* unittest
{
	import std.experimental.allocator : theAllocator;
	import core.memory : GC;
	import std.stdio;

	YSBGeneralAllocator!(shared(GCAllocator)) gca;

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
} */

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
