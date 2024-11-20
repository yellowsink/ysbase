module ysbase.allocation.source_reexport;

version (YSBase_StdxAlloc)
	public import stdx.allocator;
else
	public import std.experimental.allocator;
