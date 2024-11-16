module ysbase;

// dumb utilities can go directly in package.d lol

template transmute(R)
{
pragma(inline, true):

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
	R transmute(S)(S val) if (__traits(isPOD, S) && S.sizeof == R.sizeof)
	{
		// call the other one, i've checked this recurses correctly,
		// note the !S not !R because `transmute` resolves locally like in a struct membership, not globally.
		// you could also do `.transmute!R` with the leading dot to force global resolution. doesn't matter.
		return transmute!S(val);
	}
}
