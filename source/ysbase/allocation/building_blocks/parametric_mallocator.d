/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.allocation.building_blocks.parametric_mallocator;

import ysbase.allocation.source_reexport : platformAlignment;

/++
The parametric mallocator operates much like the `Mallocator` in `std.experimental.allocator`.

It differs in that it allows you to pass your own `malloc`, `free`, and `realloc` implementations.
This is often useful when working with
$(LINK2 https://github.com/ys-3dskit/3dskit-dlang/blob/7268815/ys3ds/memory.d#L55, embedded systems).

Other uses include allowing you to easily bind to an alternative allocator with a libc-like API,
like jemalloc, tcmalloc, or mimalloc.

$(SRCL ysbase/allocation/building_blocks/parametric_mallocator.d)

Params:
	mallocF =	A function that implements the C malloc function.
					It must take a `size_t` amount of bytes to allocate, and return a `void*`
					that either points to at least that many bytes of contiguous live memory, or null.
					You need not initialize new memory.

	freeF =		A function that implements the C free function.
					It must accept a pointer previously returned by `mallocF` or `reallocF` and free it.
					When passed `null`, must be a no-op.

	reallocF =	A function that implements the C realloc function.
					It must accept a pointer previously returned by `mallocF` or `reallocF` and a `size_t` new size.
					If the pointer is `null`, it must be equivalent to `mallocF`.
					You may or may not implement the behaviour where when size is 0, it is equivalent to `freeF`.
					You may change the size of the allocation in place, or may create a new allocation.
					The contents of the returned pointer (up to min of the sizes of the original and new allocations)
					must be identical to the contents of the old allocation. You need not initialize new memory.
					You must return a pointer to the new allocation, or null on failure.

See_Also:
$(UL
	$(LI $(LINK2 https://dlang.org/phobos/std_experimental_allocator_mallocator.html, Phobos' `Mallocator`))
	$(LI $(LINK2 https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf, The C11 Standard), Section 7.22.3)
)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
struct ParametricMallocator(
	alias mallocF,
	alias freeF,
	alias reallocF
)
{
shared const:

	/// The alignment of this allocator. Always that which can accomodate any D object on platform.
	enum uint alignment = platformAlignment;

	/// `malloc`s an array of bytes. Returns `[]` (`== null`) on failure.
	/// The contents of the array are uninitialized, so reading it is undefined behaviour.
	version (D_Ddoc)
		static void[] allocate(size_t bytes) @safe nothrow pure @nogc;
	// can't be templates as it breaks the common `forwardToMember` implementation
	// auto functions infer: pure; nothrow; @safe; @nogc; return ref; scope; return scope; ref return scope.
	// https://dlang.org/spec/function.html#function-attribute-inference
	else
	static auto /* void[] */ allocate(size_t bytes)
	{
		if (!bytes)
			return null;
		auto p = mallocF(bytes);
		return p ? (() @trusted => p[0 .. bytes])() : null;
	}

	/// `malloc`s an array of bytes. Returns `[]` (`== null`) on failure.
	/// The returned array is initialized to all zeroes (just like `calloc`).
	version (D_Ddoc)
		static void[] allocateZeroed(size_t bytes) @safe nothrow pure @nogc;
	else
	static auto /* void[] */ allocateZeroed(size_t bytes)
	{
		if (!bytes)
			return null;

		// not using calloc() here for parametrization, but a D loop is as fast as a C loop :p
		auto pRaw = allocate(bytes);
		auto p = (() @trusted => cast(ubyte[]) pRaw)();
		p[] = 0; // yes this is safe if p is null
		return p;
	}

	/// `free`s an array of bytes. It MUST have been returned by this `ParametricMallocator`'s methods,
	/// else this call is undefined behaviour.
	/// It also must not a slice of a returned array, but the full array itself.
	version (D_Ddoc)
		static bool deallocate(void[] arr) @safe nothrow pure @nogc;
	else
	static auto /* bool */ deallocate(void[] b)
	{
		freeF((() @trusted => b.ptr)());
		return true;
	}

	/**
	 * Changes the size of an allocated array, and potentially moves it.
	 *
	 * Returns: Whether or not the reallocation succeeded.
	 *
	 * Params:
	 *   array = A reference to the array to reallocate.
	 *           This array will be overwritten with the newly resized version, which may be at a different address.
	 *   new_size = The new absolute size of the array. This may be larger than, smaller than, or equal to the current length.
	 */
	version (D_Ddoc)
		static bool reallocate(ref void[] array, size_t new_size) @safe nothrow pure @nogc;
	else
	static auto /* bool */ reallocate(ref void[] b, size_t s)
	{
		if (!s)
		{
			// fuzzy area in the C standard, see http://goo.gl/ZpWeSE
			// so just deallocate and nullify the pointer
			deallocate(b);
			b = null;
			return true;
		}

		auto p = reallocF((() @trusted => b.ptr)(), s);
		if (!p)
			return false;

		// the call to deallocate above means this is never @safe anyway, but in case you just so happen
		// to provide a safe free function to this struct (how???), make it infer correctly anyway.
		b = (() @trusted => p[0 .. s])();
		return true;
	}

	/// The single global concrete instance of this struct. Do not attempt to instantiate your own instances.
	static ParametricMallocator!(mallocF, freeF, reallocF) instance;
}


