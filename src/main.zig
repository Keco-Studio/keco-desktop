const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const oauth = @import("oauth.zig");
const config = @import("config.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const App = struct {
    io: std.Io,
    runtime: ?*native_sdk.Runtime = null,
    oauth_active: bool = false,
    oauth_worker: ?*OAuthWorker = null,
    source_mode: enum { startup, handoff, failure } = .startup,
    handoff_buffer: [16 * 1024]u8 = undefined,
    handoff_len: usize = 0,
    bridge_handlers: [1]native_sdk.bridge.AsyncHandler = undefined,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "keco-studio",
            .source_fn = source,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *App = @ptrCast(@alignCast(context));
        return switch (self.source_mode) {
            .startup => native_sdk.WebViewSource.url(startup_url),
            .handoff => native_sdk.WebViewSource.url(self.handoff_buffer[0..self.handoff_len]),
            .failure => native_sdk.WebViewSource.url(failure_url),
        };
    }

    fn bridge(self: *App) native_sdk.BridgeDispatcher {
        self.bridge_handlers = .{.{
            .name = "desktop.begin_google_oauth",
            .context = self,
            .invoke_fn = beginGoogleOAuth,
        }};
        return .{
            .policy = .{ .enabled = true, .commands = &bridge_policies },
            .async_registry = .{ .handlers = &self.bridge_handlers },
        };
    }

    fn beginGoogleOAuth(context: *anyopaque, invocation: native_sdk.bridge.Invocation, responder: native_sdk.bridge.AsyncResponder) !void {
        if (!std.mem.eql(u8, invocation.request.payload, "{}")) return error.InvalidPayload;
        const self: *App = @ptrCast(@alignCast(context));
        try self.startGoogleOAuth();
        try responder.success(invocation.request.id, "{\"status\":\"started\"}");
    }

    fn startGoogleOAuth(self: *App) !void {
        if (self.oauth_active) return error.OAuthAlreadyActive;
        const runtime = self.runtime orelse return error.RuntimeUnavailable;
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try std.Io.net.IpAddress.listen(&address, self.io, .{ .reuse_address = true });
        var listener_needs_close = true;
        errdefer if (listener_needs_close) listener.deinit(self.io);

        const started = @as(i128, @intCast(std.Io.Clock.awake.now(self.io).nanoseconds));
        var transaction = try oauth.Transaction.init(self.io, listener.socket.address.getPort(), started);
        var transaction_needs_clear = true;
        errdefer if (transaction_needs_clear) transaction.clear();

        const worker = try std.heap.page_allocator.create(OAuthWorker);
        errdefer std.heap.page_allocator.destroy(worker);
        worker.* = .{
            .io = self.io,
            .listener = listener,
            .transaction = transaction,
            .control = oauth.CallbackControl.init(&listener),
            .wake = runtime.options.platform.services,
        };
        listener_needs_close = false;
        transaction_needs_clear = false;
        errdefer worker.deinit();

        var authorization: [2048]u8 = undefined;
        const authorization_url = try worker.transaction.authorizationUrl(config.supabase_origin, &authorization);
        try runtime.openExternalUrl(authorization_url);

        worker.thread = try std.Thread.spawn(.{}, OAuthWorker.run, .{worker});
        self.oauth_active = true;
        self.oauth_worker = worker;
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) !void {
        if (event_value != .effects_wake) return;
        const self: *App = @ptrCast(@alignCast(context));
        try self.consumeOAuthResult(runtime);
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) !void {
        _ = runtime;
        const self: *App = @ptrCast(@alignCast(context));
        self.cancelOAuthWorker();
    }

    fn consumeOAuthResult(self: *App, runtime: *native_sdk.Runtime) !void {
        const worker = self.oauth_worker orelse return;
        if (!worker.finished.load(.acquire)) return;
        self.oauth_worker = null;
        self.oauth_active = false;
        defer {
            worker.join();
            worker.deinit();
            std.heap.page_allocator.destroy(worker);
        }

        switch (worker.outcome) {
            .success => |success| {
                @memcpy(self.handoff_buffer[0..success.handoff_len], success.handoff_url[0..success.handoff_len]);
                self.handoff_len = success.handoff_len;
                self.source_mode = .handoff;
                defer self.clearHandoff();
                try runner.reloadPrimaryWebView(runtime, self.app());
            },
            .failure => |err| {
                runtime.recordDispatchError("oauth", err);
                self.source_mode = .failure;
                defer self.source_mode = .startup;
                try runner.reloadPrimaryWebView(runtime, self.app());
            },
        }
    }

    fn cancelOAuthWorker(self: *App) void {
        const worker = self.oauth_worker orelse return;
        worker.control.cancel(self.io);
        worker.join();
        worker.deinit();
        std.heap.page_allocator.destroy(worker);
        self.oauth_worker = null;
        self.oauth_active = false;
    }

    fn clearHandoff(self: *App) void {
        @memset(&self.handoff_buffer, 0);
        self.handoff_len = 0;
        self.source_mode = .startup;
    }

    fn runtimeReady(context: *anyopaque, runtime: *native_sdk.Runtime) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.runtime = runtime;
    }
};

const OAuthWorker = struct {
    const Outcome = union(enum) {
        success: struct {
            handoff_url: [16 * 1024]u8,
            handoff_len: usize,
        },
        failure: anyerror,
    };

    io: std.Io,
    listener: std.Io.net.Server,
    transaction: oauth.Transaction,
    control: oauth.CallbackControl,
    wake: native_sdk.platform.PlatformServices,
    thread: ?std.Thread = null,
    finished: std.atomic.Value(bool) = .init(false),
    outcome: Outcome = .{ .failure = error.OAuthWorkerNotStarted },

    fn run(self: *OAuthWorker) void {
        self.complete() catch |err| {
            self.outcome = .{ .failure = err };
        };
        self.finished.store(true, .release);
        self.wake.wake() catch {};
    }

    fn complete(self: *OAuthWorker) !void {
        defer self.transaction.clear();
        const code = try oauth.acceptLoopbackCallback(self.io, &self.listener, &self.transaction, &self.control);
        var redirect_uri: [128]u8 = undefined;
        const redirect_url = try self.transaction.callbackUrl(&redirect_uri);
        var tokens_buffer: [16 * 1024]u8 = undefined;
        defer @memset(&tokens_buffer, 0);
        const tokens = try oauth.exchangeCodeWithTimeout(
            self.io,
            std.heap.page_allocator,
            config.supabase_origin,
            config.supabase_anon_key,
            redirect_url,
            code,
            self.transaction.verifierValue(),
            &tokens_buffer,
        );
        var handoff_url: [16 * 1024]u8 = undefined;
        defer @memset(&handoff_url, 0);
        const handoff = try oauth.handoffUrl(tokens.access_token, tokens.refresh_token, &handoff_url);
        self.outcome = .{ .success = .{
            .handoff_url = handoff_url,
            .handoff_len = handoff.len,
        } };
    }

    fn join(self: *OAuthWorker) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }

    fn deinit(self: *OAuthWorker) void {
        self.control.closeAll(self.io);
        self.transaction.clear();
        switch (self.outcome) {
            .success => |*success| @memset(&success.handoff_url, 0),
            .failure => {},
        }
    }
};

const allowed_origins = [_][]const u8{"https://keco-studio-main.vercel.app"};
const allowed_authorization_urls = [_][]const u8{"https://lulrcirmwwvvnupmwqcq.supabase.co/auth/v1/authorize*"};
const bridge_policies = [_]native_sdk.BridgeCommandPolicy{.{
    .name = "desktop.begin_google_oauth",
    .origins = &allowed_origins,
}};
const startup_url = "https://keco-studio-main.vercel.app/projects?desktop=1";
const failure_url = "https://keco-studio-main.vercel.app/?desktop=1&oauth_error=desktop_oauth_failed";

pub fn main(init: std.process.Init) !void {
    var app = App{ .io = init.io };
    try runner.runWithOptions(app.app(), .{
        .app_name = "Keco Studio",
        .window_title = "Keco Studio",
        .bundle_id = "dev.keco.studio",
        .icon_path = "assets/icon.png",
        .bridge = app.bridge(),
        .runtime_ready = App.runtimeReady,
        .runtime_context = &app,
        .security = .{
            .navigation = .{
                .allowed_origins = &allowed_origins,
                .external_links = .{
                    .action = .open_system_browser,
                    .allowed_urls = &allowed_authorization_urls,
                },
            },
        },
    }, init);
}

test "app name is configured" {
    try std.testing.expectEqualStrings("keco-studio", "keco-studio");
}
