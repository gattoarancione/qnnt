const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const print_d = std.debug.print;

const registry_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 2222);

pub const Tap = struct {
    topic: []const u8,
    port: u16,
    node: *Node,
    mu: std.Thread.Mutex,
    streams: std.StringHashMap(net.Stream),
    ally: std.mem.Allocator,
    address: net.Address = undefined,
    thread: Thread = undefined,

    pub fn init(topic: []const u8, port: u16, node: *Node) Tap {
        const ally = node.arena.allocator();
        const mu = std.Thread.Mutex{};

        return .{ .topic = topic, .port = port, .node = node, .streams = std.StringHashMap(net.Stream).init(ally), .ally = ally, .mu = mu };
    }

    pub fn deinit(self: *Tap) void {
        self.clients.deinit();
    }

    pub fn pour(self: *Tap, data: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        print_d("count {d}\n", .{self.streams.count()});
        if (self.streams.count() == 0) return;

        print_d("sending {s} as {s}\n", .{ data, self.topic });

        const stream = self.streams.get(self.topic) orelse {
            print_d("no stream for topic '{s}'\n", .{self.topic});
            return;
        };

        var w = stream.writer(&.{});

        w.interface.writeAll(data) catch |err| {
            print_d("cant write to tap (err: {})\n", .{err});
            return;
        };

        //try writer.interface.writeAll(data);
        //var iterator = self.clients.iterator();
        //while (iterator.next()) |entry| {
        //const key = entry.key_ptr.*;
        //print_d("sending {s} as {s}\n", .{ data, key });
        //var client = entry.value_ptr.*.*;
        //var writer = client.stream.writer(&.{});
        //writer.interface.writeAll(data) catch |err| {
        //    print_d("cant write to tap (err: {})\n", .{err});
        //};
        //}
    }

    pub fn run(self: *Tap, attached: bool) !void {
        // run the tap thread
        self.thread = Thread.spawn(.{}, Tap.runTap, .{self}) catch |err| {
            print_d("tap won't start (err: {})\n", .{err});
            return undefined;
        };

        if (attached) {
            self.thread.join();
        }
    }

    fn runTap(self: *Tap) !void {
        print_d("Running Tap {s}\n", .{self.topic});
        var server = while (true) break self.address.listen(.{ .reuse_address = false }) catch |err| {
            if (err == error.AddressInUse) {
                //self.registry = false;
                Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        } else unreachable;
        defer server.deinit();

        //self.registry = true;
        self.port = server.listen_address.getPort();
        print_d("tap listening on port {}\n", .{server.listen_address.getPort()});

        var i: u16 = 0;
        while (true) {
            print_d("accepting {d}\n", .{i});
            const client = try server.accept();
            i += 1;

            //print_d("clients len {d}\n", .{self.clients.capacity});
            //const gop = try self.clients.getOrPut(self.topic);

            //if (!gop.found_existing) {
            //    gop.value_ptr.* = client;
            //}

            //self.clients.put(self.topic, &client) catch |err| {
            //    print_d("registry won't start (err: {})\n", .{err});
            //};
            //print_d("clients len {d}\n", .{self.clients.count()});

            print_d("strems len {d}\n", .{self.streams.count()});
            const key = try self.ally.dupe(u8, self.topic);
            try self.streams.put(key, client.stream);
            self.mu.lock();
            defer self.mu.unlock();
            print_d("strems len {d}\n", .{self.streams.count()});

            //_ = try Thread.spawn(.{}, handleTapReq, .{ self, client });
        }
    }

    fn handleTapReq(self: *Tap, client: net.Server.Connection) !void {
        _ = self;
        defer client.stream.close();

        //var rbuf: [1024]u8 = undefined;
        //var reader = client.stream.reader(&rbuf);

        // empty writer buffer => writes go straight through
        //var writer = client.stream.writer(&.{});

        while (true) {
            //const chunk = reader.interface().takeDelimiterInclusive('\n') catch |err| {
            //    if (err == error.EndOfStream) return; // client closed
            //    return err;
            //};

            //    const chunk = "caca\n";
            //    print_d("echoing {s}\n", .{chunk});
            //    //try writer.interface.writeAll(chunk);
            Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
};

pub const Node = struct {
    registry: bool,
    registry_thread: Thread,
    arena: std.heap.ArenaAllocator,
    taps: std.StringHashMap(Tap),
    mu: std.Thread.Mutex,
    // add tap
    // add sinks

    pub fn init() Node {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const ally = arena.allocator();
        const mu = std.Thread.Mutex{};

        return .{ .registry = false, .registry_thread = undefined, .arena = arena, .taps = std.StringHashMap(Tap).init(ally), .mu = mu };
    }

    pub fn deinit(self: *Node) void {
        self.taps.deinit();
        self.arena.deinit();
    }

    pub fn newTap(self: *Node, topic: []const u8) !Tap {
        const gop = try self.taps.getOrPut(topic);

        if (!gop.found_existing) {
            const tap = Tap.init(topic, 0, self);
            gop.value_ptr.* = tap;
        }

        return gop.value_ptr.*;
    }

    pub fn run(self: *Node, attached: bool) !void {
        // run the registry thread
        self.registry_thread = Thread.spawn(.{}, Node.runRegistry, .{self}) catch |err| {
            print_d("registry won't start (err: {})\n", .{err});
            return undefined;
        };

        // run the taps
        var iterator = self.taps.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0); // chose a free IPv4 port
            try entry.value_ptr.run(false);
        }

        if (attached) {
            self.registry_thread.join();
        }
    }

    fn handleRegistryReq(self: *Node, client: net.Server.Connection) !void {
        defer client.stream.close();

        var rbuf: [1024]u8 = undefined;
        var reader = client.stream.reader(&rbuf);

        // empty writer buffer => writes go straight through
        var writer = client.stream.writer(&.{});

        // greetings
        try writer.interface.print("Welcome to Qnnt {d}.{d}.{d}!\nThis is the registry\n\n", .{ 0, 2, 0 });

        while (true) {
            const chunk = reader.interface().takeDelimiterInclusive('\n') catch |err| {
                if (err == error.EndOfStream) return; // client closed
                return err;
            };

            print_d("echoing {s}\n", .{chunk});
            try writer.interface.writeAll(chunk);

            if (std.mem.startsWith(u8, chunk, "list")) {
                var iterator = self.taps.iterator();
                while (iterator.next()) |entry| {
                    try writer.interface.print("tap:{s}:{d}\n", .{ entry.value_ptr.topic, entry.value_ptr.port });
                }
            }
        }
    }

    fn runRegistry(self: *Node) !void {
        print_d("Running Registry\n", .{});
        var server = while (true) break registry_addr.listen(.{ .reuse_address = false }) catch |err| {
            if (err == error.AddressInUse) {
                self.registry = false;
                Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        } else unreachable;
        defer server.deinit();

        self.registry = true;
        print_d("listening on port {}\n", .{server.listen_address.getPort()});

        while (true) {
            const client = try server.accept();
            _ = try Thread.spawn(.{}, handleRegistryReq, .{ self, client });
        }
    }
};
