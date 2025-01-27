/++
A set of generic FP-style template utilities, that run on compile time sequences.

$(SRCL ysbase/templating.d)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.templating;

// these were originally written to try and make a template infer attributes, but as it turns out that's done anyway
// for template functions and auto functions, so this is unnecessary. The utilities can remain anyway :)

// beware: insanity lies ahead, but the best kind of insanity :)

import std.traits;
import std.meta;

/** Given `[a, b, c, d]`, evaluates to `fn(fn(fn(a, b), c), d)` with CTFE.
 * If `A` is empty, returns `Default`, as long as `Default != void` */
template reduce(alias fn, alias Default, A...)
{
	static if (A.length == 0)
	{
		static assert (!is(Default == void));
		alias reduce = Default;
	}
	else
	{
		alias reduce = Alias!(A[0]);

		static foreach (arg; A[1..$])
			reduce = Alias!(fn(reduce, arg));
	}
}

/** Concatenate an `AliasSeq!()` */
alias concat(string sep, A...) = reduce!((a, b) => a ~ sep ~ b, "", A);

static assert(concat!("") == "");
static assert(concat!(" ", "a", "b", "c") == "a b c");
static assert(concat!("_", AliasSeq!("a", "b", "c")) == "a_b_c");

/** Given a sequence of even size, interleaves the first and last halves */
template interleave(A...)
{
	static if (A.length <= 2)
		alias interleave = AliasSeq!(A);
	else
		alias interleave = AliasSeq!(A[0], A[$/2], interleave!(A[1..$/2], A[ $/2 + 1.. $]));
}

/// Maps over each element - converts `fn, [a, b, c, d]` to `[fn!a, fn!b, fn!c, fn!d]`.
template map(alias fn, A...)
{
	alias map = AliasSeq!();

	static foreach(a; A)
		map = AliasSeq!(map, fn!a);
}

/** Maps over `N`-size chunks of elements: when given `2, [a, b, c, d]`, returns `[fn!(a, b), fn!(c, d)]` */
template mapN(uint N, alias fn, A...) if (A.length % N == 0)
{
	static if (A.length == N)
		alias mapN = AliasSeq!(fn!A);
	else
		alias mapN = AliasSeq!(fn!(A[0 .. N]), mapN!(N, fn, A[N .. $]));
}

/** Given a sequence of even size, zips the first and last halves with a combiner function */
alias zipMap(alias fn, A...) = mapN!(2, fn, interleave!A);

private enum _test_concat(alias a, alias b) = a ~ "-" ~ b;
static assert(zipMap!(_test_concat, "A", "B", "C", "D", "E", "F") == AliasSeq!("A-D", "B-E", "C-F"));

/// The smallest unsigned integer type that can hold the integer `N`.
public template MinimumUIntToHold(ulong N)
{
	static if (N <= ubyte.max)
		alias MinimumUIntToHold = ubyte;
	else static if (N <= ushort.max)
		alias MinimumUIntToHold = ushort;
	else static if (N <= uint.max)
		alias MinimumUIntToHold = uint;
	else
		alias MinimumUIntToHold = ulong;
}


/// Copies all fields from `src`, but swaps any `ysbase.Unit x` for `enum x = Unit()`.
public mixin template EnumifyUnit(T) if (is(T == struct) || is(T == union))
{
	private mixin template _Step(size_t N)
	{
		import std.traits : Fields, FieldNameTuple, fullyQualifiedName;

		static if (Fields!T.length != N)
		{
			static if (__traits(isSame, Fields!T[N], ysbase.Unit))
				mixin("enum " ~ FieldNameTuple!T[N] ~ " = ysbase.Unit();");
			else
			// fullyQualifiedName preserves shared, const, etc.
			mixin(fullyQualifiedName!(Fields!T[N]) ~ " " ~ FieldNameTuple!T[N] ~ ";");

			mixin _Step!(N + 1);
		}
	}

	mixin _Step!0;
}

/// Uppercases a single character if it is in the range `a-z`, else does nothing.
public template UppercaseChar(alias character) if (isSomeChar!(typeof(character)))
{
	static if (character >= 'a' && character <= 'z')
		enum UppercaseChar = cast(typeof(character)) (character - 'a' + 'A');
	else
		enum UppercaseChar = character;
}

static assert(UppercaseChar!'5' == '5');
static assert(UppercaseChar!'B' == 'B');
static assert(UppercaseChar!'a' == 'A');
static assert(UppercaseChar!'z' == 'Z');
static assert(UppercaseChar!'f' == 'F');

/// Uppercases the first character of a string
public template UppercaseFirst(alias str) if (isSomeString!(typeof(str)))
{
	static if (str.length == 0)
		enum UppercaseFirst = str;
	else
		enum UppercaseFirst = UppercaseChar!(str[0]) ~ str[1 .. $];
}

static assert(UppercaseFirst!"hi" == "Hi");
static assert(UppercaseFirst!"j" == "J");
