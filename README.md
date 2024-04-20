# ArcadeOS

A rewrite of [arcadeos](https://github.com/amusingimpala75/arcadeos) from C to Zig.

System dependencies:
- zig 0.12.0
- qemu
- git
- xorriso

Additionally, the build script uses unix utilities (cp, mv, rm, mkdir, as this was
poorly created from a Makefile), so compilation depends on a Unix-like system.
The eventual goal is to switch to fully zig-based builds

Update the git submodule to pull down the fonts, and then
run `zig build run` or `zig build debug` to build and run the system.

Alternately, run `zig build iso` to generate an iso image.
