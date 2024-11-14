# YS Base

Hazel's base utilities for D programming.

Why? There are often problems I need to solve over and over again.
This aims to make a package I can include as the base for my projects. Hopefully you can also find it useful.

## Contents

 - memory allocation tools
   * [x] can work with std.experimental.allocator, stdx.allocator
   * [ ] automatically supports `@nogc` as long as your allocator does
   * [x] can be configured to just use the garbage collector (sets the default allocator to `GCAllocator` and disables freeing)
   * [x] fast general purpose default allocator
   * [x] version of `Mallocator` that takes the functions it calls as template args.
   * [ ] smart pointers and collectinos
     - [ ] smart pointers
     - [ ] vectors
     - [ ] strings
     - inspired by the API of [BTL](https://submada.github.io/btl/) but using a completely original implementation.
     - with practical considerations inspired by my time writing embedded software in D

 - magic bullshittery utilities,
   sourced from both general projects of mine and especially from
   [3dskit](https://github.com/ys-3dskit/3dskit-dlang/tree/7268815/ys3ds)
   * [x] `transmute!`, the equivalent of rust's `std::mem::transmute` or C++'s `std::bit_cast`.
   * [ ] `string` <-> `String` <-> `char*` conversion tools

 - template stuff
   * [ ] nice ways to forward attributes and visibility

This list will hopefully grow as I write more small lil utils.

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
