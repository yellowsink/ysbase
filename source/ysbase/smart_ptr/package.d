/++
This module contains implementations of smart pointers and similar automatic memory management tools.
They are designed to work well with $(D ysbase.allocation).

When `version (YSBase_GC)` is defined and the managed object is trivially destructible,
smart pointers may elide deallocation and reference counting,
but if a destructor is present, it will always be called deterministically (i.e. ref-counted).

$(LINK2 smart_ptr/control_block.html, Docs for `ControlBlock` and co.)

$(LINK2 smart_ptr/smart_ptr_impl.html, Docs for `SmartPtrImpl`, `isSmartPtr`, and `makeSmart`)

$(LINK2 smart_ptr/reference_wrap/ReferenceWrap.html, Docs for `ReferenceWrap`)

$(SRCL ysbase/smart_ptr/package.d)

<h2>Re-Exports:</h2>
$(UL
	$(LI $(LINK2 smart_ptr/smart_ptr_impl/isSmartPtr.html, $(D isSmartPtr)))
	$(LI $(LINK2 smart_ptr/smart_ptr_impl/makeSmart.html, $(D makeSmart)))
)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr;

import ysbase.smart_ptr.control_block;

public import ysbase.smart_ptr.smart_ptr_impl : isSmartPtr, makeSmart;

import ysbase.smart_ptr.smart_ptr_impl : SmartPtrImpl;

/// A non-shared smart pointer. Holds an object, and destroys and deallocates it when going out of scope.
alias UniquePtr(T, bool isSharedSafe = false) = SmartPtrImpl!(UniqueCtrlBlock!isSharedSafe, T, isSharedSafe);

/++ A shared reference-counted smart pointer. Supports weak references.
 +
 + While `SharedPtr` references to the managed object exist, it will be kept alive.
 +
 + `WeakPtr` references may be taken, which can access the managed object if `SharedPtr` references exist,
 + but will not prevent managed object destruction when all `SharedPtr`s are destroyed.
 +/
alias SharedPtr(T, bool isSharedSafe = false) = SmartPtrImpl!(SharedCtrlBlock!isSharedSafe, T, isSharedSafe);

/// `SharedPtr` without support for taking weak references.
alias SharedPtrNoWeak(T, bool isSharedSafe = false) = SmartPtrImpl!(SharedCtrlBlock!isSharedSafe, T, isSharedSafe);

/// A weak reference to a managed object owned by a `SharedPtr`.
alias WeakPtr(T, bool isSharedSafe = false) = SmartPtrImpl!(SharedCtrlBlock!isSharedSafe, T, isSharedSafe, true);


/// Constructs a new object inside a new unique pointer.
alias makeUnique(T, bool isSharedSafe = false, Alloc, A...) = makeSmart!(UniquePtr!(T, isSharedSafe), Alloc, A);

/// ditto
alias makeUnique(T, bool isSharedSafe = false, A...) = makeSmart!(UniquePtr!(T, isSharedSafe), A);

/// Constructs a new object inside a new shared pointer.
alias makeShared(T, bool isSharedSafe = false, Alloc, A...) = makeSmart!(SharedPtr!(T, isSharedSafe), Alloc, A);

/// ditto
alias makeShared(T, bool isSharedSafe = false, A...) = makeSmart!(SharedPtr!(T, isSharedSafe), A);

/// Constructs a new object inside a new shared pointer without weak references.
alias makeSharedNoWeak(T, bool isSharedSafe = false, Alloc, A...) = makeSmart!(SharedPtrNoWeak!(T, isSharedSafe), Alloc, A);

/// ditto
alias makeSharedNoWeak(T, bool isSharedSafe = false, A...) = makeSmart!(SharedPtrNoWeak!(T, isSharedSafe), A);


// TODO: isSharedPtr!T etc.
