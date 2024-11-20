module ysbase.allocation.building_blocks.parametric_mallocator;

import ysbase.allocation : platformAlignment;

// like Mallocator but takes any malloc, free, realloc you want.
struct ParametricMallocator(
	alias mallocF,
	alias freeF,
	alias reallocF
)
{
nothrow @system @nogc shared const pure:

		enum uint alignment = platformAlignment;

	// TODO: forward attributes from mallocF instead of asserting them
	static void[] allocate(size_t bytes)
	{
		if (!bytes)
			return null;
		auto p = mallocF(bytes);
		return p ? p[0 .. bytes] : null;
	}

	static void[] allocateZeroed(size_t bytes)
	{
		if (!bytes)
			return null;

		// not using calloc() here for parametrization, but a D loop is as fast as a C loop :p
		auto p = allocate(bytes);
		if (p)
			p[] = null;
		return p;
	}

	static bool deallocate(void[] b)
	{
		freeF(b.ptr);
		return true;
	}

	static bool reallocate(ref void[] b, size_t s)
	{
		if (!s)
		{
			// fuzzy area in the C standard, see http://goo.gl/ZpWeSE
			// so just deallocate and nullify the pointer
			deallocate(b);
			b = null;
			return true;
		}

		auto p = cast(ubyte*) reallocF(b.ptr, s);
		if (!p)
			return false;
		b = p[0 .. s];
		return true;
	}

	static ParametricMallocator!(mallocF, freeF, reallocF) instance;
}


