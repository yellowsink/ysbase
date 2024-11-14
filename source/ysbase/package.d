module ysbase;

// dumb utilities can go directly in package.d lol

template transmute(R)
{
	R transmute(S)(S val) if (S.sizeof == R.sizeof)
	{
		// this is somewhat weird compared to the standard *(cast(R*) &src); formulation, but it suppresses copies.
		// this allows much worse crimes:tm: to be committed
		// for trivial cases i would expect a decent compiler to optimize this identically.

		Uncopyable u = void;
		(cast(ubyte*) &u)[0..S.sizeof] = (cast(ubyte*) &val)[0..S.sizeof];
		return u;
	}
}

// testing
private struct Uncopyable { @disable this(this); }

static assert(__traits(compiles, transmute!Uncopyable(Uncopyable.init)));
