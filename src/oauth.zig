const std = @import("std");

pub const verifier_bytes = 96;
pub const state_bytes = 64;
pub const callback_code_bytes = 4096;
pub const timeout_ns: i128 = 5 * std.time.ns_per_min;
pub const token_exchange_timeout_seconds: i64 = 15;
pub const production_origin = "https://keco-studio-main.vercel.app";

pub const SessionTokens = struct {
    access_token: []const u8,
    refresh_token: []const u8,
};

pub const CallbackControl = struct {
    const socket_handle = std.Io.net.Socket.Handle;
    const invalid_handle = std.math.maxInt(usize);

    listener_handle: std.atomic.Value(usize) = .init(invalid_handle),
    stream_handle: std.atomic.Value(usize) = .init(invalid_handle),
    cancelled: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),

    pub fn init(listener: *const std.Io.net.Server) CallbackControl {
        var control: CallbackControl = .{};
        control.listener_handle.store(encodeHandle(listener.socket.handle), .release);
        return control;
    }

    pub fn cancel(self: *CallbackControl, io: std.Io) void {
        self.cancelled.store(true, .release);
        self.closeAll(io);
    }

    fn expire(self: *CallbackControl, io: std.Io) void {
        self.expired.store(true, .release);
        self.closeAll(io);
    }

    fn setStream(self: *CallbackControl, stream: *const std.Io.net.Stream) void {
        self.stream_handle.store(encodeHandle(stream.socket.handle), .release);
    }

    fn streamCanProceed(self: *CallbackControl, io: std.Io) bool {
        if (!self.cancelled.load(.acquire) and !self.expired.load(.acquire)) return true;
        self.closeStream(io);
        return false;
    }

    fn closeStream(self: *CallbackControl, io: std.Io) void {
        const handle = self.stream_handle.swap(invalid_handle, .acq_rel);
        if (handle == invalid_handle) return;
        const stream = std.Io.net.Stream{ .socket = socketForHandle(handle) };
        stream.shutdown(io, .both) catch {};
        stream.close(io);
    }

    pub fn closeAll(self: *CallbackControl, io: std.Io) void {
        closeHandle(io, self.listener_handle.swap(invalid_handle, .acq_rel));
        self.closeStream(io);
    }

    fn closeListener(self: *CallbackControl, io: std.Io) void {
        closeHandle(io, self.listener_handle.swap(invalid_handle, .acq_rel));
    }
};

pub const Transaction = struct {
    verifier: [verifier_bytes]u8 = [_]u8{0} ** verifier_bytes,
    verifier_len: usize = 0,
    state: [state_bytes]u8 = [_]u8{0} ** state_bytes,
    state_len: usize = 0,
    callback_code: [callback_code_bytes]u8 = [_]u8{0} ** callback_code_bytes,
    callback_code_len: usize = 0,
    callback_port: u16 = 0,
    started_ns: i128 = 0,
    consumed: bool = false,

    pub fn init(io: std.Io, port: u16, now_ns: i128) !Transaction {
        var transaction = Transaction{ .callback_port = port, .started_ns = now_ns };
        var verifier_raw: [48]u8 = undefined;
        var state_raw: [32]u8 = undefined;
        try io.randomSecure(&verifier_raw);
        try io.randomSecure(&state_raw);
        defer @memset(&verifier_raw, 0);
        defer @memset(&state_raw, 0);

        transaction.verifier_len = std.base64.url_safe_no_pad.Encoder.calcSize(verifier_raw.len);
        transaction.state_len = std.base64.url_safe_no_pad.Encoder.calcSize(state_raw.len);
        _ = std.base64.url_safe_no_pad.Encoder.encode(transaction.verifier[0..transaction.verifier_len], &verifier_raw);
        _ = std.base64.url_safe_no_pad.Encoder.encode(transaction.state[0..transaction.state_len], &state_raw);
        return transaction;
    }

    pub fn forTest(state: []const u8, verifier: []const u8) Transaction {
        std.debug.assert(state.len <= state_bytes);
        std.debug.assert(verifier.len <= verifier_bytes);
        var transaction = Transaction{};
        @memcpy(transaction.state[0..state.len], state);
        @memcpy(transaction.verifier[0..verifier.len], verifier);
        transaction.state_len = state.len;
        transaction.verifier_len = verifier.len;
        return transaction;
    }

    pub fn verifierValue(self: *const Transaction) []const u8 {
        return self.verifier[0..self.verifier_len];
    }

    pub fn stateValue(self: *const Transaction) []const u8 {
        return self.state[0..self.state_len];
    }

    pub fn callbackUrl(self: *const Transaction, output: []u8) ![]const u8 {
        return std.fmt.bufPrint(output, "http://127.0.0.1:{d}/auth/desktop/callback", .{self.callback_port});
    }

    pub fn authorizationUrl(self: *const Transaction, auth_origin: []const u8, output: []u8) ![]const u8 {
        var callback: [128]u8 = undefined;
        const callback_url = try self.callbackUrl(&callback);
        var challenge: [64]u8 = undefined;
        const challenge_value = try pkceChallenge(self.verifierValue(), &challenge);
        var writer = std.Io.Writer.fixed(output);
        try writer.print("{s}/auth/v1/authorize?provider=google&redirect_to=", .{auth_origin});
        try appendPercentEncoded(&writer, callback_url);
        try writer.writeAll("&code_challenge=");
        try appendPercentEncoded(&writer, challenge_value);
        try writer.writeAll("&code_challenge_method=S256&state=");
        try appendPercentEncoded(&writer, self.stateValue());
        return writer.buffered();
    }

    pub fn consumeCallback(self: *Transaction, request_target: []const u8) ![]const u8 {
        if (self.consumed) return error.CallbackAlreadyConsumed;
        const callback_path = "/auth/desktop/callback";
        if (!std.mem.startsWith(u8, request_target, callback_path ++ "?")) return error.InvalidCallback;
        const query = request_target[callback_path.len..];
        if (query.len <= 1) return error.InvalidCallback;

        var parsed_state: [state_bytes]u8 = undefined;
        var parsed_state_len: usize = 0;
        var parsed_code: [callback_code_bytes]u8 = undefined;
        var parsed_code_len: usize = 0;
        var has_state = false;
        var has_code = false;
        var parts = std.mem.splitScalar(u8, query[1..], '&');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidCallback;
            const separator = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidCallback;
            const key = part[0..separator];
            const value = part[separator + 1 ..];
            if (std.mem.eql(u8, key, "state")) {
                if (has_state) return error.InvalidCallback;
                parsed_state_len = try percentDecode(value, &parsed_state);
                if (parsed_state_len == 0) return error.InvalidCallback;
                has_state = true;
            } else if (std.mem.eql(u8, key, "code")) {
                if (has_code) return error.InvalidCallback;
                parsed_code_len = try percentDecode(value, &parsed_code);
                if (parsed_code_len == 0) return error.InvalidCallback;
                has_code = true;
            } else {
                return error.InvalidCallback;
            }
        }
        if (!has_state or !has_code) return error.InvalidCallback;
        if (!std.mem.eql(u8, parsed_state[0..parsed_state_len], self.stateValue())) return error.StateMismatch;

        self.consumed = true;
        @memcpy(self.callback_code[0..parsed_code_len], parsed_code[0..parsed_code_len]);
        self.callback_code_len = parsed_code_len;
        return self.callback_code[0..self.callback_code_len];
    }

    pub fn expired(self: *const Transaction, now_ns: i128) bool {
        return now_ns - self.started_ns >= timeout_ns;
    }

    pub fn clear(self: *Transaction) void {
        @memset(&self.verifier, 0);
        @memset(&self.state, 0);
        @memset(&self.callback_code, 0);
        self.verifier_len = 0;
        self.state_len = 0;
        self.callback_code_len = 0;
        self.callback_port = 0;
        self.started_ns = 0;
        self.consumed = false;
    }
};

pub fn pkceChallenge(verifier: []const u8, output: []u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    defer @memset(&digest, 0);
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const required = std.base64.url_safe_no_pad.Encoder.calcSize(digest.len);
    if (output.len < required) return error.BufferTooSmall;
    return std.base64.url_safe_no_pad.Encoder.encode(output[0..required], &digest);
}

pub fn handoffUrl(access_token: []const u8, refresh_token: []const u8, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll(production_origin ++ "/auth/desktop/session#access_token=");
    try appendPercentEncoded(&writer, access_token);
    try writer.writeAll("&refresh_token=");
    try appendPercentEncoded(&writer, refresh_token);
    return writer.buffered();
}

pub fn parseSessionTokens(response: []const u8, output: []u8) !SessionTokens {
    const Response = struct {
        access_token: []const u8,
        refresh_token: []const u8,
    };
    var parsed = std.json.parseFromSlice(Response, std.heap.page_allocator, response, .{ .ignore_unknown_fields = true }) catch return error.InvalidTokenResponse;
    defer parsed.deinit();
    if (parsed.value.access_token.len == 0 or parsed.value.refresh_token.len == 0) return error.InvalidTokenResponse;
    const total = std.math.add(usize, parsed.value.access_token.len, parsed.value.refresh_token.len) catch return error.InvalidTokenResponse;
    if (total > output.len) return error.TokenResponseTooLarge;
    @memcpy(output[0..parsed.value.access_token.len], parsed.value.access_token);
    @memcpy(output[parsed.value.access_token.len..total], parsed.value.refresh_token);
    return .{
        .access_token = output[0..parsed.value.access_token.len],
        .refresh_token = output[parsed.value.access_token.len..total],
    };
}

pub fn acceptLoopbackCallback(io: std.Io, listener: *std.Io.net.Server, transaction: *Transaction, control: *CallbackControl) ![]const u8 {
    return acceptLoopbackCallbackWithTimeoutAndConnectionTimeout(
        io,
        listener,
        transaction,
        control,
        std.Io.Duration.fromNanoseconds(timeout_ns),
        std.Io.Duration.fromSeconds(10),
    );
}

pub fn acceptLoopbackCallbackWithTimeout(
    io: std.Io,
    listener: *std.Io.net.Server,
    transaction: *Transaction,
    control: *CallbackControl,
    timeout_duration: std.Io.Duration,
) ![]const u8 {
    return acceptLoopbackCallbackWithTimeoutAndConnectionTimeout(
        io,
        listener,
        transaction,
        control,
        timeout_duration,
        timeout_duration,
    );
}

pub fn acceptLoopbackCallbackWithTimeoutAndConnectionTimeout(
    io: std.Io,
    listener: *std.Io.net.Server,
    transaction: *Transaction,
    control: *CallbackControl,
    timeout_duration: std.Io.Duration,
    connection_timeout: std.Io.Duration,
) ![]const u8 {
    var deadline = Deadline{ .control = control, .duration = timeout_duration };
    defer control.closeListener(io);
    var timeout = try std.Io.concurrent(io, closeAtDeadline, .{ io, &deadline });
    defer timeout.cancel(io) catch {};

    while (true) {
        if (control.cancelled.load(.acquire)) return error.CallbackCancelled;
        if (control.expired.load(.acquire)) return error.CallbackTimedOut;

        const stream = listener.accept(io) catch {
            if (control.cancelled.load(.acquire)) return error.CallbackCancelled;
            return error.CallbackTimedOut;
        };
        control.setStream(&stream);
        if (!control.streamCanProceed(io)) {
            if (control.cancelled.load(.acquire)) return error.CallbackCancelled;
            return error.CallbackTimedOut;
        }
        connection: {
            defer control.closeStream(io);
            var connection_deadline = ConnectionDeadline{
                .control = control,
                .handle = encodeHandle(stream.socket.handle),
                .duration = connection_timeout,
            };
            var connection_timer = try std.Io.concurrent(io, closeStreamAtDeadline, .{ io, &connection_deadline });
            defer connection_timer.cancel(io) catch {};
            var receive_buffer: [8192]u8 = undefined;
            var send_buffer: [1024]u8 = undefined;
            var reader = stream.reader(io, &receive_buffer);
            var writer = stream.writer(io, &send_buffer);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = server.receiveHead() catch {
                if (control.cancelled.load(.acquire)) return error.CallbackCancelled;
                if (control.expired.load(.acquire)) return error.CallbackTimedOut;
                break :connection;
            };
            if (request.head.method != .GET) {
                request.respond(callbackFailureHtml, .{ .keep_alive = false }) catch {};
                break :connection;
            }
            const code = transaction.consumeCallback(request.head.target) catch {
                request.respond(callbackFailureHtml, .{ .keep_alive = false }) catch {};
                break :connection;
            };
            try request.respond(callbackSuccessHtml, .{ .keep_alive = false });
            return code;
        }
    }
}

pub fn exchangeCode(
    io: std.Io,
    allocator: std.mem.Allocator,
    supabase_origin: []const u8,
    anon_key: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    verifier: []const u8,
    token_output: []u8,
) !SessionTokens {
    if (anon_key.len == 0) return error.MissingSupabaseAnonKey;
    var payload: [8192]u8 = undefined;
    var payload_writer = std.Io.Writer.fixed(&payload);
    try payload_writer.writeAll("auth_code=");
    try appendPercentEncoded(&payload_writer, code);
    try payload_writer.writeAll("&code_verifier=");
    try appendPercentEncoded(&payload_writer, verifier);
    try payload_writer.writeAll("&redirect_uri=");
    try appendPercentEncoded(&payload_writer, redirect_uri);

    var endpoint: [256]u8 = undefined;
    const endpoint_url = try std.fmt.bufPrint(&endpoint, "{s}/auth/v1/token?grant_type=pkce", .{supabase_origin});
    const uri = try std.Uri.parse(endpoint_url);
    const headers = [_]std.http.Header{
        .{ .name = "apikey", .value = anon_key },
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    };
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.POST, uri, .{ .keep_alive = false, .extra_headers = &headers });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = payload_writer.buffered().len };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload_writer.buffered());
    try body.end();
    try request.connection.?.flush();

    var response_head: [8192]u8 = undefined;
    var response = try request.receiveHead(&response_head);
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.TokenExchangeRejected;
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const response_reader = response.readerDecompressing(&transfer_buffer, &decompress, &.{});
    var response_writer = std.Io.Writer.fixed(token_output);
    _ = response_reader.streamRemaining(&response_writer) catch |err| switch (err) {
        error.WriteFailed => return error.TokenResponseTooLarge,
        error.ReadFailed => return response.bodyErr() orelse error.InvalidTokenResponse,
    };
    return parseSessionTokens(response_writer.buffered(), token_output);
}

pub fn exchangeCodeWithTimeout(
    io: std.Io,
    allocator: std.mem.Allocator,
    supabase_origin: []const u8,
    anon_key: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    verifier: []const u8,
    token_output: []u8,
) !SessionTokens {
    const ExchangeResult = anyerror!SessionTokens;
    const SelectResult = union(enum) {
        exchange: ExchangeResult,
        deadline: std.Io.Cancelable!void,
    };
    var results: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(io, &results);
    try select.concurrent(.exchange, exchangeCodeTask, .{
        io,
        allocator,
        supabase_origin,
        anon_key,
        redirect_uri,
        code,
        verifier,
        token_output,
    });
    try select.concurrent(.deadline, exchangeDeadlineTask, .{io});

    return switch (try select.await()) {
        .exchange => |result| {
            select.cancelDiscard();
            return result;
        },
        .deadline => {
            select.cancelDiscard();
            return error.TokenExchangeTimedOut;
        },
    };
}

fn exchangeCodeTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    supabase_origin: []const u8,
    anon_key: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    verifier: []const u8,
    token_output: []u8,
) anyerror!SessionTokens {
    return exchangeCode(io, allocator, supabase_origin, anon_key, redirect_uri, code, verifier, token_output);
}

fn exchangeDeadlineTask(io: std.Io) std.Io.Cancelable!void {
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(token_exchange_timeout_seconds), .awake);
}

fn appendPercentEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if ((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

const callbackSuccessHtml = "<!doctype html><title>Keco Studio</title><p>You can return to Keco Studio.</p>";
const callbackFailureHtml = "<!doctype html><title>Keco Studio</title><p>Sign-in could not be completed. You can close this page.</p>";

const Deadline = struct {
    control: *CallbackControl,
    duration: std.Io.Duration,
};

const ConnectionDeadline = struct {
    control: *CallbackControl,
    handle: usize,
    duration: std.Io.Duration,
};

fn closeAtDeadline(io: std.Io, deadline: *Deadline) std.Io.Cancelable!void {
    try std.Io.sleep(io, deadline.duration, .awake);
    deadline.control.expire(io);
}

fn closeStreamAtDeadline(io: std.Io, deadline: *ConnectionDeadline) std.Io.Cancelable!void {
    try std.Io.sleep(io, deadline.duration, .awake);
    if (deadline.control.stream_handle.load(.acquire) != deadline.handle) return;
    deadline.control.closeStream(io);
}

fn closeHandle(io: std.Io, handle: usize) void {
    if (handle == CallbackControl.invalid_handle) return;
    const socket = socketForHandle(handle);
    socket.close(io);
}

fn encodeHandle(handle: CallbackControl.socket_handle) usize {
    return switch (@typeInfo(CallbackControl.socket_handle)) {
        .pointer => @intFromPtr(handle),
        .int => @intCast(handle),
        else => @compileError("unsupported socket handle type"),
    };
}

fn socketForHandle(handle: usize) std.Io.net.Socket {
    return .{
        .handle = switch (@typeInfo(CallbackControl.socket_handle)) {
            .pointer => @ptrFromInt(handle),
            .int => @intCast(handle),
            else => @compileError("unsupported socket handle type"),
        },
        .address = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) },
    };
}

fn percentDecode(encoded: []const u8, output: []u8) !usize {
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < encoded.len) {
        if (write_index == output.len) return error.CallbackValueTooLong;
        if (encoded[read_index] != '%') {
            output[write_index] = encoded[read_index];
            read_index += 1;
            write_index += 1;
            continue;
        }
        if (read_index + 2 >= encoded.len) return error.InvalidCallback;
        output[write_index] = (try hexValue(encoded[read_index + 1])) << 4 | try hexValue(encoded[read_index + 2]);
        read_index += 3;
        write_index += 1;
    }
    return write_index;
}

fn hexValue(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidCallback,
    };
}
