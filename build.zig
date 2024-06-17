const std = @import("std");

pub fn build(b: *std.Build) !void {
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

    // TODO: support other targets
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .cpu_features_add = enabled,
        .cpu_features_sub = disabled,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "arcadeos.elf",
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel.pie = true;
    kernel.setLinkerScriptPath(b.path("linker.ld"));
    kernel.root_module.code_model = .kernel;
    const kernel_install = b.addInstallArtifact(kernel, .{ .dest_dir = .{ .override = .{ .custom = "iso" } } });
    b.getInstallStep().dependOn(&kernel_install.step);

    const options = b.addOptions();
    const font = b.option([]const u8, "font", "Which font to use for the operating system, path relative to src/fonts/vga-text-mode-fonts/FONTS") orelse "PC-IBM/BIOS_D.F16";
    options.addOption([]const u8, "font_name", font);

    kernel.root_module.addOptions("config", options);

    const limine = b.dependency("limine-zig", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));

    const limine_bin_dep = b.dependency("limine-bin", .{});

    const timeout = b.option(usize, "timeout", "How long to wait at the boot screen before automatic boot. (Default: 0)") orelse 0;

    const build_iso_step, const iso_path = addIsoStep(b, limine_bin_dep, kernel_install, true, timeout, "iso");

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64", "-M",     "q35",        "-m",    "2G",
        "-cdrom",             iso_path, "-no-reboot", "-boot", "d",
        "-serial",            "stdio",  "-smp",       "2",
    });
    run_cmd.step.dependOn(build_iso_step);
    const run_step = b.step("run", "Run arcadeos");
    run_step.dependOn(&run_cmd.step);

    const build_debug_iso_step, const debug_iso_path = addIsoStep(b, limine_bin_dep, kernel_install, false, timeout, "debug_iso");

    const debug_cmd = b.addSystemCommand(&[_][]const u8{
        "/bin/sh",
        "-c",
        b.fmt(
            "qemu-system-x86_64 -M q35 -m 2G -cdrom {s} -boot d -smp 2 --no-reboot -S -s & lldb zig-out/iso/arcadeos.elf",
            .{debug_iso_path},
        ),
        // also consider option
        // -d cpu_reset -monitor stdio
        // in order to print registers to stdio when crash
    });
    debug_cmd.step.dependOn(build_debug_iso_step);
    const debug_step = b.step("debug", "Run arcadeos with qemu in debug mode");
    debug_step.dependOn(&debug_cmd.step);

    const clean_out = std.Build.Step.RemoveDir.create(b, "zig-out");
    const clean_cache = std.Build.Step.RemoveDir.create(b, "zig-cache");
    const clean_step = b.step("clean", "Clean the build files");
    clean_step.dependOn(&clean_out.step);
    clean_step.dependOn(&clean_cache.step);

    // TODO: unit testing
}

fn generateLimineCfg(b: *std.Build, kaslr: bool, timeout: usize) struct { *std.Build.Step.WriteFile, std.Build.LazyPath } {
    const wf = std.Build.Step.WriteFile.create(b);
    const cfg = wf.add("limine.cfg", b.fmt(
        \\TIMEOUT={}
        \\
        \\:ArcadeOS
        \\  PROTOCOL=limine
        \\  KERNEL_PATH=boot:///arcadeos.elf
        \\{s}
    , .{ timeout, if (!kaslr) "  KASLR=no" else "" }));
    return .{ wf, cfg };
}

fn addIsoStep(
    b: *std.Build,
    limine_dep: *std.Build.Dependency,
    kernel_install: *std.Build.Step.InstallArtifact,
    kaslr: bool,
    timeout: usize,
    step_name: []const u8,
) struct { *std.Build.Step, []const u8 } {
    const limine_installer = b.addExecutable(.{
        .name = "limine",
        .target = b.resolveTargetQuery(.{}), // native
    });
    limine_installer.addCSourceFile(.{
        .file = limine_dep.path("limine.c"),
        .flags = &[_][]const u8{ "-g", "-O2", "-pipe", "-Wall", "-Wextra", "-std=c99" },
    });

    const limine_installer_artifact = b.addInstallArtifact(limine_installer, .{});
    const limine_installer_path = b.fmt("{s}/bin/limine", .{b.install_prefix});

    const iso_prefix = "iso/";
    const iso_name = "arcadeos.iso";

    const iso_dir = b.fmt("{s}/{s}", .{ b.install_prefix, iso_prefix });
    const iso_path = b.fmt("{s}/{s}", .{ b.install_prefix, iso_name });

    const mk_iso = b.addSystemCommand(&[_][]const u8{
        "xorriso",            "-as",             "mkisofs",          "-b",                       "limine-bios-cd.bin",
        "-no-emul-boot",      "-boot-load-size", "4",                "-boot-info-table",         "--efi-boot",
        "limine-uefi-cd.bin", "--efi-boot-part", "--efi-boot-image", "--protective-msdos-label", iso_dir,
        "-o",                 iso_path,
    });

    mk_iso.step.dependOn(&kernel_install.step);

    inline for (&[_][]const u8{ "limine-bios.sys", "limine-bios-cd.bin", "limine-uefi-cd.bin" }) |file| {
        mk_iso.step.dependOn(&b.addInstallFile(limine_dep.path(file), iso_prefix ++ file).step);
    }

    // TODO more when aarch64, etc. supported
    inline for (&[_][]const u8{"BOOTX64.EFI"}) |file| {
        mk_iso.step.dependOn(&b.addInstallFile(limine_dep.path(file), iso_prefix ++ "EFI/BOOT/" ++ file).step);
    }

    const generate_cfg, const cfg_path = generateLimineCfg(b, kaslr, timeout);
    const install_cfg = b.addInstallFile(cfg_path, iso_prefix ++ "limine.cfg");
    install_cfg.step.dependOn(&generate_cfg.step);
    mk_iso.step.dependOn(&install_cfg.step);

    const limine_install = b.addSystemCommand(&[_][]const u8{
        limine_installer_path,
        "bios-install",
        iso_path,
    });
    limine_install.step.dependOn(&mk_iso.step);
    limine_install.step.dependOn(&limine_installer_artifact.step);

    const build_iso_step = b.step(step_name, "Build arcadeos iso");
    build_iso_step.dependOn(&limine_install.step);

    return .{ build_iso_step, iso_path };
}
