# ArcadeOS

A rewrite of [arcadeos](https://github.com/amusingimpala75/arcadeos) from C to Zig.

System dependencies:
- Zig 0.12.0
- xorriso
- QEMU (runtime testing)
- POSIX compliance (/bin/sh exists, only needed from running debug qemu)

Update the git submodule to pull down the fonts, and then
run `zig build run` or `zig build debug` to build and run the system.

Alternately, run `zig build iso` to generate an iso image.

### Licensing:
- ArcadeOS is licensed under the MIT License
- ArcadeOS uses the Limine bootloader with the limine-zig bindings, both of
		which are licensed under the BSD 2-Clause License

<!---
We really need to find an alternative to the vga-text-mode-fonts which actually has a license, yikes.
-->
