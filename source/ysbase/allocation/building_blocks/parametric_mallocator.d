module ysbase.allocation.building_blocks.parametric_mallocator;

import ysbase.allocation.source_reexport : platformAlignment;

// like Mallocator but takes any malloc, free, realloc you want.
struct ParametricMallocator(
	alias mallocF,
	alias freeF,
	alias reallocF
)
{
shared const:

	enum uint alignment = platformAlignment;

	// can't be templates as it breaks the common `forwardToMember` implementation
	// auto functions infer: pure; nothrow; @safe; @nogc; return ref; scope; return scope; ref return scope.
	// https://dlang.org/spec/function.html#function-attribute-inference
	static auto /* void[] */ allocate(size_t bytes)
	{
		if (!bytes)
			return null;
		auto p = mallocF(bytes);
		return p ? (() @trusted => p[0 .. bytes])() : null;
	}

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

	static auto /* bool */ deallocate(void[] b)
	{
		freeF((() @trusted => b.ptr)());
		return true;
	}

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

	static ParametricMallocator!(mallocF, freeF, reallocF) instance;
}


