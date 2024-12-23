/++
Copyright: Public Domain
Authors: Hazel Atkinson
License: $(LINK2 https://unlicense.org, Unlicense)
+/
module ysbase.rc_struct;

import ysbase.smart_ptr : SharedPtr, makeShared;

import std.traits : isFunction, ReturnType, hasElaborateCopyConstructor;

/++
`RcStruct` is a wrapper that makes your struct into a reference-counted shared instance.

A new internal instance is created each time the wrapper is constructed, but when it is copied,
instead of causing a copy-construct and destruct, it just shares the instance.

This allows you to much more easily implement RAII, only needing a constructor and destructor,
rather than also needing to either implement reference counting yourself, or use specific tricks like `dup(2)`,
as the actual internal instance is a singleton.

All methods and constructors are automatically forwarded to the wrapper, and all fields are given `ref` getters.

In the case that the default initialization (`RcStruct!T.init` or `RcStruct!T myVariable;`) is used,
the ref counts will be lazily initialized such that the behaviour of the struct is as if
they had been initialized at declaration time.

The end result is something very close to reference semantics, it really acts like a class,
but without OOP functionality, and with deterministic destruction time.

$(SRCL ysbase/rc_struct.d)
+/
struct RcStruct(T) if (is(T == struct))
{
	private SharedPtr!(T, false) ___rcs_backing_ptr_raw;

	// lazy init
	private ref SharedPtr!(T, false) ___rcs_backing_ptr()
	{
		if (___rcs_backing_ptr_raw.isNullPtr)
			___rcs_backing_ptr_raw = SharedPtr!(T, false).make();

		return ___rcs_backing_ptr_raw;
	}

	// default copy construction does not account for lazy init
	// this lazily initializes the old object before we copy the smart pointer out of it
	this(ref typeof(this) other)
	{
		___rcs_backing_ptr_raw = other.___rcs_backing_ptr;
	}

	// constructor forwarder
	this(A...)(auto scope ref A a)
	{
		import core.lifetime : forward;

		___rcs_backing_ptr_raw = SharedPtr!(T, false).make(forward!a);
	}

	static foreach(memberName; __traits(derivedMembers, T))
		static if (
			memberName != "__ctor" && memberName != "__dtor" && memberName != "__xdtor"
			&& memberName != "__postblit" && memberName != "__fieldPostblit"
			&& memberName != "__aggrPostblit" && memberName != "__xpostblit"
		)
		{
			static if (isFunction!(__traits(getMember, T, memberName)))
				mixin(ScaffoldMethodForwarder!(T, memberName));
			else
				mixin(ScaffoldFieldForwarder!(T, memberName));
		}
}

private
{
	enum ScaffoldMethodForwarder(T, string memberName) =
		"auto ref " ~ memberName
		~ "(A...)(auto ref A a) { import core.lifetime : forward;"
		~ (is(
				ReturnType!(__traits(getMember, T, memberName)) == void) ? "" : "return ")
		~ "(*___rcs_backing_ptr)."
		~ memberName
		~ "(forward!a); }";

	enum ScaffoldFieldForwarder(T, string memberName) =
		"ref "
		~ __traits(fullyQualifiedName, typeof(__traits(getMember, T, memberName)))
		~ " " ~ memberName
		~ "() => (*___rcs_backing_ptr)." ~ memberName ~ ";";
}

/// Basic RAII posix file demo with forwarding
version (Posix)
unittest
{
	struct RAIIFile
	{
		import core.sys.posix.fcntl : open, O_RDWR, O_CREAT, O_TRUNC;
		import core.sys.posix.unistd : read, write, close, unlink, lseek;
		import core.sys.posix.stdio : SEEK_SET;
		import std.string : toStringz, assumeUTF;
		import std.conv : octal;

		int fd;
		string path;

		this(string p)
		{
			// create a file!
			fd = open(p.toStringz, O_CREAT | O_TRUNC | O_RDWR, octal!"777");
			path = p;
		}

		// disable copying this struct
		@disable this(ref RAIIFile);

		string readF()
		{
			ubyte[64] buf;

			auto bytesread = read(fd, buf.ptr, 64);
			assert(bytesread >= 0);
			lseek(fd, 0, SEEK_SET);

			return buf[0 .. bytesread].assumeUTF;
		}

		void writeF(string s)
		{
			write(fd, s.toStringz, s.length);
			lseek(fd, 0, SEEK_SET);
		}

		~this()
		{
			// destroy the file
			close(fd);
			unlink(path.toStringz);
		}
	}

	auto file = RcStruct!RAIIFile("/tmp/test.txt");
	assert(file.fd != 0);

	// copy the file!
	// note without rcstruct this would fail
	auto alsoFile = file;

	alsoFile.writeF("hi!!");

	assert(file.readF() == "hi!!");

	// alsoFile goes out of scope here and does nothing
	// then file goes out of scope and closes the file.
}

/// Showing singleton behaviour
unittest
{
	static int consCount;
	static int destrCount;

	struct Test
	{
		int field;

		string method(ref scope int x)
		{
			import std.conv : to;

			return field.to!string;
		}

		this(int a) { field = a; consCount++; }
		this(this) { consCount++; }

		~this() { destrCount++; }
	}

	{
		// default construction
		RcStruct!Test rcs;

		// copy
		auto another = rcs;
		another.field = 6;
	}

	// consCount is zero because we only ever used the default construction, so the ctor wasn't called
	assert(consCount == 0);
	assert(destrCount == 1);

	consCount = 0;
	destrCount = 0;

	{
		auto rcs = RcStruct!Test(5);
		assert(rcs.field == 5);
		int _r;
		assert(rcs.method(_r) == "5");
	}

	assert(consCount == 1);
	assert(destrCount == 1);
}
