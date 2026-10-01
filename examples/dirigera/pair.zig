//! Pairing with the hub: the exchange that turns a press of its action button into a
//! bearer token.
//!
//! Every other call in this example needs that token, and until now nothing in the
//! repository could produce one -- the bridge read a file and said "pair with the hub
//! first", which left the procedure living in a scratchpad script outside the tree. This
//! module is that procedure, written once and used by both the bridge's `--pair` and the
//! pairing panel in the GUI.
//!
//! OAuth2 with PKCE, plus a physical press:
//!
//!   GET  /v1/oauth/authorize?audience=homesmart.local&response_type=code
//!                           &code_challenge=<S256>&code_challenge_method=S256
//!        -> {"code": "..."}        and opens a pairing window on the hub
//!   ... the operator presses the action button on the underside of the hub ...
//!   POST /v1/oauth/token    (form-encoded: code, name, grant_type, code_verifier)
//!        -> {"access_token": "..."}
//!
//! THE METHODS ARE THE REVERSE OF MOST PUBLISHED EXAMPLES, and that is not a quirk of one
//! firmware: authorize is a GET -- POSTing it is a 404 -- and token is a POST. Measured
//! against firmware 2.975.3 / api 1.6.7. Getting this backwards produces a 404 that reads
//! like a wrong path, which sends you looking in the wrong place entirely.
//!
//! THE HUB ALLOWS ONE PAIRING WINDOW AT A TIME. A second authorize while one is open
//! answers `{"error":"Already one ongoing pairing request"}`, so a stray probe of that
//! endpoint locks out the next attempt until the first lapses. `run` treats that as a
//! condition to wait on rather than a failure, which is why it reads the body of a 4xx.
//! Three different 4xx bodies mean three different things here, and a bare status code
//! tells them apart not at all:
//!
//!   "Button not pressed ..."              the window is live; keep polling
//!   "Invalid authorization code"          the code is dead; open a fresh window
//!   "Already one ongoing pairing request" someone else holds the slot; wait for it

const std = @import("std");

const path_authorize = "/v1/oauth/authorize";
const path_token = "/v1/oauth/token";

/// The audience the hub expects. Not a URL and not configurable: the hub rejects anything
/// else.
const audience = "homesmart.local";

/// PKCE's verifier and its challenge.
///
/// RFC 7636 allows a verifier of 43 to 128 unreserved characters; 32 random bytes in
/// base64url is the shortest legal form and what every DIRIGERA client uses. The challenge
/// is the base64url of its SHA-256, unpadded.
pub const Pkce = struct {
    verifier: [43]u8,
    challenge: [43]u8,

    /// The seed comes from the caller rather than from a global: randomness in 0.16 lives
    /// on `Io`, and keeping that out of this module is what lets the flow be tested. It
    /// also makes the verifier deterministic under test, so the exact challenge sent can be
    /// asserted.
    pub fn fromSeed(seed: [32]u8) Pkce {
        var p: Pkce = .{ .verifier = undefined, .challenge = undefined };
        _ = encoder.encode(&p.verifier, &seed);
        p.deriveChallenge();
        return p;
    }

    /// For the RFC's own test vector, whose verifier is given as text rather than as the
    /// bytes it was encoded from.
    pub fn fromVerifier(verifier: [43]u8) Pkce {
        var p: Pkce = .{ .verifier = verifier, .challenge = undefined };
        p.deriveChallenge();
        return p;
    }

    fn deriveChallenge(p: *Pkce) void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&p.verifier, &digest, .{});
        _ = encoder.encode(&p.challenge, &digest);
    }
};

/// Unpadded base64url. The padding matters: `=` would be percent-encoded in the query and
/// the hub would compute a different challenge.
const encoder = std.base64.url_safe_no_pad.Encoder;

/// `GET /v1/oauth/authorize?...`
pub fn authorizePath(buf: []u8, challenge: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        path_authorize ++ "?audience=" ++ audience ++
            "&response_type=code&code_challenge={s}&code_challenge_method=S256",
        .{challenge},
    );
}

/// The token request's form body.
///
/// `name` is what the hub lists this client as in its app, so it is worth being a name a
/// person would recognise months later rather than "client".
pub fn tokenBody(
    buf: []u8,
    code: []const u8,
    verifier: []const u8,
    name: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "code={s}&name={s}&grant_type=authorization_code&code_verifier={s}",
        .{ code, name, verifier },
    );
}

/// One string field out of a flat JSON object. The hub's replies here are three keys at
/// most, so this reads one rather than parsing a document.
pub fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var quoted: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&quoted, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;

    var i = at + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    const start = i + 1;

    var j = start;
    while (j < json.len and json[j] != '"') j += 1;
    if (j >= json.len) return null;
    return json[start..j];
}

/// What the hub's answer to a token request means for the loop.
pub const Verdict = enum {
    /// The token is in the body.
    paired,
    /// The operator has not pressed the button yet. Keep polling this window.
    waiting,
    /// This window is no longer usable; open a fresh one.
    restart,
};

pub fn classify(status: u16, body: []const u8) Verdict {
    if (status >= 200 and status <= 299) {
        return if (jsonString(body, "access_token") != null) .paired else .restart;
    }

    // What a live window with an unpressed button answers, verbatim from firmware 2.975.3:
    //
    //   403 {"error":"Button not pressed or presence time stamp timed out."}
    //
    // This is the ordinary state for most of a pairing -- someone is walking to the hub --
    // so it must mean "keep polling". Treating it as a dead window instead reopens the
    // pairing on every poll, which is what the first version of this did against a real
    // hub: it churned through windows seconds apart and nobody was ever given time to press.
    if (std.mem.indexOf(u8, body, "Button not pressed") != null) return .waiting;

    // The hub does not recognise the code at all -- expired, consumed, or from a window it
    // has since dropped. More polling cannot help; a fresh window can. Note that this is
    // what a MADE-UP code returns, which is why probing the endpoint with a dummy value
    // gives a misleading picture of what waiting looks like.
    if (std.mem.indexOf(u8, body, "Invalid authorization code") != null) return .restart;

    return .restart;
}

/// One HTTP round trip, supplied by the caller.
///
/// The flow is defined against this rather than against `https.Client` so that nothing here
/// depends on TLS or OpenSSL. That is not tidiness: it means the whole state machine --
/// the one-window retry, the poll for the button, the lapse-and-reopen -- is driven by the
/// tests below against a fake hub, offline, every build. Tied to the real client, none of
/// it could be exercised without a hub on the bench and a finger on its button.
pub const Requester = *const fn (
    context: ?*anyopaque,
    method: []const u8,
    path: []const u8,
    content_type: []const u8,
    body: ?[]const u8,
    out: *std.ArrayList(u8),
) anyerror!u16;

/// Wait, in whatever way the caller's runtime waits. Injected so the tests can run the loop
/// at full speed.
pub const Sleep = *const fn (ms: u64, context: ?*anyopaque) void;

/// Milliseconds from any fixed origin; only differences are used. Injected so the tests
/// control the deadlines exactly instead of racing a real clock.
pub const Clock = *const fn (context: ?*anyopaque) i64;

/// Fill with cryptographically random bytes. In 0.16 that is `Io.random`, which this module
/// deliberately does not reach for.
pub const Entropy = *const fn (buffer: []u8, context: ?*anyopaque) void;

/// Everything the flow needs from the world outside it.
pub const Host = struct {
    request: Requester,
    sleep: Sleep,
    now_ms: Clock,
    entropy: Entropy,
    /// Passed back to every callback above, and to `progress` and `should_stop`.
    context: ?*anyopaque = null,
};

pub const Options = struct {
    /// How the hub will list this client.
    client_name: []const u8 = "qnnt-bridge",
    /// How long to keep offering the operator a chance to press the button.
    overall_ms: u64 = 600_000,
    /// How long to poll one window before opening another. The hub expires a code on its
    /// own schedule, so a single long poll would quietly go stale.
    window_ms: u64 = 55_000,
    poll_interval_ms: u64 = 3_000,
    /// Between a failed authorize -- usually another window already open -- and the retry.
    retry_interval_ms: u64 = 10_000,
};

/// Progress worth showing a person who is standing at the hub wondering whether to press.
pub const Progress = *const fn (message: []const u8, context: ?*anyopaque) void;

/// True to abandon the attempt. Lets a caller stop on shutdown without this module knowing
/// anything about qnnt.
pub const ShouldStop = *const fn (context: ?*anyopaque) bool;

pub const Error = error{
    /// The window never opened, or the button was never pressed.
    TimedOut,
    Cancelled,
    OutOfMemory,
};

/// Run the whole exchange, leaving the token in `token_out`.
///
/// Reopens the pairing window as it lapses, so the operator can press the button at any
/// point during `overall_ms` rather than racing a single request.
pub fn run(
    host: Host,
    token_out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    options: Options,
    progress: ?Progress,
    should_stop: ?ShouldStop,
) Error!void {
    const context = host.context;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    var path_buf: [256]u8 = undefined;
    var form_buf: [512]u8 = undefined;

    const deadline = host.now_ms(context) + @as(i64, @intCast(options.overall_ms));

    while (host.now_ms(context) < deadline) {
        if (stopped(should_stop, context)) return error.Cancelled;

        var seed: [32]u8 = undefined;
        host.entropy(&seed, context);
        const pkce = Pkce.fromSeed(seed);
        const path = authorizePath(&path_buf, &pkce.challenge) catch return error.TimedOut;

        const status = host.request(
            context, "GET", path, "application/json", null, &body,
        ) catch |err| {
            report(progress, context, "the hub did not answer the pairing request ({t})", .{err});
            host.sleep(options.retry_interval_ms, context);
            continue;
        };

        const code = if (status >= 200 and status <= 299)
            jsonString(body.items, "code")
        else
            null;

        if (code == null) {
            // Nearly always the one-window rule, and worth saying plainly: the usual cause
            // is a previous attempt -- or a stray probe of the endpoint -- still holding it.
            const reason = jsonString(body.items, "error") orelse "the hub refused the request";
            report(progress, context, "{s} -- waiting for it to lapse", .{reason});
            host.sleep(options.retry_interval_ms, context);
            continue;
        }

        // The code is a slice into `body`, which the token request below overwrites.
        var code_buf: [192]u8 = undefined;
        if (code.?.len > code_buf.len) return error.TimedOut;
        @memcpy(code_buf[0..code.?.len], code.?);
        const held_code = code_buf[0..code.?.len];

        report(progress, context, "press the action button on the underside of the hub", .{});

        var dead_code = false;
        const window_ends = @min(
            host.now_ms(context) + @as(i64, @intCast(options.window_ms)),
            deadline,
        );
        while (host.now_ms(context) < window_ends) {
            if (stopped(should_stop, context)) return error.Cancelled;

            const form = tokenBody(
                &form_buf,
                held_code,
                &pkce.verifier,
                options.client_name,
            ) catch return error.TimedOut;

            const token_status = host.request(
                context,
                "POST",
                path_token,
                "application/x-www-form-urlencoded",
                form,
                &body,
            ) catch |err| {
                report(progress, context, "the hub stopped answering ({t})", .{err});
                host.sleep(options.poll_interval_ms, context);
                continue;
            };

            switch (classify(token_status, body.items)) {
                .paired => {
                    const value = jsonString(body.items, "access_token").?;
                    token_out.clearRetainingCapacity();
                    token_out.appendSlice(allocator, value) catch return error.OutOfMemory;
                    report(progress, context, "paired", .{});
                    return;
                },
                .waiting => host.sleep(options.poll_interval_ms, context),
                .restart => {
                    // The hub dropped this code; say so rather than blaming the clock.
                    report(progress, context, "the hub discarded that code, starting over", .{});
                    dead_code = true;
                    break;
                },
            }
        }
        if (!dead_code) {
            report(progress, context, "that pairing window lapsed, opening another", .{});
        }
    }

    return error.TimedOut;
}

fn stopped(should_stop: ?ShouldStop, context: ?*anyopaque) bool {
    const f = should_stop orelse return false;
    return f(context);
}

fn report(progress: ?Progress, context: ?*anyopaque, comptime fmt: []const u8, args: anytype) void {
    const f = progress orelse return;
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    f(text, context);
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "the challenge matches RFC 7636's published vector" {
    // The one part of this flow that can be proved without a hub, and the one most likely
    // to be subtly wrong: padded base64, standard rather than url-safe alphabet, or the
    // hash taken over the seed instead of the encoded verifier. Any of those still produces
    // a plausible 43-character string, and the hub would simply reject every pairing with
    // no indication why.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".*;
    const pkce = Pkce.fromVerifier(verifier);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &pkce.challenge);
}

test "a derived verifier is url-safe and unpadded" {
    // Padding or the standard alphabet would survive a naive eyeball check and then be
    // percent-encoded in the query, so the hub would compute a different challenge.
    const pkce = Pkce.fromSeed(@splat(0xA7));
    try testing.expectEqual(@as(usize, 43), pkce.verifier.len);
    for (pkce.verifier) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
        try testing.expect(ok);
    }
    for (pkce.challenge) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
        try testing.expect(ok);
    }
}

test "a different seed gives a different verifier and challenge" {
    const a = Pkce.fromSeed(@splat(0x01));
    const b = Pkce.fromSeed(@splat(0x02));
    try testing.expect(!std.mem.eql(u8, &a.verifier, &b.verifier));
    try testing.expect(!std.mem.eql(u8, &a.challenge, &b.challenge));
}

test "the authorize query carries the audience and the S256 method" {
    var buf: [256]u8 = undefined;
    const path = try authorizePath(&buf, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    try testing.expectEqualStrings(
        "/v1/oauth/authorize?audience=homesmart.local&response_type=code" ++
            "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" ++
            "&code_challenge_method=S256",
        path,
    );
}

test "the token body carries every field the hub requires" {
    // Sending it without `grant_type`, or with the verifier left out, answers
    // {"error":"Error","message":"Something went wrong"} -- which says nothing about which
    // field is missing, so the shape is pinned here instead.
    var buf: [512]u8 = undefined;
    const form = try tokenBody(&buf, "abc-123", "verifier-xyz", "qnnt-bridge");
    try testing.expectEqualStrings(
        "code=abc-123&name=qnnt-bridge&grant_type=authorization_code&code_verifier=verifier-xyz",
        form,
    );
}

test "classify tells an unpressed button from a dead code" {
    // Verbatim from firmware 2.975.3, and the distinction the whole flow turns on. The
    // first version had these the wrong way round -- it had been measured by sending a
    // MADE-UP code, which answers "Invalid authorization code" and looks like waiting. A
    // real unpressed code answers something else entirely, so against a real hub the flow
    // reopened its pairing window every few seconds and nobody could ever press in time.
    try testing.expectEqual(Verdict.waiting, classify(
        403,
        "{\"error\":\"Button not pressed or presence time stamp timed out.\"}",
    ));
    try testing.expectEqual(Verdict.restart, classify(
        403,
        "{\"error\":\"Invalid authorization code\"}",
    ));
    try testing.expectEqual(
        Verdict.paired,
        classify(200, "{\"access_token\":\"ey.J\",\"token_type\":\"Bearer\"}"),
    );
}

test "a 2xx without a token is not treated as success" {
    try testing.expectEqual(Verdict.restart, classify(200, "{\"ok\":true}"));
}

test "jsonString reads the fields the hub actually sends" {
    try testing.expectEqualStrings(
        "4645db00-5c2e-4f9a-8d1b-2c7f",
        jsonString("{\"code\":\"4645db00-5c2e-4f9a-8d1b-2c7f\"}", "code").?,
    );
    try testing.expectEqualStrings(
        "Already one ongoing pairing request",
        jsonString("{\"error\":\"Already one ongoing pairing request\"}", "error").?,
    );
    try testing.expect(jsonString("{\"code\":\"x\"}", "access_token") == null);
}

test "jsonString does not mistake a number or a bool for a string" {
    try testing.expect(jsonString("{\"expires_in\":3600}", "expires_in") == null);
    try testing.expect(jsonString("{\"ok\":true}", "ok") == null);
}

// -- the flow, against a fake hub ------------------------------------------------------
//
// These are the tests the `Requester` indirection buys. They run the real `run` loop --
// the one-window retry, the poll for the button, the lapse-and-reopen -- with no TLS, no
// hub and no waiting, and they are the only way any of that gets exercised short of
// standing at the hub pressing its button.

/// A hub that answers from a script. Each token request consumes one verdict.
const FakeHub = struct {
    /// How many authorize calls still answer "already one ongoing pairing request".
    busy_authorizations: u32 = 0,
    /// Replies to successive token requests, in order; the last repeats.
    token_replies: []const Reply = &.{},
    token_calls: u32 = 0,
    authorize_calls: u32 = 0,
    sleeps: u32 = 0,
    clock_ms: i64 = 0,
    seed_byte: u8 = 0x5A,
    /// Captured so a test can check what was actually sent.
    last_content_type: [64]u8 = undefined,
    last_content_type_len: usize = 0,
    last_body: [256]u8 = undefined,
    last_body_len: usize = 0,

    const Reply = struct { status: u16, body: []const u8 };

    fn request(
        context: ?*anyopaque,
        method: []const u8,
        path: []const u8,
        content_type: []const u8,
        body: ?[]const u8,
        out: *std.ArrayList(u8),
    ) anyerror!u16 {
        const self: *FakeHub = @ptrCast(@alignCast(context.?));
        out.clearRetainingCapacity();

        if (std.mem.startsWith(u8, path, path_authorize)) {
            try testing.expectEqualStrings("GET", method);
            self.authorize_calls += 1;
            if (self.busy_authorizations > 0) {
                self.busy_authorizations -= 1;
                try out.appendSlice(testing.allocator,
                    "{\"error\":\"Already one ongoing pairing request\"}");
                return 400;
            }
            try out.appendSlice(testing.allocator, "{\"code\":\"window-code-1\"}");
            return 200;
        }

        try testing.expectEqualStrings("POST", method);
        try testing.expectEqualStrings(path_token, path);
        self.last_content_type_len = @min(content_type.len, self.last_content_type.len);
        @memcpy(self.last_content_type[0..self.last_content_type_len],
                content_type[0..self.last_content_type_len]);
        if (body) |payload| {
            self.last_body_len = @min(payload.len, self.last_body.len);
            @memcpy(self.last_body[0..self.last_body_len], payload[0..self.last_body_len]);
        }

        const index = @min(self.token_calls, self.token_replies.len - 1);
        self.token_calls += 1;
        const reply = self.token_replies[index];
        try out.appendSlice(testing.allocator, reply.body);
        return reply.status;
    }

    /// Sleeping advances the fake clock, which is what makes the deadline tests exact
    /// rather than a race against the wall clock.
    fn sleep(ms: u64, context: ?*anyopaque) void {
        const self: *FakeHub = @ptrCast(@alignCast(context.?));
        self.sleeps += 1;
        self.clock_ms += @intCast(ms);
    }

    fn now(context: ?*anyopaque) i64 {
        const self: *FakeHub = @ptrCast(@alignCast(context.?));
        // Every reading moves on a little, so a loop that makes no progress still reaches
        // its deadline instead of spinning for ever.
        self.clock_ms += 1;
        return self.clock_ms;
    }

    /// Fixed, so the verifier under test is predictable.
    fn entropy(buffer: []u8, context: ?*anyopaque) void {
        const self: *FakeHub = @ptrCast(@alignCast(context.?));
        @memset(buffer, self.seed_byte);
    }

    fn host(self: *FakeHub) Host {
        return .{
            .request = request,
            .sleep = sleep,
            .now_ms = now,
            .entropy = entropy,
            .context = self,
        };
    }

    fn contentType(self: *const FakeHub) []const u8 {
        return self.last_content_type[0..self.last_content_type_len];
    }

    fn sentBody(self: *const FakeHub) []const u8 {
        return self.last_body[0..self.last_body_len];
    }
};

const fast: Options = .{
    .poll_interval_ms = 0,
    .retry_interval_ms = 0,
    .window_ms = 60_000,
    .overall_ms = 60_000,
};

test "the button is pressed straight away" {
    var hub: FakeHub = .{ .token_replies = &.{
        .{ .status = 200, .body = "{\"access_token\":\"tok-abc\",\"token_type\":\"Bearer\"}" },
    } };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try run(hub.host(), &token, testing.allocator, fast, null, null);

    try testing.expectEqualStrings("tok-abc", token.items);
    try testing.expectEqual(@as(u32, 1), hub.authorize_calls);
}

test "the token request is form-encoded and carries the verifier that matched the challenge" {
    // The two halves of PKCE are generated in one place and sent in two different requests;
    // if `run` ever sent a verifier from a different pairing attempt the hub would reject
    // every pairing, and only a live hub would say so.
    var hub: FakeHub = .{ .token_replies = &.{
        .{ .status = 200, .body = "{\"access_token\":\"tok\"}" },
    } };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try run(hub.host(), &token, testing.allocator, fast, null, null);

    try testing.expectEqualStrings("application/x-www-form-urlencoded", hub.contentType());
    const sent = hub.sentBody();
    try testing.expect(std.mem.startsWith(u8, sent, "code=window-code-1&name=qnnt-bridge"));
    try testing.expect(std.mem.indexOf(u8, sent, "&grant_type=authorization_code&") != null);

    const marker = "code_verifier=";
    const at = std.mem.indexOf(u8, sent, marker).?;
    const verifier = sent[at + marker.len ..];
    try testing.expectEqual(@as(usize, 43), verifier.len);
}

test "it keeps polling while the button has not been pressed" {
    var hub: FakeHub = .{ .token_replies = &.{
        .{ .status = 403, .body = "{\"error\":\"Button not pressed or presence time stamp timed out.\"}" },
        .{ .status = 403, .body = "{\"error\":\"Button not pressed or presence time stamp timed out.\"}" },
        .{ .status = 200, .body = "{\"access_token\":\"tok-late\"}" },
    } };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try run(hub.host(), &token, testing.allocator, fast, null, null);

    try testing.expectEqualStrings("tok-late", token.items);
    try testing.expectEqual(@as(u32, 3), hub.token_calls);
    // One window only: waiting is not a reason to reopen.
    try testing.expectEqual(@as(u32, 1), hub.authorize_calls);
}

test "another pairing window already open is waited out, not given up on" {
    // The failure this guards is the one that actually happened: a stray probe of the
    // authorize endpoint held the hub's single pairing slot, and every later attempt was
    // refused until it lapsed.
    var hub: FakeHub = .{
        .busy_authorizations = 2,
        .token_replies = &.{.{ .status = 200, .body = "{\"access_token\":\"tok\"}" }},
    };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try run(hub.host(), &token, testing.allocator, fast, null, null);

    try testing.expectEqualStrings("tok", token.items);
    try testing.expectEqual(@as(u32, 3), hub.authorize_calls);
}

test "a dead code opens a fresh window instead of polling for ever" {
    var hub: FakeHub = .{ .token_replies = &.{
        .{ .status = 403, .body = "{\"error\":\"Invalid authorization code\"}" },
        .{ .status = 200, .body = "{\"access_token\":\"tok-second-window\"}" },
    } };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try run(hub.host(), &token, testing.allocator, fast, null, null);

    try testing.expectEqualStrings("tok-second-window", token.items);
    try testing.expectEqual(@as(u32, 2), hub.authorize_calls);
}

test "it gives up rather than spinning when nobody presses the button" {
    var hub: FakeHub = .{ .token_replies = &.{
        .{ .status = 403, .body = "{\"error\":\"Button not pressed or presence time stamp timed out.\"}" },
    } };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    const options: Options = .{
        .poll_interval_ms = 0,
        .retry_interval_ms = 0,
        .window_ms = 0,
        .overall_ms = 0,
    };
    try testing.expectError(
        error.TimedOut,
        run(hub.host(), &token, testing.allocator, options, null, null),
    );
    try testing.expectEqualStrings("", token.items);
}

test "cancelling stops the loop" {
    const Stopper = struct {
        fn always(context: ?*anyopaque) bool {
            _ = context;
            return true;
        }
    };
    var hub: FakeHub = .{ .token_replies = &.{
        .{ .status = 200, .body = "{\"access_token\":\"tok\"}" },
    } };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try testing.expectError(error.Cancelled, run(
        hub.host(),
        &token,
        testing.allocator,
        fast,
        null,
        Stopper.always,
    ));
    try testing.expectEqual(@as(u32, 0), hub.authorize_calls);
}

test "progress names the hub's own reason for refusing" {
    const Capture = struct {
        var seen: [8][128]u8 = undefined;
        var count: usize = 0;
        fn record(message: []const u8, context: ?*anyopaque) void {
            _ = context;
            if (count >= seen.len) return;
            const n = @min(message.len, seen[count].len);
            @memcpy(seen[count][0..n], message[0..n]);
            lengths[count] = n;
            count += 1;
        }
        var lengths: [8]usize = @splat(0);
        fn at(i: usize) []const u8 {
            return seen[i][0..lengths[i]];
        }
    };
    Capture.count = 0;

    var hub: FakeHub = .{
        .busy_authorizations = 1,
        .token_replies = &.{.{ .status = 200, .body = "{\"access_token\":\"tok\"}" }},
    };
    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(testing.allocator);

    try run(hub.host(), &token, testing.allocator, fast, Capture.record, null);

    try testing.expect(std.mem.indexOf(u8, Capture.at(0), "Already one ongoing pairing request") != null);
    try testing.expect(std.mem.indexOf(u8, Capture.at(1), "press the action button") != null);
    try testing.expectEqualStrings("paired", Capture.at(2));
}
