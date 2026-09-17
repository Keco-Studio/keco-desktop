const std = @import("std");
const oauth = @import("oauth");

test "PKCE challenge is SHA-256 base64url without padding" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        try oauth.pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", &output),
    );
}

test "callback accepts a Supabase code-only callback and rejects a replay" {
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");

    try std.testing.expectEqualStrings(
        "code-a",
        try transaction.consumeCallback("/auth/desktop/callback?code=code-a"),
    );
    try std.testing.expectError(
        error.CallbackAlreadyConsumed,
        transaction.consumeCallback("/auth/desktop/callback?code=code-b"),
    );
}

test "callback accepts a matching state when the provider supplies it" {
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");

    try std.testing.expectEqualStrings(
        "code-a",
        try transaction.consumeCallback("/auth/desktop/callback?code=code-a&state=expected-state"),
    );
}

test "callback rejects malformed, repeated, and mismatched state when supplied" {
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");

    try std.testing.expectError(error.InvalidCallback, transaction.consumeCallback("/"));
    try std.testing.expectError(error.InvalidCallback, transaction.consumeCallback("/auth/desktop/callback?state=expected-state"));
    try std.testing.expectError(error.InvalidCallback, transaction.consumeCallback("/auth/desktop/callback?code=a&code=b"));
    try std.testing.expectError(error.InvalidCallback, transaction.consumeCallback("/auth/desktop/callback?code=code-a&state=expected-state&state=expected-state"));
    try std.testing.expectError(error.InvalidCallback, transaction.consumeCallback("/auth/desktop/callback?code=code-a&unexpected=value"));
    try std.testing.expectError(error.StateMismatch, transaction.consumeCallback("/auth/desktop/callback?code=code-a&state=wrong"));
}

test "transaction expires after five minutes and clears secret storage" {
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");
    transaction.started_ns = 10;

    try std.testing.expect(!transaction.expired(10 + oauth.timeout_ns - 1));
    try std.testing.expect(transaction.expired(10 + oauth.timeout_ns));

    transaction.clear();
    try std.testing.expectEqual(@as(usize, 0), transaction.verifier_len);
    try std.testing.expectEqual(@as(usize, 0), transaction.state_len);
    for (transaction.verifier) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (transaction.state) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "authorization and handoff URLs percent encode values" {
    var transaction = oauth.Transaction.forTest("state value", "verifier value");
    transaction.callback_port = 41234;
    var authorization: [1024]u8 = undefined;
    var handoff: [1024]u8 = undefined;

    const authorization_url = try transaction.authorizationUrl("https://auth.example.test", &authorization);
    try std.testing.expect(std.mem.indexOf(u8, authorization_url, "state=state%20value") != null);
    try std.testing.expect(std.mem.indexOf(u8, authorization_url, "redirect_to=http%3A%2F%2F127.0.0.1%3A41234%2Fauth%2Fdesktop%2Fcallback") != null);

    const handoff_url = try oauth.handoffUrl("access token", "refresh/token", &handoff);
    try std.testing.expectEqualStrings(
        "https://keco-studio-main.vercel.app/auth/desktop/session#access_token=access%20token&refresh_token=refresh%2Ftoken",
        handoff_url,
    );
}

test "token response accepts only nonempty token pair into caller storage" {
    var output: [256]u8 = undefined;
    const tokens = try oauth.parseSessionTokens(
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\"}",
        &output,
    );
    try std.testing.expectEqualStrings("access", tokens.access_token);
    try std.testing.expectEqualStrings("refresh", tokens.refresh_token);
    try std.testing.expectError(error.InvalidTokenResponse, oauth.parseSessionTokens("{\"access_token\":\"access\"}", &output));
}

test "token exchange deadline is bounded" {
    try std.testing.expectEqual(@as(i64, 15), oauth.token_exchange_timeout_seconds);
}

test "token exchange payload is JSON with only the Supabase PKCE fields" {
    var output: [256]u8 = undefined;

    try std.testing.expectEqualStrings(
        "{\"auth_code\":\"code-a\",\"code_verifier\":\"verifier-a\"}",
        try oauth.tokenExchangePayload("code-a", "verifier-a", &output),
    );
}

test "token exchange payload JSON escapes credential values" {
    var output: [256]u8 = undefined;

    try std.testing.expectEqualStrings(
        "{\"auth_code\":\"code\\\"\\\\\\n\",\"code_verifier\":\"verifier\\t\"}",
        try oauth.tokenExchangePayload("code\"\\\n", "verifier\t", &output),
    );
}

test "partial loopback request cannot outlive callback deadline" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&listen_address, io, .{ .reuse_address = true });
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");
    transaction.callback_port = listener.socket.address.getPort();

    const Result = struct {
        value: anyerror![]const u8,
    };
    var result = Result{ .value = error.TestNotRun };
    const Worker = struct {
        fn run(result_out: *Result, io_value: std.Io, listener_value: *std.Io.net.Server, transaction_value: *oauth.Transaction, control_value: *oauth.CallbackControl) void {
            result_out.value = oauth.acceptLoopbackCallbackWithTimeout(io_value, listener_value, transaction_value, control_value, std.Io.Duration.fromMilliseconds(40));
        }
    };
    var control = oauth.CallbackControl.init(&listener);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &result, io, &listener, &transaction, &control });

    const client_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", transaction.callback_port);
    const stream = try client_address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [32]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.writeAll("GET /auth/desktop/callback");
    try writer.interface.flush();

    thread.join();
    try std.testing.expectError(error.CallbackTimedOut, result.value);
}

test "callback continues after a malformed request" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&listen_address, io, .{ .reuse_address = true });
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");
    transaction.callback_port = listener.socket.address.getPort();
    var control = oauth.CallbackControl.init(&listener);

    const Result = struct { value: anyerror![]const u8 };
    var result = Result{ .value = error.TestNotRun };
    const Worker = struct {
        fn run(result_out: *Result, io_value: std.Io, listener_value: *std.Io.net.Server, transaction_value: *oauth.Transaction, control_value: *oauth.CallbackControl) void {
            result_out.value = oauth.acceptLoopbackCallbackWithTimeout(io_value, listener_value, transaction_value, control_value, std.Io.Duration.fromSeconds(1));
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &result, io, &listener, &transaction, &control });

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", transaction.callback_port);
    const malformed = try address.connect(io, .{ .mode = .stream });
    var malformed_buffer: [128]u8 = undefined;
    var malformed_writer = malformed.writer(io, &malformed_buffer);
    try malformed_writer.interface.writeAll("POST /auth/desktop/callback HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try malformed_writer.interface.flush();
    malformed.close(io);

    const valid = try address.connect(io, .{ .mode = .stream });
    defer valid.close(io);
    var valid_buffer: [256]u8 = undefined;
    var valid_writer = valid.writer(io, &valid_buffer);
    try valid_writer.interface.writeAll("GET /auth/desktop/callback?code=code-a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try valid_writer.interface.flush();

    thread.join();
    try std.testing.expectEqualStrings("code-a", try result.value);
}

test "partial request times out before a valid callback arrives" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&listen_address, io, .{ .reuse_address = true });
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");
    transaction.callback_port = listener.socket.address.getPort();
    var control = oauth.CallbackControl.init(&listener);

    const Result = struct { value: anyerror![]const u8 };
    var result = Result{ .value = error.TestNotRun };
    const Worker = struct {
        fn run(result_out: *Result, io_value: std.Io, listener_value: *std.Io.net.Server, transaction_value: *oauth.Transaction, control_value: *oauth.CallbackControl) void {
            result_out.value = oauth.acceptLoopbackCallbackWithTimeoutAndConnectionTimeout(
                io_value,
                listener_value,
                transaction_value,
                control_value,
                std.Io.Duration.fromSeconds(1),
                std.Io.Duration.fromMilliseconds(30),
            );
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &result, io, &listener, &transaction, &control });

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", transaction.callback_port);
    const partial = try address.connect(io, .{ .mode = .stream });
    var partial_buffer: [128]u8 = undefined;
    var partial_writer = partial.writer(io, &partial_buffer);
    try partial_writer.interface.writeAll("GET /auth/desktop/callback");
    try partial_writer.interface.flush();

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(80), .awake);
    const valid = try address.connect(io, .{ .mode = .stream });
    defer valid.close(io);
    var valid_buffer: [256]u8 = undefined;
    var valid_writer = valid.writer(io, &valid_buffer);
    try valid_writer.interface.writeAll("GET /auth/desktop/callback?code=code-a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try valid_writer.interface.flush();

    thread.join();
    partial.close(io);
    try std.testing.expectEqualStrings("code-a", try result.value);
}
