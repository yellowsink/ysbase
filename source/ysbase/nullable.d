/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.nullable;

import std.typecons : StdNullable = Nullable;

/++
`Nullable` is a wrapper type that can hold either a `T` or nothing.

This is a wrapper of `std.typecons.Nullable` with exactly the same API but the only change that it supports `T == void`.

The only omission from the API in this case is the range interface's `front` and `back` as void ranges make no sense in D.
Also, the `Nullable!T.existent` static value is then available, representing the `Nullable!void` with a value.

It adds the `Nullable!T.null_` value, which is equivalent to `Nullable!T.init`.

Please see $(LINK2 https://dlang.org/library/std/typecons/nullable.html#2, `std.typecons.Nullable`'s docs).

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
struct Nullable(T)
{
	/// Is the Nullable holding a void?
	enum IsVoid = is(T == void);

	static if (IsVoid)
	{
		void get() {}
		size_t length() => isNull ? 1 : 0;

		bool isNull = true;

		void nullify() { isNull = true; }
		auto opAssign()
		{
			isNull = false;
			return this;
		}

		// allow default implemented opEquals

		void[] opSlice(this This)() { return []; }

		string toString() => isNull ? "Nullable.null" : "Nullable!void()";

		// new api!
		enum Nullable!void existent = { isNull : false };

		static assert(!Nullable!void.existent.isNull);
	}
	else
	{
		private Nullable!T _inner;
		alias _inner this;
	}

	enum null_ = Nullable!T.init;
}
