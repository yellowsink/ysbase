module ysbase.allocation.building_blocks;

public import ysbase.allocation.building_blocks.source_reexport;

public import ysbase.allocation.building_blocks.parametric_mallocator;

import core.memory : pureFree, pureMalloc, pureRealloc;

alias Mallocator = ParametricMallocator!(pureMalloc, pureFree, pureRealloc);
