/++
`Result` is a wrapper type that can either represent success (presence of an `T`),
or a failure/error value (type `E`).
This can be directly likened to Rust's `Result<T, E>`, and C++'s `std::expected<T, E>`.

It allows localised error handling by manually checking error state (`if (auto value = res) {}`), and centralised error
handling via the `.get` method and `*` operator, which throw the unexpected value if present (`auto value = *res;`).

The result module implements an API loosely based on a proposal shown off by Andrei Alexandrescu in
$(LINK2 https://youtu.be/PH4WBuE1BHI, this cppcon talk), and implemented in `std::expected`.

$(SRCL ysbase/result.d)

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.result;

import std.traits : isInstanceOf, isCallable, ReturnType, hasElaborateDestructor, isCopyable, TemplateArgsOf;
import std.typecons : Nullable;

import ysbase.memory : zcmove;

// Note about this module: I know barely anything about OpenD (https://opendlang.org/changes.html), and am skeptical of
// its ability to go anywhere, but its `opImplicitCast` would make this implementation *hugely* nicer to use.
// Looking forward to any kind of similar DIPs that could replace `alias this`, which sadly cannot be generic.

/// The struct returned by `err()`, please refer to its documentation.
struct ErrWrap(E) if (isCopyable!E)
{
	E _err;

	/// This provides type information for `return err().insteadOf!T;` to compile.
	Result!(T, E) insteadOf(T)() => Result!(T, E)(this);
}

/++
Creates a value representing failure, with no knowledge of the success type. Exists to ease type deduction.

Sadly, D's type implicit conversions are not as nice as C++'s, so we cannot make `return err(...);` compile,
though `Result!(T, E) name = err(...);` and `Result!(T, E) name; name = err(...);` both compile.
To return errors directly from a function, you can write `return err(...).insteadOf!T;`.

`E` must be copyable as it could be thrown.

Sister to `ok()`.

$(SRCLL ysbase/result.d, 51)
+/
ErrWrap!E err(E)(auto ref E u) if (isCopyable!E) => ErrWrap!E(u);

/// The struct returned by `ok()`, please refer to its documentation.
struct OkWrap(T)
{
	T _ok;

	/// This provides type information for `return ok().insteadOf!E;` to compile.
	Result!(T, E) insteadOf(E)() => Result!(T, E)(zcmove(this));
}

/++
Creates a value representing a success, with no knowledge of the error type. Exists to ease type deduction.

Sadly, D's type implicit conversions are not as nice as C++'s, so we cannot make `return ok(...);` compile,
though `Result!(T, E) name = ok(...);` and `Result!(T, E) name; name = ok(...);` both compile.
To return sucess directly from a function, you can write `return ok(...).insteadOf!E;`.

Sister to `err()`.

$(SRCLL ysbase/result.d, 73)
+/
OkWrap!T ok(T)(auto ref T v) => OkWrap!T(zcmove(v));

/// The `Exception` used to wrap non-`Exception` error values for `Result` when they must be thrown.
///
/// Note that `ResultException` may contain `Throwable` non-`Exception` types (such as `Error`s!), as throwables that
/// are not `Exception`s should not be used for control flow and so are not treated as "special" by ysbase's `Result`.
class ResultException(E) if (!is(E : Exception)) : Exception
{
	/// The `err` value of the result from which this exception was thrown.
	E thrownErr;

	// we don't need to handle E == void as if a result cannot be err, ResultException can never be thrown!
	pure @safe this(E e, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		thrownErr = e;
		super("Cannot attempt to get the value from a result that is err.", file, line, next);
	}
}

/// An exception thrown when trying to get the error out of a result that was ok.
class ResultWasOkException : Exception
{
	pure @safe this(string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super("Cannot attempt to get the error from a result that is ok.", file, line, next);
	}
}

/++
`Result` is the wrapper type containing either a success value of type `T` or failure of type `E`.
$(LINK2 ../result.html, See top level docs).

The default initialization of a result (e.g. `Result!(T, E) res;`) is in the OK state with a default-initialized `T`.

`T` and `E` cannot be `void`, as that would make the ok-ness of the result statically knowable. You may, naturally,
use $(LINK2 /ysbase/Unit.html, `Unit`) to have payloadless ok and/or error cases.

`E` must be copyable as it could be thrown. `T` need not be.

$(SRCLL ysbase/result.d, 114)
+/
struct Result(T, E) if (!is(T == void) && !is(E == void) && isCopyable!E)
{
	version (D_DDoc)
	{
		/// Will the error be wrapped in `ResultException` when thrown?
		static bool ErrWillBeWrapped; // @suppress(dscanner.style.phobos_naming_convention)
	}

	enum ErrWillBeWrapped = !is(E : Exception);

@safe:

	/// The ok caes type `T`
	alias ValueType = T;
	/// The error case type `E`
	alias ErrType = E;

	private union Inner
	{
		T val;
		E err;
	}

	// default the Result to a default-inited T, so _hasValue defaults to true
	private bool _hasValue = true;
	private Inner _value;

	~this() @trusted
	{
		if (_hasValue)
			destroy!false(_value.val);
		else
			destroy!false(_value.err);
	}

	nothrow
	{
		// constructors for the OK case
		/// Direct constructor for the OK case
		this(ref T t)
		{
			_value.val = zcmove(t);
		}

		/// ditto
		this(T val) { this(val); }

		/// Promotes an `OkWrap` with no knowledge of the corresponding `E` type to a `Result`.
		this(ref OkWrap!T ok) { this(ok._ok); }

		/// ditto
		this(OkWrap!T ok) { this(ok._ok); }

		// assignment for the OK case
		/// `= T` operator
		Result opAssign()(auto ref T t)
		{
			_value.val = zcmove(t);
			_hasValue = true;
			return this;
		}

		/// `= .ok(T)` operator
		Result opAssign()(auto ref OkWrap!T ok)
		{
			_value.val = zcmove(ok._ok);
			_hasValue = true;
			return this;
		}

		// constructors for the Err case
		/// Promotes an `ErrWrap` with no knowledge of the corresponding `T` type to a `Result`.
		this(ref ErrWrap!E err)
		{
			_value.err = err._err;
			_hasValue = false;
		}

		/// ditto
		this(ErrWrap!E err) { this(err); }

		/// Directly constructs a Result with an error value `err`.
		/// Produces slightly more efficicient code than freestanding `.err()` on DMD and GDC, but does NOT on LDC.
		static Result err()(auto ref E err) pure @trusted
		{
			Result r = void;
			r._value.err = err;
			r._hasValue = false;
			return r;
		}

		// assignment for the Err case
		/// `= .err(E)` operator
		Result opAssign()(auto ref ErrWrap!E err) @trusted
		{
			_value.err = err._err;
			_hasValue = false;
			return this;
		}
	}

	/// If this result is OK (has a `T`)
	bool isOk() pure nothrow const => _hasValue;

	/// Casts to `bool` (including `if (result)`) check if the result `isOk()`
	alias opCast(T : bool) = isOk;

	/// Gets the value of the result if it exists, or throws the error type if not
	static if (isCopyable!T)
	T get() pure @trusted => getRef();

	/// Moves the value of the result out if it exists, or throws the error type if not.
	T getMove() @trusted => zcmove(getRef());

	/// Gets a reference to the value of the result if it exists, or throws the error type if not.
	///
	/// Not safe as assigning an error to this result would then invalidate the reference.
	ref inout(T) getRef() pure inout @system
	{
		if (_hasValue)
			return _value.val;

		static if (ErrWillBeWrapped)
			throw new ResultException!E(_value.err);
		else
			throw _value.err;
	}

	/// The `*` operator is an alias to `get()`
	alias opUnary(string op : "*") = get;

	/// Gets the value of the result if it exists, or lazily evaluates and returns `default_`
	static if (isCopyable!T)
	T getOr(lazy T default_) pure const @trusted
		=> _hasValue ? _value.val : default_;

	/// Gets the error out of the result, or throws `ResultWasOkayException`
	E getError() pure @trusted => getErrorRef();

	/// Moves the error of the result out if it exists, or throws the error type if not.
	E getErrorMove() @trusted => zcmove(getErrorRef());

	/// Gets a reference to the error out of the result, or throws `ResultWasOkayException`
	///
	/// Not safe as assigning a success to this result would then invalidate the reference.
	ref inout(E) getErrorRef() pure inout @system
	{
		if (_hasValue)
			throw new ResultWasOkException;

		return _value.err;
	}

	/// Gets the error out of the result if it exists, or lazily evaluates and returns `default_`
	E getErrorOr(lazy E default_) pure @trusted
		=> !_hasValue ? _value.err : default_;

	/// Gets the value of result, and causes undefined behaviour if its an err
	ref inout(T) getUnchecked() pure nothrow inout @system => _value.val;

	/// Gets the error of result, and causes undefined behaviour if its ok
	ref inout(E) getErrorUnchecked() pure nothrow inout @system => _value.err;

	/// Returns an `std.typecons.Nullable` with the result value
	static if (isCopyable!T)
	Nullable!T tryGet() pure nothrow @trusted => _hasValue ? Nullable!T(_value.val) : Nullable!T.init;

	/// Returns an `std.typecons.Nullable` with the error value
	Nullable!E tryGetError() pure nothrow @trusted => !_hasValue ? Nullable!E(_value.err) : Nullable!E.init;

	/// `==` operator implementation
	bool opEquals(R)(auto ref const R other) const pure nothrow @trusted if (isInstanceOf!(.Result, R))
	{
		if (_hasValue != other._hasValue) return false;

		return _hasValue
			? _value.val == other._value.val
			: _value.err == other._value.err;
	}

	/// ditto
	bool opEquals(R)(auto ref const R other) const pure nothrow @trusted if (isInstanceOf!(OkWrap, R) || isInstanceOf!(ErrWrap, R))
	{
		enum rhsOk = isInstanceOf!(OkWrap, R);

		static if (rhsOk)
		{
			return _hasValue && _value.val == other._ok;
		}
		else
		{
			return !_hasValue && _value.err == other._err;
		}
	}

	/// ditto
	// used for associative arrays and the like
	// ideally want const @nogc @trusted pure nothrow but we just gotta go with what we can
	size_t toHash()() @trusted
	{
		return _hasValue ? hashOf(_value.val) : hashOf(_value.err);
	}

	// chaining ops:

	/// If this value is Ok, map it through the function, else just return self
	auto map(alias F)() @trusted
	{
		alias ResType = Result!(typeof(F(T.init)), E);

		if (_hasValue)
			return ResType(F(_value.val));
		else
			return ResType.err(_value.err);
	}

	/// ditto
	Result!(ReturnType!F, E) map(F)(auto ref F func) if (isCallable!F) => map!((v) => func(v));

	/// If this value is Ok, lazily return res2, else just return self
	R and_then(R)(lazy R res2) if (isInstanceOf!(.Result, R) && is(R.ErrType == E))
	{
		if (_hasValue)
			return res2;
		else
			return .err(_value.err).insteadOf!(R.ValueType);
	}

	/// If this value is Err, map it through the function, else just return self
	auto map_err(alias F)() @trusted
	{
		alias ResType = Result!(T, typeof(F(E.init)));

		if (_hasValue)
			return ResType(_value.val);
		else
			return ResType.err(F(_value.err));
	}

	/// ditto
	Result!(T, ReturnType!F) map_err(F)(auto ref F func)if (isCallable!F) => map_err!((e) => func(e));

	/// If this value is Err, lazily return res2, else just return self
	R or_else(R)(lazy R res2) if (isInstanceOf!(.Result, R) && is(R.ValueType == T))
	{
		if (_hasValue)
			return .ok(_value.val).insteadOf!(R.ErrType);
		else
			return res2;
	}

	/// Converts a result of a nullable T into a nullable result
	/// Ok(null) becomes null, Ok(NotNull(v)) becomes NotNull(Ok(v)), and Err(e) becomes NotNull(Err(e))
	static if (isInstanceOf!(Nullable, T))
	Nullable!(Result!(TemplateArgsOf!T, E)) transpose() pure nothrow @trusted
	{
		alias OkBranchType = TemplateArgsOf!T;
		alias InnerResult = Result!(OkBranchType, E);

		if (_hasValue)
		{
			if (_value.val.isNull)
				return Nullable!InnerResult.init;
			else
				return Nullable!InnerResult(.ok(_value.val.get).insteadOf!E);
		}
		else
			return Nullable!InnerResult(.err(_value.err).insteadOf!OkBranchType);
	}

	/// Flattens a `Result(Result(T, E), E)` to a `Result(T, E)`. The logic is `isOk ? get : this`.
	static if (isInstanceOf!(.Result, T) && is(T.ErrType == E))
	T flatten() pure nothrow @trusted
		=> _hasValue ? _value.val : .err(_value.err).insteadOf!(T.ValueType);
}

/// Local error handling with Result:
unittest
{
	Result!(int, string) doSomething()
	{
		Result!(int, string) res;

		// do some work...
		res = ok(5);
		// also valid
		res = err(":(");
		// also valid
		res = 5;

		return res;
	}

	Result!(int, string) doSomethingElse() => err(":(").insteadOf!int;

	// ======

	auto result = doSomething();
	if (result) {
		// get the result value
		int val = *result;
	}

	// also works if you don't care about handling the error case
	if (auto res = doSomething()) {
		*res;
	}

	auto failedResult = doSomethingElse();
	if (!failedResult.isOk) {
		// report an error here to the logs etc
		string e = failedResult.getError;
	}
}

/// Centralised error handling with result
unittest
{
	Result!(int, string) doSomething() => err(":(").insteadOf!int;

	// we don't care about errors! we just wanna get the thing and double it!
	// note nice ergonomics in this function if we don't want to think about errors rn - like rust; unlike go :p
	int doubledTheThing()
	{
		// trying to get from a errored result throws
		return doSomething().get * 2;
	}

	try {
		auto doubled = doubledTheThing();
		assert(0);
	} catch (ResultException!string) {}

	// and equally getting the error from a valid result throws to be handled later:
	auto r = Result!(int, string)(3);

	try {
		r.getError;
		assert(0);
	} catch (ResultWasOkException)
	{
	}
}

/// Many ways to construct a result:
unittest
{
	// explicit ok
	auto o1 = Result!(int, string)(3);
	// construct from value
	Result!(int, string) o2 = 3;
	// construct from ok()
	Result!(int, string) o3 = ok(3);
	// fully implicit ok
	auto o4 = ok(3).insteadOf!string;

	// explicit err
	auto e1 = Result!(int, string).err("hi");
	// construct from err()
	Result!(int, string) e2 = err("hi");
	// fully implicit err
	auto e3 = err("hi").insteadOf!int;

	// `.insteadOf` is sadly necessary as current D has no way to cast the ok() and err() types to
	// a full Result!() in a function return position - that is, `return ok();` cannot be made to work.
	// If OpenD style opImplicitCast ever hits upstream, a best attempt at supporting this will be made. :)
}

/// Many ways of retrieving the values from the result:
unittest
{
	Result!(int, string) success = 0;
	Result!(int, string) failure = err("");

	// copy value / error out
	success.get;
	failure.getError;

	// dereference operator is an alias for get
	*success;

	// move value / error out for types that arent copyable / are expensive to copy
	success.getMove;
	failure.getErrorMove;

	// get references to allow in-place modification. unsafe due to ability for reference to outlive result mutation
	success.getRef++;
	failure.getErrorRef = "hi :)";

	// get as a `std.typecons.Nullable`
	assert(!success.tryGet.isNull);
	assert(success.tryGetError.isNull);
	assert(failure.tryGet.isNull);
	assert(!failure.tryGetError.isNull);

	// get with lazily-evaluated default
	failure.getOr(10);
	success.getErrorOr("actually everything's fine!");

	// unchecked getters that invoke UB (REALLY bad) if the state is wrong
	if (success.isOk) success.getUnchecked;
	if (!failure.isOk) failure.getErrorUnchecked;
}

/// `Exception`s need not be wrapped in a `ResultException`:
unittest
{
	class MyException : Exception
	{
		this(string msg)
		{
			super(msg);
		}
	}

	Result!(int, MyException) noWrap = err(new MyException("an error occurred here!"));
	Result!(int, string) wrapped = err("an error occurred here!");

	static assert(!noWrap.ErrWillBeWrapped);
	static assert(wrapped.ErrWillBeWrapped);

	try { *noWrap; } catch (MyException) {}
	try { *wrapped; } catch (ResultException!string) {}
}

/// results can be compared and placed into associative arrays
unittest
{
	Result!(int, string) r1 = 3;
	Result!(int, string) r2 = 3;

	assert(r1 == r2);
	assert(r1.toHash() == r2.toHash());

	r2 = err("aaa!");
	assert(r1 != r2);
	r1 = err("wha?");
	assert(r1 != r2);
}

/// Functional-style map on results
unittest
{
	Result!(bool, string) success;
	Result!(bool, string) failure = err("err");

	// apply function to success value, do nothing to errors
	// compile time function gets inlined
	auto mappedSuccess = success.map!((v) => !v);
	auto mappedFailure = failure.map!((v) => !v);
	assert(*mappedSuccess);
	assert(failure == mappedFailure);

	// alternatively pass a function pointer or delegate of known signature at runtime
	bool flip(bool b) => !b;

	auto mappedSucc2 = success.map(&flip);
	assert(*mappedSucc2);

	// apply function to error value, do nothing to successes
	auto errMappedSuccess = success.map_err!((e) => e ~ " and some extra detail");
	auto errMappedFailure = failure.map_err!((e) => e ~ " and some extra detail");
	assert(success == errMappedSuccess);
	assert(errMappedFailure.getError == "err and some extra detail");

	string repeat(string s) => s ~ s;

	auto mappedErr2 = failure.map_err(&repeat);
	assert(mappedErr2.getError == "errerr");
}

/// Functional-style compositions of multiple / nested results
unittest
{
	Result!(int, int) success1 = 1;
	Result!(int, int) success2 = 2;
	Result!(int, int) success3 = 3;
	Result!(int, int) failure1 = err(1);
	Result!(int, int) failure2 = err(2);
	Result!(int, int) failure3 = err(3);

	// and_then takes the first error it encounters, or the rightmost success case if there are no errors
	assert(success1.and_then(success2) == ok(2));
	assert(failure1.and_then(failure2) == err(1));

	assert(success1.and_then(failure2).and_then(success3) == err(2));

	// or_else is the opposite - it takes the first success it encounters, or the rightmost error if there is no success
	assert(success1.or_else(success2) == ok(1));
	assert(failure1.or_else(failure2) == err(2));

	assert(success1.or_else(failure2).or_else(success3) == ok(1));

	// flatten a nested result, note `.flatten` is only defined if the error types are the same
	alias Nested = Result!(Result!(int, string), string);

	auto doubleSuccess = Nested(ok(5).insteadOf!string);
	auto nestedFailure = Nested(err("inner").insteadOf!int);
	auto outerFailure = Nested.err("outer");

	assert(doubleSuccess.flatten == ok(5));
	assert(nestedFailure.flatten == err("inner"));
	assert(outerFailure.flatten == err("outer"));

	// convert a Result!(Nullable!T) into a Nullable!(Result!T)
	// exactly equivalent to Rust's `Result::transpose`
	import std.typecons : Nullable, nullable;

	Result!(Nullable!int, string) okNull;
	Result!(Nullable!int, string) okNotNull = nullable(5);
	Result!(Nullable!int, string) errN = err(":(");

	assert(okNull.transpose.isNull);
	assert(okNotNull.transpose.get == ok(5));
	assert(errN.transpose.get == err(":("));
}

