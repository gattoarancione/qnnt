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

    // Glob matching and the '/'-segment tree, shared by the console tools so qnnt-ls and
    // qnnt-cat cannot disagree about what a pattern means -- what one lists must be what
    // the other subscribes to.

    // Buffered stdout for the tools: their output is data for a pipe, and std.debug.print
    // goes to stderr.
    const stdout_mod = b.createModule(.{
        .root_source_file = b.path("src/stdout.zig"),
        .target = target,
        .optimize = optimize,
    });

    const qnnt_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "qnnt",
        .root_module = qnnt_lib_mod,
    });

    b.installArtifact(qnnt_lib);

    // Speaking HTTP over a socket, minus anything device-specific: a connect with a real
    // deadline, and decoding a chunked response. Shared by the UGV and DIRIGERA examples,
    // which talk to two different small embedded web servers and need the same three
    // things.
    const wire_mod = b.createModule(.{
        .root_source_file = b.path("examples/net/wire.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // socket, connect, fcntl, getsockopt
    });

    // -- the IKEA DIRIGERA chain ------------------------------------------------------
    //
    // No fake here either, and for the same reason as the UGV: the risk in this example is
    // a command reaching a real light in someone's home, which a simulator cannot
    // exercise. What IS offline-testable is every parser, and those carry the tests.

    // TLS through OpenSSL, because Zig 0.16's std client cannot talk to this hub: the hub
    // is TLS 1.2 with an ECDSA certificate, and std offers only ECDHE_RSA suites for 1.2.
    // See the header of examples/dirigera/tls_openssl.zig. Path-provided, the same way the
    // Qt examples take -Dqt=.
    const openssl_path = b.option(
        []const u8,
        "dirigera-openssl",
        "Path to an OpenSSL installation, e.g. /opt/homebrew/opt/openssl@3 (needed for the dirigera step)",
    );

    const dirigera_tls_mod = b.createModule(.{
        .root_source_file = b.path("examples/dirigera/tls_openssl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dirigera_tls_mod.addImport("wire", wire_mod);
    if (openssl_path) |prefix| {
        dirigera_tls_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        dirigera_tls_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        dirigera_tls_mod.linkSystemLibrary("ssl", .{});
        dirigera_tls_mod.linkSystemLibrary("crypto", .{});
    }

    // HTTPS to the hub, with the chain verified against IKEA's embedded root.
    const dirigera_https_mod = b.createModule(.{
        .root_source_file = b.path("examples/dirigera/https.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dirigera_https_mod.addImport("wire", wire_mod);
    dirigera_https_mod.addImport("tls_openssl", dirigera_tls_mod);

    // The hub's vocabulary: device types, attributes, and what it will accept.
    const dirigera_hub_mod = b.createModule(.{
        .root_source_file = b.path("examples/dirigera/hub.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Enough of RFC 6455 to listen to the hub's push stream.
    const dirigera_ws_mod = b.createModule(.{
        .root_source_file = b.path("examples/dirigera/ws.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dirigera_step = b.step("dirigera", "Build the IKEA DIRIGERA bridge");

    // The topic payload types, shared with the C++ station through a golden frame.
    const dirigera_frames_mod = b.createModule(.{
        .root_source_file = b.path("examples/dirigera/frames.zig"),
        .target = target,
        .optimize = optimize,
    });
    dirigera_frames_mod.addImport("qnnt", qnnt_lib_mod);

    const dirigera_bridge_mod = b.createModule(.{
        .root_source_file = b.path("examples/dirigera/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dirigera_bridge_mod.addImport("https", dirigera_https_mod);
    dirigera_bridge_mod.addImport("hub", dirigera_hub_mod);
    dirigera_bridge_mod.addImport("ws", dirigera_ws_mod);
    dirigera_bridge_mod.addImport("frames", dirigera_frames_mod);
    dirigera_bridge_mod.addImport("qnnt", qnnt_lib_mod);
    dirigera_bridge_mod.linkLibrary(qnnt_lib);

    if (openssl_path) |prefix| {
        dirigera_bridge_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        dirigera_bridge_mod.linkSystemLibrary("ssl", .{});
        dirigera_bridge_mod.linkSystemLibrary("crypto", .{});
    }

    const dirigera_bridge = b.addExecutable(.{
        .name = "dirigera-bridge",
        .root_module = dirigera_bridge_mod,
    });

    if (openssl_path == null) {
        // A clear message rather than a wall of linker errors.
        const explain = b.addFail(
            "the dirigera example needs OpenSSL: pass -Ddirigera-openssl=/path " ++
                "(e.g. /opt/homebrew/opt/openssl@3). Zig 0.16's std TLS client cannot " ++
                "handshake with the hub -- see examples/dirigera/tls_openssl.zig.",
        );
        dirigera_step.dependOn(&explain.step);
    } else {
        b.installArtifact(dirigera_bridge);
        dirigera_step.dependOn(&b.addInstallArtifact(dirigera_bridge, .{}).step);
    }

    // -- the UGV Beast chain ----------------------------------------------------------
    //
    // No fake here, unlike the LiDAR and camera chains: the robot is the only thing that
    // can be driven, and a fake that accepted drive commands and did nothing would be a
    // worse test than none. The bridge talks to the real robot over HTTP.

    // Socket.IO over its long-polling transport. Separate from the protocol module because
    // it knows nothing about robots -- it would serve any Socket.IO server.
    const ugv_sio_mod = b.createModule(.{
        .root_source_file = b.path("examples/ugv/sio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ugv_sio_mod.addImport("wire", wire_mod);

    // The robot's own command and telemetry vocabulary, read from GET /config.
    const ugv_beast_mod = b.createModule(.{
        .root_source_file = b.path("examples/ugv/beast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ugv_beast_mod.addImport("sio", ugv_sio_mod);

    const ugv_step = b.step("ugv", "Build the UGV Beast bridge, and the GUI with -Dqt=...");

    const ugv_mjpeg_mod = b.createModule(.{
        .root_source_file = b.path("examples/ugv/mjpeg.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ugv_bridge_mod = b.createModule(.{
        .root_source_file = b.path("examples/ugv/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    ugv_bridge_mod.addImport("sio", ugv_sio_mod);
    ugv_bridge_mod.addImport("beast", ugv_beast_mod);
    ugv_bridge_mod.addImport("qnnt", qnnt_lib_mod);
    ugv_bridge_mod.addImport("wire", wire_mod);
    // The MJPEG reader: its own module because it is pure byte handling with tests of its
    // own, and the bridge is the only thing here that does network I/O for video.
    ugv_bridge_mod.addImport("mjpeg", ugv_mjpeg_mod);
    ugv_bridge_mod.linkLibrary(qnnt_lib);

    const ugv_bridge = b.addExecutable(.{ .name = "ugv-bridge", .root_module = ugv_bridge_mod });
    b.installArtifact(ugv_bridge);
    ugv_step.dependOn(&b.addInstallArtifact(ugv_bridge, .{}).step);

    // The camera-to-driver handoff. Its own module because both ends use it and neither
    // owns it: the fake writes, the driver reads.
    const zed_shm_mod = b.createModule(.{
        .root_source_file = b.path("examples/zed/shm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // open, ftruncate, mmap
    });

    // The depth-camera chain's shared vocabulary, the analogue of examples/lidar/scan.zig.
    const zed_frame_mod = b.createModule(.{
        .root_source_file = b.path("examples/zed/frame.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const zed_driver_mod = b.createModule(.{
        .root_source_file = b.path("examples/zed/zed.zig"),
        .target = target,
        .optimize = optimize,
    });
    zed_driver_mod.addImport("frame", zed_frame_mod);
    zed_frame_mod.addImport("shm", zed_shm_mod);

    const zed_world_mod = b.createModule(.{
        .root_source_file = b.path("examples/zed/world.zig"),
        .target = target,
        .optimize = optimize,
    });
    zed_world_mod.addImport("frame", zed_frame_mod);

    const zed_step = b.step("zed", "Build the fake ZED camera, the bridge, and the viewer with -Dqt=...");

    // The fake camera: no qnnt at all, exactly like the LiDAR fakes. It speaks the framing
    // in zed.zig and nothing else.
    const fake_zed_mod = b.createModule(.{
        .root_source_file = b.path("examples/zed/fake_zed.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fake_zed_mod.addImport("frame", zed_frame_mod);
    fake_zed_mod.addImport("zed", zed_driver_mod);
    fake_zed_mod.addImport("world", zed_world_mod);
    fake_zed_mod.addImport("shm", zed_shm_mod);

    const fake_zed = b.addExecutable(.{ .name = "fake-zed", .root_module = fake_zed_mod });
    b.installArtifact(fake_zed);
    zed_step.dependOn(&b.addInstallArtifact(fake_zed, .{}).step);

    // The bridge: the driver on one side, qnnt topics on the other.
    const camera_mod = b.createModule(.{
        .root_source_file = b.path("examples/zed/camera.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    camera_mod.addImport("frame", zed_frame_mod);
    camera_mod.addImport("zed", zed_driver_mod);
    camera_mod.addImport("shm", zed_shm_mod);
    camera_mod.addImport("qnnt", qnnt_lib_mod);
    camera_mod.linkLibrary(qnnt_lib);

    const camera_sensor = b.addExecutable(.{ .name = "camera-sensor", .root_module = camera_mod });
    b.installArtifact(camera_sensor);
    zed_step.dependOn(&b.addInstallArtifact(camera_sensor, .{}).step);

    // The REAL camera's producer, in place of the fake: reads a ZED over UVC and fills the
    // same shared region. Objective-C against AVFoundation, so macOS only and opt-in --
    // and it produces no depth, because depth is the ZED SDK's and there is no ZED SDK for
    // macOS. See the header of examples/zed/zed_uvc.m.
    // The REAL camera's producer, in place of the fake: reads a ZED and fills the same
    // shared region. One flag, because which API to use is not the caller's business --
    // AVFoundation on macOS, V4L2 on Linux, and neither produces depth, because depth is the
    // ZED SDK's and the SDK needs an NVIDIA GPU. See the headers of zed_uvc.m and zed_v4l2.c.
    if (b.option(bool, "camera", "Build the real-camera producer for this platform (macOS or Linux)") orelse false) {
        const Producer = struct { name: []const u8, src: []const u8, frameworks: bool };
        const producer: ?Producer = switch (target.result.os.tag) {
            .macos => .{ .name = "zed-uvc", .src = "examples/zed/zed_uvc.m", .frameworks = true },
            .linux => .{ .name = "zed-v4l2", .src = "examples/zed/zed_v4l2.c", .frameworks = false },
            else => null,
        };

        if (producer) |prod| {
            const mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            mod.addCSourceFile(.{
                .file = b.path(prod.src),
                .flags = if (prod.frameworks)
                    &.{ "-fobjc-arc", "-Wall", "-Wextra" }
                else
                    &.{ "-std=c11", "-Wall", "-Wextra" },
            });
            if (prod.frameworks) {
                for ([_][]const u8{ "AVFoundation", "Foundation", "CoreMedia", "CoreVideo" }) |fw| {
                    mod.linkFramework(fw, .{});
                }
            }

            const exe = b.addExecutable(.{ .name = prod.name, .root_module = mod });
            b.installArtifact(exe);
            zed_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        } else {
            std.debug.print(
                "-Dcamera: no real-camera producer for {s}. macOS captures with AVFoundation\n" ++
                    "and Linux with V4L2; on anything else the producer would be the ZED SDK,\n" ++
                    "which is also where depth comes from.\n",
                .{@tagName(target.result.os.tag)},
            );
        }
    }


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

    // ---------------------------------------------------------------- the lidar example
    //
    // A fake RS-LiDAR-16 in Zig publishing at the rate the real one transmits, and a
    // Qt/QML viewer that renders the point cloud. `zig build lidar` builds the sensor; add
    // -Dqt=... and it builds the viewer too, which needs Qt Quick rather than only Core.
    const lidar_step = b.step("lidar", "Build the fake LiDAR sensor, and the viewer with -Dqt=...");

    // The driver is its own module, imported by both the fake sensor and the bridge, so
    // the MSOP layout has exactly one definition. It depends on nothing from qnnt: a
    // sensor driver has no business knowing about the transport that carries its output.
    // Shared vocabulary first: both drivers produce these types, so a consumer written
    // against one works with the other.
    const scan_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/scan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // The synthetic room, shared by both fakes so the two sensors are comparable.
    const scene_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/scene.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const rs16_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/rs16.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rs16_mod.addImport("scan", scan_mod);

    const helios_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/helios32.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    helios_mod.addImport("scan", scan_mod);
    // Only for the test that proves the two formats are not interchangeable.
    helios_mod.addImport("rs16", rs16_mod);

    // The fake sensor: no qnnt at all, just UDP. It pretends to be hardware.
    const fake_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/fake_rs16.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fake_mod.addImport("rs16", rs16_mod);
    fake_mod.addImport("scan", scan_mod);
    fake_mod.addImport("scene", scene_mod);
    const fake_rs16 = b.addExecutable(.{ .name = "fake-rs16", .root_module = fake_mod });
    b.installArtifact(fake_rs16);
    lidar_step.dependOn(&b.addInstallArtifact(fake_rs16, .{}).step);

    // The second device: twice the packet rate through the same pipeline.
    const fake_helios_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/fake_helios32.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fake_helios_mod.addImport("helios32", helios_mod);
    fake_helios_mod.addImport("scan", scan_mod);
    fake_helios_mod.addImport("scene", scene_mod);
    const fake_helios = b.addExecutable(.{ .name = "fake-helios32", .root_module = fake_helios_mod });
    b.installArtifact(fake_helios);
    lidar_step.dependOn(&b.addInstallArtifact(fake_helios, .{}).step);

    // The bridge: driver in, TLD topic out.
    const lidar_mod = b.createModule(.{
        .root_source_file = b.path("examples/lidar/sensor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lidar_mod.addImport("qnnt", qnnt_lib_mod);
    lidar_mod.addImport("rs16", rs16_mod);
    lidar_mod.addImport("helios32", helios_mod);
    lidar_mod.addImport("scan", scan_mod);
    const lidar_sensor = b.addExecutable(.{ .name = "lidar-sensor", .root_module = lidar_mod });
    lidar_sensor.root_module.linkLibrary(qnnt_lib);
    b.installArtifact(lidar_sensor);
    lidar_step.dependOn(&b.addInstallArtifact(lidar_sensor, .{}).step);

    const mesh_step = b.step("mesh", "Build the interop mesh nodes (examples/mesh/)");

    // The Qt interface proposal, built only when told where Qt is. Qt is not a dependency
    // of qnnt and `zig build test` must work without it, so this is opt-in rather than
    // detected: -Dqt=/path/to/Qt/6.10.3/macos (a kit directory containing lib/ and
    // libexec/moc). moc runs over the header, since it declares QObject classes.
    if (b.option([]const u8, "qt", "Path to a Qt kit, enabling the qt-demo step")) |qt_path| {
        const moc = b.addSystemCommand(&.{b.pathJoin(&.{ qt_path, "libexec", "moc" })});
        moc.addArgs(&.{"-I"});
        moc.addDirectoryArg(b.path("include"));
        moc.addFileArg(b.path("include/qnnt_qt.hpp"));
        moc.addArg("-o");
        const moc_out = moc.addOutputFileArg("moc_qnnt_qt.cpp");

        // The example declares its own QObject in the .cpp and includes the moc output at
        // the bottom, which is the usual pattern for a single-file Qt program. That needs a
        // second moc run, and its output directory on the include path.
        const moc_demo = b.addSystemCommand(&.{b.pathJoin(&.{ qt_path, "libexec", "moc" })});
        moc_demo.addArgs(&.{"-I"});
        moc_demo.addDirectoryArg(b.path("include"));
        moc_demo.addFileArg(b.path("examples/qt_demo.cpp"));
        moc_demo.addArg("-o");
        const demo_moc_out = moc_demo.addOutputFileArg("qt_demo.moc");

        const qt_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        qt_mod.addCSourceFile(.{
            .file = b.path("examples/qt_demo.cpp"),
            // No -Werror here: the flags Qt's own headers want are its business, not ours.
            .flags = &.{ "-std=c++20", "-Wall" },
        });
        qt_mod.addCSourceFile(.{ .file = moc_out, .flags = &.{"-std=c++20"} });
        qt_mod.addIncludePath(b.path("include"));
        qt_mod.addIncludePath(demo_moc_out.dirname());
        qt_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "include" }) });
        qt_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "lib" }) });

        // Qt ships frameworks on macOS and plain libraries everywhere else, and the two
        // spellings are not interchangeable -- asking for a system library that is a
        // framework fails the link rather than being ignored.
        if (target.result.os.tag == .macos) {
            qt_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "lib", "QtCore.framework", "Headers" }) });
            qt_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "lib" }) });
            qt_mod.linkFramework("QtCore", .{});
        } else {
            qt_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "include", "QtCore" }) });
            qt_mod.linkSystemLibrary("Qt6Core", .{});
        }
        qt_mod.linkLibrary(qnnt_c_static);

        const qt_demo = b.addExecutable(.{ .name = "qt-demo", .root_module = qt_mod });
        b.installArtifact(qt_demo);

        const run_qt_demo = b.addRunArtifact(qt_demo);
        const qt_step = b.step("qt-demo", "Build and run the Qt interface example (needs -Dqt=...)");
        qt_step.dependOn(&run_qt_demo.step);

        // The cross-language pairs. Each is two processes, so a step runs only the Qt half
        // -- start the Python side in another terminal.
        //
        //   qt-telemetry : Qt packs a struct, examples/telemetry_receiver.py unpacks it
        //   qt-receiver  : examples/telemetry_sender.py packs it, Qt unpacks it
        const qt_examples = [_]struct {
            name: []const u8,
            src: []const u8,
            step: []const u8,
            help: []const u8,
            quick: bool, // needs Qt Quick, not only Qt Core
        }{
            .{
                .name = "mesh-qt",
                .src = "examples/mesh/node_qt.cpp",
                .step = "mesh-qt",
                .help = "Build the Qt node of the interop mesh (needs -Dqt=...)",
                .quick = false,
            },
            .{
                .name = "lidar-viewer",
                .src = "examples/lidar/viewer.cpp",
                .step = "lidar-viewer",
                .help = "Build the Qt/QML LiDAR viewer (needs -Dqt=...)",
                .quick = true,
            },
            .{
                .name = "dirigera-home",
                .src = "examples/dirigera/home.cpp",
                .step = "dirigera-home",
                .help = "Build the Qt/QML DIRIGERA control station (needs -Dqt=...)",
                .quick = true,
            },
            .{
                .name = "ugv-pilot",
                .src = "examples/ugv/pilot.cpp",
                .step = "ugv-pilot",
                .help = "Build the Qt/QML UGV Beast control station (needs -Dqt=...)",
                .quick = true,
            },
            .{
                .name = "camera-viewer",
                .src = "examples/zed/viewer.cpp",
                .step = "camera-viewer",
                .help = "Build the Qt/QML depth camera viewer (needs -Dqt=...)",
                .quick = true,
            },
            .{
                .name = "can-station",
                .src = "examples/can/station.cpp",
                .step = "can-station",
                .help = "Build the Qt/QML CAN mesh station (needs -Dqt=...)",
                .quick = true,
            },
        };

        for (qt_examples) |ex| {
            // Each declares its own QObject in the .cpp and includes the moc output at the
            // bottom, so each needs its own moc run.
            const ex_moc = b.addSystemCommand(&.{b.pathJoin(&.{ qt_path, "libexec", "moc" })});
            ex_moc.addArgs(&.{"-I"});
            ex_moc.addDirectoryArg(b.path("include"));
            ex_moc.addFileArg(b.path(ex.src));
            ex_moc.addArg("-o");
            const ex_moc_out = ex_moc.addOutputFileArg(b.fmt("{s}.moc", .{std.fs.path.stem(ex.src)}));

            const ex_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            });
            ex_mod.addCSourceFile(.{ .file = b.path(ex.src), .flags = &.{ "-std=c++20", "-Wall" } });
            ex_mod.addCSourceFile(.{ .file = moc_out, .flags = &.{"-std=c++20"} });
            ex_mod.addIncludePath(b.path("include"));
            ex_mod.addIncludePath(ex_moc_out.dirname());
            ex_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "include" }) });
            ex_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "lib" }) });
            // Qt Quick pulls in Gui, Qml and Quick on top of Core, and each needs its
            // headers on the path -- Qt's own includes are not self-locating.
            const modules: []const []const u8 = if (ex.quick)
                &.{ "QtCore", "QtGui", "QtQml", "QtQuick" }
            else
                &.{"QtCore"};

            if (target.result.os.tag == .macos) {
                ex_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "lib" }) });
                for (modules) |m| {
                    ex_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "lib", b.fmt("{s}.framework", .{m}), "Headers" }) });
                    ex_mod.linkFramework(m, .{});
                }
            } else {
                for (modules) |m| {
                    ex_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ qt_path, "include", m }) });
                    ex_mod.linkSystemLibrary(b.fmt("Qt6{s}", .{m["Qt".len..]}), .{});
                }
            }
            ex_mod.linkLibrary(qnnt_c_static);

            const exe = b.addExecutable(.{ .name = ex.name, .root_module = ex_mod });
            b.installArtifact(exe);

            // The install step, not the compile step, for the same reason `mesh` above
            // does it: a step named after a binary has to leave the binary in zig-out/bin
            // where it can be run, not merely prove it compiles.
            const step = b.step(ex.step, ex.help);
            step.dependOn(&b.addInstallArtifact(exe, .{}).step);

            // So that `zig build mesh -Dqt=...` builds all five rather than four.
            if (std.mem.eql(u8, ex.name, "mesh-qt")) {
                mesh_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            }
            if (std.mem.eql(u8, ex.name, "camera-viewer")) {
                zed_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            }
            if (std.mem.eql(u8, ex.name, "lidar-viewer")) {
                lidar_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            }
            if (std.mem.eql(u8, ex.name, "ugv-pilot")) {
                ugv_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            }
            if (std.mem.eql(u8, ex.name, "dirigera-home")) {
                dirigera_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            }
            // can-station is deliberately NOT tied to the `can` step. That step is guarded
            // on Linux because SocketCAN is; the station only watches topics, and a topic
            // does not care which kernel produced it -- so it builds and runs on a mac
            // against a mesh of gateways running anywhere.
        }
    }

    // ---------------------------------------------------------------- the interop mesh
    //
    // examples/mesh/ holds one node per language, all publishing the same struct on their
    // own topic and receiving it from the other four. `zig build mesh` builds the four that
    // need a toolchain; the Python node needs none, and the Qt node appears when -Dqt is
    // given (see below). examples/mesh/run.sh starts them all.
    const mesh_zig_mod = b.createModule(.{
        .root_source_file = b.path("examples/mesh/node.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mesh_zig_mod.addImport("qnnt", qnnt_lib_mod);
    const mesh_zig = b.addExecutable(.{ .name = "mesh-zig", .root_module = mesh_zig_mod });
    mesh_zig.root_module.linkLibrary(qnnt_lib);
    b.installArtifact(mesh_zig);
    // The install step, not the compile step: `zig build mesh` has to leave the binaries in
    // zig-out/bin where run.sh looks for them.
    mesh_step.dependOn(&b.addInstallArtifact(mesh_zig, .{}).step);

    const mesh_natives = [_]struct {
        name: []const u8,
        src: []const u8,
        cpp: bool,
    }{
        .{ .name = "mesh-c", .src = "examples/mesh/node.c", .cpp = false },
        .{ .name = "mesh-cpp", .src = "examples/mesh/node.cpp", .cpp = true },
    };

    for (mesh_natives) |node| {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = node.cpp,
        });
        mod.addCSourceFile(.{
            .file = b.path(node.src),
            .flags = if (node.cpp)
                &.{ "-std=c++20", "-Wall", "-Wextra", "-Werror" }
            else
                &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
        mod.addIncludePath(b.path("include"));
        mod.linkLibrary(qnnt_c_static);

        const exe = b.addExecutable(.{ .name = node.name, .root_module = mod });
        b.installArtifact(exe);
        mesh_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // ---------------------------------------------------------------- the CAN gateway
    //
    // examples/can/ bridges a local SocketCAN interface onto a qnnt mesh: several hosts,
    // several independent buses, no gateway configured with the names of the others.
    //
    // LINUX ONLY, and the step says so on anything else rather than failing to compile a
    // file full of AF_CAN. CAN is a kernel subsystem; there is nothing to port. Everything
    // that is not the kernel lives in examples/can/frame.zig, whose tests run everywhere --
    // which is the only reason this example has any coverage on a mac at all.
    const can_step = b.step("can", "Build the CAN gateway (examples/can/, Linux only)");
    if (target.result.os.tag == .linux) {
        // Named modules, created once and shared by the gateway and the test binary. A
        // second anonymous module over the same file would be a different module holding
        // the same source, which Zig rejects outright.
        const can_frame_mod = b.createModule(.{
            .root_source_file = b.path("examples/can/frame.zig"),
            .target = target,
            .optimize = optimize,
        });
        can_frame_mod.addImport("qnnt", qnnt_lib_mod);

        const can_socketcan_mod = b.createModule(.{
            .root_source_file = b.path("examples/can/socketcan.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        can_socketcan_mod.addImport("frame", can_frame_mod);

        const can_mod = b.createModule(.{
            .root_source_file = b.path("examples/can/gateway.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        can_mod.addImport("qnnt", qnnt_lib_mod);
        can_mod.addImport("frame", can_frame_mod);
        can_mod.addImport("socketcan", can_socketcan_mod);

        const can_gw = b.addExecutable(.{ .name = "qnnt-can-gw", .root_module = can_mod });
        can_gw.root_module.linkLibrary(qnnt_lib);
        b.installArtifact(can_gw);
        can_step.dependOn(&b.addInstallArtifact(can_gw, .{}).step);

        // The SocketCAN tests need a real CAN interface, so they are INSTALLED rather than
        // run: `zig build test` on a developer's machine has no bus to talk to, and
        // docker/can.sh runs this binary in a container after creating one. Without it this
        // file has no coverage at all, which is how it shipped a read that returned a frame
        // borrowing its own stack.
        const can_test = b.addTest(.{
            .name = "qnnt-can-test",
            .root_module = can_socketcan_mod,
        });
        can_test.root_module.linkLibrary(qnnt_lib);
        can_step.dependOn(&b.addInstallArtifact(can_test, .{}).step);
    } else {
        const explain = b.addSystemCommand(&.{
            "echo",
            "the CAN gateway is Linux only (SocketCAN is a kernel subsystem). " ++
                "Cross-compile it with: zig build can -Dtarget=aarch64-linux-gnu",
        });
        can_step.dependOn(&explain.step);
    }

    const test_step = b.step("test", "Run unit tests");

    // These used to need serialising, because every node contended for one well-known
    // registry port and build steps run in parallel. Each now uses a port of its own
    // (22300 tests, 22301 the C node demo, 22302 Python), so they are independent.
    for ([_][]const u8{
        "lib/tld.zig",
        "lib/resolve.zig",
        "lib/env.zig",
        "lib/qnnt.zig",
        "examples/lidar/scan.zig",
        "examples/zed/frame.zig",
        "examples/zed/zed.zig",
        "examples/zed/world.zig",
        "examples/zed/shm.zig",
        "src/ls.zig",
        "src/cat.zig",
        "examples/net/wire.zig",
        "examples/dirigera/https.zig",
        "examples/dirigera/hub.zig",
        "examples/dirigera/frames.zig",
        "examples/dirigera/ws.zig",
        "examples/ugv/sio.zig",
        "examples/ugv/beast.zig",
        "examples/ugv/mjpeg.zig",
        "examples/can/frame.zig",
    }) |src| {
        // Skipped without -Ddirigera-openssl, since it cannot link. See below.
        if (std.mem.eql(u8, src, "examples/dirigera/https.zig") and openssl_path == null)
            continue;

        const test_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // threads and getenv, as above
        });

        // The tools under src/ reach the library through the `qnnt` module the way any
        // consumer does, so their tests need it wired up; the lib/ files are the library.
        // lib/topics.zig deliberately needs neither -- it touches no network, which is why
        // its tests are the cheap ones.
        if (std.mem.startsWith(u8, src, "src/") and true) {
            test_mod.linkLibrary(qnnt_lib);
            test_mod.addImport("qnnt", qnnt_lib_mod);
            test_mod.addImport("stdout", stdout_mod);
        }
        // The CAN wire format is defined in terms of TLD and matched with the library's
        // own matcher, so its tests reach the library the way the gateway does.
        if (std.mem.startsWith(u8, src, "examples/can/")) {
            test_mod.linkLibrary(qnnt_lib);
            test_mod.addImport("qnnt", qnnt_lib_mod);
        }
        // The camera driver is written against the shared vocabulary the same way a
        // consumer would be, so its tests need that module.
        if (std.mem.startsWith(u8, src, "examples/zed/")) {
            test_mod.addImport("frame", zed_frame_mod);
            test_mod.addImport("shm", zed_shm_mod);
        }
        // The robot's protocol module parses telemetry with the Socket.IO client's JSON
        // readers, so its tests need that module.
        if (std.mem.startsWith(u8, src, "examples/ugv/")) {
            test_mod.addImport("sio", ugv_sio_mod);
            test_mod.addImport("wire", wire_mod);
        }
        if (std.mem.startsWith(u8, src, "examples/dirigera/")) {
            test_mod.addImport("wire", wire_mod);
            test_mod.addImport("qnnt", qnnt_lib_mod);
            test_mod.linkLibrary(qnnt_lib);
            test_mod.addImport("tls_openssl", dirigera_tls_mod);
            // https.zig's tests reach OpenSSL to prove the embedded anchor loads, so they
            // only run when the library is available. Everything else in the example --
            // the hub vocabulary, the WebSocket framing, the wire helpers -- is pure Zig
            // and always tested.
            if (openssl_path) |prefix| {
                test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
                test_mod.linkSystemLibrary("ssl", .{});
                test_mod.linkSystemLibrary("crypto", .{});
            }
        }

        const tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The two LiDAR drivers: pure wire-format logic with no qnnt dependency, and the
    // endianness, offsets and distance units they pin are exactly what drifts. They need
    // their module graph, so they cannot ride the simple loop above.
    //
    // Declared here rather than beside the lidar step because `test` must not depend on
    // the example's build options.
    {
        const t_scan = b.createModule(.{
            .root_source_file = b.path("examples/lidar/scan.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const t_rs16 = b.createModule(.{
            .root_source_file = b.path("examples/lidar/rs16.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        t_rs16.addImport("scan", t_scan);

        const t_helios = b.createModule(.{
            .root_source_file = b.path("examples/lidar/helios32.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        t_helios.addImport("scan", t_scan);
        t_helios.addImport("rs16", t_rs16);

        for ([_]*Build.Module{ t_rs16, t_helios }) |mod| {
            const tests = b.addTest(.{ .root_module = mod });
            test_step.dependOn(&b.addRunArtifact(tests).step);
        }
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

    // The C++ logic the viewers depend on, extracted into headers so it can be tested with
    // no Qt, no hub and no robot. Deliberately not behind -Dqt=: anything testable only
    // through the Qt executables would in practice never run, which is how this side of
    // the repository ended up with no coverage at all.
    const cpp_logic_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cpp_logic_mod.link_libcpp = true;
    cpp_logic_mod.addCSourceFile(.{
        .file = b.path("examples/cpp_logic_test.cpp"),
        .flags = &.{ "-std=c++20", "-Wall", "-Wextra", "-Werror" },
    });
    // The golden-frame checks decode real TLD, so this needs the wrapper and the C library
    // behind it -- but still no Qt.
    cpp_logic_mod.addIncludePath(b.path("include"));
    cpp_logic_mod.linkLibrary(tld_c_static);

    const cpp_logic = b.addExecutable(.{ .name = "cpp-logic-test", .root_module = cpp_logic_mod });
    const run_cpp_logic = b.addRunArtifact(cpp_logic);
    const cpp_logic_step = b.step("cpp-logic", "Run the Qt-free C++ logic checks");
    cpp_logic_step.dependOn(&run_cpp_logic.step);

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
    test_step.dependOn(&run_cpp_logic.step);
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
        // Not demo nodes but tools, split the way the shell splits things: one lists, one
        // moves data. `zig build ls -- --tree` passes arguments through.
        .{ .name = "qnnt-ls", .src = "src/ls.zig", .step = "ls" },
        .{ .name = "qnnt-cat", .src = "src/cat.zig", .step = "cat" },
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
        exe.root_module.addImport("stdout", stdout_mod);

        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_exe.addArgs(args);

        const run_exe_step = b.step(node.step, b.fmt("Run {s}", .{node.name}));
        run_exe_step.dependOn(&run_exe.step);
    }
}
