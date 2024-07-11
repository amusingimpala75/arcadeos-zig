const std = @import("std");

const disk_image_step = @import("disk-image-step");

pub fn build(b: *std.Build) !void {
    const limine_module = b.dependency("limine-zig", .{}).module("limine");

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

    const kernel_executable_options: std.Build.ExecutableOptions = .{
        .name = "arcadeos.elf",
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    };

    const kernel_options = b.addOptions();
    const font = b.option(
        []const u8,
        "font",
        "Which font to use for the operating system, path relative to src/fonts/vga-text-mode-fonts/FONTS",
    ) orelse "PC-IBM/BIOS_D.F16";
    kernel_options.addOption([]const u8, "font_name", font);

    const kernel = b.addExecutable(kernel_executable_options);
    kernel.pie = true;
    kernel.setLinkerScriptPath(b.path("linker.ld"));
    kernel.root_module.code_model = .kernel;
    kernel.root_module.addImport("limine", limine_module);
    kernel.root_module.addOptions("config", kernel_options);

    const kernel_install = b.addInstallArtifact(kernel, .{});
    b.getInstallStep().dependOn(&kernel_install.step);

    const timeout = b.option(
        usize,
        "timeout",
        "How long to wait at the boot screen before automatic boot. (Default: 0)",
    ) orelse 0;

    const kaslr = b.option(
        bool,
        "kaslr",
        "Enable kernel address-space layout randomization (Defaults to true for release, false for debug",
    ) orelse (optimize != .Debug);

    const build_iso_step = addIsoStep(
        b,
        kernel_install,
        kaslr,
        timeout,
        "iso",
    );

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64", "-M",                                   "q35",        "-m",      "2G",
        "-drive",             "format=raw,file=zig-out/arcadeos.img", "-no-reboot", "-serial", "stdio",
        "-smp",               "2",
    });
    run_cmd.step.dependOn(build_iso_step);
    const run_step = b.step("run", "Run arcadeos");
    run_step.dependOn(&run_cmd.step);

    const build_debug_iso_step = addIsoStep(
        b,
        kernel_install,
        kaslr,
        timeout,
        "debug_iso",
    );

    const debug_cmd = b.addSystemCommand(&[_][]const u8{
        "/bin/sh",
        "-c",
        b.fmt(
            "qemu-system-x86_64 -M q35 -m 2G -drive format=raw,file={s} -smp 2 --no-reboot -S -s & lldb zig-out/bin/arcadeos.elf",
            .{"zig-out/arcadeos.img"},
        ),
        // also consider option
        // -d cpu_reset -monitor stdio
        // in order to print registers to stdio when crash
    });
    debug_cmd.step.dependOn(build_debug_iso_step);
    const debug_step = b.step("debug", "Run arcadeos with qemu in debug mode");
    debug_step.dependOn(&debug_cmd.step);

    const clean_out = std.Build.Step.RemoveDir.create(b, "zig-out");
    const clean_cache = std.Build.Step.RemoveDir.create(b, ".zig-cache");
    const clean_step = b.step("clean", "Clean the build files");
    clean_step.dependOn(&clean_out.step);
    clean_step.dependOn(&clean_cache.step);

    // check step for ZLS
    const check_kernel = b.addExecutable(kernel_executable_options);

    check_kernel.root_module.code_model = .kernel;
    check_kernel.root_module.addOptions("config", kernel_options);
    check_kernel.root_module.addImport("limine", limine_module);

    const check_step = b.step("check", "check the code for compilation but do not create binary");

    check_step.dependOn(&check_kernel.step);
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
    kernel_install: *std.Build.Step.InstallArtifact,
    kaslr: bool,
    timeout: usize,
    step_name: []const u8,
) *std.Build.Step {
    const limine = b.dependency("limine-bin", .{});
    const limine_installer = b.addExecutable(.{
        .name = "limine",
        .target = b.resolveTargetQuery(.{}), // native
    });
    limine_installer.addCSourceFile(.{
        .file = limine.path("limine.c"),
        .flags = &[_][]const u8{ "-g", "-O2", "-pipe", "-Wall", "-Wextra", "-std=c99" },
    });

    const limine_installer_artifact = b.addInstallArtifact(limine_installer, .{});
    const limine_installer_path = b.fmt("{s}/bin/limine", .{b.install_prefix});

    const generate_cfg, const cfg_path = generateLimineCfg(b, kaslr, timeout);

    const disk_image_step_dep = b.dependency("disk-image-step", .{});
    var rootfs = disk_image_step.FileSystemBuilder.init(b);

    inline for (&.{ "limine-bios.sys", "limine-bios-cd.bin", "limine-uefi-cd.bin" }) |file| {
        rootfs.addFile(limine.path(file), file);
    }
    inline for (&.{"BOOTX64.EFI"}) |file| {
        rootfs.addFile(limine.path(file), "EFI/BOOT/" ++ file);
    }
    rootfs.addFile(cfg_path, "limine.cfg");
    rootfs.addFile(kernel_install.emitted_bin.?, "arcadeos.elf");

    const initialize_disk = disk_image_step.initializeDisk(disk_image_step_dep, 8 * disk_image_step.MiB, .{
        .mbr = .{
            .partitions = .{
                &.{
                    .offset = 512 * 4,
                    .size = 512 * (2048 - 4),
                    .type = .empty,
                    .bootable = false,
                    .data = .uninitialized,
                },
                &.{
                    .offset = 512 * 2048,
                    .size = 5 * disk_image_step.MiB,
                    .bootable = true,
                    .type = .fat16_lba,
                    .data = .{
                        .fs = rootfs.finalize(
                            .{ .format = .fat16, .label = "ROOTFS" },
                        ),
                    },
                },
                null,
                null,
            },
        },
    });
    initialize_disk.step.dependOn(&generate_cfg.step);
    initialize_disk.step.dependOn(&kernel_install.step);

    const install_disk = b.addInstallFile(initialize_disk.getImageFile(), "arcadeos.img");
    install_disk.step.dependOn(&initialize_disk.step);

    const limine_install = b.addSystemCommand(&[_][]const u8{
        limine_installer_path,
        "bios-install",
        "zig-out/arcadeos.img",
    });
    limine_install.step.dependOn(&install_disk.step);
    limine_install.step.dependOn(&limine_installer_artifact.step);

    const create_iso_step = b.step(step_name, "Create arcadeos iso");
    create_iso_step.dependOn(&limine_install.step);

    return create_iso_step;
}
