/++
`Result` is a wrapper type that can either represent success (presence of an `T`),
or a failure/error value (type `E`).
This can be directly likened to Rust's `Result<T, E>`, and C++'s `std::expected<T, E>`.

It allows localised error handling by manually checking error state (`if (auto value = res) {}`), and centralised error
handling via the `.get` method and `*` operator, which throw the unexpected value if present (`auto value = *res;`).

The result module implements an API based on a proposal shown off by Andrei Alexandrescu in
$(LINK2 https://youtu.be/PH4WBuE1BHI, This cppcon talk), and implemented in `std::expected`.

Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.result;

// Note about this module: I know barely anything about OpenD (https://opendlang.org/changes.html), and am skeptical of
// its ability to go anywhere, but its `opImplicitCast` would make this implementation *hugely* nicer to use.
// Looking forward to any kind of similar DIPs that could replace `alias this`, which sadly cannot be generic.

/++
An unremarkable wrapper struct for a value that is an error but that has no knowledge of the success type.

This allows for improved type deduction (sadly not as nice as C++'s implicit conversion rules allow).
See $(LINK https://godbolt.org/z/TYKvd4Pbv) to see examples of how the type deduction plays out.

Use $(D err) to construct this.
+/
struct ErrWrap(E)
{
	static if (!is(E == void))
	E _err;

	/// While implicit conversion is possible for `Expected!(E, U) = unexpected();` cases,
	/// it is not for `return unexpected();` cases, so this allows the `return unexpected().insteadOf!E;` pattern.
	auto insteadOf(E)() => Result!(T, E)(this);
}

/// Creates a value representing failure. Like `ErrWrap` itself, exists to ease type deduction.
ErrWrap!E err(E)(auto ref E u) => ErrWrap(u);

/++
An unremarkable wrapper struct for a value that is a success but that has no knowledge of the error type.

This allows for improved type deduction (sadly not as nice as C++'s implicit conversion rules allow).
See $(LINK https://godbolt.org/z/TYKvd4Pbv) to see examples of how the type deduction plays out.

Use $(D ok) to construct this.
+/
struct OkWrap(T)
{
	static if (!is(T == void))
	T _ok;

	/// While implicit conversion is possible for `Expected!(E, U) = unexpected();` cases,
	/// it is not for `return unexpected();` cases, so this allows the `return unexpected().insteadOf!E;` pattern.
	auto insteadOf(E)() => Expected!(E, U)(this);
}

/// Creates a value representing a success! Like `OkWrap` itself, exists to ease type deduction.
OkWrap!T ok(T)(auto ref T v) => OkWrap(v);

/++
`Result` is the wrapper type containing either a success value of type `T` or failure of type `E`. See top level docs.

The default initialization of a result (e.g. `Result!(T, E) res;`) is in the OK state with a default-initialized `T`.

Always-okay results can be achieved by `Result!(T, void)`. Always-err results can be achieved by `Result!(void, E)`.
Constructors and `=` operators will be removed as appropriate, but getter functions' signatures will not be changed.

`Result!(void, void)` is not allowed, as then, e.g. `get` has no `T` to give, but also no `E` to give to `ResultException`.
+/
struct Result(T, E) if (!is(T == void) || !is(E == void))
{
	import core.lifetime : move;
	import std.traits : isInstanceOf, isCallable, ReturnType;
	import ysbase.nullable : Nullable;

	version (D_DDoc)
	{
		/// Will the error be wrapped in `ResultException` when thrown?
		static bool ErrWillBeWrapped;

		/// Is this result always OK, and never err? (This is the same concept as Rust's `std::convert::Infallible`)
		static bool IsAlwaysOk;

		/// Is this result always err, and never OK?
		static bool IsAlwaysErr;

		/// Is the OKness of this result statically known?
		static bool IsFixedState;
	}

	enum ErrWillBeWrapped = !is(E : Exception);

	enum IsAlwaysOk = is(E == void);

	enum IsAlwaysErr = is(T == void);

	enum IsFixedState = IsNeverErr || IsNeverOk;

@safe:

	///
	alias ValueType = T;
	///
	alias ErrType = E;

	private union Inner
	{
		static if (!IsNeverOk)
			T val;

		static if (!IsNeverErr)
			E err;
	}

	// default the Result to a default-inited T, so _hasValue defaults to true
	static if (!IsFixedState)
		private bool _hasValue = true;
	else static if (AlwaysOk)
		private enum _hasValue = true;
	else
		private enum _hasValue = false;

	private Inner _value;

	nothrow
	{
		// constructors for the OK case
		static if (!IsAlwaysErr)
		{
			/// Direct constructor for the OK case
			this(ref T val)
			{
				_value.val = move(val);
			}

			/// ditto
			this(T val) { this(val); }

			/// Promotes an `OkWrap` with no knowledge of the corresponding `E` type to a `Result`.
			static if (!IsAlwaysErr)
			this(ref OkWrap!T t) { this(t._ok); }

			/// ditto
			static if (!IsAlwaysErr)
			this(OkWrap!T t) { this(t._ok); }

			// assignment for the OK case
			/// `= T` operator
			Result opAssign(T value)
			{
				_value.val = value;
				_hasValue = true;
				return this;
			}

			/// `= .ok(T)` operator
			Result opAssign(OkWrap!T value)
			{
				_value.val = value._ok;

				static if (!IsFixedState)
					_hasValue = true;
				return this;
			}
		}

		// constructors for the Err case
		static if (!IsAlwaysOk)
		{
			/// Promotes an `ErrWrap` with no knowledge of the corresponding `T` type to a `Result`.
			this(ref ErrWrap!E e)
			{
				_value.err = e._err;

				static if (!IsFixedState)
					_hasValue = false;
			}

			/// ditto
			this(ErrWrap!E e) { this(e); }

			/// Directly constructs a Result with an error value `err`.
			/// Produces slightly more efficicient code than freestanding `.err()` on DMD and GDC, but does NOT on LDC.
			static Result err()(auto ref E err) pure @trusted
			{
				Result r = void;
				r._value.err = err;

				static if (!IsFixedState)
					r._hasValue = false;
				return r;
			}

			// assignment for the Err case
			/// `= .err(E)` operator
			Result opAssign(ErrWrap!E e)
			{
				_value.err = e._err;

				static if (!IsFixedState)
					_hasValue = false;
				return this;
			}
		}
	}

	/// If this result is OK (has a `T`)
	bool isOk() pure nothrow const => _hasValue;

	/// Casts to `bool` (including `if (result)`) check if the result `isOk()`
	alias opCast(T : bool) = isOk;

	/// Gets the value of the result if it exists, or throws the error type if not
	// this doesn't genericise nicely as `return` on a void makes no sense.
	static if (!IsAlwaysErr)
	T get() pure const @trusted => getRef();

	static if (IsAlwaysErr)
	void get() pure const { getRef(); }

	/// Gets a reference to the value of the result if it exists, or throws the error type if not.
	///
	/// Not safe as assigning an error to this result would then invalidate the reference.
	// this doesn't genericise nicely as `ref void` makes no sense.
	static if (!IsAlwaysErr)
	ref T getRef() pure const @system
	{
		if (!_hasValue)
			throw _value.err; // TODO: handle non-Exception `E`s nicely

		return _value.val;
	}

	static if (IsAlwaysErr)
	void getRef() pure const { throw _value.err; }

	/// The `*` operator is an alias to `get()`
	alias opUnary(string op : "*") = get;

	/// Gets the value of the result if it exists, or lazily evaluates and returns `default_`
	static if (!IsAlwaysErr)
	T getOr(lazy T default_) pure nothrow const @trusted
		=> _hasValue ? _value.val : default_;

	static if (IsAlwaysErr)
	void getOr() pure nothrow const {}

	/// Gets the error out of the result, or throws `ResultWasOkayException`
	static if (!IsAlwaysOk)
	E getError() pure const @trusted => getErrorRef();

	static if (IsAlwaysOk)
	void getError() pure const { getErrorRef(); }

	/// Gets a reference to the error out of the result, or throws `ResultWasOkayException`
	///
	/// Not safe as assigning a success to this result would then invalidate the reference.
	static if (!IsAlwaysOk)
	ref E getErrorRef() pure const @system
	{
		if (_hasValue)
			throw new ResultWasOkException;

		return _value.err;
	}

	static if (IsAlwaysOk)
	void getErrorRef() pure const { throw new ResultWasOkException; }

	/// Gets the error out of the result if it exists, or lazily evaluates and returns `default_`
	static if (!IsAlwaysOk)
	E getErrorOr(lazy E default_) pure nothrow const @trusted
		=> !_hasValue ? _value.err : default_;

	static if (IsAlwaysOk)
	void getErrorOr() pure nothrow const {}

	/// Gets the value of result, and causes undefined behaviour if its an err
	static if (!IsAlwaysErr)
	T getUnchecked() pure nothrow const @system => _value.val;

	static if (IsAlwaysErr)
	void getUnchecked() pure nothrow const {}

	/// Gets the error of result, and causes undefined behaviour if its ok
	static if (!IsAlwaysOk)
	T getErrorUnchecked() pure nothrow const @system => _value.err;

	static if (IsAlwaysOk)
	void getErrorUnchecked() pure nothrow const {}

	/// Returns an `std.typecons.Nullable` with the result value
	static if (!IsAlwaysErr)
	Nullable!T tryGet() pure const nothrow @trusted => _hasValue ? Nullable!T(_value.val) : Nullable!T.init;

	static if (IsAlwaysErr)
	Nullable!void tryGet() pure const nothrow @trusted => Nullable!T.init;

	/// Returns an `std.typecons.Nullable` with the error value
	static if (!IsAlwaysOk)
	Nullable!E tryGetError() pure const nothrow @trusted => !_hasValue ? Nullable!E(_value.err) : Nullable!E.init;

	static if (IsAlwaysOk)
	Nullable!void tryGetError() pure const nothrow @trusted => Nullable!E.init;


	/// `==` operator implementation
	bool opEquals(R)(auto ref const R other) const pure nothrow if (isInstanceOf!(Result, R))
	{
		if (_hasValue != other._hasValue) return false;

		// oh boy i love that even though the compiler will optimise the branches out i still can't refer to val etc
		static if (IsFixedState || other.IsFixedState)
		{
			static if (IsFixedState)
			{
				static if (_hasValue)
					return _value.val == other._value.val;
				else
					return _value.err == other._value.err;
			}
			else static if (other.IsFixedState)
			{
				static if (other._hasValue)
					return _value.val == other._value.val;
				else
					return _value.err == other._value.err;
			}
			else
				return _value.err == other._value.err;
		}
		else
			return hasValue ? _value.val == other._value.val : _value.err == other._value.err;
	}

	/// ditto
	// used for associative arrays and the like
	size_t toHash() const @nogc @safe pure nothrow
	{
		import ysbase : getHashOf;

		// I wish D had a combination `if` and `static if` based on if the param was an `enum` lvalue or not.
		static if (IsAlwaysOk)
			return getHashOf(_value.val);
		else static if (IsAlwaysErr)
			return getHashOf(_value.err);
		else
			return _hasValue ? getHashOf(_value.val) : getHashOf(_value.err);
	}


	// chaining ops:

	/// If this value is Ok, map it through the function, else just return self
	Result!(ReturnType!F, E) map(F)(auto ref F func) if(isCallable!F)
	{
		if (_hasValue)
			return ok(func(_value.val)).insteadOf!E;
		else
			return err(_value.err).insteadOf!(ReturnType!F);

			// TODO: finish converting this to allow fixedstate or entirely remove it
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
	// we don't need to handle E == void as if a result cannot be err, ResultException can never be thrown!
	this(string callerName)(E e, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		thrownErr = e;
		super("Cannot call " ~ callerName ~ " on a result that is err.", file, line, next);
	}
}

/// An exception thrown when trying to get the error out of a result that was ok.
class ResultWasOkException : Exception
{
	this(string callerName)(string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super("Cannot call " ~ callerName ~ " on a result that is ok.", file, line, next);
	}
}
