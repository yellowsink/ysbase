module ysbase.allocation.building_blocks.source_reexport;

version (YSBase_StdxAlloc)
	public import stdx.allocator.building_blocks;
else
	public import std.experimental.allocator.building_blocks;
