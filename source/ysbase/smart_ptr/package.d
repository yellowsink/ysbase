/++
This module contains implementations of smart pointers and similar automatic memory management tools.
They are designed to work well with $(D ysbase.allocation).

When `version (YSBase_GC)` is defined and the managed object is trivially destructible,
smart pointers may elide deallocation and reference counting,
but if a destructor is present, it will always be called deterministically (i.e. ref-counted).

$(LINK2 smart_ptr/control_block.html, Docs for `ControlBlock` and co.)

$(LINK2 smart_ptr/smart_ptr_impl.html, Docs for `SmartPtrImpl` and  `isSmartPtr`)

$(LINK2 smart_ptr/reference_wrap/ReferenceWrap.html, Docs for `ReferenceWrap`)

$(SRCL ysbase/smart_ptr/package.d)

<h2>Re-Exports:</h2>
$(UL
	$(LI $(LINK2 smart_ptr/smart_ptr_impl/isSmartPtr.html, $(D isSmartPtr)))
)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr;

import ysbase.smart_ptr.control_block;

public import ysbase.smart_ptr.smart_ptr_impl : isSmartPtr;

import ysbase.smart_ptr.smart_ptr_impl : SmartPtrImpl;

///
unittest
{
	auto sp = makeUnique!int(5);

	assert(*sp == 5);

	*sp = 10;

	assert(*sp == 10);
}

///
unittest
{
	class MyClass { int x; this(int a) { x = a * 5; } }

	auto sp = makeUnique!MyClass(20);

	assert(sp.reference == *sp); // classes are reference types

	assert(sp.value.x == 100);
}

/// Use a custom allocator
unittest
{
	import ysbase.allocation : InSituRegion;

	InSituRegion!512 stackAlloc; // allocate memory on the stack

	auto sp = makeUnique!int(stackAlloc, 5);
}

///
unittest
{
	// prove that there is only ever one instance live.
	static int numberOfDestructorCalls = 0;

	struct IntWrapper
	{
		int x;

		this(int a) { x = a; }
		~this() { numberOfDestructorCalls++; }
	}

	// this weak pointer will outlive the owning shared pointer
	WeakPtr!IntWrapper outerWeakPtr;

	{
		auto shr = makeShared!IntWrapper(25);

		auto anotherShr = shr; // copy construct

		assert(anotherShr.value.x == 25);

		outerWeakPtr = anotherShr.weakRef;

		assert(!outerWeakPtr.isDangling);
		assert(outerWeakPtr.value.x == 25);

		// while shr is live, can turn our weak pointer back into a strong pointer
		assert(outerWeakPtr.tryPromoteToShared().value.x == 25);
	}

	assert(outerWeakPtr.isDangling);

	// now its dangling, a promotion returns an empty pointer
	assert(outerWeakPtr.tryPromoteToShared().isNullPtr);

	// we only ever had one IntWrapper
	assert(numberOfDestructorCalls == 1);
}

/// A non-shared smart pointer. Holds an object, and destroys and deallocates it when going out of scope.
alias UniquePtr(T, bool isSharedSafe = false) = SmartPtrImpl!(UniqueCtrlBlock, T, isSharedSafe);

/++ A shared reference-counted smart pointer. Supports weak references.
 +
 + While `SharedPtr` references to the managed object exist, it will be kept alive.
 +
 + `WeakPtr` references may be taken, which can access the managed object if `SharedPtr` references exist,
 + but will not prevent managed object destruction when all `SharedPtr`s are destroyed.
 +/
alias SharedPtr(T, bool isSharedSafe = false) = SmartPtrImpl!(SharedCtrlBlock, T, isSharedSafe);

/// `SharedPtr` without support for taking weak references.
alias SharedPtrNoWeak(T, bool isSharedSafe = false) = SmartPtrImpl!(ControlBlock!(true, false), T, isSharedSafe);

/// A weak reference to a managed object owned by a `SharedPtr`.
alias WeakPtr(T, bool isSharedSafe = false) = SmartPtrImpl!(SharedCtrlBlock, T, isSharedSafe, true);


/// Constructs a new object inside a new unique pointer.
auto makeUnique(T, bool isSharedSafe = false, A...)(A args)
{
	return UniquePtr!(T, isSharedSafe).make(args);
}

/// ditto
auto makeUnique(T, bool isSharedSafe = false, Alloc, A...)(ref Alloc allocator, A args)
{
	return UniquePtr!(T, isSharedSafe).make(allocator, args);
}

/// Constructs a new object inside a new shared pointer.
auto makeShared(T, bool isSharedSafe = false, A...)(A args)
{
	return SharedPtr!(T, isSharedSafe).make(args);
}

/// ditto
auto makeShared(T, bool isSharedSafe = false, Alloc, A...)(ref Alloc allocator, A args)
{
	return SharedPtr!(T, isSharedSafe).make(allocator, args);
}

/// Constructs a new object inside a new shared pointer without weak references.
auto makeSharedNoWeak(T, bool isSharedSafe = false, A...)(A args)
{
	return SharedPtrNoWeak!(T, isSharedSafe).make(args);
}

/// ditto
auto makeSharedNoWeak(T, bool isSharedSafe = false, Alloc, A...)(ref Alloc allocator, A args)
{
	return SharedPtrNoWeak!(T, isSharedSafe).make(allocator, args);
}

// TODO: isSharedPtr!T etc.
