const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qnnt_lib_mod = b.createModule(.{
        .root_source_file = b.path("lib/qnnt.zig"),
        .target = target,
        .optimize = optimize,
            // libc is required, not incidental. Two things depend on it and both failed
            // silently on Linux without it, while macOS masked the problem by always
            // linking libSystem:
            //   * `configureFromEnvironment` uses getenv, and `builtin.link_libc` is a
            //     property of the MODULE being compiled -- a C program linking libc does
            //     not make it true inside this library;
            //   * std.Thread uses pthreads with libc and a raw-clone path without it, and
            //     that path tripped an alignment assert on aarch64-linux at the first
            //     spawnWorker, aborting qnnt_init outright.
            .link_libc = true,
    });

    const qnnt_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "qnnt",
        .root_module = qnnt_lib_mod,
    });

    b.installArtifact(qnnt_lib);

    // The TLD codec's C ABI, built both ways: static for C/C++ callers that link, shared
    // for anything that loads it at runtime (ctypes/cffi will want the latter). Its root
    // is only the codec, so the shared object pulls in no threads and no sockets.
    const tld_c_mod = b.createModule(.{
        .root_source_file = b.path("lib/tld_c.zig"),
        .target = target,
        .optimize = optimize,
    });

    var tld_c_static: *Build.Step.Compile = undefined;
    for ([_]std.builtin.LinkMode{ .static, .dynamic }) |linkage| {
        const lib = b.addLibrary(.{
            .linkage = linkage,
            .name = "qnnt_tld",
            .root_module = tld_c_mod,
        });
        lib.installHeader(b.path("include/qnnt_tld.h"), "qnnt_tld.h");
        lib.installHeader(b.path("include/qnnt_tld.hpp"), "qnnt_tld.hpp");
        b.installArtifact(lib);
        if (linkage == .static) tld_c_static = lib;
    }

    // The full node C ABI: lifecycle, publishing, both subscription modes, and the TLD
    // exports folded in so one library carries the whole surface.
    const qnnt_c_mod = b.createModule(.{
        .root_source_file = b.path("lib/qnnt_c.zig"),
        .target = target,
        .optimize = optimize,
        // Same reason as qnnt_lib_mod above: getenv and pthreads.
        .link_libc = true,
    });

    var qnnt_c_static: *Build.Step.Compile = undefined;
    var qnnt_c_dynamic: *Build.Step.Compile = undefined;
    for ([_]std.builtin.LinkMode{ .static, .dynamic }) |linkage| {
        const lib = b.addLibrary(.{
            .linkage = linkage,
            .name = "qnnt_c",
            .root_module = qnnt_c_mod,
        });
        lib.installHeader(b.path("include/qnnt.h"), "qnnt.h");
        lib.installHeader(b.path("include/qnnt_tld.h"), "qnnt_tld.h");
        lib.installHeader(b.path("include/qnnt_tld.hpp"), "qnnt_tld.hpp");
        b.installArtifact(lib);
        if (linkage == .static) qnnt_c_static = lib else qnnt_c_dynamic = lib;
    }

    const test_step = b.step("test", "Run unit tests");

    // These used to need serialising, because every node contended for one well-known
    // registry port and build steps run in parallel. Each now uses a port of its own
    // (22300 tests, 22301 the C node demo, 22302 Python), so they are independent.
    for ([_][]const u8{ "lib/tld.zig", "lib/resolve.zig", "lib/env.zig", "lib/qnnt.zig" }) |src| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .link_libc = true, // threads and getenv, as above
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // A C program compiled against the header and linked to the static library. This is
    // the only thing that actually checks the hand-written header against the exports,
    // so `zig build test` depends on it: a mismatch there is invisible from Zig.
    const c_demo_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_demo_mod.addCSourceFile(.{
        .file = b.path("examples/tld_demo.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_demo_mod.addIncludePath(b.path("include"));
    c_demo_mod.linkLibrary(tld_c_static);

    const c_demo = b.addExecutable(.{ .name = "tld-demo-c", .root_module = c_demo_mod });
    b.installArtifact(c_demo);

    const run_c_demo = b.addRunArtifact(c_demo);
    const c_demo_step = b.step("c-demo", "Build and run the C example against the TLD C ABI");
    c_demo_step.dependOn(&run_c_demo.step);

    // Same for C++: the header-only wrapper is only proven by compiling it.
    const cpp_demo_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    cpp_demo_mod.addCSourceFile(.{
        .file = b.path("examples/tld_demo.cpp"),
        .flags = &.{ "-std=c++20", "-Wall", "-Wextra", "-Werror" },
    });
    cpp_demo_mod.addIncludePath(b.path("include"));
    cpp_demo_mod.linkLibrary(tld_c_static);

    const cpp_demo = b.addExecutable(.{ .name = "tld-demo-cpp", .root_module = cpp_demo_mod });
    b.installArtifact(cpp_demo);

    const run_cpp_demo = b.addRunArtifact(cpp_demo);
    const cpp_demo_step = b.step("cpp-demo", "Build and run the C++ example against the wrapper");
    cpp_demo_step.dependOn(&run_cpp_demo.step);

    // The struct mapping in C++: TLD_* macros, the msgpack-shaped calls, and the check
    // that this side agrees byte-for-byte with the Zig and Python mappings on one golden
    // frame. That agreement is the only thing standing between a C++ producer and a Zig
    // consumer, so it belongs in `test`.
    const tld_map_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    tld_map_mod.addCSourceFile(.{
        .file = b.path("examples/tld_map.cpp"),
        .flags = &.{ "-std=c++20", "-Wall", "-Wextra", "-Werror" },
    });
    tld_map_mod.addIncludePath(b.path("include"));
    tld_map_mod.linkLibrary(tld_c_static);

    const tld_map = b.addExecutable(.{ .name = "tld-map-cpp", .root_module = tld_map_mod });
    b.installArtifact(tld_map);

    const run_tld_map = b.addRunArtifact(tld_map);
    // Reads lib/testdata/interop.tld by a relative path, so it must run from the root.
    run_tld_map.setCwd(b.path("."));
    const tld_map_step = b.step("tld-map", "Build and run the C++ struct-mapping example");
    tld_map_step.dependOn(&run_tld_map.step);

    // And the same mapping from C, where the schema is a descriptor table rather than a
    // macro. It reads the same golden frame, so all four languages are pinned to one
    // artifact.
    const tld_map_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tld_map_c_mod.addCSourceFile(.{
        .file = b.path("examples/tld_map.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    tld_map_c_mod.addIncludePath(b.path("include"));
    tld_map_c_mod.linkLibrary(tld_c_static);

    const tld_map_c = b.addExecutable(.{ .name = "tld-map-c", .root_module = tld_map_c_mod });
    b.installArtifact(tld_map_c);

    const run_tld_map_c = b.addRunArtifact(tld_map_c);
    run_tld_map_c.setCwd(b.path("."));
    const tld_map_c_step = b.step("tld-map-c", "Build and run the C struct-mapping example");
    tld_map_c_step.dependOn(&run_tld_map_c.step);

    // A whole node driven from C: schedule a publisher, consume the same topic through a
    // callback and through the queue at once.
    const node_demo_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    node_demo_mod.addCSourceFile(.{
        .file = b.path("examples/node_demo.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    node_demo_mod.addIncludePath(b.path("include"));
    node_demo_mod.linkLibrary(qnnt_c_static);

    const node_demo = b.addExecutable(.{ .name = "node-demo-c", .root_module = node_demo_mod });
    b.installArtifact(node_demo);

    const run_node_demo = b.addRunArtifact(node_demo);
    const node_demo_step = b.step("node-demo", "Build and run the C node example");
    node_demo_step.dependOn(&run_node_demo.step);

    // The Python package, checked against the shared library just built. The path is
    // passed as an argument so the script never has to guess which build it is testing.
    const python_demo = b.addSystemCommand(&.{ "python3", "python/demo.py" });
    python_demo.addFileArg(qnnt_c_dynamic.getEmittedBin());
    const python_step = b.step("python-demo", "Run the Python package against the built library");
    python_step.dependOn(&python_demo.step);

    // Bundle the shared library into the package, then build a wheel from it. The copy
    // lands in the source tree because that is where setuptools looks for package data;
    // `python/qnnt/_lib/` is generated, not authored.
    const bundle = b.addUpdateSourceFiles();
    bundle.addCopyFileToSource(qnnt_c_dynamic.getEmittedBin(), b.fmt("python/qnnt/_lib/{s}", .{
        qnnt_c_dynamic.out_filename,
    }));

    const wheel = b.addSystemCommand(&.{
        "python3", "-m", "pip", "wheel", "--no-deps", "--quiet",
        "--wheel-dir", "zig-out/wheel", "./python",
    });
    wheel.step.dependOn(&bundle.step);

    const wheel_step = b.step("wheel", "Bundle the shared library and build a Python wheel");
    wheel_step.dependOn(&wheel.step);

    // Installing the wheel into a throwaway venv and running the demo from it is the only
    // check that the packaging works: it proves the library is inside the wheel and found
    // without QNNT_LIBRARY or a source checkout to fall back on.
    const wheel_test = b.addSystemCommand(&.{ "python3", "python/verify_wheel.py" });
    wheel_test.step.dependOn(&wheel.step);

    const wheel_test_step = b.step("wheel-test", "Install the wheel in a venv and run the demo from it");
    wheel_test_step.dependOn(&wheel_test.step);

    // The five demo node roles in C and C++, mirroring src/node-0..4. One program each,
    // with the role chosen by argument, so the roles stay directly comparable:
    //   zig build run-c -- 0        zig build run-cpp -- 3 1000 64
    // Topics and rates match the Zig nodes, so any mix of languages interoperates.
    const node_langs = [_]struct {
        name: []const u8,
        src: []const u8,
        step: []const u8,
        cpp: bool,
    }{
        .{ .name = "node-c", .src = "examples/nodes.c", .step = "run-c", .cpp = false },
        .{ .name = "node-cpp", .src = "examples/nodes.cpp", .step = "run-cpp", .cpp = true },
    };

    for (node_langs) |lang| {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = lang.cpp,
        });
        mod.addCSourceFile(.{
            .file = b.path(lang.src),
            .flags = if (lang.cpp)
                &.{ "-std=c++20", "-Wall", "-Wextra", "-Werror" }
            else
                &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
        mod.addIncludePath(b.path("include"));
        mod.linkLibrary(qnnt_c_static);

        const exe = b.addExecutable(.{ .name = lang.name, .root_module = mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        const step = b.step(lang.step, b.fmt("Run {s} (role 0..4 as the first argument)", .{lang.name}));
        step.dependOn(&run.step);

        // Compiling them is part of `test`; running a role would block forever.
        test_step.dependOn(&exe.step);
    }

    test_step.dependOn(&run_c_demo.step);
    test_step.dependOn(&run_cpp_demo.step);
    test_step.dependOn(&run_node_demo.step);
    test_step.dependOn(&run_tld_map.step);
    test_step.dependOn(&run_tld_map_c.step);
    test_step.dependOn(&python_demo.step);

    // `zig build test`. The TLD module is standalone and tested on its own; qnnt.zig
    // pulls in the network stack, so its tests run as a separate module.



    // Each node is its own executable sharing the qnnt module, with a matching
    // `run` step: `zig build run-0` ... `zig build run-4`.
    const nodes = [_]struct { name: []const u8, src: []const u8, step: []const u8 }{
        .{ .name = "qnnt-node-0", .src = "src/node-0.zig", .step = "run-0" },
        .{ .name = "qnnt-node-1", .src = "src/node-1.zig", .step = "run-1" },
        .{ .name = "qnnt-node-2", .src = "src/node-2.zig", .step = "run-2" },
        .{ .name = "qnnt-node-3", .src = "src/node-3.zig", .step = "run-3" },
        .{ .name = "qnnt-node-4", .src = "src/node-4.zig", .step = "run-4" },
        // The round-trip pair: node-6 probes, node-5 echoes. Separate from the one-way
        // pair above because a round trip needs one clock, not two agreeing ones.
        .{ .name = "qnnt-node-5", .src = "src/node-5.zig", .step = "run-5" },
        .{ .name = "qnnt-node-6", .src = "src/node-6.zig", .step = "run-6" },
    };

    for (nodes) |node| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(node.src),
            .target = target,
            .optimize = optimize,
            // Needed for getenv, which is how `configureFromEnvironment` reads QNNT_*.
            // Without it Zig links no libc on Linux (macOS always links libSystem), the
            // binary comes out static, and every environment variable is silently
            // ignored -- which is exactly how a node ended up with no cluster key and no
            // federation port on Linux while working on macOS.
            .link_libc = true,
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
