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

LinkedLists implement $(LINK2 https://dlang.org/phobos/std_range_primitives.html#isRandomAccessRange, random access ranges),
but note that iteration will modify the list in-place, and random access is slow, and therefore it is recommended to use
a `LinkedList.Cursor` instead.

LinkedLists provide an efficent implementation of `foreach` that does not mutate the list.

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

		() @trusted { this = rhs; }();
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
	void opAssign(Rhs)(auto scope ref Rhs rhs) if (isInputRange!Rhs && is(T == ElementType!Rhs))
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
			i = -i;
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

	ref inout(T) front() inout @property @safe
	{
		enforce(_head, "Cannot get the front of an empty linked list");
		return _head.item;
	}

	ref inout(T) back() inout @property @safe
	{
		enforce(_tail, "Cannot get the back of an empty linked list");
		return _tail.item;
	}

	void popFront()
	{
		auto curs = cursorToFront;
		if (curs.exists)
			curs.remove();
	}

	void popBack()
	{
		auto curs = cursorToBack;
		if (curs.exists)
			curs.remove();
	}

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
	alias pushBack() = opOpAssign!"~";

	/// In-place append operator `~=` for a range, appends the contents of the range `rhs` onto the end of this
	void opOpAssign(string op : "~", R)(R rhs) if (isInputRange!R && is(T == ElementType!R))
	{
		foreach (ref v; rhs)
			this ~= v;
	}

	/// ditto
	alias pushBack(R) = opOpAssign!("~", R);

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
	bool opEquals(R)(auto ref const R rhs) const @safe if (isLinkedList!R && is(R.T == T))
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
		import core.lifetime : moveEmplace;

		// fast path for the end of the list
		if (idx == length)
		{
			this ~= range;
			return;
		}

		// fast path for the start of the list
		if (idx == 0)
		{
			this.pushFront(range);
			return;
		}

		auto curs = cursorAt(idx);
		foreach (ref v; range)
			curs = curs.insertAfter(v);
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

		if (n == 0)
			return;

		// fast path for the last element
		if (n == 1 && idx + 1 == length)
			_store[idx] = T.init;
		else // blit the elements left.
			_blitStoreBy(-n, idx + n, (length - idx - n));

		_length -= n;
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

unittest
{
	LinkedList!int myList;
}
