/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.tagged_union;

import ysbase : Unit, unit;

import ysbase.templating : MinimumUIntToHold, EnumifyUnit, zipMap, concat, map;

import std.traits : FieldNameTuple, Fields, fullyQualifiedName, isInstanceOf;

import std.meta : Alias;


private template _generateTagT(T, Backing)
{
	import std.meta : Alias;

	alias working = Alias!("enum TagT : " ~ Backing.stringof ~ " { ");

	static foreach (name; FieldNameTuple!T)
		working = Alias!(working ~ name ~ ", ");

	enum _generateTagT = working ~ "}";
}

/// The exception thrown when an incorrect union access was made.
class WrongUnionCaseException(TU) if (isInstanceOf!(TaggedUnion, TU)) : Exception
{
	/// The case that someone attempted to get
	TU.TagT attemptedToGet;

	/// The case that the union was in
	TU.TagT actuallyWas;

	pure @safe this(
		const ref TU tu, const TU.TagT att, string file = __FILE__, size_t line = __LINE__, Throwable next = null
	)
	{
		import std.conv : to;

		attemptedToGet = att;
		actuallyWas = tu.tag;

		super(
			"Cannot attempt to get the payload for the " ~ att.to!string ~ " case from a union of case " ~ tu.tag.to!string,
			file, line, next
		);
	}
}

/++
A tagged union (also known as a discriminated union) is a wrapper that can hold many different types in overlapping
space. It may only hold one case at a time. The way it differs from a standard D `union` is that it $(I knows which case
it's holding), and in fact, it can have many cases of the same type.

It is better to think of a tagged union as an `enum` that gives each case an optional and heterogenously typed value.
(In this respect, TaggedUnion is equivalent to a Rust `enum`.)

You should generate this by writing a standard `D` union $(I as if it was tagged), and then passing that as the template
parameter to `TaggedUnion`, which will scaffold an efficient and safe implementation.

$(SRCL ysbase/tagged_union.d)
+/
struct TaggedUnion(T) if (is(T == union))
{
	/// The unsigned integral type that holds the union tag - this is the smallest unsigned integer possible.
	alias TagTBacking = MinimumUIntToHold!(FieldNameTuple!T.length);

	version (D_Ddoc)
	{
		/// `TagT` is the enum type that is the tag for the union. It has one member for each case.
		enum TagT : TagTBacking { _ }
	}
	else
	mixin(_generateTagT!(T, TagTBacking));

	/// `BackingT` is the raw union holding the contents of the tagged union.
	/// It is identical to `T` but with any `Unit x;` fields swapped for `enum x = unit;` instead.
	union BackingT
	{
		mixin EnumifyUnit!T;
	}

	/// A compile time sequence of the string names of the cases
	alias CaseNames = FieldNameTuple!T;

	/// A compile time sequence of the payload types of the cases
	alias CasePayloads = Fields!T;

	// thanks past me for making zipMap!
	private enum _qualTypeAndName(T, string name) = fullyQualifiedName!T ~ " " ~ name;

	/// A compile time sequence of fully qualified case strings "payloadtype name" suitable for mixins
	alias CaseDeclarators = zipMap!(_qualTypeAndName, CasePayloads, CaseNames);

	private TagT _tag;
	private BackingT _backing;

	/// Get the current case tag (discriminator)
	TagT tag() const pure nothrow @safe => _tag;

	/// Returns the value as a raw union. This is unsafe but allows you to direct get what you need.
	BackingT rawBacking() const pure nothrow @system => _backing;

	version (D_Ddoc)
	{
		private struct YourType {}

		/// Static constructor for a specific tagged union case
		static TaggedUnion caseName(YourType value) @safe;

		/// Gets the value for this case if its set, or throws if it is not this case
		inout(YourType) caseName() inout pure @safe;

		/// Gets a reference to the value for this case if its set, or throws if it is not this case
		ref inout(YourType) caseNameRef() inout @system;

		/// `.caseName = value` handler: Sets the case of this tagged union to `caseName` and assigns the value
		void caseName(YourType value) @safe;

		/// `u.setCaseName(v)` is equivalent to `u.caseName = v`.
		/// Always generated for consistency with the unit case.
		void setCaseName(YourType value) @safe;

		/// $(I IF `caseName` is `Unit`), a parameterless version of `setCaseName` is generated.
		/// This is because `.caseName = unit` (which works!) looks ugly.
		void setCaseName() @safe;

		/// Returns true if the current case is `caseName`
		bool isCaseName() const pure @safe;
	}

	// now for the real implementations!
	version (D_Ddoc) {}
	else
	{
		~this() @trusted
		{
			template _genCase(T, string name)
			{
				static if (is(T == Unit))
					enum _genCase = "case " ~ name ~ ": break;";
				else
					enum _genCase = "case " ~ name ~ ": destroy!false(_backing." ~ name ~ "); break;";
			}

			alias cases = concat!("\n", zipMap!(_genCase, CasePayloads, CaseNames));

			mixin("with (TagT) final switch (_tag) {" ~ cases ~ "}");
		}

		private void _throwIfWrongCase(string caseName)() const pure @safe
		{
			if (_tag != mixin("TagT." ~ caseName))
				throw new WrongUnionCaseException!TaggedUnion(this, mixin("TagT." ~ caseName));
		}

		// static constructor
		private static TaggedUnion _cons(string caseName, VV...)(VV valueOrVoid) pure nothrow @safe
		{
			static assert(VV.length <= 1);

			TagT tag = mixin("TagT." ~ caseName);

			alias Type = typeof(mixin("T." ~ caseName));

			static if (!is(Type == Unit))
				static assert(VV.length == 1, "Cannot try to initialize a non-unit union case without a value");

			TaggedUnion u;
			u._tag = tag;

			static if (VV.length) // it's fine to just omit this for unit
				mixin("u._backing." ~ caseName ~ " = valueOrVoid[0];");

			return u;
		}

		// inout(YourType) caseName() inout pure @safe;
		auto _getCaseValue(string caseName)() inout pure @trusted
		{
			_throwIfWrongCase!caseName();

			return cast(inout) mixin("_backing." ~ caseName);
		}

		// ref YourType caseNameRef() inout @system;
		ref auto _getCaseValueRef(string caseName)() inout @system
		{
			_throwIfWrongCase!caseName();

			return mixin("_backing." ~ caseName);
		}
	}
}


// example union spec to scaffold type from
union TestInput
{
	int x;
	bool y;
	Unit z; // payload-less case
}

alias TestUnion = TaggedUnion!TestInput;

unittest
{
	// instantiate the template so we get errors
	TestUnion un = TestUnion._cons!"x"(5);

	un._getCaseValue!"x"();

	un._getCaseValueRef!"x"() += 2;

	try {
		un._getCaseValue!"y"();
		assert(0);
	} catch (WrongUnionCaseException!TestUnion) {}
}
