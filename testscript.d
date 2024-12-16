/+ dub.sdl:
	name "testscript"
	dependency "ysbase" path="."
+/


module testscript;

void main()
{
	import ysbase.allocation;
	import std.stdio;

	Mallocator ma;

	writeln(ma.allocate(50));
	writeln(ma.allocateZeroed(50));
}
