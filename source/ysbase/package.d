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
}

