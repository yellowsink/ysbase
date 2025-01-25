/++
I often find I need to write the same utilities again and again in my projects, so I have written a library to
provide a sane and semi-modular base. Hopefully you find it useful too!

It contains enhanced performant and composable memory allocators,
smart pointers and similar configurable-allocator memory utilities (strings w/ SSO, lists, refcount wrappers).

It also includes miscellaneous utilities that I find myself writing a lot, and some template helpers.

Please see the $(LINK2 https://github.com/yellowsink/ysbase/blob/main/README.md, README) for more information,
including on what the deal is with all the `std.experimental.allocator` forks, and the build-time configuration
available with this library.

$(SRCL ysbase/package.d)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase;

// dumb utilities can go directly in package.d lol

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
 + $(SRCLL ysbase/package.d, 41)
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
		*(cast(ubyte[S.sizeof]*) &u) = *(cast(ubyte[S.sizeof]*) &val);
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
	struct TwoIntegers { uint x; uint y; }

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
	struct Simple { int x; }

	// rvalues are allowed as long as they are POD
	int x = transmute!int(Simple(5));
	Simple s = transmute!Simple(10);

	// fails to compile
	// assert(transmute!int(ComplexCtors(10)) == 500);
}

/// Gets the hash code for an object. Calls `value.toHash` if it exists, else uses the class pointer, or hashes the struct value.
/// Will fail if an object has `toHash` but does not define it to be `const @nogc @safe pure nothrow`.
size_t getHashOf(T)(auto const ref T value) const @nogc @safe pure nothrow
{
	import std.traits : hasMember;

	static if (hasMember!(T, "toHash"))
		return value.toHash();
	else static if (is(T == class) || is(T == interface))
		return cast(size_t) (cast(void*) value);
	else
	{
		// LDC can optimise this out beautifully https://godbolt.org/z/WfjnzEYhf (in the `ref` case it does lose tho)
		import std.algorithm : fold;

		return (()@trusted => value.transmute!(ubyte[T.sizeof]))().fold!((a, b) => a ^ b);
	}
}
