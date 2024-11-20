module ysbase.allocation.source_reexport;

version (YSBase_StdxAlloc)
	public import stdx.allocator;
else
	public import std.experimental.allocator;

// why is this package scoped in the stdlib?????

/*
Returns `true` if `ptr` is aligned at `alignment`.
*/
@nogc nothrow pure
bool alignedAt(T)(T* ptr, uint alignment)
{
	return cast(size_t) ptr % alignment == 0;
}

/*
Returns s rounded up to a multiple of base.
*/
@safe @nogc nothrow pure
size_t roundUpToMultipleOf(size_t s, uint base)
{
	assert(base);
	auto rem = s % base;
	return rem ? s + base - rem : s;
}
