const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zflate", .{
        .root_source_file = b.path("src/zflate.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zflate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zflate", .module = mod },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("z", .{});
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zflate");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.linkSystemLibrary("z", .{});
    mod_tests.root_module.link_libc = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
