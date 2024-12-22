/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr.smart_ptr_impl;

import ysbase.smart_ptr.control_block;
import ysbase.smart_ptr.reference_wrap;

import std.traits : isInstanceOf, TemplateArgsOf, hasElaborateDestructor, hasMember, isDynamicArray, ForeachType;

/// Is `T` some kind of smart pointer?
enum isSmartPtr(T) = isInstanceOf!(SmartPtrImpl, T);

/++
This struct implements a smart pointer.

$(SRCLL ysbase/smart_ptr/smart_ptr_impl.d, 27)

Params:
	ControlBlock = The type of the relevant control block.
	ManagedType = The type managed by this smart pointer.
	hasAtomicRCs_ = If the pointer is thread-safe or not. All operations are lock-free if thread-safe.
	isWeak_ = If this pointer is a weak ptr.
+/
struct SmartPtrImpl(ControlBlock, ManagedType, bool hasAtomicRCs_, bool isWeak_ = false)
{
// #region Traits

	static assert(isCtrlBlock!ControlBlock, "ControlBlock must be a control block.");

	version (D_Ddoc)
	{
		// sigh. ddox.

		/// Is the managed object shared? (SharedPtr)
		public static bool isManagedObjectShared;

		/// Can this smart pointer have weak references taken of it?
		public static bool canHaveWeakPtr;

		/// Is the managed object non-shared? (UniquePtr)
		public static bool isManagedObjectUnique;

		/// Is this a weak pointer?
		public static bool isWeak;

		/// Does this smart pointer use atomic reference counting?
		public static bool hasAtomicRCs;
	}
	else
	{
		public enum isManagedObjectShared = TemplateArgsOf!ControlBlock[0];

		public enum canHaveWeakPtr = TemplateArgsOf!ControlBlock[1];

		public enum isManagedObjectUnique = !isManagedObjectShared;

		public enum isWeak = isWeak_;

		public enum hasAtomicRCs = hasAtomicRCs_;
	}

	/// The type managed by this smart pointer
	public alias T = ManagedType;

	/// The `SharedPtr` or `UniquePtr` type corresponding to this `WeakPtr`
	static if (isWeak)
		public alias StrongOfThis = SmartPtrImpl!(ControlBlock, ManagedType, hasAtomicRCs);

	/// The `WeakPtr` type corresponding to this `SharedPtr` or `UniquePtr`
	static if (canHaveWeakPtr && !isWeak)
		public alias WeakOfThis = SmartPtrImpl!(ControlBlock, ManagedType, hasAtomicRCs, true);

	static if (!canHaveWeakPtr)
		static assert(!isWeak, "Cannot construct a weakptr on a control block without a weak refcount.");


	// if we can or cannot share from this smart pointer
	static if (isWeak)
		private enum canShareFrom(SP) =
			isSmartPtr!SP && SP.canHaveWeakPtr && SP.hasAtomicRCs == hasAtomicRCs && is(ManagedType : SP.T);
	else
		private enum canShareFrom(SP) =
			isSmartPtr!SP && SP.isManagedObjectShared && SP.hasAtomicRCs == hasAtomicRCs && is(ManagedType : SP.T);

// #endregion

// #region State, Constructors, Destructors, and opAssign

	mixin template StateImpl()
	{
		package ReferenceWrap!ManagedType _managed_obj;
		package ControlBlock* _control_block;
	}

	static if (hasAtomicRCs) shared { mixin StateImpl!(); }
	else mixin StateImpl!();

	/// Equivalent to `SmartPtrImpl.init`.
	this(typeof(null) nil) {}

	/++ Creates a new smart pointer that shares `rhs`'s object. Not defined for `UniquePtr`
	 + (this is the copy constructor, and `UniquePtr` is uncopyable).
	 +
	 + Params:
	 +   rhs = A `SharedPtr` to share from.
	 +         Must match our own safety and, and its type must be the same as (or a class descendant of) ours.
	 +/
	static if (isManagedObjectShared || isWeak)
	this(Rhs)(auto scope ref Rhs rhs) if (canShareFrom!Rhs)
	{
		this = rhs;
	}

	// we need to tell the language specifically how copy constructors work in the trivial case,
	// or despite our implementation above, it will do a naive default copy construct.
	/// ditto
	static if (isManagedObjectShared || isWeak)
	this(ref typeof(this) rhs)
	{
		this = rhs;
	}

	// unique pointers are not copy constructible
	static if (isManagedObjectUnique && !isWeak)
		@disable this(this);

	/// Makes this a null smart pointer. Releases the reference to the contained object if applicable.
	void opAssign(typeof(null) nil)
	{
		destructorImpl();

		// destructorImpl leaves the state of this object undefined, so we then need to properly nullify ourselves.
		_managed_obj.reference = null;
		_control_block = null;
	}

	/++ Makes this smart pointer share `rhs`'s object. Defined for `SharedPtr` and `WeakPtr` only.
	 + Releases the reference to the currently contained object if applicable.
	 +
	 + Params:
	 +   rhs = A `SharedPtr` to share from.
	 +         Must match our own safety and, and its type must be the same as (or a class descendant of) ours.
	 +/
	static if (isManagedObjectShared || isWeak)
	void opAssign(Rhs)(auto scope ref Rhs rhs) if (canShareFrom!Rhs)
	{
		// clean the slate: set ourselves to the null smart pointer
		if (_control_block !is null) this = null;

		// if the rhs is a null pointer, stop here.
		if (!rhs.refCountStrong) return;

		// if we're copying a weak pointer, and its already dangling, don't bother sharing it either.
		static if (Rhs.isWeak)
			if (rhs.isDangling) return;

		_managed_obj = rhs._managed_obj;
		_control_block = rhs._control_block;

		incr_ref();
	}

	~this()
	{
		destructorImpl();
	}

// #endregion

// #region make()

	/// Constructs a new object inside a new smart pointer.
	static if (!isWeak && !isDynamicArray!ManagedType)
	static typeof(this) make(Allocator, Args...)(auto ref Allocator alloc, Args a) if (hasMember!(Allocator, "allocate"))
	{
		import ysbase.allocation : make;

		typeof(this) newsp;

		newsp._control_block = alloc.make!ControlBlock();
		newsp._control_block.deallocate = (void[] block) { alloc.deallocate(block); };

		static if (isManagedObjectShared || canHaveWeakPtr)
			newsp.incr_ref();

		newsp._managed_obj = alloc.make!ManagedType(a);

		return newsp;
	}

	/// ditto
	static if (!isWeak && !isDynamicArray!ManagedType)
	static typeof(this) make(Args...)(Args a)
	{
		import ysbase.allocation : theAllocator, processAllocator;

		// this isn't strictly necessary, but if you're sharing the RC, we should use a shared allocator.
		static if (hasAtomicRCs)
			return make(processAllocator, a);
		else
			return make(theAllocator, a);
	}

	/// ditto
	static if (!isWeak && isDynamicArray!ManagedType)
	static typeof(this) make(Allocator, Args...)(auto ref Allocator alloc, size_t len, Args a) if (hasMember!(Allocator, "allocate"))
	{
		import ysbase.allocation : make, makeArray;

		typeof(this) newsp;

		newsp._control_block = alloc.make!ControlBlock();
		newsp._control_block.deallocate = (void[] block) { alloc.deallocate(block); };

		static if (isManagedObjectShared || canHaveWeakPtr)
			newsp.incr_ref();

		newsp._managed_obj = alloc.makeArray!(ForeachType!ManagedType)(len, a);

		return newsp;
	}

	/// ditto
	static if (!isWeak && isDynamicArray!ManagedType)
	static typeof(this) make(Args...)(size_t len, Args a)
	{
		import ysbase.allocation : theAllocator, processAllocator;

		static if (hasAtomicRCs)
			return make(processAllocator, len, a);
		else
			return make(theAllocator, len, a);
	}

// #endregion

// #region State Getters

	/// How many strong references there are to the managed object. 0 for null and dangling pointers.
	/// Not defined for UniquePtr unless it can have weak pointers.
	static if (isManagedObjectShared || canHaveWeakPtr)
	ptrdiff_t refCountStrong() @property
	{
		import core.atomic : atomicLoad;

		if (_control_block)
		{
			static if (hasAtomicRCs)
				return atomicLoad(&_control_block.strongRefCount);
			else
				return _control_block.strongRefCount;
		}
		return 0;
	}

	/// How many weak references there are. Defined for `WeakPtr` and any strong pointer with weak pointers enabled.
	static if (canHaveWeakPtr)
	ptrdiff_t refCountWeak() @property
	{
		import core.atomic : atomicLoad;

		if (_control_block)
		{
			static if (hasAtomicRCs)
				return atomicLoad(&_control_block.weakRefCount);
			else
				return _control_block.weakRefCount;
		}
		return 0;
	}

	/// If the managed object is now gone. Defined only for `WeakPtr`.
	static if (isWeak)
	bool isDangling() @property => refCountStrong == 0;

	/// If this smart pointer is null. `false` if this is a dangling weak pointer.
	bool isNullPtr() @property => _control_block is null;

// #endregion

// #region Value Access

	/// Provides the `*` operator. Alias for `value`.
	template opUnary(string op) if (op == "*")
	{
		alias opUnary = value;
	}

	/++ Gets the value out of the smart pointer. Note that this is never an atomic load,
	 + for thread-safe lock-free access, use `reference`.
	 +
	 + In debug builds, will perform checking for null derefs and for dangling WeakPtr derefs.
	 +/
	ref ManagedType value() @property
	{
		assert(_managed_obj.reference, "Cannot dereference an empty smart pointer");
		static if (isWeak)
			assert(!isDangling, "Cannot dereference a dangling WeakPtr. THIS WILL CAUSE USE-AFTER-FREE IN RELEASE BUILDS.");

		return _managed_obj.value;
	}

	/// Gets a reference to the value in the smart pointer. `ManagedType` for class and slice types, else `ManagedType*`.
	version (D_Ddoc)
		ManagedType* reference() @property;
	else
	auto reference()
	{
		assert(_managed_obj.reference, "Cannot get a reference into an empty smart pointer");
		return _managed_obj.reference;
	}

// #endregion

// #region WeakPtr Transforms

	/// Create a weak pointer to the object managed by this smart pointer.
	static if (canHaveWeakPtr && !isWeak)
	WeakOfThis weakRef() => WeakOfThis(this);

	/// Tries to promote a weak pointer back to a shared pointer (cannot promote to a unique pointer).
	/// Returns an empty shared pointer if this is dangling.
	/// If your code relies on this, it is probably a serious code smell.
	static if (isWeak && isManagedObjectShared)
	StrongOfThis tryPromoteToShared() => StrongOfThis(this);

// #endregion

// #region Internals

	// returns the *new* value
	static if (isManagedObjectShared || canHaveWeakPtr)
	private ptrdiff_t incr_ref()
	{
		import core.atomic : atomicOp;
		import std.meta : Alias;

		assert(_control_block, "Cannot access the refcount on a null smart pointer");

		static if (isWeak)
			ptrdiff_t* rc = &_control_block.weakRefCount;
		else
			ptrdiff_t* rc = &_control_block.strongRefCount;

		static if (hasAtomicRCs)
			return atomicOp!"+="(*rc, 1);
		else
			return ++(*rc);
	}

	// returns the *new* value
	static if (isManagedObjectShared || canHaveWeakPtr)
	private ptrdiff_t decr_ref()
	{
		import core.atomic : atomicOp;

		assert(_control_block, "Cannot access the refcount on a null smart pointer");

		static if (isWeak)
			ptrdiff_t* rc = &_control_block.weakRefCount;
		else
			ptrdiff_t* rc = &_control_block.strongRefCount;

		static if (hasAtomicRCs)
			return atomicOp!"-="(*rc, 1);
		else
			return --(*rc);
	}


	// implements the release logic for ~this()
	// leaves dangling pointers in the struct, so if used outside of the destructor, must nullify the internal pointers.
	private void destructorImpl()
	{
		if (isNullPtr) return;

		static if (isManagedObjectUnique)
		{
			// uniqueptr and weakptr to uniqueptr

			// we can just deallocate the object
			deallocateManagedObj();

			// and see if we need to deallocate the control block
			static if (!canHaveWeakPtr)
				deallocateControlBlock();
			else
			{
				if (refCountWeak() == 0)
					deallocateControlBlock();
				else
					decr_ref(); // having weak pointers means we still need to refcount unique pointers.
			}
		}
		else static if (!isWeak)
		{
			// shared ptr

			if (decr_ref() == 0)
				{
				// last reference! destroy the object
				deallocateManagedObj();

				// if we can have weak pointers, we must check that there are none before we destroy the control block
				static if (canHaveWeakPtr)
					auto canDestroyCtrl = refCountWeak() == 0;
				else
					auto canDestroyCtrl = true;

				if (canDestroyCtrl)
					deallocateControlBlock();
			}
		}
		else
		{
			// weak pointer to sharedptr
			if (decr_ref() == 0 && refCountStrong() == 0)
				{
				// last weak pointer gone, and there are no strong refs left, destroy the control block
				deallocateControlBlock();
			}
		}
	}

	// implements the deallocation for ~this()
	// leaves dangling pointers in the struct, so should ONLY be used in the destructor.
	private void deallocateManagedObj()
	{
		auto dealloc = _control_block.deallocate;

		// value type pointers can just be deallocated
		static if (!is(ManagedType == class) && !is(ManagedType == interface))
		{
			// destroy then deallocate the object
			destroy!false(_managed_obj.value);
			dealloc((cast(void*) _managed_obj.reference)[0 .. ManagedType.sizeof]);
		}
		else
		{
			// classes need special attention
			// https://github.com/dlang/phobos/blob/8973596/std/experimental/allocator/package.d#L2427

			// cast interfaces to a concrete class
			static if (is(ManagedType == interface))
				auto ob = cast(Object) _managed_obj.reference;
			else
				auto ob = _managed_obj.reference;

			// get a slice to the class content
			auto support = (cast(void*) ob)[0 .. typeid(ob).initializer.length];

			// destroy and deallocate it
			destroy!false(_managed_obj.value);
			dealloc(support);
		}
	}

	// implements the deallocation for ~this()
	// leaves dangling pointers in the struct, so should ONLY be used in the destructor.
	private void deallocateControlBlock()
	{
		auto dealloc = _control_block.deallocate;
		dealloc((cast(void*) _control_block)[0 .. ControlBlock.sizeof]);
	}

// #endregion
}

// TODO: opCast
// TODO: opCmp, opEquals
// TODO: (maybe) swap, the weird atomic methods that BTl has.
// TODO: full unit tests
// TODO: intrusive pointers (both with and without weak support)
