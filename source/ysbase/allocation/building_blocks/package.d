module ysbase.allocation.building_blocks;

public:

import ysbase.allocation.building_blocks.source_reexport;

import ysbase.allocation.building_blocks.parametric_mallocator : ParametricMallocator;

import ysbase.allocation.building_blocks.shared_bucketizer : SharedBucketizer;

import ysbase.allocation.building_blocks.shared_segregator : SharedSegregator;

private import core.memory : pureFree, pureMalloc, pureRealloc;

alias Mallocator = ParametricMallocator!(pureMalloc, pureFree, pureRealloc);
