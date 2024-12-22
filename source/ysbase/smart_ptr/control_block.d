/++
Control block and related utilities

$(SRCL ysbase/smart_ptr/control_block.d)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr.control_block;

/++
Internal control block used to manage smart pointers.

The control block is always allocated by the same allocator as the managed object.

$(SRCL ysbase/smart_ptr/control_block.d)

Params:
	NeedsRefCount = Whether or not a reference count must be included. This is true for all shared pointers.
	NeedsWeakCount = Whether or not to include a weak reference count.
		This is true for all weak pointers, and all shared pointers that support weak references.
+/
struct ControlBlock(bool NeedsRefCount, bool NeedsWeakCount)
{
	/// Disable copy constructor
	@disable this(this);

	// still keep it if we only need weak, as having weak means you need to track if dangling or not.
	/// Primary reference count, keeps the managed object live when >= 1
	static if (NeedsRefCount || NeedsWeakCount)
		ptrdiff_t strongRefCount;

	/// Weak reference count, keeps the *control block* (not the managed object) live when this or the strong count >= 1
	static if (NeedsWeakCount)
		ptrdiff_t weakRefCount;

	// Destructor for the managed object. May be null for trivial types.
	//void delegate() destructor;

	/// Closure over the relevant allocator's `deallocate`.
	/// May only be null if `version (YSBase_GC)` and the managed object is POD.
	/// The control block MUST NOT outlive the allocator.
	void delegate(void[]) deallocate;
}


import std.traits : isInstanceOf;

// ddox doesn't really like an eponymous enum template. too bad!
/// If `T` is some control block.
enum isCtrlBlock(T) = isInstanceOf!(ControlBlock, T);
