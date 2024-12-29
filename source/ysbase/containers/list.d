/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.containers.list;

import ysbase.allocation : reallocate, stateSize, theAllocator, expandArray, shrinkArray, makeArray, dispose;

import std.traits : isInstanceOf, hasElaborateDestructor;

import std.range : isInputRange, ElementType, hasLength;

import std.algorithm : max;

/// Is `T` a `List`?
enum isList(T) = isInstanceOf!(List, T);

/++
A List is a contiguous collection of elements like an array, that can grow and shrink.
Their elements are just as efficient to access as arrays.

Lists may allocate some extra unused capacity to optimize for future growth.
Common practice is to $(LINK2 https://en.wikipedia.org/wiki/Dynamic_array#Growth_factor, double in size when full),
but this library multiplies its size by 1.5 when full,
$(LINK2 https://github.com/facebook/folly/blob/main/folly/docs/FBVector.md#memory-handling, in line with `folly::fbvector`).

Lists do not have reference semantics, and copying one will copy the entire contents of the list.
You can achieve reference semantics with $(D $(LINK2 ../../rc_struct/RcStruct.html, RcStruct)!List).

Lists implement $(I most of) the API of a $(LINK2 https://dlang.org/phobos/std_range_primitives.html#isRandomAccessRange,
random access range), minus the `save` method.
Therefore the only defined range type that List actually implements is an input range.
List provides an efficent `foreach` and `foreach_reverse` implementation, which is sufficient for functions that take a
range and just loop over it (this includes the implementations of List's constructors, `=`, `~`, and `~=` operators!)
but it is highly recommended not to use a List instance as a range $(I in general) because:
$(UL
	$(LI The lack of the `save` method makes it incompatible with anything requiring a forward range)
	$(LI `popFront` on a List mutates the list and is very expensive!)
	$(LI Both of these problems are easily solved by using `l[]`, which is very cheap and is a random-access range.)
)

Note that `List` purposefully excludes some functions that might otherwise make sense, as they are trivial to implement
with provided methods, for example there is no `moveFrom(idx)`, as `move(list[idx])` works just fine,
and similarly there is no `.ptr`, as, while `&list[0]` will work only for non-empty lists, `list[].ptr` always works.

Why is barely any of List `@safe`?:
List allows you to take references to the elements within it, and therefore any methods which mutate the list such
that they could invalidate those references are unsafe as they can create dangling pointers.

$(SRCL ysbase/containers/list.d)

Params:
	T_ = The type of the list elements
	TAlloc = The type of the allocator. If `void`, then `theAllocator` is used instead of any local instance.
	BoundsChecks = Should bounds checks always be performed, or only in debug builds?
+/
struct List(T_, TAlloc = void, bool BoundsChecks = true)
{
// #region traits
public:

	version (D_Ddoc)
	{
		/// Does this list use `theAllocator`? (`TAlloc == void`)
		static bool allocatorIsDefault;

		/// If this allocator is not `theAllocator`, does it have any state (is an instance held within the list)?
		static bool allocatorIsStateful;
	}

	enum allocatorIsDefault = is(TAlloc == void);

	enum allocatorIsStateful = !allocatorIsDefault && stateSize!TAlloc != 0;

	/// The element type of the list
	alias T = T_;

// #endregion

// #region state
private:

	static if (allocatorIsDefault)
		alias _allocator = theAllocator;
	else static if (allocatorIsStateful)
		TAlloc _allocator;
	else
		alias _allocator = TAlloc.instance;

	// _store.length is the capacity
	T[] _store;
	size_t _length;


// #endregion

public:
// #region constructors, destructors, opAssign

	/// Construct an empty List with the given allocator instance. Requires the allocator to be stateful and non-default.
	static if (allocatorIsStateful)
	this(TAlloc alloc)
	{
		_allocator = alloc;
	}

	/// Construct a list out of another list (or range), with a provided allocator instance.
	/// Requires the allocator to be stateful and non-default.
	static if (allocatorIsStateful)
	this(R)(auto scope ref R rhs, TAlloc alloc) if (isInputRange!R && is(T == ElementType!R))
	{
		_allocator = alloc;
		() @trusted { this = rhs; }();
	}

	/// Construct a list out of another list or range.
	/// If the allocator is stateful, non-default and `rhs` is a list with the same allocator type,
	/// this will copy `rhs`'s allocator, else it will use a default-constructed allocator.
	///
	/// To explicitly construct from another list with the same `TAlloc` with a default-initialized allocator instance,
	/// you could first define the list and then assign the list into it.
	this(R)(auto scope ref R rhs) if (isInputRange!R && is(T == ElementType!R))
	{
		static if (allocatorIsStateful && isList!R && is(typeof(rhs.allocator == TAlloc)))
			_allocator = rhs.allocator;

		() @trusted { this = rhs; }();
	}

	/// copy constructor
	this(ref typeof(this) rhs)
	{
		static if (allocatorIsStateful)
			_allocator = rhs.allocator;

		() @trusted { this = rhs[]; }();
	}

	/// Clear this list
	void opAssign(typeof(null) nil)
	{
		_length = 0;
		// default initialize the backing store, this will call correctly destructors
		_store[] = T.init;
	}

	/// Copy into this list from an input range (or another list!)
	/// Note this copies every element, it does not share them.
	void opAssign(Rhs)(auto scope ref Rhs rhs) if (isInputRange!Rhs && is(T == ElementType!Rhs))
	{
		static if (hasLength!Rhs)
			reserve(rhs.length);

		size_t copiedLen;
		foreach (ref element; rhs)
		{
			// if we don't know rhs's length, we can't be sure we can fit it ahead of time,
			// so we have to check each time if we're about to run out of space and grow dynamically.
			static if (!hasLength!Rhs)
				if (copiedLen == capacity)
					_autoGrow();

			_store[copiedLen++] = element;
		}

		// if rhs is smaller than our existing store, destruct the remaining elements
		if (copiedLen < _length)
			_store[copiedLen .. _length] = T.init;

		_length = copiedLen;
	}

	~this() @trusted // its not really but otherwise *having a list* in @safe code is impossible
	{
		if (!_store)
			return;

		_allocator.dispose(_store);
		_store = null;
		_length = 0;
	}

// #endregion

// #region getter properties

	/// The number of elements in the list. Part of the range interface
	size_t length() const @property @safe => _length;

	/// The number of elements this list can hold without resizing (the size of the current backing array).
	size_t capacity() const @property @safe => _store.length;

	/// The number of extra elements this list could hold without resizing.
	size_t freeSpace() const @property @safe => capacity - length;

	/// Is this list empty? Part of the range interface.
	bool empty() const @property @safe => !_length;

	/// The allocator in use
	ref auto allocator() const @property @safe => _allocator;

// #endregion

// #region slicing operators, `in`, at

	/// Equivalent to `this[n]`, except negative indices are interpreted as relative to the array end (`at(-1) == back`).
	ref inout(T) at(ptrdiff_t n) inout @safe => _store[_wrapAndCheck(n)];

	/// Unary slice `[]` operator
	inout(T)[] opIndex() inout @safe => _store[0 .. _length];

	/// Index `[n]` operator (`ref`, so provides get, set, and indexUnary)
	ref inout(T) opIndex(size_t i) inout @safe => _store[_boundsCheck(i)];

	/// Slice `[i .. j]` operator
	inout(T)[] opSlice(size_t dim: 0)(size_t i, size_t j) inout @safe
	{
		_enforce(i < j, "start of slice cannot be after the end of the slice");
		// slices point 1 past the end of the array
		_boundsCheck(j - 1);
		return _store[i .. j];
	}

	// part of the slice operator implementation
	// https://dlang.org/spec/operatoroverloading.html#slice
	inout(T)[] opIndex(inout(T)[] slice) @safe => slice;

	/// `$` operator in slices
	size_t opDollar(size_t dim: 0)() const @safe => _length;

	/// Index Op Assign (e.g. `v[n] += 5`) operator
	// this is implemented purely because opIndexOpAssign has to exist for slice op assign
	// and because it exists, the impl using ref for indexing fails, so we have to provide an indexed version.
	void opIndexOpAssign(string op, T)(auto ref T rhs, size_t i)
	{
		_boundsCheck(i);
		mixin("_store[i] " ~ op ~ "= rhs;");
	}

	/// Slice Op Assign (e.g. `v[i..j] += 5`, `v[] -= 2`) operator
	// Has to exist because we overload slicing
	void opIndexOpAssign(string op, T)(auto ref T rhs, T[] slice)
	{
		foreach (ref val; slice)
			mixin("val " ~ op ~ "= rhs;");
	}

	/// ditto
	void opIndexOpAssign(string op, T)(auto ref T rhs) => opIndexOpAssign!op(rhs, this[]);

	/// Slice and Index Unary operators (e.g. `++v[n]`, `++v[i..j]`, `++v[]`)
	// also, has to exist because we overload slicing
	void opIndexUnary(string op)(T[] slice)
	{
		foreach (ref val; slice)
			mixin(op ~ "val;");
	}

	/// ditto
	void opIndexUnary(string op)(size_t idx)
	{
		mixin(op ~ "_store[idx];");
	}

	/// ditto
	void opIndexUnary(string op)()
	{
		opIndexUnary!op(this[]);
	}

	/// The `in` keyword, which checks if there exists a value that `== lhs`
	T* opBinaryRight(string op: "in", L)(auto ref const L lhs) @safe
	{
		foreach (i, ref v; this[])
			if (v == lhs)
				return &this[i];

		return null;
	}

// #endregion

// #region append operators, ==

	/// Append operator `~` for a range, creates a copy of this list and appends the range `rhs`'s elements to it.
	typeof(this) opBinary(string op: "~", R)(R rhs) @safe if (isInputRange!R && is(T == ElementType!R))
	{
		import std.range : chain;

		// directly constructing from chain() doesn't copy the allocator.
		typeof(this) newList;

		static if (allocatorIsStateful)
			newList._allocator = _allocator;

		() @trusted { newList = chain(this[], rhs); }();

		return newList; // nrvo should kick in here
	}

	/// Append operator `~` for an element, creates a copy of this list and appends the element to it.
	typeof(this) opBinary(string op : "~")(auto ref T value) @safe
	{
		auto copy = this;
		() @trusted { copy ~= value; }();
		return copy;
	}

	/// Equality operator `==`
	bool opEquals(R)(auto ref const R rhs) const @safe if (isList!R && is(R.T == T))
	{
		if (rhs.length != length) return false;

		foreach (i, ref value; this[])
			if (value != rhs[i]) return false;

		return true;
	}

	/// ditto
	// necessary because the default tohash just hashes the struct bits, but to work as an AA key, the rule is that
	// if two objects are equal, they MUST have the same hash, else its undefined behaviour,
	// so we must actually hash the list contents ourselves.
	size_t toHash() const @nogc @safe pure nothrow
	{
		import std.traits : hasMember;
		import ysbase : transmute;

		size_t h;

		foreach (i, ref value; this[])
		{
			static if (hasMember!(T, "toHash"))
				h ^= i.toHash();
			else static if (is(T == class) || is(T == interface))
				h ^= cast(size_t) (cast(void*) T);
			else
				foreach (byte_; (() @trusted => value.transmute!(ubyte[T.sizeof]))())
					h ^= byte_;
		}

		return h;
	}

	/// In-place append operator `~=` for a range, appends the contents of the range `rhs` onto the end of this
	void opOpAssign(string op: "~", R)(R rhs) if (isInputRange!R && is(T == ElementType!R))
	{
		static if (hasLength!R)
			reserve(rhs.length);

		foreach (ref element; rhs)
		{
			// couldn't pre-allocate space, need to check on the fly
			static if (!hasLength!R)
				if (!freeSpace)
					_autoGrow();

			_store[_length++] = element;
		}
	}

	/// In-place append operator `~=` for a value, appends the value onto the end of this
	void opOpAssign(string op : "~")(auto ref T value)
	{
		reserve(1);

		_store[_length++] = value;
	}

// #endregion

// #region efficient foreach implementation
	// without this, it would remove pop elements from the front of this list repeatedly, which is really not good.

	// if the delegate is safe, then the function below is safe, else it isn't
	/// Implements efficient `foreach`
	int opApply(scope int delegate(ref T) @safe dg) @trusted
	{
		return opApply(cast(int delegate(ref T)) dg);
	}

	/// ditto
	int opApply(scope int delegate(ref T) dg)
	{
		foreach (ref item; this[])
		{
			auto result = dg(item);
			if (result) return result;
		}
		return 0;
	}

	/// Implements effecient `foreach_reverse`
	int opApplyReverse(scope int delegate(ref T) @safe dg) @trusted
	{
		return opApplyReverse(cast(int delegate(ref T)) dg);
	}

	/// ditto
	int opApplyReverse(scope int delegate(ref T) dg)
	{
		foreach_reverse (ref item; this[])
		{
			auto result = dg(item);
			if (result) return result;
		}
		return 0;
	}

// #endregion

// #region front, back, popFront, popBack
	// implements the range interface

	ref inout(T) front() inout @property @safe => this[0];

	ref inout(T) back() inout @property @safe => this[$ - 1];

	void popFront()
	{
		if (empty) return;

		removeAt(0);
	}

	void popBack()
	{
		if (empty) return;

		_store[--_length] = T.init;
	}

// #endregion

// #region other mutation methods

	/// Constructs a new element at the end of this array.
	void emplaceBack(A...)(auto ref A args)
	{
		import core.lifetime : forward;

		reserve(1);

		// for non-class types, there is no () constructor, and we keep the unused capacity default-inited at all times.
		static if (A.length == 0 && !is(T == class) && !is(T == interface))
			_length++;
		else
			_store[_length++] = T(forward!args);
	}

	/// Inserts `value` into the list such that it is then at `list[idx]`.
	void insertAt()(size_t idx, auto ref T value)
	{
		import std.range : only;

		insertAt(idx, only(value));
	}

	/// Inserts `range` into the list at `idx`. The length of the list must be known ahead of time.
	void insertAt(R)(size_t idx, auto ref R range) if (isInputRange!R && hasLength!R)
	{
		import core.lifetime : moveEmplace;

		// bounds check
		auto rangLen = range.length;

		_boundsCheck(idx);

		// a reserve then a blit is very inefficient but i'll make it better later.
		reserve(rangLen);

		// fast path for the end of the list
		if (idx == length)
		{
			this ~= range;
			return;
		}

		// blit over elements to make space
		auto openedUpSpace = _blitStoreBy!false(rangLen, idx, length - idx);

		assert(openedUpSpace.length == rangLen, "range to insert is not the same length as the opened up spaces");

		size_t i;
		foreach (ref value; range)
			moveEmplace(value, openedUpSpace[i++]);

		_length += rangLen;
	}

	/// Constructs a new element in the middle of the lTist such that it is at `list[idx]`
	void emplaceAt(A...)(size_t idx, auto ref A args)
	{
		import core.lifetime : forward;

		// i'm sure there's a more efficient way to do this
		insertAt(idx, T(forward!args));
	}

	/// Removes `n` elements from `idx` from the list.
	void removeAt(size_t idx, size_t n = 1)
	{
		_boundsCheck(idx);
		_boundsCheck(idx + n);

		if (n == 0) return;

		// fast path for the last element
		if (n == 1 && idx + 1 == length)
			_store[idx] = T.init;
		else
			// blit the elements left.
			_blitStoreBy(-n, idx + n, (length - idx - n));

		_length -= n;
	}

// #endregion

// #region capacity management APIs

	/// Ensures there is enough capacity for at least `additional` more elements to be pushed without reallocation.
	void reserve(size_t additional)
	{
		if (additional <= freeSpace) return;

		auto neededGrowth = additional - freeSpace;
		_autoGrow(neededGrowth);
	}

	/// Grows the total capacity to at least `cap`. Note that `reserve` is relative and `growCapacityTo` is absolute.
	void growCapacityTo(size_t cap)
	{
		if (cap > capacity)
			reserve(cap - length);
	}

	/// Shrinks the backing array such that the capacity and length are equal.
	// this is it, this is the one slightly goofy function name I'm giving myself for this module -- Hazel
	void shrinkwrap()
	{
		import ysbase.allocation : shrinkArray;

		if (freeSpace)
			_allocator.shrinkArray(_store, freeSpace);
	}

// #endregion

// #region internals
private:

	pragma(inline, true)
	static void _enforce(T)(const T value, lazy string msg) @safe pure
	{
		import std.exception : enforce;

		static if (BoundsChecks)
			enforce(value, msg);
		else
			assert(value, msg);
	}

	//size_t _boundsCheck(ptrdiff_t idx) => _boundsCheck(idx, this[]);

	size_t _boundsCheck(ptrdiff_t idx/* , T[] range */) const @safe pure
	{
		_enforce(idx >= 0, "index out of range");
		_enforce(idx < length, "index out of range");

		// doesn't work
		//auto addr = &_store[idx];
		//_enforce(&range[0] < addr && addr < &range[$ - 1], "index out of range");

		return idx;
	}

	size_t _wrapAndCheck(ptrdiff_t idx) const @safe pure
	{
		if (idx < 0)
			idx += length;

		return _boundsCheck(idx);
	}

	// blits a range to the left or to the right by `dx`, as efficiently as possible.
	// If `destructTarget`, calls the destructor on the lost elements else it just assumes uninit and blits over it.
	// Returns a slice to the elements that need initializing - the object will be in an invalid state until inited.
	T[] _blitStoreBy(bool destructTarget = true)(ptrdiff_t dx, size_t idx, size_t len)
	{
		if (dx == 0) return [];

		// lower bound
		assert(idx + dx >= 0, "blit out of range");

		// upper bound
		assert(idx + dx + len <= capacity, "blit out of range");

		// first, destruct the target elements
		static if (hasElaborateDestructor!T && destructTarget)
		{
			// if we're moving right, targets are from past the end of the slice, for dx elems,
			// else its dx elements to the left of it.
			auto targets = dx > 0 ? _store[idx + len .. idx + len + dx] : _store[idx + dx .. idx];

			foreach (ref value; targets) destroy!false(value);
		}

		// then, blit the array over
		_blit(_store[idx .. idx + len], _store[idx + dx .. idx + dx + len]);

		// finally, return the newly opened elements
		// if we're moving right, these are the first dx of the array
		// if we're moving left, these are the last dx of the array
		return dx > 0
			? _store[idx .. idx + dx]
			: _store[idx + len + dx .. idx + len];
	}

	// correctly calls opPostMove but does not call destructors for overwritten types nor re-initialize src.
	void _blit(T)(T[] src, T[] dest)
	{
		import core.stdc.string : memmove, memcpy;
		import std.traits : hasElaborateMove;

		auto dvoid = cast(void[]) dest;
		auto svoid = cast(void[]) src;

		assert(src.length == dest.length);

		static if (!hasElaborateMove!T)
			memmove(dvoid.ptr, svoid.ptr, svoid.length);
		else
		{
			// no overlap, can do a fast memcpy
			if ((dvoid.ptr + dvoid.length < svoid.ptr) || (svoid.ptr + svoid.length < dvoid.ptr))
			{
				memcpy(dvoid.ptr, svoid.ptr, svoid.length);

				// call opPostMove
				foreach (ref value, i; dest)
					value.opPostMove(src[i]);
			}

			// implement a memmove ourselves
			if (dvoid.ptr > svoid.ptr)
			{
				// we're moving forwards in memory, so move the back before the front
				for (ptrdiff_t i = src.length; i >= 0; i--)
				{
					auto b = i * T.sizeof;
					// blit
					*(cast(ubyte[T.sizeof]*) (dvoid.ptr + b)) = *(cast(ubyte[T.sizeof]*) (svoid.ptr + b));
					// postmove
					dest[i].opPostMove(src[i]);
				}
			}
			else
			{
				// moving backwards in memory, move from the front first
				for (ptrdiff_t i = 0; i < src.length; i++)
				{
					auto b = i * T.sizeof;
					// blit
					*(cast(ubyte[T.sizeof]*) (dvoid + b)) = *(cast(ubyte[T.sizeof]*) (svoid + b));
					// postmove
					dest[i].opPostMove(src[i]);
				}
			}
		}
	}

	bool _growBacking(size_t delta)
	{
		if (_store.ptr)
			return _allocator.expandArray(_store, delta);
		else
		{
			_store = _allocator.makeArray!T(delta);
			return _store !is null;
		}
	}

	void _autoGrow(size_t neededAmt = 0)
	{
		// grow to 1.5x unless we need more
		auto success = _growBacking(max(1, neededAmt, capacity / 2));
		assert(success);
	}
// #endregion
}

///
unittest
{
	List!int someIntegers = [1, 2, 3];

	assert(someIntegers.length == 3);

	someIntegers ~= [4, 5];
	someIntegers ~= 6;

	assert(someIntegers.length == 6);

	assert(someIntegers[] == [1, 2, 3, 4, 5, 6]);

	// replace the list content
	someIntegers = [5, 3, 6];

	assert(someIntegers.length == 3);

	// slicing a list works exactly as expected
	assert(someIntegers[2 .. $] == [6]);

	// copying a list shallow-copies its content
	auto moreIntegers = someIntegers;

	assert(moreIntegers == someIntegers);

	moreIntegers[2] = 5;

	assert(moreIntegers != someIntegers);

	// `at` allows negative indices relative to the back of the array
	assert(moreIntegers.at(-2) == 3);

	// clear the list
	someIntegers = null;

	assert(someIntegers.empty);
	assert(someIntegers.capacity > 0, "assigning to a list uses the same backing store to reduce allocations");
}

/// Insert and remove elements from the list
unittest
{
	List!int someIntegers = [1, 2, 3, 4, 5];

	// remove 3 from the list
	someIntegers.removeAt(2);

	assert(someIntegers[] == [1, 2, 4, 5]);

	// insert 8 and 9 before 5
	someIntegers.insertAt(3, [8, 9]);

	assert(someIntegers[] == [1, 2, 4, 8, 9, 5]);

	// remove 1 and 2, and insert 7 after 4
	someIntegers.removeAt(0, 2);
	someIntegers.insertAt(1, 7);

	assert(someIntegers[] == [4, 7, 8, 9, 5]);
}

/// Capacity controls
unittest
{
	List!int someInts = [1, 2, 3];

	// make space for one more element
	someInts.reserve(1);

	assert(someInts.capacity >= 4);

	// increase the capacity to at least 12
	someInts.growCapacityTo(12);
	assert(someInts.capacity >= 12);

	// reduce the capacity to match the length
	someInts.shrinkwrap();
	assert(!someInts.freeSpace);
}

/// Emplace items in place
unittest
{
	static struct HasBigConstructor { this(string a, int b, double c) {} }

	List!HasBigConstructor list;

	list.emplaceBack("hi!", 5, 4.7);

	// create a few more items (default construction is valid too!)
	list.emplaceBack();
	list.emplaceBack();
	list.emplaceBack();

	// emplace one of them
	list.emplaceAt(2, "hi", 4, 2.5);
}

/// Slice mutation operations
unittest
{
	import std.range : iota;

	List!int integers = iota(0, 20);

	// increment all integers
	++integers[];

	assert(integers[0] == 1);

	// multiply some of them by 5
	integers[3 .. 7] *= 5;

	// decrement the fifth item then divide by 2
	--integers[4];
	integers[4] /= 2;

	assert(integers[4] == 12);

	// find the first 20 in the list and change it to 42 using the `in` operator
	if (auto ptr = 20 in integers)
		*ptr = 42;
	else
		assert(false);

	assert(!(7 in integers));
}

/// Appending to a new list
unittest
{
	List!int leftSide = [1, 2, 3];

	auto with67 = leftSide ~ [6, 7];

	auto with9 = with67 ~ 9;

	// all are different instances
	assert(leftSide[].ptr != with67[].ptr);
	assert(with67[].ptr != with9[].ptr);

	assert(leftSide[] == [1, 2, 3]);
	assert(with67[] == [1, 2, 3, 6, 7]);
	assert(with9[] == [1, 2, 3, 6, 7, 9]);
}

/// @safe iteration
unittest
{
	List!int myList = [1, 2, 3];

	foreach (integer; myList)
	{
		int x;
		int* y = &x; // do something unsafe
	}

	// but we can't in an @safe context:
	assert(!__traits(compiles,
		() @safe {
			foreach (integer; myList)
			{
				int x;
				int* y = &x;
			}
		}
	));

	() @safe {
		// but we can have @safe foreach bodies
		foreach (integer; myList) {}
	}();
}
