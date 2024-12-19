/++
A version of Phobos' `Region` but `shared`.

All operations are lock-free and atomic.

The real implementation is really in $(D SharedBorrowedRegion), the other two are wrappers over it that automatically
manage backing for, and forward operations to it.

Currently $(D expand()) is missing because, in all honesty, lock-free is hard -- Hazel.

$(SRCL ysbase/allocation/building_blocks/shared_region.d)

See_Also:
$(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html, Phobos' `Region`)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.allocation.building_blocks.shared_region;

import ysbase.allocation;
import std.typecons;

/**
A `Region` allocator allocates memory straight from one contiguous chunk.
There is no deallocation, and once the region is full, allocation requests
return `null`. Therefore, `Region`s are often used (a) in conjunction with
more sophisticated allocators; or (b) for batch-style very fast allocations
that deallocate everything at once.

The region stores three pointers, corresponding to the current position in
the store and the limits. One allocation entails rounding up the allocation
size for alignment purposes, bumping the current pointer, and comparing it
against the limit.

`Region` deallocates the chunk of memory during destruction.

The `minAlign` parameter establishes alignment. If $(D minAlign > 1), the
sizes of all allocation requests are rounded up to a multiple of `minAlign`.
Applications aiming at maximum speed may want to choose $(D minAlign = 1) and
control alignment externally.

$(SRCLL ysbase/allocation/building_blocks/shared_region.d, 46)
*/
shared struct SharedRegion(ParentAllocator,
	uint minAlign = platformAlignment,
	Flag!"growDownwards" growDownwards = No.growDownwards)
{
	static assert(minAlign.isGoodStaticAlignment);
	static assert(ParentAllocator.alignment >= minAlign);

	import std.traits : hasMember;
	import std.typecons : Ternary;

	// state
	/**
    The _parent allocator. Depending on whether `ParentAllocator` holds state
    or not, this is a member variable or an alias for
    `ParentAllocator.instance`.
    */
	static if (stateSize!ParentAllocator)
	{
		ParentAllocator parent;
	}
	else
	{
		alias parent = ParentAllocator.instance;
	}

	private SharedBorrowedRegion!(minAlign, growDownwards) _impl;

	private void* roundedBegin() const pure nothrow @trusted @nogc
	{
		return _impl.roundedBegin;
	}

	private void* roundedEnd() const pure nothrow @trusted @nogc
	{
		return _impl.roundedEnd;
	}
	/**
    Constructs a region backed by a user-provided store.
    Assumes the memory was allocated with `ParentAllocator`.

    Params:
        store = User-provided store backing up the region. Assumed to have been
        allocated with `ParentAllocator`.
        n = Bytes to allocate using `ParentAllocator`. If `parent.allocate(n)`
        returns `null`, the region will be initialized as empty (correctly
        initialized but unable to allocate).
        */
	this(ubyte[] store) pure nothrow @nogc
	{
		_impl = store;
	}

	/// Ditto
	static if (!stateSize!ParentAllocator)
		this(size_t n)
		{
			this(cast(ubyte[])(parent.allocate(n.roundUpToAlignment(alignment))));
		}

	/// Ditto
	static if (stateSize!ParentAllocator)
		this(ParentAllocator parent, size_t n)
		{
			this.parent = parent;
			this(cast(ubyte[])(parent.allocate(n.roundUpToAlignment(alignment))));
		}

	/*
    TODO: The postblit of `BasicRegion` should be disabled because such objects
    should not be copied around naively.
    */

	/**
    If `ParentAllocator` defines `deallocate`, the region defines a destructor
    that uses `ParentAllocator.deallocate` to free the memory chunk.
    */
	static if (hasMember!(ParentAllocator, "deallocate"))
		 ~this()
		{
			with (_impl)
				parent.deallocate(_begin[0 .. _end - _begin]);
		}

	/**
    Rounds the given size to a multiple of the `alignment`
    */
	size_t goodAllocSize(size_t n) const pure nothrow @safe @nogc
	{
		return _impl.goodAllocSize(n);
	}

	/**
    Alignment offered.
    */
	alias alignment = minAlign;

	/**
    Allocates `n` bytes of memory. The shortest path involves an alignment
    adjustment (if $(D alignment > 1)), an increment, and a comparison.

    Params:
        n = number of bytes to allocate

    Returns:
        A properly-aligned buffer of size `n` or `null` if request could not
        be satisfied.
    */
	void[] allocate(size_t n) pure nothrow @trusted @nogc
	{
		return _impl.allocate(n);
	}

	/**
    Allocates `n` bytes of memory aligned at alignment `a`.

    Params:
        n = number of bytes to allocate
        a = alignment for the allocated block

    Returns:
        Either a suitable block of `n` bytes aligned at `a`, or `null`.
    */
	void[] alignedAllocate(size_t n, uint a) pure nothrow @trusted @nogc
	{
		return _impl.alignedAllocate(n, a);
	}

	/// Allocates and returns all memory available to this region.
	void[] allocateAll() pure nothrow @trusted @nogc
	{
		return _impl.allocateAll;
	}

	/+ /**
    Expands an allocated block in place. Expansion will succeed only if the
    block is the last allocated. Defined only if `growDownwards` is
    `No.growDownwards`.
    */
	static if (growDownwards == No.growDownwards)
		bool expand(ref void[] b, size_t delta) pure nothrow @safe @nogc
		{
			return _impl.expand(b, delta);
		} +/

	/**
    Deallocates `b`. This works only if `b` was obtained as the last call
    to `allocate`; otherwise (i.e. another allocation has occurred since) it
    does nothing.

    Params:
        b = Block previously obtained by a call to `allocate` against this
        allocator (`null` is allowed).
    */
	bool deallocate(void[] b) pure nothrow @nogc
	{
		return _impl.deallocate(b);
	}

	/**
    Deallocates all memory allocated by this region, which can be subsequently
    reused for new allocations.
    */
	bool deallocateAll() pure nothrow @nogc
	{
		return _impl.deallocateAll;
	}

	/**
    Queries whether `b` has been allocated with this region.

    Params:
        b = Arbitrary block of memory (`null` is allowed; `owns(null)` returns
        `false`).

    Returns:
        `true` if `b` has been allocated with this region, `false` otherwise.
    */
	Ternary owns(const void[] b) const pure nothrow @trusted @nogc
	{
		return _impl.owns(b);
	}

	/**
    Returns `Ternary.yes` if no memory has been allocated in this region,
    `Ternary.no` otherwise. (Never returns `Ternary.unknown`.)
    */
	Ternary empty() const pure nothrow @safe @nogc
	{
		return _impl.empty;
	}

	/// Nonstandard property that returns bytes available for allocation.
	size_t available() const @safe pure nothrow @nogc
	{
		return _impl.available;
	}
}

/**
A `BorrowedRegion` allocates directly from a user-provided block of memory.

Unlike a `Region`, a `BorrowedRegion` does not own the memory it allocates from
and will not deallocate that memory upon destruction. Instead, it is the user's
responsibility to ensure that the memory is properly disposed of.

In all other respects, a `BorrowedRegion` behaves exactly like a `Region`.

$(SRCLL ysbase/allocation/building_blocks/shared_region.d, 255)
*/
shared struct SharedBorrowedRegion(uint minAlign = platformAlignment,
	Flag!"growDownwards" growDownwards = No.growDownwards)
{
	static assert(minAlign.isGoodStaticAlignment);

	import std.typecons : Ternary;

	import core.atomic;

	// state
	private shared void* _current;
	// set only in the constructor, safe to share
	private __gshared void* _begin, _end;

	private void* roundedBegin() const pure nothrow @trusted @nogc
	{
		return cast(void*) roundUpToAlignment(cast(size_t) _begin, alignment);
	}

	private void* roundedEnd() const pure nothrow @trusted @nogc
	{
		return cast(void*) roundDownToAlignment(cast(size_t) _end, alignment);
	}

	/**
    Constructs a region backed by a user-provided store.

    Params:
        store = User-provided store backing up the region.
    */
	this(ubyte[] store) pure nothrow @nogc
	{
		_begin = store.ptr;
		_end = store.ptr + store.length;
		static if (growDownwards)
			_current = roundedEnd();
		else
			_current = roundedBegin();
	}

	/*
    TODO: The postblit of `BorrowedRegion` should be disabled because such objects
    should not be copied around naively.
    */

	/**
    Rounds the given size to a multiple of the `alignment`
    */
	size_t goodAllocSize(size_t n) const pure nothrow @safe @nogc
	{
		return n.roundUpToAlignment(alignment);
	}

	/**
    Alignment offered.
    */
	alias alignment = minAlign;

	/**
    Allocates `n` bytes of memory. The shortest path involves an alignment
    adjustment (if $(D alignment > 1)), an increment, and a comparison.

    Params:
        n = number of bytes to allocate

    Returns:
        A properly-aligned buffer of size `n` or `null` if request could not
        be satisfied.
    */
	void[] allocate(size_t n) pure nothrow @trusted @nogc
	{
		const rounded = goodAllocSize(n);
		if (n == 0 || rounded < n || available < rounded)
			return null;

		static if (growDownwards)
		{
			assert(available >= rounded);
			//auto result = (atomicLoad(_current) - rounded)[0 .. n];
			assert((_current.atomicLoad - rounded) >= _begin);
			//_current = result.ptr;
			auto result = _current.atomicOp!"-="(rounded)[0 .. n];
			assert(owns(result) == Ternary.yes);
		}
		else
		{
			auto result = atomicFetchAdd(_current, rounded)[0 .. n];
			//_current += rounded;
		}

		return result;
	}

	/**
    Allocates `n` bytes of memory aligned at alignment `a`.

    Params:
        n = number of bytes to allocate
        a = alignment for the allocated block

    Returns:
        Either a suitable block of `n` bytes aligned at `a`, or `null`.
    */
	void[] alignedAllocate(size_t n, uint a) pure nothrow @trusted @nogc
	{
		import std.math.traits : isPowerOf2;

		assert(a.isPowerOf2);

		const rounded = goodAllocSize(n);
		if (n == 0 || rounded < n || available < rounded)
			return null;

		static if (growDownwards)
		{
			auto savedCurr = _current.atomicLoad;

			// cas loop
			for (;;)
			{
				auto tmpCurrent = savedCurr - rounded;
				auto result = tmpCurrent.alignDownTo(a);
				if (result <= tmpCurrent && result >= _begin)
				{
					// _current = result;
					if (casWeak(&_current, &savedCurr, result))
						return cast(void[]) result[0 .. n];
				}
				else break;
			}
		}
		else
		{
			// bump the pointer so the start is aligned
			auto savedCurrent = _current.atomicLoad;

			// CAS loop
			for (;;)
			{
				auto alignedOldCurrent = savedCurrent.alignUpTo(a);
				if (alignedOldCurrent < savedCurrent || alignedOldCurrent > _end)
					return null;

				// inlining and tweaking allocate() isn't the greatest, but it can't operate on the real state.
				auto availableSpurious = _end - alignedOldCurrent;
				if (n == 0 || rounded < n || availableSpurious < rounded)
					return null;

				auto bumpedCurrent = alignedOldCurrent + rounded;

				if (casWeak(&_current, &savedCurrent, bumpedCurrent))
					return bumpedCurrent[0 .. n];
			}
		}
		return null;
	}

	/// Allocates and returns all memory available to this region.
	void[] allocateAll() pure nothrow @trusted @nogc
	{
		static if (growDownwards)
		{
			//auto result = _begin[0 .. (_current - _begin)];
			//_current = _begin;

			auto oldCurrent = atomicExchange(_current, _begin);
			auto result = _begin[0 .. (oldCurrent - _begin)];
		}
		else
		{
			//auto result = _current[0 .. (_end - _current)];
			//_current = _end;

			auto oldCurrent = atomicExchange(_current, _end);
			auto result = oldCurrent[0 .. (_end - oldCurrent)];
		}
		return result;
	}

	// TODO: lock-free expand()
/+
	/**
    Expands an allocated block in place. Expansion will succeed only if the
    block is the last allocated. Defined only if `growDownwards` is
    `No.growDownwards`.
    */
	static if (growDownwards == No.growDownwards)
		bool expand(ref void[] b, size_t delta) pure nothrow @safe @nogc
		{
			assert(owns(b) == Ternary.yes || b is null);
			assert((() @trusted => b.ptr + b.length <= _current)() || b is null);
			if (b is null || delta == 0)
				return delta == 0;

			auto newLength = b.length + delta;

			if ((()@trusted => _current < b.ptr + b.length + alignment)())
				{
				immutable currentGoodSize = this.goodAllocSize(b.length);
				immutable newGoodSize = this.goodAllocSize(newLength);
				immutable goodDelta = newGoodSize - currentGoodSize;

				// This was the last allocation! Allocate some more and we're done.
				if (goodDelta == 0
					|| (()@trusted => allocate(goodDelta).length == goodDelta)())
					{
					b = (() @trusted => b.ptr[0 .. newLength])();
					assert((() @trusted => _current < b.ptr + b.length + alignment)());
					return true;
				}
			}
			return false;
		}
+/
	/**
    Deallocates `b`. This works only if `b` was obtained as the last call
    to `allocate`; otherwise (i.e. another allocation has occurred since) it
    does nothing.

    Params:
        b = Block previously obtained by a call to `allocate` against this
        allocator (`null` is allowed).
    */
	bool deallocate(void[] b) pure nothrow @nogc
	{
		assert(owns(b) == Ternary.yes || b.ptr is null);
		auto rounded = goodAllocSize(b.length);
		static if (growDownwards)
		{
			/* if (b.ptr == _current)
			{
				_current += rounded;
				return true;
			} */

			auto p = b.ptr;
			return cas(&_current, &p, p + rounded);
		}
		else
		{
			if (b.ptr + rounded == _current)
			{
				assert(b.ptr !is null || _current is null);
				_current = b.ptr;
				return true;
			}

			auto p = b.ptr + rounded;
			return cas(&_current, &p, b.ptr);
		}
		return false;
	}

	/**
    Deallocates all memory allocated by this region, which can be subsequently
    reused for new allocations.
    */
	bool deallocateAll() pure nothrow @nogc
	{
		static if (growDownwards)
		{
			_current.atomicStore(roundedEnd());
		}
		else
		{
			_current.atomicStore(roundedBegin());
		}
		return true;
	}

	/**
    Queries whether `b` has been allocated with this region.

    Params:
        b = Arbitrary block of memory (`null` is allowed; `owns(null)` returns
        `false`).

    Returns:
        `true` if `b` has been allocated with this region, `false` otherwise.
    */
	Ternary owns(const void[] b) const pure nothrow @trusted @nogc
	{
		return Ternary(b && (&b[0] >= _begin) && (&b[0] + b.length <= _end));
	}

	/**
    Returns `Ternary.yes` if no memory has been allocated in this region,
    `Ternary.no` otherwise. (Never returns `Ternary.unknown`.)
    */
	Ternary empty() const pure nothrow @safe @nogc
	{
		static if (growDownwards)
			return Ternary(_current.atomicLoad == roundedEnd());
		else
			return Ternary(_current.atomicLoad == roundedBegin());
	}

	/// Nonstandard property that returns bytes available for allocation.
	size_t available() const @safe pure nothrow @nogc
	{
		static if (growDownwards)
		{
			return _current.atomicLoad - _begin;
		}
		else
		{
			return _end - _current.atomicLoad;
		}
	}
}


/**
`InSituRegion` is a convenient region that carries its storage within itself
(in the form of a statically-sized array).

The first template argument is the size of the region and the second is the
needed alignment. Depending on the alignment requested and platform details,
the actual available storage may be smaller than the compile-time parameter. To
make sure that at least `n` bytes are available in the region, use
$(D InSituRegion!(n + a - 1, a)).

Given that the most frequent use of `InSituRegion` is as a stack allocator, it
allocates starting at the end on systems where stack grows downwards, such that
hot memory is used first.

$(SRCLL ysbase/allocation/building_blocks/shared_region.d, 583)
*/
shared struct SharedInSituRegion(size_t size, size_t minAlign = platformAlignment)
{
	import std.algorithm.comparison : max;
	import std.conv : to;
	import std.traits : hasMember;
	import std.typecons : Ternary;
	import core.thread.types : isStackGrowingDown;

	static assert(minAlign.isGoodStaticAlignment);
	static assert(size >= minAlign);

	static if (isStackGrowingDown)
		enum growDownwards = Yes.growDownwards;
	else
		enum growDownwards = No.growDownwards;

	@disable this(this);

	// state {
	private SharedBorrowedRegion!(minAlign, growDownwards) _impl;
	union
	{
		private ubyte[size] _store = void;
		private double _forAlignmentOnly1;
	}
	// }

	/**
    An alias for `minAlign`, which must be a valid alignment (nonzero power
    of 2). The start of the region and all allocation requests will be rounded
    up to a multiple of the alignment.

    ----
    InSituRegion!(4096) a1;
    assert(a1.alignment == platformAlignment);
    InSituRegion!(4096, 64) a2;
    assert(a2.alignment == 64);
    ----
    */
	alias alignment = minAlign;

	private void lazyInit()
	{
		assert(!_impl._current);
		_impl = typeof(_impl)(_store);
		assert(_impl._current.alignedAt(alignment));
	}

	/**
    Allocates `bytes` and returns them, or `null` if the region cannot
    accommodate the request. For efficiency reasons, if $(D bytes == 0) the
    function returns an empty non-null slice.
    */
	void[] allocate(size_t n)
	{
		// Fast path
	entry:
		auto result = _impl.allocate(n);
		if (result.length == n)
			return result;
		// Slow path
		if (_impl._current)
			return null; // no more room
		lazyInit;
		assert(_impl._current);
		goto entry;
	}

	/**
    As above, but the memory allocated is aligned at `a` bytes.
    */
	void[] alignedAllocate(size_t n, uint a)
	{
		// Fast path
	entry:
		auto result = _impl.alignedAllocate(n, a);
		if (result.length == n)
			return result;
		// Slow path
		if (_impl._current)
			return null; // no more room
		lazyInit;
		assert(_impl._current);
		goto entry;
	}

	/**
    Deallocates `b`. This works only if `b` was obtained as the last call
    to `allocate`; otherwise (i.e. another allocation has occurred since) it
    does nothing. This semantics is tricky and therefore `deallocate` is
    defined only if `Region` is instantiated with `Yes.defineDeallocate`
    as the third template argument.

    Params:
        b = Block previously obtained by a call to `allocate` against this
        allocator (`null` is allowed).
    */
	bool deallocate(void[] b)
	{
		if (!_impl._current)
			return b is null;
		return _impl.deallocate(b);
	}

	/**
    Returns `Ternary.yes` if `b` is the result of a previous allocation,
    `Ternary.no` otherwise.
    */
	Ternary owns(const void[] b) pure nothrow @safe @nogc
	{
		if (!_impl._current)
			return Ternary.no;
		return _impl.owns(b);
	}

	/**
    Expands an allocated block in place. Expansion will succeed only if the
    block is the last allocated.
    */
	static if (hasMember!(typeof(_impl), "expand"))
		bool expand(ref void[] b, size_t delta)
		{
			if (!_impl._current)
				lazyInit;
			return _impl.expand(b, delta);
		}

	/**
    Deallocates all memory allocated with this allocator.
    */
	bool deallocateAll()
	{
		// We don't care to lazily init the region
		return _impl.deallocateAll;
	}

	/**
    Allocates all memory available with this allocator.
    */
	void[] allocateAll()
	{
		if (!_impl._current)
			lazyInit;
		return _impl.allocateAll;
	}

	/**
    Nonstandard function that returns the bytes available for allocation.
    */
	size_t available()
	{
		if (!_impl._current)
			lazyInit;
		return _impl.available;
	}
}
