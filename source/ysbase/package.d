module ysbase;

// dumb utilities can go directly in package.d lol

template transmute(R)
{
	R transmute(S)(ref S val) if (S.sizeof == R.sizeof)
	{
		// this is somewhat weird compared to the standard *(cast(R*) &src); formulation, but it suppresses copies.
		// this allows much worse crimes:tm: to be committed

		// this is *identical* (tied fastest) to the naive for trivial types,
		// and the fastest implementation for non-trivial types. https://godbolt.org/z/av7x1ejrP

		R u = void;
		(cast(ubyte*) &u)[0..S.sizeof] = (cast(ubyte*) &val)[0..S.sizeof];
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

