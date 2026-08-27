const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qnnt_lib_mod = b.createModule(.{
        .root_source_file = b.path("lib/qnnt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const qnnt_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "qnnt",
        .root_module = qnnt_lib_mod,
    });

    b.installArtifact(qnnt_lib);

//    const lib_tests = b.addTest(.{
//        .root_module = lib_mod,
//    });

//    const run_lib_tests = b.addRunArtifact(lib_tests);

//    const test_step = b.step("test", "Run unit tests");
//    test_step.dependOn(&run_lib_tests.step);


    // Each node is its own executable sharing the qnnt module, with a matching
    // `run` step: `zig build run-0`, `zig build run-1`, `zig build run-2`.
    const nodes = [_]struct { name: []const u8, src: []const u8, step: []const u8 }{
        .{ .name = "qnnt-node-0", .src = "src/node-0.zig", .step = "run-0" },
        .{ .name = "qnnt-node-1", .src = "src/node-1.zig", .step = "run-1" },
        .{ .name = "qnnt-node-2", .src = "src/node-2.zig", .step = "run-2" },
    };

    for (nodes) |node| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(node.src),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = node.name,
            .root_module = exe_mod,
        });

        exe.root_module.linkLibrary(qnnt_lib);
        exe.root_module.addImport("qnnt", qnnt_lib_mod);

        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_exe.addArgs(args);

        const run_exe_step = b.step(node.step, b.fmt("Run {s}", .{node.name}));
        run_exe_step.dependOn(&run_exe.step);
    }
}
