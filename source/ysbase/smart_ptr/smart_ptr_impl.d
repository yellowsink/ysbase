/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr.smart_ptr_impl;

import ysbase.smart_ptr.control_block;
import ysbase.smart_ptr.reference_wrap;

import std.traits : isInstanceOf, TemplateArgsOf, hasElaborateDestructor;

// TODO: this is nowhere near done

/// Is `T` some kind of smart pointer?
enum isSmartPtr(T) = isInstanceOf!(SmartPtrImpl, T);

/// Constructs a new object inside a new smart pointer.
static SP makeSmart(SP, Allocator, Args...)(Allocator alloc, Args a) if (isSmartPtr!SP)
{
	import ysbase.allocation : make;

	SP newsp;

	newsp._control_block = alloc.make!ControlBlock();
	newsp._control_block.deallocate = (void[] block) => alloc.deallocate(block);

	newsp._managed_obj = alloc.make!(SP.T)(a);

	return newsp;
}

/// ditto
static SP makeSmart(SP, Args...)(Args a) if (isSmartPtr!SP)
{
	import ysbase.allocation : theAllocator;

	return theAllocator.makeSmart!SP(a);
}

/++
This struct implements a smart pointer.

$(SRCL ysbase/smart_ptr/smart_ptr_impl.d)

Params:
	ControlBlock = The type of the relevant control block.
	ManagedType = The type managed by this smart pointer.
	isSharedSafe = If the pointer is thread-safe or not. All operations are lock-free if thread-safe.
	isWeak = If this pointer is a weak ptr.
+/
struct SmartPtrImpl(ControlBlock, ManagedType, bool isSharedSafe, bool isWeak = false)
{
	static assert(isCtrlBlock!ControlBlock, "ControlBlock must be a control block.");

	version (D_Ddoc)
	{
		// sigh. ddox.

		/// Is this smart pointer a `UniquePtr`?
		public static bool isUniquePtr;

		/// Does this smart pointer share the reference with other smart pointers? (`SharedPtr` or `WeakPtr`)
		public static bool isSharedOrWeakPtr;

		/// Is this a `WeakPtr`?
		public static bool isWeakPtr;

		/// Is this a `SharedPtr` (not a `WeakPtr`)
		public static bool isSharedPtr;

		/// Can this smart pointer's managed object have weak references to it?
		public static bool canHaveWeakPtr;

		/// Is this smart pointer thread-safe? (Is the managed object and control block `shared`?)
		public static bool SharedSafe;
	}
	else
	{
		public enum isUniquePtr = isUniqueCtrlBlock!ControlBlock;

		public enum isSharedOrWeakPtr = isSharedCtrlBlock!ControlBlock;

		public enum isWeakPtr = isWeak;

		public enum isSharedPtr = isSharedOrWeakPtr && !isWeak;

		public enum canHaveWeakPtr = isSharedOrWeakPtr && TemplateArgsOf!ControlBlock[1];

		public enum SharedSafe = isSharedSafe;
	}

	public alias T = ManagedType;

	static if (isUniquePtr)
		static assert(!isWeak, "A UniquePtr cannot also be a WeakPtr.");

	mixin template StateImpl()
	{
		package ReferenceWrap!(ManagedType, isSharedSafe) _managed_obj;
		package ControlBlock* _control_block;
	}

	static if (isSharedSafe) shared { mixin StateImpl!(); }
	else mixin StateImpl!();

	/// Equivalent to `SmartPtrImpl.init`, handles `null` assignments.
	this(typeof(null) nil) {}

	/++ Creates a new smart pointer that shares `rhs`'s object.
	 +
	 + Params:
	 +   rhs = A `SharedPtr` to share from.
	 +         Must match our own safety and, and its type must be the same as (or a class descendant of) ours.
	 +/
	static if (isSharedOrWeakPtr)
	this(Rhs)(auto scope ref Rhs rhs)
	// Rhs must be a smart pointer, that is shared, and matches our sharedness, and must have a compatible type.
	if (isSmartPtr!Rhs && Rhs.isSharedPtr && Rhs.SharedSafe == isSharedSafe && is(ManagedType : Rhs.T))
	{
		// no object managed by rhs, so we are just the null smart pointer
		if (!rhs.strongRefCount) return;

		_managed_obj = rhs._managed_obj;
		_control_block = rhs._control_block;

		incr_ref();
	}

	/// How many strong references there are to the managed object. Defined for `SharedPtr` and `WeakPtr`.
	static if (isSharedOrWeakPtr)
	ptrdiff_t strongRefCount()
	{
		if (_control_block) return _control_block.strongRefCount;
		return 0;
	}

	/// How many weak references there are. Defined for `WeakPtr` and any `SharedPtr` with weak pointers enabled.
	static if (canHaveWeakPtr)
	ptrdiff_t weakRefCount()
	{
		if (_control_block) return _control_block.weakRefCount;
		return 0;
	}

	/// If the managed object is now gone. Defined only for `WeakPtr`.
	static if (isWeak)
	bool isExpired()
	{
		return strongRefCount == 0;
	}

	/++ `*` operator. Gets the value out of the smart pointer. `ref` if not `SharedSafe`.
	 +
	 + This restriction is because for a s
	 +/
	auto ref ManagedType opUnary(string op)() if (op == "*")
	{
		assert(_managed_obj.reference, "Cannot dereference an empty smart pointer");

		return _managed_obj.value;
	}

	/// Gets a reference to the value in the smart pointer. `T` for class types, `T*` for value types.
	auto reference()
	{
		assert(_managed_obj.reference, "Cannot get a reference into an empty smart pointer");
		return _managed_obj.reference;
	}

	private void incr_ref()
	{
		import core.atomic : atomicOp;

		assert(_control_block, "Cannot access the refcount on a null smart pointer");

		static if (isWeak)
			alias rc = _control_block.weakRefCount;
		else
			alias rc = _control_block.strongRefCount;

		static if (isSharedSafe)
			atomicOp!"+="(rc, 1);
		else
			rc++;
	}

	private void decr_ref()
	{
		import core.atomic : atomicOp;

		assert(_control_block, "Cannot access the refcount on a null smart pointer");

		static if (isWeak)
			alias rc = _control_block.weakRefCount;
		else
			alias rc = _control_block.strongRefCount;

		static if (isSharedSafe)
			atomicOp!"-="(rc, 1);
		else
			rc--;
	}
}
