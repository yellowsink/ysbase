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
	SharedSafe = When set, all members are `shared` and must be accessed in a thread-safe way.
		This must be set when using a `shared` allocator and allows thread-safe smart pointers.
+/
struct ControlBlock(bool NeedsRefCount, bool NeedsWeakCount, bool SharedSafe)
{
	/// Disable copy constructor
	@disable this(this);

	version (D_Ddoc)
	{
		/// Primary reference count, keeps the managed object live when >= 1
		shared ptrdiff_t strongRefCount;

		/// Weak reference count, keeps the *control block* (not the managed object) live when this or the strong count >= 1
		shared ptrdiff_t weakRefCount;

		/// Destructor for the managed object. May be null for trivial types.
		//void delegate() destructor;

		/// Deallocation closure for the allocator.
		/// May only be null if `version (YSBase_GC)` AND `destructor is null`.
		/// The control block must not outlive the allocator.
		void delegate(void[]) deallocate;
	}

	// avoid duplication with sharedness
	mixin template Impl()
	{
		static if (NeedsRefCount)
			ptrdiff_t strongRefCount;

		static if (NeedsWeakCount)
			ptrdiff_t weakRefCount;

		//void delegate() destructor;

		void delegate(void[]) deallocate;
	}

	static if (SharedSafe)
		shared
		{
			mixin Impl!();
		}
	else
		mixin Impl!();
}

/// A control block for a UniquePtr
alias UniqueCtrlBlock(bool SharedSafe) = ControlBlock!(false, false, SharedSafe);

/// A control block for a SharedPtr or IntrusivePtr
alias SharedCtrlBlock(bool SharedSafe) = ControlBlock!(true, true, SharedSafe);

import std.traits : isInstanceOf, TemplateArgsOf;

// ddox doesn't like an eponymous enum template. too bad!

/// If `T` is some control block.
enum isCtrlBlock(T) = isInstanceOf!(ControlBlock, T);

/// If `T` is a $(D UniquePtr) control block.
enum isUniqueCtrlBlock(T) = isCtrlBlock!T && !TemplateArgsOf!T[0] && !TemplateArgsOf!T[1];

/// If `T` is a $(D SharedPtr) or $(D WeakPtr) control block.
enum isSharedCtrlBlock(T) = isCtrlBlock!T && TemplateArgsOf!T[0] && TemplateArgsOf!T[1];

static assert(isUniqueCtrlBlock!(UniqueCtrlBlock!true));
static assert(isSharedCtrlBlock!(SharedCtrlBlock!true));

static assert(!isUniqueCtrlBlock!(SharedCtrlBlock!true));
static assert(!isSharedCtrlBlock!(UniqueCtrlBlock!true));
