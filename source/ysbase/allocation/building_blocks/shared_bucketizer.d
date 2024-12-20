/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.allocation.building_blocks.shared_bucketizer;

/++
A version of Phobos' `Bucketizer` but `shared`, and requires the `Allocator` to be shared.

This allocator uses distinct allocator instances for each in a set of "buckets", so allocations with size in the range
$(D [min, min + step$(RPAREN)) go to the first allocator, and $(D [min + step, min + step * 2$(RPAREN)) to the next bucket, and so on.

Allocations directed to this allocator larger than `max` or smaller than `min` will fail safely.
Try using $(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks_segregator.html, `Segregator`).

$(SRCL ysbase/allocation/building_blocks/shared_bucketizer.d)

Params:
	Allocator =	The parent allocator to redirect allocation requests to. Must have `allocate() shared`.
	min =			The minimum allocation size served by this allocator.
	max =			The maximum allocation size served by this allocator.
	step =		The size of the range of sizes to be directed to each bucket. Must be a factor of `max - min`.

See_Also:
$(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks_bucketizer.html, Phobos' `Bucketizer`)
+/
shared struct SharedBucketizer(Allocator, size_t min, size_t max, size_t step)
{
		import ysbase.allocation.source_reexport : roundUpToMultipleOf, alignedAt;
		import common = ysbase.allocation.source_reexport;
		import std.traits : hasMember, hasFunctionAttributes;
		import std.typecons : Ternary;

		static assert((max - (min - 1)) % step == 0,
				"Invalid limits when instantiating " ~ Bucketizer.stringof);

		static assert(hasMember!(Allocator, "allocate")
			&& hasFunctionAttributes!(Allocator.allocate, "shared"),
				"Allocator must offer shared allocation");

		// state
		/**
		The array of allocators is publicly available for e.g. initialization and
		inspection.
		*/
		Allocator[(max + 1 - min) / step] buckets;

		pure nothrow @safe @nogc
		private shared(Allocator)* allocatorFor(size_t n)
		{
				const i = (n - min) / step;
				return i < buckets.length ? &buckets[i] : null;
		}

		/// The alignment offered is the same as `Allocator.alignment`.
		enum uint alignment = Allocator.alignment;

		/// Rounds up to the maximum size of the bucket in which `bytes` falls.
		pure nothrow @safe @nogc
		size_t goodAllocSize(size_t bytes) const
		{
				// round up bytes such that bytes - min + 1 is a multiple of step
				assert(bytes >= min);
				const min_1 = min - 1;
				return min_1 + roundUpToMultipleOf(bytes - min_1, step);
		}

		/// Directs the call to either one of the `buckets` allocators.
		void[] allocate(size_t bytes)
		{
				if (!bytes) return null;
				if (auto a = allocatorFor(bytes))
				{
						const actual = goodAllocSize(bytes);
						auto result = a.allocate(actual);
						return result.ptr ? result.ptr[0 .. bytes] : null;
				}
				return null;
		}

		/// Directs the call to either one of the `buckets` allocators.
		static if (hasMember!(Allocator, "allocateZeroed"))
		void[] allocateZeroed()(size_t bytes)
		{
				if (!bytes) return null;
				if (auto a = allocatorFor(bytes))
				{
						const actual = goodAllocSize(bytes);
						auto result = a.allocateZeroed(actual);
						return result.ptr ? result.ptr[0 .. bytes] : null;
				}
				return null;
		}

		/**
		Allocates the requested `bytes` of memory with specified `alignment`.
		Directs the call to either one of the `buckets` allocators. Defined only
		if `Allocator` defines `alignedAllocate`.
		*/
		static if (hasMember!(Allocator, "alignedAllocate"))
		void[] alignedAllocate(size_t bytes, uint alignment)
		{
				if (!bytes) return null;
				if (auto a = allocatorFor(bytes))
				{
						const actual = goodAllocSize(bytes);
						auto result = a.alignedAllocate(actual, alignment);
						return result !is null ? (() @trusted => (&result[0])[0 .. bytes])() : null;
				}
				return null;
		}

		/**
		This method allows expansion within the respective bucket range. It succeeds
		if both `b.length` and $(D b.length + delta) fall in a range of the form
		$(D [min + k * step, min + (k + 1) * step$(RPAREN)).
		*/
		bool expand(ref void[] b, size_t delta)
		{
				if (!b || delta == 0) return delta == 0;
				assert(b.length >= min && b.length <= max);
				const available = goodAllocSize(b.length);
				const desired = b.length + delta;
				if (available < desired) return false;
				b = (() @trusted => b.ptr[0 .. desired])();
				return true;
		}

		/**
		This method allows reallocation within the respective bucket range. If both
		`b.length` and `size` fall in a range of the form $(D [min + k *
		step, min + (k + 1) * step$(RPAREN)), then reallocation is in place. Otherwise,
		reallocation with moving is attempted.
		*/
		bool reallocate(ref void[] b, size_t size)
		{
				if (size == 0)
				{
						deallocate(b);
						b = null;
						return true;
				}
				if (size >= b.length && expand(b, size - b.length))
				{
						return true;
				}
				assert(b.length >= min && b.length <= max);
				if (goodAllocSize(size) == goodAllocSize(b.length))
				{
						b = b.ptr[0 .. size];
						return true;
				}
				// Move cross buckets
				return common.reallocate(this, b, size);
		}

		/// Similar to `reallocate`, with alignment. Defined only if `Allocator` defines `alignedReallocate`.
		static if (hasMember!(Allocator, "alignedReallocate"))
		bool alignedReallocate(ref void[] b, size_t size, uint a)
		{
				if (size == 0)
				{
						deallocate(b);
						b = null;
						return true;
				}
				if (size >= b.length && b.ptr.alignedAt(a) && expand(b, size - b.length))
				{
						return true;
				}
				assert(b.length >= min && b.length <= max);
				if (goodAllocSize(size) == goodAllocSize(b.length) && b.ptr.alignedAt(a))
				{
						b = b.ptr[0 .. size];
						return true;
				}
				// Move cross buckets
				return common.alignedReallocate(this, b, size, a);
		}

		/// Defined only if `Allocator` defines `owns`. Finds the owner of `b` and forwards the call to it.
		static if (hasMember!(Allocator, "owns"))
		Ternary owns(void[] b)
		{
				if (!b.ptr) return Ternary.no;
				if (auto a = allocatorFor(b.length))
				{
						const actual = goodAllocSize(b.length);
						return a.owns(b.ptr[0 .. actual]);
				}
				return Ternary.no;
		}

		/// This method is only defined if `Allocator` defines `deallocate`.
		static if (hasMember!(Allocator, "deallocate"))
		bool deallocate(void[] b)
		{
				if (!b.ptr) return true;
				if (auto a = allocatorFor(b.length))
				{
						a.deallocate(b.ptr[0 .. goodAllocSize(b.length)]);
				}
				return true;
		}

		/**
		This method is only defined if all allocators involved define $(D
		deallocateAll), and calls it for each bucket in turn. Returns `true` if all
		allocators could deallocate all.
		*/
		static if (hasMember!(Allocator, "deallocateAll"))
		bool deallocateAll()
		{
				bool result = true;
				foreach (ref a; buckets)
				{
						if (!a.deallocateAll()) result = false;
				}
				return result;
		}

		/**
		This method is only defined if all allocators involved define $(D
		resolveInternalPointer), and tries it for each bucket in turn.
		*/
		static if (hasMember!(Allocator, "resolveInternalPointer"))
		Ternary resolveInternalPointer(const void* p, ref void[] result)
		{
				foreach (ref a; buckets)
				{
						Ternary r = a.resolveInternalPointer(p, result);
						if (r == Ternary.yes) return r;
				}
				return Ternary.no;
		}
}

unittest
{
	import ysbase.allocation.building_blocks.shared_bucketizer;
	import ysbase.allocation;
	alias A = SharedBucketizer!(SharedFreeList!(GCAllocator, 0, unbounded), 1, 128, 16);

	shared A a;
	shared b = a;
}

unittest
{
	import ysbase.allocation.building_blocks.shared_bucketizer;
	import ysbase.allocation;
	alias a = SharedBucketizer!(SharedFreeList!(GCAllocator, 0, unbounded), 1, 128, 16);


	// TODO: need a shared segregator :(
	//shared Segregator!(8, a, a) b;
	a b;

	import core.thread.osthread;

	auto slic = b.allocate(50);

	new Thread({
		// shared!
		b.deallocate(slic);
	}).start().join();
}
