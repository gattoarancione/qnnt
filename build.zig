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


    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/node.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "qnnt-node",
        .root_module = exe_mod,
    });

    exe.linkLibrary(qnnt_lib);

    exe.root_module.addImport("qnnt", qnnt_lib_mod);

//    const pkg = b.dependency("qnnt", .{
//        .target = target,
//        .optimize = optimize,
//    });
//    exe.root_module.addImport("qnnt", pkg.module("qnnt"));

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);

    const run_exe_step = b.step("run", "Run a QNNT node");
    run_exe_step.dependOn(&run_exe.step);
}
