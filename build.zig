const std = @import("std");

pub fn build(b: *std.Build) void {
    // Enabled/Disabled features
    var enabled = std.Target.Cpu.Feature.Set.empty;
    var disabled = std.Target.Cpu.Feature.Set.empty;
    const Features = std.Target.x86.Feature;
    disabled.addFeature(@intFromEnum(Features.mmx));
    disabled.addFeature(@intFromEnum(Features.sse));
    disabled.addFeature(@intFromEnum(Features.sse2));
    disabled.addFeature(@intFromEnum(Features.avx));
    disabled.addFeature(@intFromEnum(Features.avx2));
    enabled.addFeature(@intFromEnum(Features.soft_float));

    const target: std.zig.CrossTarget = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .cpu_features_add = enabled,
        .cpu_features_sub = disabled,
        .abi = .none,
    };
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "arcadeos.elf",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = target,
        .optimize = optimize,
    });
    kernel.code_model = .kernel;

    const font = b.option([]const u8, "font", "Which font to use for the operating system, path relative to src/fonts/vga-text-mode-fonts/FONTS") orelse "PC-IBM/BIOS_D.F16";

    const options = b.addOptions();
    options.addOption([]const u8, "font_name", font);
    kernel.addOptions("config", options);

    const limine = b.dependency("limine", .{});
    kernel.addModule("limine", limine.module("limine"));
    kernel.pie = true;
    kernel.setLinkerScriptPath(.{ .path = "linker.ld" });

    const kernel_install = b.addInstallArtifact(kernel, .{});
    b.getInstallStep().dependOn(&kernel_install.step);

    // There's got to be a better way to do these
    const limine_build = blk: {
        const limine_download = b.addSystemCommand(&[_][]const u8{
            "/bin/sh",
            "-c",
            "git -C limine pull || git clone https://github.com/limine-bootloader/limine.git --branch=v5.x-branch-binary --depth=1",
        });
        const limine_build = b.addSystemCommand(&[_][]const u8{
            "make",
            "-C",
            "limine",
        });
        limine_build.step.dependOn(&limine_download.step);
        break :blk limine_build;
    };

    const build_iso_step = addIsoStep(b, &limine_build.step, &kernel_install.step, "limine.cfg", "iso");

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64", "-M",           "q35",        "-m",    "2G",
        "-cdrom",             "arcadeos.iso", "-no-reboot", "-boot", "d",
        "-serial",            "stdio",        "-smp",       "2",
    });
    run_cmd.step.dependOn(build_iso_step);
    const run_step = b.step("run", "Run arcadeos");
    run_step.dependOn(&run_cmd.step);

    const build_debug_iso_step = addIsoStep(b, &limine_build.step, &kernel_install.step, "limine-debug.cfg", "debug_iso");

    const debug_cmd = b.addSystemCommand(&[_][]const u8{
        "/bin/sh",
        "-c",
        "qemu-system-x86_64 -M q35 -m 2G -cdrom arcadeos.iso -boot d -smp 2 --no-reboot -S -s & lldb zig-out/bin/arcadeos.elf",
        // also consider option
        // -d cpu_reset -monitor stdio
        // in order to print registers to stdio when crash
    });
    debug_cmd.step.dependOn(build_debug_iso_step);
    const debug_step = b.step("debug", "Run arcadeos with qemu in debug mode");
    debug_step.dependOn(&debug_cmd.step);

    const clean = b.addSystemCommand(&[_][]const u8{
        "rm", "-rf", "zig-out", "zig-cache", "./limine/", "./iso/", "arcadeos.iso",
    });
    const clean_step = b.step("clean", "Clean the build files");
    clean_step.dependOn(&clean.step);

    // TODO: unit testing
    //    const unit_tests = b.addTest(.{
    //        .root_source_file = .{ .path = "src/main.zig" },
    //        .target = target,
    //        .optimize = optimize,
    //    });
    //
    //    const run_unit_tests = b.addRunArtifact(unit_tests);
    //
    //    const test_step = b.step("test", "Run unit tests");
    //    test_step.dependOn(&run_unit_tests.step);
}

fn addIsoStep(
    b: *std.Build,
    limine_build_step: *std.Build.Step,
    kernel_install_step: *std.Build.Step,
    cfg_name: []const u8,
    step_name: []const u8,
) *std.Build.Step {
    const iso_build = blk: {
        const cleanup = b.addSystemCommand(&[_][]const u8{ "rm", "-rf", "./iso/" });

        const mkdir = b.addSystemCommand(&[_][]const u8{ "mkdir", "iso" });
        mkdir.step.dependOn(&cleanup.step);
        const cp_iso_root = b.addSystemCommand(&[_][]const u8{
            "cp",
            "-v",
            "zig-out/bin/arcadeos.elf", // how can I not hardcode this?
            "limine/limine-bios.sys",
            "limine/limine-bios-cd.bin",
            "limine/limine-uefi-cd.bin",
            "iso/",
        });
        cp_iso_root.step.dependOn(&mkdir.step);
        cp_iso_root.step.dependOn(limine_build_step);
        cp_iso_root.step.dependOn(kernel_install_step);
        const mkdir_efi = b.addSystemCommand(&[_][]const u8{
            "mkdir",
            "-p",
            "iso/EFI/BOOT",
        });
        mkdir_efi.step.dependOn(&mkdir.step);
        const cp_efi = b.addSystemCommand(&[_][]const u8{
            "cp",
            "-v",
            "limine/BOOTX64.EFI",
            "iso/EFI/BOOT/",
        });
        cp_efi.step.dependOn(&mkdir_efi.step);
        cp_efi.step.dependOn(limine_build_step);
        const cp_cfg = b.addSystemCommand(
            &[_][]const u8{ "cp", cfg_name, "iso/limine.cfg" },
        );
        cp_cfg.step.dependOn(&mkdir.step);
        cp_cfg.step.dependOn(limine_build_step);
        const mk_iso = b.addSystemCommand(&[_][]const u8{
            "xorriso",            "-as",             "mkisofs",          "-b",                       "limine-bios-cd.bin",
            "-no-emul-boot",      "-boot-load-size", "4",                "-boot-info-table",         "--efi-boot",
            "limine-uefi-cd.bin", "--efi-boot-part", "--efi-boot-image", "--protective-msdos-label", "iso",
            "-o",                 "arcadeos.iso",
        });
        mk_iso.step.dependOn(&cp_cfg.step);
        mk_iso.step.dependOn(&cp_efi.step);
        mk_iso.step.dependOn(&cp_iso_root.step);
        const limine_install = b.addSystemCommand(&[_][]const u8{
            "./limine/limine",
            "bios-install",
            "arcadeos.iso",
        });
        limine_install.step.dependOn(&mk_iso.step);
        break :blk limine_install;
    };

    const build_iso_step = b.step(step_name, "Build arcadeos iso");
    build_iso_step.dependOn(&iso_build.step);

    return build_iso_step;
}
