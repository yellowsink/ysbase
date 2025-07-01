/++
This module contains tools for memory management, especially copy-constructor elision and move semantics.

It is inspired by $(LINK2 https://dlang.org/phobos/core_lifetime.html, $(D core.lifetime)) and Rust's
$(LINK2 https://doc.rust-lang.org/stable/std/mem, `std::mem`).

Note that while some of the functions here exactly match those in `std::mem`, the equivalent of `std::mem::take` is
`core.lifetime.move`, not included here.

$(SRCL ysbase/memory.d)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.memory;

/++
 + Reinterprets the bits of one type as that of another, without calling any constructors or destructors.
 +
 + The types must be of exactly the same size. It will be copied as simply as possible - just like a POD struct copy.
 + The source value should be passed by reference, ideally.
 + The source value may be passed by value if it is $(LINK2 https://dlang.org/spec/glossary.html#pod, POD),
 + to enable rvalues to be passed in easily,
 + but this is explicitly disallowed for non-POD types, to ensure we are still eliding the copy constructor.
 +
 + Naturally, this function is horrendously unsafe and will absolutely cause bugs if miused.
 +
 + It is defined as a nested eponymous template, not a function template, to allow much more comfortable inference.
 + This has the side effect that it is very difficult to explicitly specify.
 + I suggest using $(LINK2 https://dlang.org/phobos/std_meta.html#.Instantiate, Instantiate).
 +
 + $(SRCLL ysbase/memory.d, 32)
 +/
template transmute(R)
{
pragma(inline, true):

	/// The concrete transmute implementation for passing by-reference
	R transmute(S)(ref S val) if (S.sizeof == R.sizeof)
	{
		/* this is somewhat weird compared to the standard *(cast(R*) &src); formulation, but it suppresses copies.
		   this allows much worse crimes:tm: to be committed

		   this is *identical* (tied fastest) to the naive for trivial types,
		   and the fastest implementation for non-trivial types.
		   showing that its fast with a ubyte[] slice copy, on LLVM: https://godbolt.org/z/av7x1ejrP

		   swapping from a ubyte[] slice to a ubyte[N]* fixes our parity on GDC: https://godbolt.org/z/3vosfb6fM
		   note also that while LDC will inline this anyway, GDC won't.
		   one more note: GDC can actually supress the copy on the naive version sometimes, LDC can't. interesting.

		   dmd is beyond even trying to optimise, its just bad lol, but thats okay, we all have our flaws.
		   wow, i really have over-engineered transmute() huh?
		 */

		R u = void;
		*(cast(ubyte[S.sizeof]*)&u) = *(cast(ubyte[S.sizeof]*)&val);
		return u;
	}

	// non-ref input allows taking rvalues as well as lvalues,
	// but purposefully force you not to use it for nontrivial types as it FORCES a copy to not take via ref
	/// The concrete transmute implementation for POD rvalues
	R transmute(S)(S val) if (__traits(isPOD, S) && S.sizeof == R.sizeof)
	{
		// call the other one, i've checked this recurses correctly,
		// note the !S not !R because `transmute` resolves locally like in a struct membership, not globally.
		// you could also do `.transmute!R` with the leading dot to force global resolution. doesn't matter.
		return transmute!S(val);
	}
}

///
unittest
{
	struct TwoIntegers
	{
		uint x;
		uint y;
	}

	// Not demoing this with, say, a `ulong` as Little Endian makes it significantly more confusing
	uint[2] intArray = [0xABCD, 0x1234];
	auto intStruct = TwoIntegers(0xABCD, 0x1234);

	assert(intStruct == transmute!TwoIntegers(intArray));
}

///
unittest
{
	static struct ComplexCtors
	{
		@disable this(this); // not allowed to copy!

		// complex constructor
		this(int a)
		{
			x = a * 50;
		}

		int x;
	}

	int one = 5;

	ComplexCtors complex = transmute!ComplexCtors(one);

	assert(complex.x == 5); // 5, not 250

	// transmute it back again, without calling copy ctor

	int two = transmute!int(complex);

	assert(two == 5);
}

///
unittest
{
	struct Simple
	{
		int x;
	}

	// rvalues are allowed as long as they are POD
	int x = transmute!int(Simple(5));
	Simple s = transmute!Simple(10);

	// fails to compile
	// assert(transmute!int(ComplexCtors(10)) == 500);
}

/++ `move()` but just does a copy for copyable types with $(LINK2 https://godbolt.org/z/7M1vPz3e6, no overhead).
 +
 + `zcmove` is useful where you don't actually care about copy elision,
 + but do care about making code compile with uncopyable arguments without having to pay for `move()` otherwise.
 +
 + It can optionally be set to move for some copyable types, if the type has an *elaborate* copy process - that is,
 + instead of "copy whenever possible", "copy whenever cheap".
 +
 + $(SRCLL ysbase/memory.d, 142)
 +/
T zcmove(T, bool MoveIfElab = false)(scope ref return T src) @safe
{
	import core.lifetime : move;
	import std.traits : hasElaborateCopyConstructor, isCopyable;

	static if (!isCopyable!T || (MoveIfElab && hasElaborateCopyConstructor!T))
		return move(src);
	else
		return src;
}

/++ `dirtyMove` performs a safe move in all aspects other than leaving the source untouched.
 + This is ONLY safe if you know for 100% that you will be overwriting the source immediately after this.
 +
 + $(SRCLL ysbase/memory.d, 158)
 +/
void dirtyMove(T)(ref T source, ref T target)
{
	import core.internal.moving : __move_post_blt; // lol

	*cast(ubyte[T.sizeof]*) &target = *cast(ubyte[T.sizeof]*) &source;

	__move_post_blt(target, source);
}

/++ `swap` moves two values into each others' positions without copy-constructing etc them.
 +
 + $(SRCLL ysbase/memory.d, 171)
 +/
void swap(T)(ref T x, ref T y) @trusted
{
	// move x into a temporary but leave x in invalid state
	// don't use `move` to avoid extra initializations
	// still need to call post moves though
	T tmp = void;
	dirtyMove(x, tmp);
	dirtyMove(y, x);
	dirtyMove(tmp, y);
}

///
unittest
{
	static struct ComplexMove
	{
		@disable this(this); // uncopyable

		int x;
		int y;
		int* ptrToOneOfThese; // self referential pointer

		void opPostMove(const ref ComplexMove old) nothrow
		{
			this.ptrToOneOfThese = cast(int*) (cast(void*) &this + (cast(void*) old.ptrToOneOfThese - cast(void*) &old));
		}
	}

	// sanity-check my opPostMove
	import core.lifetime : move;
	ComplexMove one;
	one.ptrToOneOfThese = &one.x;

	ComplexMove two;
	move(one, two);

	assert(two.ptrToOneOfThese == &two.x);

	// now, swap!

	ComplexMove pointsToX = ComplexMove(5, 6);
	pointsToX.ptrToOneOfThese = &pointsToX.x;

	ComplexMove pointsToY = ComplexMove(7, 8);
	pointsToY.ptrToOneOfThese = &pointsToY.y;

	// swap!
	swap(pointsToX, pointsToY);

	assert(pointsToX.ptrToOneOfThese == &pointsToX.y);
	assert(pointsToY.ptrToOneOfThese == &pointsToY.x);
}

/++ `replace` moves a value out of the target and returns it to you, and moves the source into the target.
 +
 + $(SRCLL ysbase/memory.d, 232)
 +
 + Params:
 +   target     = The destination to move in and out of
 +   source     = The new value to move into the target
 +/
T replace(T)(ref T target, auto ref T source) @trusted
{
	import core.lifetime : moveEmplace;

	// NRVO should make this ultra efficient for us :D
	T ret = void;

	dirtyMove(target, ret);

	moveEmplace(source, target);

	return ret;
}

///
unittest
{
	static struct Uncopyable { @disable this(this); int x; }

	auto target = Uncopyable(1);

	auto source = Uncopyable(2);

	auto retreived = replace(target, source);

	assert(retreived.x == 1);
	assert(target.x == 2);
	assert(source.x == 0);
}
