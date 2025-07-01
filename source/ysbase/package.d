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
A singleton type that can be used in place of `void`, `noreturn`, or `typeof(null)` as potential "nothing" types.

You can use any of the following expressions to obtain a `Unit`: `Unit()`, `Unit.init`, `unit`.

Unlike `void`, which represents a type that has no value at all, `Unit` represents a type that has a single true
value. It is most accurately comparable to Rust's `()`.

To exemplify the distinction: `Result!(T, void)` (if it compiled!) would represent a never-err result, while
`Result!(T, Unit)` would represent a result that can be err, but does not carry a payload for that case.

This behaviour hugely improves the ease of use of a payloadless pattern in generic code as, unlike `void`, `Unit`
absolutely can be passed to and returned from functions, may exist within structs and unions, and does not make
it possible for some of the potential data structure states to be made invalid.

Technically speaking, there is absolutely nothing at all special about this type, it is literally `struct Unit {}`,
any empty struct will do, but it is useful to have one globally recognised unit type that we can agree upon, just like
`()` in Rust and `unit` in F#.

Note that this is not an anonymous struct `struct Unit;` as that definition would make `Unit` impossible to handle
except through a pointer indirection, and is thus no better than `void`!

$(SRCLL ysbase/package.d, 48)
+/
struct Unit
{
	// why have the compiler emit a binary equals check, when units are singleton?
	bool opEquals(const Unit) const => true;
	size_t toHash() const @nogc @safe pure nothrow => 0;
}

version (D_Ddoc)
	/// The pre-constructed singleton value of type `Unit`.
	static Unit unit;
else
	enum unit = Unit();

/// If the provided type or value is unit
public enum isUnit(T) = __traits(isSame, T, Unit);

/// ditto
public enum isUnit(alias S) = isUnit!(typeof(S));
