# YS Base

Hazel's base utilities for D programming.

Why? There are often problems I need to solve over and over again.
This aims to make a package I can include as the base for my projects. Hopefully you can also find it useful.

## Contents

 - memory allocation tools
   * [x] can work with std.experimental.allocator, stdx.allocator
   * [x] automatically supports `@nogc` as long as your allocator does
   * [x] can be configured to just use the garbage collector (sets the default allocator to `GCAllocator` and disables freeing)
   * [x] fast general purpose default allocator
   * [x] version of `Mallocator` that takes the functions it calls as template args.
   * [WIP] shared allocator building blocks
   * [WIP] shared global allocator by default
   * [WIP] smart pointers and collections
     - [x] smart pointers
     - [ ] vectors
     - [ ] strings
     - [ ] ref-counted struct wrappers
     - Inspired by the API of [BTL](https://submada.github.io/btl/) but using a completely original implementation.
     - With practical considerations inspired by my time writing embedded software in D

 - Magic bullshittery utilities,
   sourced from both general projects of mine and especially from
   [3dskit](https://github.com/ys-3dskit/3dskit-dlang/tree/7268815/ys3ds)
   * [x] `transmute!`, the equivalent of rust's `std::mem::transmute` or C++'s `std::bit_cast`.
   * [ ] `string` ⇋ `String` ⇋ `char*` conversion tools

 - template stuff

This list will hopefully grow as I write more small lil utils.

## The forest of `std.experimental.allocator` forks

`std.experimental.allocator` provides an interface for composable allocators of the type described in
Andrei Alexandrescu's excellent talk,
[std::allocator is to Allocation what std::vector is to Vexation](https://youtu.be/LIb3L4vKZ7U).

`stdx.allocator` is a subtly different version of this entire module tree broken out to be a sort of "LTS" version,
so that production ready code like vibe.d can depend on it - the std version being experimental and all.

YSBase can run on either `std` or `stdx` variants of allocator. I suggest you use stdx if you are using vibe.d and std
otherwise.

I don't really want to spawn another fork of these, but I encountered an issue in that many of the building_blocks do
not support `shared`. Some, like `Segregator`, handle it perfectly! Others, like `FreeList` do not.

So the `ysbase.allocation` modules not only re-export std/x allocator, but also overrides some allocator types with more
suitable types e.g. a `ParametricMallocator` template that takes the malloc function as a parameter, and a shared-safe
`FreeList`.

The plan is eventually to have all building blocks make themselves shared automatically eventually.
The default implementations support this exclusively for stateless allocators, but it should be totally possible to have
shared stateful allocators too (though there are potential performance drawbacks to be aware of!).

## Configurations and Versions

You can choose different behaviour at compile time using dub.json/dub.sdl:

```sdl
subConfiguration "ysbase" "stdxalloc"
```
Use `stdx.allocator` instead of `std.experimental.allocator`.
Note that `stdx.allocator` is basically a frozen / LTS version of `std.experimental.allocator`,
but neither have received updates in years so just using `std` isn't likely to cause stability issues.

```sdl
version "YSBase_GC"
```
Rely on the garbage collector for all freeing. This does the following things:
 - Sets the default allocator to `GCAllocator`
 - Memory management tools such as smart pointers and strings will NOT free memory automatically
   * If you pass a custom allocator in this mode, they will just leak.
 - Destructors will still run as usual, if present
 - For trivially destructible types, *may* significantly simplify bookkeeping for performance.
 - Disables automatic initialization of `processAllocator`

Why you wouldn't then just use raw pointers, strings, slice concatenation, `new`, etc., I don't know, but sure.

```sdl
version "YSBase_NoGlobalAlloc"
```

Disables initializing `processAllocator` with an instance of `YSBAllocator!Mallocator` before `main()`.
You need not set this version if you have set `YSBase_GC` already.
