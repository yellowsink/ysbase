/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.tagged_union;

import ysbase : Unit, unit, isUnit;

import ysbase.templating : MinimumUIntToHold, EnumifyUnit, zipMap, concat, map, UppercaseFirst;

import std.traits : FieldNameTuple, Fields, fullyQualifiedName, isInstanceOf, isCopyable;

import std.meta : Alias;


private template _generateTagT(T, Backing)
{
	import std.meta : Alias;

	alias working = Alias!("enum TagT : " ~ Backing.stringof ~ " { ");

	static foreach (name; FieldNameTuple!T)
		working = Alias!(working ~ name ~ ", ");

	enum _generateTagT = working ~ "}";
}

private enum _generateCaseConstructor(string caseName) =
	"static TaggedUnion new" ~ UppercaseFirst!caseName ~ "(A...)(A a) @safe => TaggedUnion._cons!\"" ~ caseName ~ "\"(forward!a);";

private enum _generateCaseGetter(string caseName) =
	"auto " ~ caseName ~ "() inout pure @safe => TaggedUnion._getCaseValue!\"" ~ caseName ~ "\"();";

private enum _generateCaseGetterRef(string caseName) =
	"ref auto " ~ caseName ~ "Ref() inout @system => TaggedUnion._getCaseValueRef!\"" ~ caseName ~ "\"();";

private enum _generateCaseSetterAnonymous(string caseName) =
	"void " ~ caseName ~ "(A)(A a) @safe => TaggedUnion._setCaseValue!\"" ~ caseName ~ "\"(forward!a);";

private enum _generateCaseSetterNamed(string caseName) =
	"void set" ~ UppercaseFirst!caseName ~ "(A...)(A a) @safe => TaggedUnion._setCaseValue!\"" ~ caseName ~ "\"(forward!a);";

private enum _generateCaseEmplace(string caseName) =
	"void emplace" ~ UppercaseFirst!caseName ~ "(A...)(A a) => TaggedUnion._emplaceCaseValue!\"" ~ caseName ~ "\"(forward!a);";

private enum _generateCaseChecker(string caseName) =
	"bool is" ~ UppercaseFirst!caseName ~ "() @safe => TaggedUnion._isCase!\"" ~ caseName ~ "\"();";

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
	import core.lifetime : forward;

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
	/* union BackingT
	{
		mixin EnumifyUnit!T;
	} */
	alias BackingT = T;

	/// A compile time sequence of the string names of the cases
	alias CaseNames = FieldNameTuple!T;

	/// A compile time sequence of the payload types of the cases
	alias CasePayloads = Fields!T;

	// thanks past me for making zipMap!
	private enum _qualTypeAndName(T, string name) = fullyQualifiedName!T ~ " " ~ name;

	/// A compile time sequence of fully qualified case strings "payloadtype name" suitable for mixins
	alias CaseDeclarators = zipMap!(_qualTypeAndName, CasePayloads, CaseNames);

	private enum TagT _tagOf(string caseName) = mixin("TagT." ~ caseName);
	private alias _typeOf(string caseName) = typeof(mixin("T." ~ caseName));

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
		static TaggedUnion newCaseName(YourType value) @safe;

		/// Gets the value for this case if its set, or throws if it is not this case.
		/// Only defined when `YourType` is copyable.
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

		/// Constructs the case name in-place in the tagged union
		void emplaceCaseName(A...)(A args) @safe;

		/// Returns true if the current case is `caseName`
		bool isCaseName() const pure @safe;
	}

	// real implementations of the actual logic
	version (D_Ddoc) {}
	else
	{
		~this() @trusted
		{
			template _genCase(T, string name)
			{
				static if (isUnit!T)
					enum _genCase = "case " ~ name ~ ": break;";
				else
					enum _genCase = "case " ~ name ~ ": destroy!false(_backing." ~ name ~ "); break;";
			}

			alias cases = concat!("\n", zipMap!(_genCase, CasePayloads, CaseNames));

			mixin("with (TagT) final switch (_tag) {" ~ cases ~ "}");
		}

		private void _throwIfWrongCase(string caseName)() const pure @safe
		{
			if (_tag != _tagOf!caseName)
				throw new WrongUnionCaseException!TaggedUnion(this, _tagOf!caseName);
		}

		// static constructor
		private static TaggedUnion _cons(string caseName, VV...)(VV valueOrVoid) pure nothrow @safe
		{
			static assert(VV.length <= 1);

			static if (!isUnit!(_typeOf!caseName))
				static assert(VV.length == 1, "Cannot try to initialize a non-unit union case without a value");

			TaggedUnion u;
			u._tag = _tagOf!caseName;

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

		// void caseName(YourType value) @safe;
		// void setCaseName(YourType value) @safe;
		// void setCaseName() @safe;
		private void _setCaseValue(string caseName, VV...)(VV valueOrVoid) @safe
		{
			static assert(VV.length <= 1);

			static if (VV.length)
				mixin("_backing." ~ caseName ~ " = valueOrVoid[0];");
			else
				mixin("_backing." ~ caseName ~ " = typeof(_backing." ~ caseName ~ ").init;");

			// if the previous throws this won't run so we remain valid
			_tag = _tagOf!caseName;
		}

		// void emplaceCaseName(A...)(A args) @safe;
		private void _emplaceCaseValue(string caseName, A...)(A args)
		{
			import core.lifetime : forward, emplace;

			alias Type = _typeOf!caseName;

			emplace!Type(mixin("&_backing." ~ caseName), forward!args);

			_tag = _tagOf!caseName;
		}

		// bool isCaseName() const pure @safe;
		private bool _isCase(string caseName)() const pure @safe => _tag == mixin("TagT." ~ caseName);
	}

	// generate all functions of each type
	static foreach (name; CaseNames)
	{
		mixin(_generateCaseConstructor!name);
		mixin(_generateCaseSetterNamed!name);
		mixin(_generateCaseChecker!name);
		mixin(_generateCaseGetterRef!name);
		mixin(_generateCaseEmplace!name);
		mixin(_generateCaseSetterAnonymous!name);

		static if (isCopyable!(typeof(mixin("T." ~ name))))
		{
			mixin(_generateCaseGetter!name);
		}
	}
}

///
unittest
{
	union TestInput
	{
		int x;
		bool y;
		Unit z; // payload-less case
	}

	alias TestUnion = TaggedUnion!TestInput;

	auto un = TestUnion.newX(5);

	assert(un.x == 5); // access x

	un.xRef += 2; // get a ref to allow in-place modification

	assert(un.isX);

	// accessing another case throws
	try {
		un.y;
		assert(0);
	} catch (WrongUnionCaseException!TestUnion) {}

	// change the case to z
	un.setZ();
	assert(un.isZ);

	// payloadless cases are of the singleton type Unit, to allow them to be easily used with generics
	import ysbase : unit;
	assert(un.z == unit);
	un.z = unit;

	// change the case to y just by setting it.
	// `un.setY()` will initialize to `T.init`, `un.setY(value)` is equivalent to `un.y = value`
	un.y = true;
	assert(un.isY);
}

///
unittest
{
	// zero size unions are basically just enums
	union OopsAllUnits
	{
		Unit x;
		Unit y;
		Unit z;
	}

	auto tu = TaggedUnion!OopsAllUnits.newX();
}


///
unittest
{
	// construct a case in-place
	static struct Uncopyable
	{
		@disable this(this);

		int x;

		this(int y)
		{
			x = 2 * y;
		}
	}

	union Template
	{
		Unit foo;
		Uncopyable bar;
	}

	auto tmpl = TaggedUnion!Template.newFoo();

	assert(tmpl.isFoo);

	tmpl.emplaceBar(5);

	assert(tmpl.barRef.x == 10);

	// move out of the union
	import core.lifetime : move;

	Uncopyable moved = move(tmpl.barRef);
	assert(moved.x == 10);
	assert(tmpl.barRef.x == 0);
}
