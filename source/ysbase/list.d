/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.list;

import ysbase.allocation : reallocate, stateSize, theAllocator, expandArray, shrinkArray, makeArray, dispose;

import std.traits : isInstanceOf;

import std.range : isInputRange, ElementType;

import std.algorithm : max;

/++
A List is a contiguous collection of elements like an array, that can grow and shrink.
Their elements are just as efficient to access as arrays.

Lists may allocate some extra unused capacity to optimize for future growth.
Common practice is to $(LINK2 https://en.wikipedia.org/wiki/Dynamic_array#Growth_factor, double in size when full),
but this library multiplies its size by 1.5 when full,
$(LINK2 https://github.com/facebook/folly/blob/main/folly/docs/FBVector.md#memory-handling, in line with `folly::fbvector`).

Lists do not have reference semantics, and copying one will copy the entire contents of the list.
You can achieve reference semantics with $(D $(LINK2 ../rc_struct/RcStruct.html, RcStruct)!List).

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

$(SRCL ysbase/list.d)

Params:
	T_ = The type of the list elements
	TAlloc = The type of the allocator. If `void`, then `theAllocator` is used instead of any local instance.
+/
struct List(T_, TAlloc = void)
{
// #region traits
public:

	enum allocatorIsDefault = is(TAlloc == void);

	enum allocatorIsStateful = !allocatorIsDefault && stateSize!TAlloc != 0;

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
	this(R)(auto scope ref R rhs, TAlloc alloc) if (isInputRange!R)
	{
		_allocator = alloc;
		this = rhs;
	}

	/// Construct a list out of another list.
	/// If the allocator is stateful, non-default and `rhs` is a list with the same allocator type,
	/// this will copy `rhs`'s allocator, else it will use a default-constructed allocator.
	///
	/// To explicitly construct from another list with the same `TAlloc` with a default-initialized allocator instance,
	/// you could first define the list and then assign the list into it.
	this(R)(auto scope ref R rhs) if (isInputRange!R && is(T == ElementType!R))
	{
		static if (allocatorIsStateful && isList!R && is(typeof(rhs.allocator == TAlloc)))
			_allocator = rhs.allocator;

		this = rhs;
	}

	/// copy constructor
	this(ref typeof(this) rhs)
	{
		static if (allocatorIsStateful)
			_allocator = rhs.allocator;

		this = rhs;
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
		import std.range : hasLength;

		static if (hasLength!Rhs)
		{
			if (rhs.length > capacity)
				_autoGrow(rhs.length - capacity);
		}

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

	~this()
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
	size_t length() @property => _length;

	/// The number of elements this list can hold without resizing (the size of the current backing array).
	size_t capacity() @property => _store.length;

	/// The number of extra elements this list could hold without resizing.
	size_t freeSpace() @property => capacity - length;

	/// Is this list empty? Part of the range interface.
	bool empty() @property => !_length;

	/// The allocator in use
	ref auto allocator() @property => _allocator;

// #endregion

// #region slicing operators

	/// Unary slice `[]` operator
	T[] opIndex() => _store[0 .. _length];

	/// Index `[n]` operator (`ref`, so provides get, set, and indexUnary)
	ref T opIndex(size_t i)
	{
		assert(i < _length, "overflow");

		return _store[i];
	}

	/// Slice `[i .. j]` operator
	T[] opSlice(size_t dim: 0)(size_t i, size_t j)
	{
		assert(i < j, "start of slice cannot be after the end of the slice");
		assert(j < _length, "overflow");
		return _store[i .. j];
	}

	// part of the slice operator implementation
	// https://dlang.org/spec/operatoroverloading.html#slice
	T[] opIndex(T[] slice) => slice;

	/// `$` operator in slices
	size_t opDollar(size_t dim: 0)() => _length;


	/// Index Op Assign (e.g. `v[n] += 5`) operator
	void opIndexOpAssign(string op, T)(auto ref T rhs, size_t i)
	{
		mixin("this[i] " ~ op ~ "= rhs;");
	}

	/// Slice Op Assign (e.g. `v[i..j] += 5`) operator
	void opIndexOpAssign(string op, T)(auto ref T rhs, T[] slice = this[])
	{
		foreach (ref val; slice)
			mixin("val " ~ op ~ "= rhs;");
	}

	/// Slice Unary operators (e.g. `++v[]`)
	void opIndexUnary(string op)(T[] slice = this[])
	{
		foreach (ref val; slice)
			mixin(op ~ "val;");
	}

// #endregion

// #region append operators

	/// Append operator `~` for a range, creates a copy of this list and appends the range `rhs`'s elements to it.
	typeof(this) opBinary(string op: "~", R)(R rhs) if (isInputRange!T && is(T == ElementType!R))
	{
		import core.lifetime : move;
		import std.range : chain;

		// directly constructing from chain() doesn't copy the allocator.
		typeof(this) newList;

		static if (allocatorIsStateful)
			newList._allocator = _allocator;

		newList = chain(this, rhs);

		return move(newList);
	}

	/// Append operator `~` for an element, creates a copy of this list and appends the element to it.
	typeof(this) opBinary(string op : "~")(auto ref T value)
	{
		import core.lifetime : move;

		auto copy = this;
		copy ~= value;
		return move(copy);
	}

	/// In-place append operator `~=` for a range, appends the contents of the range `rhs` onto the end of this
	void opOpAssign(string op: "~", R)(R rhs) if (isInputRange!T && is(T == ElementType!R))
	{
		import std.range : hasLength;

		static if (hasLength!R)
		{
			if (rhs.length > freeSpace)
				_autoGrow(rhs.length - freeSpace);
		}

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
		if (!freeSpace) _autoGrow();

		_store[_length++] = value;
	}

// #endregion

// #region efficient foreach implementation
	// without this, it would remove pop elements from the front of this list repeatedly, which is really not good.

	int opApply(scope int delegate(ref T) dg)
	{
		if (_store) return 0;

		foreach (ref item; this[])
		{
			auto result = dg(item);
			if (result) return result;
		}
		return 0;
	}

	int opApplyReverse(scope int delegate(ref T) dg)
	{
		if (_store) return 0;

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

	ref T front() @property => this[0];

	ref T back() @property => this[$];

	void popFront()
	{
		if (empty) return;

		// TODO
	}

	void popBack()
	{
		if (empty) return;

		_store[_length--] = T.init;
	}

// #endregion

// #region other mutation methods

	/// Alias for `~=`
	void pushBack()(auto ref T value)
	{
		this ~= value;
	}

	/// Constructs a new element at the end of this array.
	void emplaceBack(A...)(auto ref A args)
	{
		if (!freeSpace) _autoGrow();

		// for non-class types, there is no () constructor, and we keep the unused capacity default-inited at all times.
		static if (A.length == 0 && !is(T == class) && !is(T == interface))
			_length++;
		else
			_store[_length++] = T(args);
	}

	/// Alias for `this = null;`
	void clear() { this = null; }

	// TODO: so many missing APIs lol

// #endregion

// #region capacity management APIs

	/// Ensures there is enough capacity for at least `additional` more elements to be pushed without reallocation.
	void reserve(size_t additional)
	{
		if (additional <= freeSpace) return;

		auto neededGrowth = additional - freeSpace;
		_autoGrow(neededGrowth);
	}

	/// Grows the total capacity to at least `cap`. Note that `reserve` is relative and `growsCapacityTo` is absolute.
	void growCapacityTo(size_t cap)
	{
		if (cap > capacity)
			reserve(cap - length);
	}

	/// Shrinks the backing array such that the capacity and length are equal.
	// this is it, this is the one slightly goofy function name I'm giving myself for this module -- Hazel
	void shrinkwrap()
	{
		// uses allocator's native reallocate(), or failing that, ysbase.allocation.reallocate(_allocator). thanks UFCS!
		if (freeSpace)
			_allocator.reallocate(_store, _length);
	}

// #endregion

// #region internals
private:

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

enum isList(T) = isInstanceOf!(List, T);

unittest
{
	List!int _instantiate;
	auto copy = _instantiate;
}

unittest
{
	List!int myList = [1, 2, 3];

	assert(myList.length == 3);
	assert(myList[] == [1, 2, 3]);
}
