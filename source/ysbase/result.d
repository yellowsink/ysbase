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

import std.traits : isInstanceOf, isCallable, ReturnType, hasElaborateDestructor, isCopyable;
import std.typecons : Nullable;

import ysbase : zcmove;

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

/++
`Result` is the wrapper type containing either a success value of type `T` or failure of type `E`.
$(LINK2 ../result.html, See top level docs).

The default initialization of a result (e.g. `Result!(T, E) res;`) is in the OK state with a default-initialized `T`.

`T` and `E` cannot be `void`, as that would make the ok-ness of the result statically knowable. You may, naturally,
use $(LINK2 /ysbase/Unit.html, `Unit`) to have payloadless ok and/or error cases.

`E` must be copyable as it could be thrown. `T` need not be.

$(SRCLL ysbase/result.d, 88)
+/
struct Result(T, E) if (!is(T == void) && !is(E == void) && isCopyable!E)
{
	version (D_DDoc)
	{
		/// Will the error be wrapped in `ResultException` when thrown?
		static bool ErrWillBeWrapped;
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
	T get() pure const @trusted => getRef();

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
	E getError() pure const @trusted => getErrorRef();

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
	E getErrorOr(lazy E default_) pure const @trusted
		=> !_hasValue ? _value.err : default_;

	/// Gets the value of result, and causes undefined behaviour if its an err
	ref inout(T) getUnchecked() pure nothrow inout @system => _value.val;

	/// Gets the error of result, and causes undefined behaviour if its ok
	ref inout(E) getErrorUnchecked() pure nothrow inout @system => _value.err;

	/// Returns an `std.typecons.Nullable` with the result value
	static if (isCopyable!T)
	Nullable!T tryGet() pure const nothrow @trusted => _hasValue ? Nullable!T(_value.val) : Nullable!T.init;

	/// Returns an `std.typecons.Nullable` with the error value
	Nullable!E tryGetError() pure const nothrow @trusted => !_hasValue ? Nullable!E(_value.err) : Nullable!E.init;

	/// `==` operator implementation
	bool opEquals(R)(auto ref const R other) const pure nothrow if (isInstanceOf!(Result, R))
	{
		if (_hasValue != other._hasValue) return false;

		return hasValue
			? _value.val == other._value.val
			: _value.err == other._value.err;
	}

	/// ditto
	// used for associative arrays and the like
	size_t toHash() const @nogc @trusted pure nothrow
	{
		import ysbase : getHashOf;

		return _hasValue ? getHashOf(_value.val) : getHashOf(_value.err);
	}

	// chaining ops:

	/// If this value is Ok, map it through the function, else just return self
	Result!(ReturnType!F, E) map(F)(auto ref F func) if (isCallable!F)
	{
		if (_hasValue)
			return ok(func(_value.val)).insteadOf!E;
		else
			return err(_value.err).insteadOf!(ReturnType!F);
	}

	/// If this value is Ok, lazily return res2, else just return self
	inout(R) and_then(R)(lazy inout(R) res2) const pure nothrow if (isInstanceOf!(Result, R) && is(R.ErrType == E))
	{
		if (_hasValue)
			return res2;
		else
			return err(_value.err).insteadOf!R.ValueType;
	}

	/// If this value is Err, map it through the function, else just return self
	Result!(T, ReturnType!F) map_err(F)(auto ref F func) if (isCallable!F)
	{
		if (_hasValue)
			return ok(_value.val).insteadOf!(ReturnType!F);
		else
			return err(func(_value.err)).insteadOf!T;
	}

	/// If this value is Err, lazily return res2, else just return self
	inout(R) or_else(R)(lazy inout(R) res2) const pure nothrow if (isInstanceOf!(Result, R) && is(R.ValueType == T))
	{
		if (_hasValue)
			return ok(_value.val).insteadOf!(R.ErrType);
		else
			return res2;
	}

	/// Converts a result of a nullable T into a nullable result
	/// Ok(null) becomes null, Ok(NotNull(v)) becomes NotNull(Ok(v)), and Err(e) becomes NotNull(Err(e))
	static if (isInstanceOf!(Nullable, T))
	Nullable!(Result!(typeof(T.get), E)) transpose() const pure nothrow
	{
		alias OkBranchType = typeof(T.get);
		alias InnerResult = Result!(OkBranchType, E);

		if (_hasValue)
		{
			if (_value.val.isNull)
				return Nullable!InnerResult.init;
			else
				return Nullable!InnerResult(ok(_value.val.get).insteadOf!E);
		}
		else
			return Nullable!InnerResult(err(_value.err).insteadOf!OkBranchType);
	}

	/// Flattens a `Result(Result(T, E), E)` to a `Result(T, E)`. The logic is `isOk ? get : this`.
	static if (isInstanceOf!(Result, T) && is(T.ErrType == E))
	inout(T) flatten() inout pure nothrow @trusted
		=> _hasValue ? _value.val : err(_value.err).insteadOf!(T.ValueType);
}

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

unittest
{
	// just to make it actually compile check everything
	Result!(int, bool) instantiate;
}
