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

<h2>What is a Smart Pointer and why do I need one?</h2>

A basic pointer `T*` is not very sophisticated. It points to some object somewhere else in memory, and hopefully that
object still exists and is valid at that location.

It is up to you to make sure that your pointer is to a safe place
(e.g. a pointer to the stack should not escape a function), and is cleaned up (e.g. calling `free()`).

It also does not communicate to you what the relationship between that pointer and the object it references is.
Generally, our software turns out more maintainable if we can have one reference to an object be its "owner",
responsible for its construction and destruction.

Smart pointers allow us to encode that relationship more easily, as well as making heap allocation more accessible to
a programmer without as much ceremony or opportunities to (pardon my language) fuck it up.
(Note that many of the largest C software projects in the world have frequently $(I fucked it up) with raw pointers).

So, smart pointers allow you to hide the nitty gritty of allocating and freeing memory. Okay, but doesn't D have a GC?

Yes! It does! But sometimes you may choose not to use the GC, and more importantly, the GC cannot really guarantee
to call your destructor! These smart pointers will always call your destructor as soon as they possibly can,
deterministically.
They also allow you to use a custom allocator to take advantage of higher performance allocation techniques than the
general-purpose GC happens to use (e.g. explicit deallocation returning to a freelist to allow reusing memory more
efficiently).

In fact, these smart pointers can work hand-in-hand with the D GC!
When YSBase is in GC Mode, smart pointers will assume their memory is always garbage collected, allowing them to take
advantage of all the practical performance improvements that entails, but will still make sure to run your destructors
if present, allowing you to use them in generic code, claiming speedups were possible, without sacrificing correctness.

Okay, cool, I want to use one of these "smart pointer" thingys! But wait, which one do I want?

<h2>What kind of Smart Pointer do I need?</h2>

If you are using the object in $(I one place), use a $(B unique pointer).
This is a kind of pointer that, when created, allocates the memory for its object, cannot have copies made of it
(you can still pass them to and from functions by $(LINK2 https://dlang.org/phobos/core_lifetime.html#.move, moving them)),
and will free the object's memory when it goes out of scope.

You can still take raw pointer references to the unique pointer's content as long as you make sure they are all gone
before the unique pointer dies (note: D is not Rust, so we can't statically verify this unfortunately).

That's all fine, but what if your code is more complex? I need to pass my objects around multiple places, they all need
to share the reference, etc., this won't work for me!

Ok, that's fine, we have another smart pointer for that: the $(B shared pointer)!
You can create a shared pointer with a new object inside, which will allocate both it, and a shared reference count.
When you copy the shared pointer around, the reference count will be used to keep track of how many shared pointers to
that object exist.

Only when the $(I last) shared pointer to that object goes out of scope, the object is destroyed.

Now, to explain a variation on shared pointers: the somewhat less intuitive $(B weak pointers).
When you have a shared pointer, it can be beneficial to take a pointer to the same object that does $(I not) stop it
from being freed.

This is a very unintuitive concept at first sight - why would I not just use a raw pointer if it doesn't keep the
managed object alive?
Well, weak pointers still hold a strong reference to the reference counts, so (and this is the key point of the weak pointer)
they give you a way to test if the object is gone before you try to access it.

With a raw pointer, you have no way of knowing if all the owning shared pointers have gone yet or not, but with a weak
pointer, you can call `isDangling` before accessing it, to find out if the object is still alive.

Finally, perhaps the most mysterious of the bunch: $(B intrusive pointers).
This particular smart pointer goes by many names over in C++ land including the cryptic `std::enable_shared_from_this`.

To understand it you need to know that a standard shared pointer holds two raw pointers within it: one to the object,
and one to a $(I control block), which contains the reference counts and other implementation details.

An intrusive pointer changes how this works slightly: while it may still have a control block (usually a smaller one
with just the weak reference count), the main strong reference count actually lives $(I inside the managed object).

This is achieved in C++ with a class to inherit and a special method to construct intrusive pointers, and it is achieved
in this library by requiring that any type you construct an `IntrusivePtr` around contains exactly one member of type
`IntrusiveControlBlock`.

The name intrusive comes from the fact that the implementation details of the pointer are inside the object it manages:
the pointer intrudes into your object to change the refcount, instead of just leaving it alone (aside from destruction)
as per usual.

<h2>Is my shared pointer thread safe?</h2>

The unhelpful-but-technically-true answer to this is "its exactly as safe as a normal pointer", but that doesn't really
help anyone.

All YSBase smart pointers can do their reference counting atomically, if enabled. As this incurs extra overhead, it is
not always-on, but it is automatically enabled by the `make*` family of functions if either the type is `shared`,
or you pass a custom allocator with `shared allocate()`.

Note that the sharedness of the allocator is irrelevant to the atomicity of the reference counts, but when unspecified,
we use one to infer the other as both imply that you plan to share the smart pointer across threads.

You must not share a smart pointer where the allocator's `deallocate` is not `shared` across threads, nor should you
share one without atomic reference counting across threads.

$(B Smart pointers do not make the type they contain thread-safe.)
You must either include a lock within your type, or use safe atomic operations yourself to ensure safety.
The smart pointers will make sure that their job (managing your object's lifetime) is safe across threads,
but it is not their job to make *your* logic safe.

You should not use the `.value` accessor and `*` operators when sharing across threads, as they do a non-atomic load.
You should use atomic methods on the `.reference` accessor.

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr;

public import ysbase.smart_ptr.smart_ptr_impl : isSmartPtr;

import ysbase.smart_ptr.control_block;

import ysbase.smart_ptr.smart_ptr_impl;

import ysbase.allocation : isSharedAllocator;

import std.traits : isDynamicArray;

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

/// weak pointer to unique pointers are possible, but be aware that they will cause the uniqueptr to keep refcounts.
unittest
{
	WeakPtr!(int, true) weak;

	{
		auto sp = makeUnique!(int, true)(5);

		weak = sp;

		assert(*weak == 5);
	}

	assert(weak.isDangling);
}

/// construct a dynamic array
unittest
{
	auto sp1 = makeUnique!(int[])(7, 5);
	auto sp2 = makeUnique!(int[])(3);

	assert(*sp1 == [5, 5, 5, 5, 5, 5, 5]);

	assert(*sp2 == [0, 0, 0]);
}

/// A non-shared smart pointer. Holds an object, and destroys and deallocates it when going out of scope.
alias UniquePtr(T, bool canHaveWeak = false, bool atomicRC = is(T == shared)) = SmartPtrImpl!(ControlBlock!(false, canHaveWeak), T, atomicRC);

/// A shared reference-counted smart pointer. While `SharedPtr`s to the managed object exist, it will be kept alive.
alias SharedPtr(T, bool canHaveWeak = true, bool atomicRC = is(T == shared)) = SmartPtrImpl!(ControlBlock!(true, canHaveWeak), T, atomicRC);

/// A weak reference to a managed object owned by a `SharedPtr`.
alias WeakPtr(T, bool isUnique = false, bool atomicRC = is(T == shared)) = SmartPtrImpl!(ControlBlock!(!isUnique, true), T, atomicRC, true);


/// Constructs a new object inside a new unique pointer.
auto makeUnique(T, bool canHaveWeak = false, A...)(A args) if (!isDynamicArray!T)
	=> UniquePtr!(T, canHaveWeak).make(args);

/// ditto
auto makeUnique(T, bool canHaveWeak = false, A...)(size_t len, A args) if (isDynamicArray!T)
	=> UniquePtr!(T, canHaveWeak).make(len, args);

/// ditto
auto makeUnique(T, bool canHaveWeak = false, Alloc, A...)(ref Alloc allocator, A args) if (!isDynamicArray!T)
	=> UniquePtr!(T, canHaveWeak, is(T == shared) || isSharedAllocator!Alloc).make(allocator, args);

/// ditto
auto makeUnique(T, bool canHaveWeak = false, Alloc, A...)(ref Alloc allocator, size_t len, A args) if (isDynamicArray!T)
	=> UniquePtr!(T, canHaveWeak, is(T == shared) || isSharedAllocator!Alloc).make(allocator, len, args);

/// Constructs a new object inside a new shared pointer.
auto makeShared(T, bool canHaveWeak = true, A...)(A args) if (!isDynamicArray!T)
	=> SharedPtr!(T, canHaveWeak).make(args);

/// ditto
auto makeShared(T, bool canHaveWeak = true, A...)(size_t len, A args) if (isDynamicArray!T)
	=> SharedPtr!(T, canHaveWeak).make(len, args);

/// ditto
auto makeShared(T, bool canHaveWeak = true, Alloc, A...)(ref Alloc allocator, A args) if (!isDynamicArray!T)
	=> SharedPtr!(T, canHaveWeak, is(T == shared) || isSharedAllocator!Alloc).make(allocator, args);

/// ditto
auto makeShared(T, bool canHaveWeak = true, Alloc, A...)(ref Alloc allocator, size_t len, A args) if (isDynamicArray!T)
	=> SharedPtr!(T, canHaveWeak, is(T == shared) || isSharedAllocator!Alloc).make(allocator, len, args);
