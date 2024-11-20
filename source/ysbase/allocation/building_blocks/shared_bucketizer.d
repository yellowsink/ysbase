module ysbase.allocation.building_blocks.shared_bucketizer;

// std.experimental.bucketizer but `shared`, and requires `Allocator` to be shared

shared struct SharedBucketizer(Allocator, size_t min, size_t max, size_t step)
{
		import ysbase.allocation.source_reexport : roundUpToMultipleOf, alignedAt;
		import common = ysbase.allocation.source_reexport;
		import std.traits : hasMember;
		import std.typecons : Ternary;

		static assert((max - (min - 1)) % step == 0,
				"Invalid limits when instantiating " ~ Bucketizer.stringof);

		// state
		/**
		The array of allocators is publicly available for e.g. initialization and
		inspection.
		*/
		shared(Allocator)[(max + 1 - min) / step] buckets;

		pure nothrow @safe @nogc
		private shared(Allocator)* allocatorFor(size_t n)
		{
				const i = (n - min) / step;
				return i < buckets.length ? &buckets[i] : null;
		}

		/**
		The alignment offered is the same as `Allocator.alignment`.
		*/
		enum uint alignment = Allocator.alignment;

		/**
		Rounds up to the maximum size of the bucket in which `bytes` falls.
		*/
		pure nothrow @safe @nogc
		size_t goodAllocSize(size_t bytes) const
		{
				// round up bytes such that bytes - min + 1 is a multiple of step
				assert(bytes >= min);
				const min_1 = min - 1;
				return min_1 + roundUpToMultipleOf(bytes - min_1, step);
		}

		/**
		Directs the call to either one of the `buckets` allocators.
		*/
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

		static if (hasMember!(Allocator, "allocateZeroed"))
		package(std) void[] allocateZeroed()(size_t bytes)
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
		$(D [min + k * step, min + (k + 1) * step - 1]).
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
		step, min + (k + 1) * step - 1]), then reallocation is in place. Otherwise,
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

		/**
		Similar to `reallocate`, with alignment. Defined only if `Allocator`
		defines `alignedReallocate`.
		*/
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

		/**
		Defined only if `Allocator` defines `owns`. Finds the owner of `b` and forwards the call to it.
		*/
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

		/**
		This method is only defined if `Allocator` defines `deallocate`.
		*/
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

// TODO: why is this not working when in a segregator?
enum isShared1 = is(typeof(SharedBucketizer!Mallocator) == shared);
enum isShared2 = !stateSize!(SharedBucketizer!Mallocator);

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


	shared Segregator!(8, a, a) b;
	//shared SharedBucketizer!Mallocator b;

	b.allocate(50);
}
