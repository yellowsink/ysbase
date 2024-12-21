/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.smart_ptr.reference_wrap;

/++
`ReferenceWrap` wraps a reference to `T` and provides access to it as a reference and as a value.
It does so without wrapping classes in an unnecessary pointer.

$(SRCL ysbase/smart_ptr/reference_wrap.d)
+/
struct ReferenceWrap(T, bool isSharedSafe = false)
{
	enum isClass = is(T == class) || is(T == interface);

	static if (isClass)
		alias RefT = T;
	else
		alias RefT = T*;

	/// A reference to the `T`
	RefT reference;


	this(RefT reference)
	{
		this.reference = reference;
	}

	void opAssign(RefT reference)
	{
		this.reference = reference;
	}

	/// The underlying value of the `T`. `ref` if not shared.
	auto ref T value()
	{
		import core.atomic : atomicLoad;

		static if (isClass) return reference;
		else
		{
			assert(reference);
			static if (isSharedSafe)
				return reference.atomicLoad;
			else
				return *reference;
		}
	}
}
