const std = @import("std");
const hub_mod = @import("hub.zig");
const logger = @import("logger");
const ui_mod = @import("ui.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logger.logFn,
};

const c = @cImport({
    @cInclude("unistd.h");
});

const default_host = "10.0.1.141";
const default_port: u16 = 411;
const default_nick = "TestBot";

const Config = struct {
    host: []u8,
    port: u16,
    nick: []u8,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.nick);
    }
};

const ParsedInput = union(enum) {
    chat: []const u8,
    private_message: struct {
        nick: []const u8,
        text: []const u8,
    },
    invalid: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    hub: hub_mod.DccHub,
    ui: ui_mod.Ui,
    mutex: std.Thread.Mutex = .{},
    should_exit: bool = false,

    fn deinit(self: *App) void {
        self.ui.deinit();
        self.hub.deinit();
    }

    fn handleEvent(self: *App, event: *hub_mod.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (event.*) {
            .log => |line| try self.ui.addAppLog(.info, "hub", "{s}", .{line}),
            .chat => |chat| try self.ui.addChatLog(chat.nick, chat.text),
            .private_message => |message| try self.ui.addPrivateMessageLog(message.from, message.text),
            .op_list => |payload| {
                const count = try self.ui.updateOpList(payload);
                try self.ui.addAppLog(.info, "hub", "Updated op list ({d})", .{count});
            },
            .bot_list => |payload| {
                const count = try self.ui.updateBotList(payload);
                try self.ui.addAppLog(.info, "hub", "Updated bot list ({d})", .{count});
            },
            .connected => self.ui.setConnected(true),
        }

        try self.ui.render();
    }

    fn requestExit(self: *App) void {
        self.mutex.lock();
        self.should_exit = true;
        self.mutex.unlock();
    }

    fn isExiting(self: *App) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_exit;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("memory leak detected");
    }
    const allocator = gpa.allocator();

    var config = try parseConfig(allocator);
    defer config.deinit(allocator);

    const address = try std.net.Address.parseIp4(config.host, config.port);

    var app = App{
        .allocator = allocator,
        .hub = try hub_mod.DccHub.connect(allocator, address, config.nick),
        .ui = try ui_mod.Ui.init(allocator, config.host, config.port, config.nick),
    };
    defer app.deinit();

    app.mutex.lock();
    try app.ui.addAppLog(.info, "client", "Starting client for {s}:{d} as {s}", .{ app.ui.host, app.ui.port, app.ui.nick });
    try app.ui.addAppLog(.info, "network", "Connecting to {s}:{d}", .{ app.ui.host, app.ui.port });
    try app.ui.addAppLog(.info, "ui", "Type messages and press Enter. Use /msg <nick> <text> for PMs.", .{});
    try app.ui.addAppLog(.info, "ui", "Press Tab to switch between Logs, Chat, and PMs. Press Ctrl+C to exit.", .{});
    try app.ui.render();
    app.mutex.unlock();

    const network_thread = try std.Thread.spawn(.{}, networkThreadMain, .{&app});
    defer network_thread.join();

    try inputLoop(&app);
    app.requestExit();
    app.hub.close();
}

fn parseConfig(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    return .{
        .host = try allocator.dupe(u8, if (args.len > 1) args[1] else default_host),
        .port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else default_port,
        .nick = try allocator.dupe(u8, if (args.len > 3) args[3] else default_nick),
    };
}

fn inputLoop(app: *App) !void {
    var buffer: [1]u8 = undefined;

    while (!app.isExiting()) {
        const read_count = c.read(c.STDIN_FILENO, &buffer, 1);
        if (read_count < 0) return error.TerminalReadFailed;
        if (read_count == 0) continue;

        if (!try handleInputByte(app, buffer[0])) return;
    }
}

fn handleInputByte(app: *App, byte: u8) !bool {
    switch (byte) {
        3 => {
            app.requestExit();
            return false;
        },
        9 => {
            app.mutex.lock();
            app.ui.switchTab();
            try app.ui.render();
            app.mutex.unlock();
        },
        '\r', '\n' => {
            app.mutex.lock();
            const maybe_message = try app.ui.takeInput();
            try app.ui.render();
            app.mutex.unlock();

            if (maybe_message) |message| {
                defer app.allocator.free(message);
                try dispatchInputMessage(app, message);
            }
        },
        127, 8 => {
            app.mutex.lock();
            app.ui.popInputByte();
            try app.ui.render();
            app.mutex.unlock();
        },
        else => {
            if (std.ascii.isControl(byte)) return true;

            app.mutex.lock();
            try app.ui.appendInputByte(byte);
            try app.ui.render();
            app.mutex.unlock();
        },
    }

    return true;
}

fn dispatchInputMessage(app: *App, message: []const u8) !void {
    switch (parseInput(app.ui.activeTab(), message)) {
        .chat => |text| {
            if (text.len == 0) return;

            app.hub.sendChat(text) catch |err| {
                app.mutex.lock();
                defer app.mutex.unlock();
                try app.ui.addAppLog(.err, "chat", "Chat send failed: {}", .{err});
                try app.ui.render();
            };
        },
        .private_message => |private_message| {
            app.hub.sendPrivateMessage(private_message.nick, private_message.text) catch |err| {
                app.mutex.lock();
                defer app.mutex.unlock();
                try app.ui.addAppLog(.err, "chat", "Private message send failed: {}", .{err});
                try app.ui.render();
            };
        },
        .invalid => |reason| {
            app.mutex.lock();
            defer app.mutex.unlock();
            try app.ui.addAppLog(.warn, "ui", "{s}", .{reason});
            try app.ui.render();
        },
    }
}

fn parseInput(active_tab: ui_mod.ViewTab, message: []const u8) ParsedInput {
    const trimmed = std.mem.trim(u8, message, " ");
    if (trimmed.len == 0) return .{ .chat = "" };
    if (!std.mem.startsWith(u8, trimmed, "/")) {
        if (active_tab == .pms) {
            return .{ .invalid = "Use /msg <nick> <message> in the PM tab" };
        }
        return .{ .chat = trimmed };
    }

    if (std.mem.startsWith(u8, trimmed, "/msg")) {
        const rest = std.mem.trimLeft(u8, trimmed[4..], " ");
        if (rest.len == 0) {
            return .{ .invalid = "Usage: /msg <nick> <message>" };
        }

        const nick_end = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            return .{ .invalid = "Usage: /msg <nick> <message>" };
        };
        const nick = std.mem.trim(u8, rest[0..nick_end], " ");
        if (nick.len == 0) {
            return .{ .invalid = "Usage: /msg <nick> <message>" };
        }

        const text = std.mem.trimLeft(u8, rest[nick_end + 1 ..], " ");
        if (text.len == 0) {
            return .{ .invalid = "Usage: /msg <nick> <message>" };
        }

        return .{ .private_message = .{ .nick = nick, .text = text } };
    }

    return .{ .invalid = "Unknown command. Supported: /msg <nick> <message>" };
}

fn networkThreadMain(app: *App) void {
    var events: std.ArrayList(hub_mod.Event) = .empty;
    defer events.deinit(app.allocator);

    while (!app.isExiting()) {
        for (events.items) |*event| {
            hub_mod.deinitEvent(app.allocator, event);
        }
        events.clearRetainingCapacity();

        const bytes_read = app.hub.readEvents(&events) catch |err| {
            app.mutex.lock();
            defer app.mutex.unlock();
            app.should_exit = true;
            app.ui.addAppLog(.err, "network", "Network error: {}", .{err}) catch {};
            app.ui.render() catch {};
            return;
        };

        if (bytes_read == 0) {
            app.mutex.lock();
            defer app.mutex.unlock();
            app.should_exit = true;
            app.ui.addAppLog(.warn, "network", "Connection closed by hub", .{}) catch {};
            app.ui.render() catch {};
            return;
        }

        for (events.items) |*event| {
            app.handleEvent(event) catch {};
            hub_mod.deinitEvent(app.allocator, event);
        }
        events.clearRetainingCapacity();
    }
}

test "parseInput parses private message command" {
    const parsed = parseInput(.chat, "/msg alice hello there");

    switch (parsed) {
        .private_message => |message| {
            try std.testing.expectEqualStrings("alice", message.nick);
            try std.testing.expectEqualStrings("hello there", message.text);
        },
        else => return error.UnexpectedInputKind,
    }
}

test "parseInput rejects malformed msg command" {
    const parsed = parseInput(.chat, "/msg alice");

    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings("Usage: /msg <nick> <message>", reason),
        else => return error.ExpectedInvalidInput,
    }
}

test "parseInput blocks plain text in PM tab" {
    const parsed = parseInput(.pms, "hello everyone");

    switch (parsed) {
        .invalid => |reason| try std.testing.expectEqualStrings("Use /msg <nick> <message> in the PM tab", reason),
        else => return error.ExpectedInvalidInput,
    }
}

test "parseInput still allows plain text in chat tab" {
    const parsed = parseInput(.chat, "hello everyone");

    switch (parsed) {
        .chat => |text| try std.testing.expectEqualStrings("hello everyone", text),
        else => return error.UnexpectedInputKind,
    }
}
