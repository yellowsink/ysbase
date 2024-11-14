module ysbase.templating;

// NOTE: this module is very work in progress rn and is working up to getting ForwardAttrs working.

// beware: insanity lies ahead, but the best kind of insanity :)

import std.traits;
import std.meta;

/** given [a, b, c, d], evaluates to fn(fn(fn(a, b), c), d) with CTFE
 * if A is empty, returns Default, as long as Default != void */
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

/** concatenate an AliasSeq!() */
alias concat(string sep, A...) = reduce!((a, b) => a ~ sep ~ b, "", A);

static assert(concat!("") == "");
static assert(concat!(" ", "a", "b", "c") == "a b c");
static assert(concat!("_", AliasSeq!("a", "b", "c")) == "a_b_c");

/** given a sequence of even size, interleaves the first and last halves */
template interleave(A...)
{
	static if (A.length <= 2)
		alias interleave = AliasSeq!(A);
	else
		alias interleave = AliasSeq!(A[0], A[$/2], interleave!(A[1..$/2], A[ $/2 + 1.. $]));
}

/** maps N chunk of elements: when given 2, [a, b, c, d], returns [fn(a, b), fn(c, d)] */
template mapN(uint N, alias fn, A...) if (A.length % N == 0)
{
	static if (A.length == N)
		alias mapN = AliasSeq!(fn!A);
	else
		alias mapN = AliasSeq!(fn!(A[0 .. N]), mapN!(N, fn, A[N .. $]));
}

/** given a sequence of even size, zips the first and last halves with a combiner function */
alias zipMap(alias fn, A...) = mapN!(2, fn, interleave!A);

private enum _test_concat(alias a, alias b) = a ~ "-" ~ b;
static assert(zipMap!(_test_concat, "A", "B", "C", "D", "E", "F") == AliasSeq!("A-D", "B-E", "C-F"));

/**  */
mixin template ForwardAttrs(string name, alias source, alias func)
{
	enum funcText = fullyQualifiedName!(ReturnType!func) ~ " " ~ name ~ "("
		~ concat!(", ", zipMap!((a, b) => a ~ b, Parameters!func, ParameterIdentifierTuple!func));
}


void test(ref int x, string y) @nogc nothrow @live
{

}

//mixin ForwardAttrs!("test2", test, {});

/* pragma(msg, Parameters!test);
pragma(msg, ParameterIdentifierTuple!test);


private enum _concat_types_strings(A, string b) = fullyQualifiedName!A ~ " " ~ b;
pragma(msg, zipMap!(_concat_types_strings, Parameters!test, ParameterIdentifierTuple!test)); */

// TODO: templates are insane
