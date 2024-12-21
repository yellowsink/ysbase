/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr.smart_ptr_impl;

import ysbase.smart_ptr.control_block;
import ysbase.smart_ptr.reference_wrap;

import std.traits : isInstanceOf, TemplateArgsOf, hasElaborateDestructor, hasMember;

/// Is `T` some kind of smart pointer?
enum isSmartPtr(T) = isInstanceOf!(SmartPtrImpl, T);

/++
This struct implements a smart pointer.

$(SRCLL ysbase/smart_ptr/smart_ptr_impl.d, 27)

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

	/// The type managed by this smart pointer
	public alias T = ManagedType;

	/// The `SharedPtr` type corresponding to this `WeakPtr`
	static if (isWeak)
		public alias StrongOfThis = SmartPtrImpl!(ControlBlock, ManagedType, isSharedSafe);

	/// The `WeakPtr` type corresponding to this `SharedPtr`
	static if (canHaveWeakPtr && !isWeak)
		public alias WeakOfThis = SmartPtrImpl!(ControlBlock, ManagedType, isSharedSafe, true);


	static if (!canHaveWeakPtr)
		static assert(!isWeak, "UniquePtr and SharedPtrNoWeak cannot be weak pointers.");

	mixin template StateImpl()
	{
		package ReferenceWrap!(ManagedType, isSharedSafe) _managed_obj;
		package ControlBlock* _control_block;
	}

	static if (isSharedSafe) shared { mixin StateImpl!(); }
	else mixin StateImpl!();

	/// Equivalent to `SmartPtrImpl.init`.
	this(typeof(null) nil) {}

	/++ Creates a new smart pointer that shares `rhs`'s object. Defined for `SharedPtr` and `WeakPtr` only
	 + (this is the copy constructor, and `UniquePtr` is uncopyable).
	 +
	 + Params:
	 +   rhs = A `SharedPtr` to share from.
	 +         Must match our own safety and, and its type must be the same as (or a class descendant of) ours.
	 +/
	static if (isSharedOrWeakPtr)
	this(Rhs)(auto scope ref Rhs rhs)
	// Rhs must be a smart pointer, that is shared, and matches our sharedness, and must have a compatible type.
	if (isSmartPtr!Rhs && Rhs.isSharedOrWeakPtr && Rhs.SharedSafe == isSharedSafe && is(ManagedType : Rhs.T))
	{
		this = rhs;
	}

	// we need to tell the language specifically how copy constructors work in the trivial case,
	// or despite our implementation above, it will do a naive default copy construct.
	/// ditto
	static if (isSharedOrWeakPtr)
	this(ref typeof(this) rhs)
	{
		this = rhs;
	}

	// unique pointers are not copy constructible
	static if (isUniquePtr)
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
	static if (isSharedOrWeakPtr)
	void opAssign(Rhs)(auto scope ref Rhs rhs)
	// Rhs must be a smart pointer, that is shared, and matches our sharedness, and must have a compatible type.
	if (isSmartPtr!Rhs && Rhs.isSharedOrWeakPtr && Rhs.SharedSafe == isSharedSafe && is(ManagedType : Rhs.T))
	{
		// clean the slate: set ourselves to the null smart pointer
		if (_control_block !is null) this = null;

		if (!rhs.refCountStrong) return;

		static if (Rhs.isWeakPtr)
			if (rhs.isDangling) return;

		_managed_obj = rhs._managed_obj;
		_control_block = rhs._control_block;

		incr_ref();
	}

	~this()
	{
		destructorImpl();
	}

	/// Constructs a new object inside a new smart pointer.
	static if (!isWeak)
	static typeof(this) make(Allocator, Args...)(auto ref Allocator alloc, Args a) if (hasMember!(Allocator, "allocate"))
	{
		import ysbase.allocation : make;

		typeof(this) newsp;

		newsp._control_block = alloc.make!ControlBlock();
		newsp._control_block.deallocate = (void[] block) { alloc.deallocate(block); };

		static if (isSharedOrWeakPtr) newsp.incr_ref();

		newsp._managed_obj = alloc.make!ManagedType(a);

		return newsp;
	}

	/// ditto
	static if (!isWeak)
	static typeof(this) make(Args...)(Args a)
	{
		import ysbase.allocation : theAllocator;

		return make(theAllocator, a);
	}

	/// How many strong references there are to the managed object. Defined for `SharedPtr` and `WeakPtr`.
	static if (isSharedOrWeakPtr)
	ptrdiff_t refCountStrong() @property
	{
		if (_control_block)
		{
			static if (isSharedSafe)
				return _control_block.atomicLoad.strongRefCount;
			else
				return _control_block.strongRefCount;
		}
		return 0;
	}

	/// How many weak references there are. Defined for `WeakPtr` and any `SharedPtr` with weak pointers enabled.
	static if (canHaveWeakPtr)
	ptrdiff_t refCountWeak() @property
	{
		if (_control_block)
		{
			static if (isSharedSafe)
				return _control_block.atomicLoad.weakRefCount;
			else
				return _control_block.weakRefCount;
		}
		return 0;
	}

	/// If the managed object is now gone. Defined only for `WeakPtr`.
	static if (isWeak)
	bool isDangling() @property
	{
		return refCountStrong == 0;
	}

	/// If this smart pointer is null. `false` if this is a dangling weak pointer.
	bool isNullPtr() @property
	{
		return _control_block is null;
	}

	/// Provides the `*` operator. Alias for `value`.
	template opUnary(string op) if (op == "*")
	{
		alias opUnary = value;
	}

	/++ Gets the value out of the smart pointer. `ref` if not `SharedSafe`.
	 +
	 + This restriction is because for a shared managed value, writes would require locking or atomicity.
	 +
	 + In debug builds, will perform checking for null derefs and for dangling WeakPtr derefs.
	 +/
	auto ref ManagedType value() @property
	{
		assert(_managed_obj.reference, "Cannot dereference an empty smart pointer");
		static if (isWeak)
			assert(!isDangling, "Cannot dereference a dangling WeakPtr. THIS WILL CAUSE USE-AFTER-FREE IN RELEASE BUILDS.");

		return _managed_obj.value;
	}

	/// Gets a reference to the value in the smart pointer. `ManagedType` for class types, `ManagedType*` for value types.
	version (D_Ddoc)
		ManagedType* reference() @property;
	else
	auto reference()
	{
		assert(_managed_obj.reference, "Cannot get a reference into an empty smart pointer");
		return _managed_obj.reference;
	}

	/// Create a weak pointer to the object managed by this shared pointer.
	static if (canHaveWeakPtr && !isWeak)
	WeakOfThis weakRef()
	{
		return WeakOfThis(this);
	}

	/// Tries to promote a weak pointer back to a shared pointer.
	/// Returns an empty shared pointer if this is dangling.
	/// If your code relies on this, it is probably a serious code smell.
	static if (isWeak)
	StrongOfThis tryPromoteToShared()
	{
		return StrongOfThis(this);
	}

	// returns the *new* value
	static if (isSharedOrWeakPtr)
	private ptrdiff_t incr_ref()
	{
		import core.atomic : atomicOp;
		import std.meta : Alias;

		assert(_control_block, "Cannot access the refcount on a null smart pointer");

		static if (isWeak)
			ptrdiff_t* rc = &_control_block.weakRefCount;
		else
			ptrdiff_t* rc = &_control_block.strongRefCount;

		static if (isSharedSafe)
			return atomicOp!"+="(*rc, 1);
		else
			return ++(*rc);
	}

	// returns the *new* value
	static if (isSharedOrWeakPtr)
	private ptrdiff_t decr_ref()
	{
		import core.atomic : atomicOp;

		assert(_control_block, "Cannot access the refcount on a null smart pointer");

		static if (isWeak)
			ptrdiff_t* rc = &_control_block.weakRefCount;
		else
			ptrdiff_t* rc = &_control_block.strongRefCount;

		static if (isSharedSafe)
			return atomicOp!"-="(*rc, 1);
		else
			return --(*rc);
	}


	// implements the release logic for ~this()
	// leaves dangling pointers in the struct, so if used outside of the destructor, must nullify the internal pointers.
	static if (isUniquePtr)
		private void destructorImpl()
		{
			if (isNullPtr) return;

			deallocateManagedObj();
			deallocateControlBlock();
		}
	else
		private void destructorImpl()
		{
			if (isNullPtr) return;

			static if (!isWeak)
				{
				// strong references

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
				// weak pointer
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
}

// TODO: opCast
// TODO: slice support
// TODO: opCmp, opEquals
// TODO: (maybe) swap, the weird atomic methods that BTl has.
// TODO: full unit tests
// TODO: intrusive pointers
