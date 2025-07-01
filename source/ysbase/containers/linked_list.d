/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.containers.linked_list;

import ysbase.allocation : reallocate, stateSize, theAllocator, make, dispose;

import std.traits : isInstanceOf, hasElaborateDestructor;

import std.range : isInputRange, ElementType, hasLength;

import std.algorithm : max;

import std.exception : enforce;

/// Is `T` a `LinkedList`?
enum isLinkedList(T) = isInstanceOf!(LinkedList, T);

/++
A LinkedList is a $(LINK2 https://en.wikipedia.org/wiki/Doubly_linked_list, doubly-linked list).

LinkedLists do not have reference semantics, and copying one will copy the entire contents of the list.
You can achieve reference semantics with $(D $(LINK2 ../../rc_struct/RcStruct.html, RcStruct)!LinkedList).

LinkedLists implement almost implement
$(LINK2 https://dlang.org/phobos/std_range_primitives.html#isBidirectionalRange, bidirectional ranges), but not the
`save` method. They do implement input ranges.
Range iteration will pop the head off the list in-place, and therefore it is recommended to use
a `LinkedList.Range` for iteration instead, which implements a performant bidirectional range that does not mutate the
list.

LinkedLists do, however provide an efficent implementation of `foreach` that does not mutate the list.

If you are not familar with linked lists, the TL;DR of their purpose over a normal `List` is:
$(UL
	$(LI Insertion and removal is very very fast (constant time))
	$(LI But, indexing into the list is quite slow (time grows linearly with list size))
	$(LI In general, they are very simple to implement, which makes them popular in systems programming,
		but this is of little relevance here.)
)

$(SRCL ysbase/containers/linked_list.d)

Params:
	T_ = The type of the list elements
	TAlloc = The type of the allocator. If `void`, then `theAllocator` is used instead of any local instance.
+/
struct LinkedList(T_, TAlloc = void)
{
public:
// #region traits

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

private:
// #region state

	static struct Node
	{
		Node* prev;
		Node* next;
		T item;
	}

	static if (allocatorIsDefault)
		alias _allocator = theAllocator;
	else static if (allocatorIsStateful)
		TAlloc _allocator;
	else
		alias _allocator = TAlloc.instance;

	Node* _head;
	Node* _tail;

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
	this(R)(auto ref scope R rhs, TAlloc alloc) if (isInputRange!R && is(T == ElementType!R))
	{
		_allocator = alloc;
		() @trusted { this ~= rhs; }();
	}

	/// Construct a list out of another list or range.
	/// If the allocator is stateful, non-default and `rhs` is a list with the same allocator type,
	/// this will copy `rhs`'s allocator, else it will use a default-constructed allocator.
	///
	/// To explicitly construct from another list with the same `TAlloc` with a default-initialized allocator instance,
	/// you could first define the list and then assign the list into it.
	this(R)(auto ref scope R rhs) if (isInputRange!R && is(T == ElementType!R))
	{
		static if (allocatorIsStateful && isLinkedList!R && is(typeof(rhs.allocator == TAlloc)))
			_allocator = rhs.allocator;

		() @trusted { this ~= rhs; }();
	}

	/// copy constructor
	this(ref typeof(this) rhs)
	{
		static if (allocatorIsStateful)
			_allocator = rhs.allocator;

		() @trusted { this ~= rhs; }();
	}

	/// Clear this list
	void opAssign(typeof(null) nil)
	{
		auto curs = cursorToFront();
		while (curs.exists)
		{
			auto nc = curs.next();
			curs.remove();
			curs = nc;
		}
	}

	/// Copy into this list from an input range (or another list!)
	/// Note this copies every element, it does not share them.
	void opAssign(Rhs)(auto ref scope Rhs rhs) if (isInputRange!Rhs && is(T == ElementType!Rhs))
	{
		this = null;
		this ~= rhs;
	}

	~this() @trusted
	{
		this = null;
	}

// #endregion

// #region cursor API

	/// A cursor, which is a struct that encapsulates a reference to a list node and allows efficient mutation on it.
	///
	/// A cursor outliving the LinkedList it references is undefined behaivour.
	/// As such, it is recommended that cursors are used $(I temporarily), for implementing mutation algorithms,
	/// and not as ways of keeping long lived references to items in the list.
	static struct Cursor
	{
		private LinkedList!(T, TAlloc)* ll;
		private Node* node;

		/// If the cursor is pointing at a node or not currently,
		/// Can be `false` as you could, for example, have an empty list, or done `cursorToFront.prev`.
		bool exists() const => node !is null;

		/// Retreives the value pointed to by this cursor.
		ref T value()
		{
			enforce(exists, "Cannot get the value out of an empty cursor");
			return node.item;
		}

		/// Gets the cursor to the next node in the list.
		Cursor next()
		{
			enforce(exists, "Cannot get the next cursor to an empty cursor");
			return Cursor(ll, node.next);
		}

		/// Gets the cursor to the previous node in the list.
		Cursor prev()
		{
			enforce(exists, "Cannot get the previous cursor to an empty cursor");
			return Cursor(ll, node.prev);
		}

		/// Removes this node from the list, and makes this cursor non-existent.
		/// Save the next or previous cursor if you want to retain a handle to the list.
		void remove()
		{
			enforce(exists, "Cannot remove a node that does not exist");

			if (node == ll._head)
				ll._head = null;

			if (node == ll._tail)
				ll._tail = null;

			if (node.prev)
			{
				node.prev.next = node.next;
			}
			if (node.next)
			{
				node.next.prev = node.prev;
			}

			ll._deallocateNode(node);
		}

		/// Inserts a new node before this one and returns a cursor to it
		Cursor insertBefore()(auto ref T t)
		{
			enforce(exists, "cannot insert a node before an empty cursor");

			auto n = ll._allocateNode(t);

			// update previous node
			if (node.prev)
			{
				n.prev = node.prev;
				node.prev.next = n;
			}

			// update this node
			n.next = node;
			node.prev = n;

			if (node == ll._head)
				ll._head = n;

			return Cursor(ll, n);
		}

		/// Inserts a new node after this one and returns a cursor to it
		Cursor insertAfter()(auto ref T t)
		{
			enforce(exists, "cannot insert a node after an empty cursor");

			auto n = ll._allocateNode(t);

			// update next node
			if (node.next)
			{
				n.next = node.next;
				node.next.prev = n;
			}

			// update this node
			n.prev = node;
			node.next = n;

			if (node == ll._tail)
				ll._tail = n;

			return Cursor(ll, n);
		}
	}

	/// Gets the cursor pointing to the front of this list. Returns an empty cursor if the list is empty.
	Cursor cursorToFront() => Cursor(&this, _head);

	/// Gets the cursor pointing to the back of this list. Returns an empty cursor if the list is empty.
	Cursor cursorToBack() => Cursor(&this, _tail);

	/// Gets the cursor pointing to the `i`th element of this list. Slow. Throws if out of range.
	/// Negative values are relative to the end of the list.
	Cursor cursorAt(ptrdiff_t i)
	{
		auto fromFront = i > 0;
		auto curs = fromFront ? cursorToFront : cursorToBack;

		void enf() { enforce(curs.exists, "index out of range while getting cursor"); }

		if (fromFront)
		{
			for(; i; curs = curs.next, i--)
				enf();
		}
		else
		{
			i = -i - 1;
			for (; i; curs = curs.prev, i--)
				enf();
		}

		enf();

		return curs;
	}

// #endregion

// #region getters and range interface

	// don't provide this as otherwise range apis will assume it is performant.
	//size_t length() const @property @safe {};

	/// Is this list empty? Part of the range interface.
	bool empty() const @property @safe => !_head;

	/// The allocator in use
	ref auto allocator() inout @property @safe => _allocator;

	/// The first element of the list
	ref inout(T) front() inout @property @safe
	{
		enforce(_head, "Cannot get the front of an empty linked list");
		return _head.item;
	}

	/// The last element of the list
	ref inout(T) back() inout @property @safe
	{
		enforce(_tail, "Cannot get the back of an empty linked list");
		return _tail.item;
	}

	/// Removes the first element from the list
	void popFront()
	{
		auto curs = cursorToFront;
		if (curs.exists)
			curs.remove();
	}

	/// Removes the last element from the list
	void popBack()
	{
		auto curs = cursorToBack;
		if (curs.exists)
			curs.remove();
	}

	/// Gets the `n`th element in the list. Slow. Negative values index from the end
	ref T at(ptrdiff_t n) => cursorAt(n).value;

// #endregion

// #region append operators and prepend functions, ==

	/// In-place append operator `~=` for a value, appends the value onto the end of this
	void opOpAssign(string op : "~")(auto ref T value)
	{
		if (empty)
		{
			_head = _allocateNode(value);
			_tail = _head;
		}
		else
		{
			cursorToBack.insertAfter(value);
		}
	}

	/// ditto
	//alias pushBack() = opOpAssign!"~";

	/// In-place append operator `~=` for a range, appends the contents of the range `rhs` onto the end of this
	void opOpAssign(string op : "~", R)(auto ref R rhs) if (isInputRange!R && is(T == ElementType!R))
	{
		foreach (ref v; rhs)
			this ~= v;
	}

	/// ditto
	//alias pushBack(R) = opOpAssign!("~", R);

	/// Pushes `value` onto the front of the list in-place.
	void pushFront()(auto ref T value)
	{
		if (empty)
		{
			_head = _allocateNode(value);
			_tail = _head;
		}
		else
		{
			cursorToFront.insertAfter(value);
		}
	}

	/// Pushes a range onto the front of the list in-place.
	void pushFront(R)(R rhs)if (isInputRange!R && is(T == ElementType!R))
	{
		foreach (ref v; rhs)
			pushFront(v);
	}

	/// Append operator `~` for a range, creates a copy of this list and appends the range `rhs`'s elements to it.
	typeof(this) opBinary(string op : "~", R)(R rhs) @safe if (isInputRange!R && is(T == ElementType!R))
	{
		typeof(this) newList;

		static if (allocatorIsStateful)
			newList._allocator = _allocator;

		newList ~= this;
		newList ~= rhs;

		return newList; // nrvo should kick in here
	}

	/// Append operator `~` for an element, creates a copy of this list and appends the element to it.
	typeof(this) opBinary(string op : "~")(auto ref T value) @safe
	{
		auto copy = this;
		copy ~= value;
		return copy;
	}

	/// Equality operator `==`
	bool opEquals(R)(auto ref R rhs) @safe if (isLinkedList!R && is(R.T == T))
	{
		auto ourCurs = cursorToFront;
		auto theirCurs = rhs.cursorToFront;

		while (ourCurs.exists || theirCurs.exists)
		{
			if (ourCurs.exists != theirCurs.exists)
				return false;

			if (ourCurs.value != theirCurs.value)
				return false;

			ourCurs = ourCurs.next;
			theirCurs = theirCurs.next;
		}

		return true;
	}

	/// ditto
	bool opEquals(R)(auto ref const R rhs) @safe if (!isLinkedList!R && isInputRange!R && is(ElementType!R == T))
	{
		auto ourCurs = cursorToFront;

		foreach (ref value; rhs)
		{
			// we finished first!
			if (!ourCurs.exists) return false;

			if (ourCurs.value != value) return false;

			ourCurs = ourCurs.next;
		}

		// must have the same lengths
		return !ourCurs.exists;
	}

	/// ditto
	// necessary because the default tohash just hashes the struct bits, but to work as an AA key, the rule is that
	// if two objects are equal, they MUST have the same hash, else its undefined behaviour,
	// so we must actually hash the list contents ourselves.
	size_t toHash()
	{
		size_t h;

		foreach (ref value; this)
			h ^= hashOf(value);

		return h;
	}

// #endregion

// #region foreach, iterator

	/// Implements efficient `foreach`
	int opApply(scope int delegate(ref T) dg)
	{
		auto curs = cursorToFront;

		for (; curs.exists; curs = curs.next)
		{
			auto result = dg(curs.value);
			if (result) return result;
		}

		return 0;
	}

	/// Implements efficient `foreach_reverse`
	int opApplyReverse(scope int delegate(ref T) dg)
	{
		auto curs = cursorToBack;

		for (; curs.exists; curs = curs.prev)
		{
			auto result = dg(curs.value);
			if (result) return result;
		}

		return 0;
	}

	/// A bidirectional range over a Linked List
	static struct Range
	{
		private Node* _f;
		private Node* _b;

		///
		this(ref LinkedList!(T, TAlloc) ll)
		{
			_f = ll._head;
			_b = ll._tail;
		}

		///
		ref T front() @property => _f.item;

		///
		ref T back() @property => _b.item;

		///
		bool empty() @property const => _f is null || _b is null;

		///
		void popFront()
		{
			_f = _f.next;
		}

		///
		void popBack()
		{
			_b = _b.prev;
		}

		///
		Range save() => this;
	}

	import std.range : isBidirectionalRange;
	static assert(isBidirectionalRange!Range);

	/// Gets an efficient to iterate bidirectional range over the linked list.
	/// It is undefined behaviour for the range to outlive the list.
	Range range() @property => Range(this);

// #endregion

// #region mutation methods

	/// Constructs a new element at the end of this list.
	void emplaceBack(A...)(auto ref A args)
	{
		import core.lifetime : forward;

		this ~= T(forward!args);
	}

	/// Inserts `value` into the list such that it is then at `list[idx]`. Slow.
	void insertAt()(size_t idx, auto ref T value)
	{
		import std.range : only;

		insertAt(idx, only(value));
	}

	/// Inserts `range` into the list at `idx`. Slow.
	void insertAt(R)(size_t idx, auto ref R range) if (isInputRange!R && is(T == ElementType!R))
	{
		auto curs = cursorAt(idx);
		foreach (ref v; range)
			curs = curs.insertAfter(v);
	}

	/// Constructs a new element in the middle of the lTist such that it is at `list[idx]`. Slow.
	void emplaceAt(A...)(size_t idx, auto ref A args)
	{
		import core.lifetime : forward;

		// i'm sure there's a more efficient way to do this
		insertAt(idx, T(forward!args));
	}

	/// Removes `n` elements from `idx` from the list. Slow.
	void removeAt(size_t idx, size_t n = 1)
	{
		auto curs = cursorAt(idx);
		for (auto i = n + 1; i; i--)
		{
			enforce(curs.exists, "Ran out of elements to remove from the list");
			curs.remove();
			curs = curs.next;
		}
	}

// #endregion

	private Node* _allocateNode()(ref T t)
	{
		import core.lifetime : forward;

		auto n = _allocator.make!Node();
		n.item = t;
		return n;
	}

	private void _deallocateNode(Node* node)
	{
		_allocator.dispose(node);
	}
}

/// Using cursors to modify in the middle of a linked list, `foreach`
unittest
{
	LinkedList!int myList = [0, 1, 2, 3];

	// get a cursor to the 2
	auto cursor2 = myList.cursorAt(-2);

	// add a 4 after it
	auto cursor4 = cursor2.insertAfter(4);

	// remove the one
	cursor2.prev.remove();

	// remove the two
	cursor2.remove();

	// increment all values
	foreach (ref value; myList)
		value++;

	assert(myList == [1, 5, 4]);
}

/// linked lists have a `.range` property that allows efficient use as a range without mutating the list.
unittest
{
	import std.range : cycle, retro, take;
	import std.array : array;

	LinkedList!int ll = [1, 2, 3, 4];

	assert(array(ll.range.cycle.take(10)) == [1, 2, 3, 4, 1, 2, 3, 4, 1, 2]);
	assert(array(ll.range.retro.cycle.take(5)) == [4, 3, 2, 1, 4]);
}

/// linked lists have value semantics
unittest
{
	LinkedList!int a = [1, 2, 3];

	auto b = a;

	assert(a == b);

	a.popFront();

	assert(a != b);
}
