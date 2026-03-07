const std = @import("std");
const hub_mod = @import("hub.zig");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
});

const default_host = "10.0.1.141";
const default_port: u16 = 411;
const default_nick = "TestBot";
const max_log_lines: usize = 256;

const Config = struct {
    host: []u8,
    port: u16,
    nick: []u8,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.nick);
    }
};

const LogBuffer = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    lines: std.ArrayList([]u8) = .empty,

    fn deinit(self: *LogBuffer) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit(self.allocator);
    }

    fn appendOwned(self: *LogBuffer, line: []u8) !void {
        if (self.lines.items.len >= self.capacity) {
            const removed = self.lines.orderedRemove(0);
            self.allocator.free(removed);
        }
        try self.lines.append(self.allocator, line);
    }

    fn appendFmt(self: *LogBuffer, comptime format: []const u8, args: anytype) !void {
        try self.appendOwned(try std.fmt.allocPrint(self.allocator, format, args));
    }
};

const ScreenSize = struct {
    cols: u16,
    rows: u16,
};

const Terminal = struct {
    original: c.termios,
    raw_enabled: bool = false,

    fn init() !Terminal {
        var terminal = Terminal{ .original = undefined };
        if (c.tcgetattr(c.STDIN_FILENO, &terminal.original) != 0) return error.TerminalUnavailable;

        var raw = terminal.original;
        raw.c_iflag &= ~@as(c.tcflag_t, @intCast(c.IXON | c.ICRNL | c.BRKINT | c.INPCK | c.ISTRIP));
        raw.c_oflag &= ~@as(c.tcflag_t, @intCast(c.OPOST));
        raw.c_cflag |= @as(c.tcflag_t, @intCast(c.CS8));
        raw.c_lflag &= ~@as(c.tcflag_t, @intCast(c.ECHO | c.ICANON | c.IEXTEN | c.ISIG));
        raw.c_cc[c.VMIN] = 0;
        raw.c_cc[c.VTIME] = 1;

        if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) != 0) return error.TerminalUnavailable;
        terminal.raw_enabled = true;

        try std.fs.File.stdout().writeAll("\x1b[?1049h\x1b[2J\x1b[H");
        return terminal;
    }

    fn deinit(self: *Terminal) void {
        if (self.raw_enabled) {
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &self.original);
        }
        std.fs.File.stdout().writeAll("\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l") catch {};
    }

    fn size() ScreenSize {
        var winsize: c.struct_winsize = undefined;
        if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &winsize) == 0 and winsize.ws_col != 0 and winsize.ws_row != 0) {
            return .{ .cols = winsize.ws_col, .rows = winsize.ws_row };
        }
        return .{ .cols = 100, .rows = 30 };
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    hub: hub_mod.DccHub,
    host: []u8,
    port: u16,
    terminal: Terminal,
    mutex: std.Thread.Mutex = .{},
    app_logs: LogBuffer,
    chat_logs: LogBuffer,
    input: std.ArrayList(u8) = .empty,
    should_exit: bool = false,
    connected: bool = false,

    fn deinit(self: *App) void {
        self.input.deinit(self.allocator);
        self.chat_logs.deinit();
        self.app_logs.deinit();
        self.hub.deinit();
        self.terminal.deinit();
        self.allocator.free(self.host);
    }

    fn addAppLogLocked(self: *App, comptime format: []const u8, args: anytype) !void {
        try self.app_logs.appendFmt(format, args);
    }

    fn addChatLogLocked(self: *App, nick: []const u8, text: []const u8) !void {
        try self.chat_logs.appendFmt("<{s}> {s}", .{ nick, text });
    }

    fn renderLocked(self: *App) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const screen = Terminal.size();
        const width: usize = @max(@as(usize, screen.cols), 20);
        const height: usize = @max(@as(usize, screen.rows), 10);

        const separator_row = height / 2;
        const chat_header_row = separator_row + 1;
        const input_row = height;
        const log_body_rows = if (separator_row > 2) separator_row - 2 else 0;
        const chat_body_start = chat_header_row + 1;
        const chat_body_rows = if (input_row > chat_body_start) input_row - chat_body_start else 0;

        const header = try std.fmt.allocPrint(
            self.allocator,
            "NMDC client — {s}:{d} — nick {s} — {s}",
            .{ self.host, self.port, self.hub.nick, if (self.connected) "connected" else "connecting" },
        );
        defer self.allocator.free(header);

        try stdout.writeAll("\x1b[H\x1b[2J");
        try writeAt(stdout, 1, width, header);
        try writeAt(stdout, 2, width, "App logs");
        try renderLines(stdout, 3, log_body_rows, width, self.app_logs.lines.items);
        try writeSeparator(stdout, separator_row, width);
        try writeAt(stdout, chat_header_row, width, "Chat");
        try renderLines(stdout, chat_body_start, chat_body_rows, width, self.chat_logs.lines.items);

        const prompt_text = try std.fmt.allocPrint(
            self.allocator,
            "> {s}",
            .{tailSlice(self.input.items, if (width > 2) width - 2 else 0)},
        );
        defer self.allocator.free(prompt_text);
        try writeAt(stdout, input_row, width, prompt_text);

        const prompt_slice = tailSlice(self.input.items, if (width > 2) width - 2 else 0);
        const cursor_col = @min(width, 3 + prompt_slice.len);
        try stdout.print("\x1b[{d};{d}H", .{ input_row, cursor_col });
    }

    fn handleEvent(self: *App, event: *hub_mod.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (event.*) {
            .log => |line| try self.addAppLogLocked("{s}", .{line}),
            .chat => |chat| try self.addChatLogLocked(chat.nick, chat.text),
            .connected => self.connected = true,
        }

        try self.renderLocked();
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

    var terminal = try Terminal.init();
    errdefer terminal.deinit();

    var app = App{
        .allocator = allocator,
        .hub = try hub_mod.DccHub.connect(allocator, address, config.nick),
        .host = try allocator.dupe(u8, config.host),
        .port = config.port,
        .terminal = terminal,
        .app_logs = .{ .allocator = allocator, .capacity = max_log_lines },
        .chat_logs = .{ .allocator = allocator, .capacity = max_log_lines },
    };
    defer app.deinit();

    app.mutex.lock();
    try app.addAppLogLocked("Connecting to {s}:{d}", .{ app.host, app.port });
    try app.addAppLogLocked("Type messages and press Enter. Press Ctrl+C to exit.", .{});
    try app.renderLocked();
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
        '\r', '\n' => {
            var maybe_message: ?[]u8 = null;

            app.mutex.lock();
            if (app.input.items.len != 0) {
                maybe_message = try app.allocator.dupe(u8, app.input.items);
                app.input.clearRetainingCapacity();
            }
            try app.renderLocked();
            app.mutex.unlock();

            if (maybe_message) |message| {
                defer app.allocator.free(message);
                app.hub.sendChat(message) catch |err| {
                    app.mutex.lock();
                    defer app.mutex.unlock();
                    try app.addAppLogLocked("Chat send failed: {}", .{err});
                    try app.renderLocked();
                };
            }
        },
        127, 8 => {
            app.mutex.lock();
            if (app.input.items.len != 0) {
                _ = app.input.pop();
            }
            try app.renderLocked();
            app.mutex.unlock();
        },
        else => {
            if (std.ascii.isControl(byte)) return true;

            app.mutex.lock();
            try app.input.append(app.allocator, byte);
            try app.renderLocked();
            app.mutex.unlock();
        },
    }

    return true;
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
            app.addAppLogLocked("Network error: {}", .{err}) catch {};
            app.renderLocked() catch {};
            return;
        };

        if (bytes_read == 0) {
            app.mutex.lock();
            defer app.mutex.unlock();
            app.should_exit = true;
            app.addAppLogLocked("Connection closed by hub", .{}) catch {};
            app.renderLocked() catch {};
            return;
        }

        for (events.items) |*event| {
            app.handleEvent(event) catch {};
            hub_mod.deinitEvent(app.allocator, event);
        }
        events.clearRetainingCapacity();
    }
}

fn renderLines(
    writer: anytype,
    start_row: usize,
    available_rows: usize,
    width: usize,
    lines: []const []u8,
) !void {
    const visible = @min(available_rows, lines.len);
    const first = lines.len - visible;

    for (0..available_rows) |offset| {
        const line = if (offset < visible) lines[first + offset] else "";
        try writeAt(writer, start_row + offset, width, line);
    }
}

fn writeSeparator(writer: anytype, row: usize, width: usize) !void {
    try writer.print("\x1b[{d};1H", .{row});
    for (0..width) |_| {
        try writer.writeByte('-');
    }
    try writer.writeAll("\x1b[K");
}

fn writeAt(writer: anytype, row: usize, width: usize, text: []const u8) !void {
    try writer.print("\x1b[{d};1H", .{row});
    try writer.writeAll(truncateForWidth(text, width));
    try writer.writeAll("\x1b[K");
}

fn truncateForWidth(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[0..width];
}

fn tailSlice(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[text.len - width ..];
}

test "truncateForWidth clips long lines" {
    try std.testing.expectEqualStrings("hello", truncateForWidth("hello", 10));
    try std.testing.expectEqualStrings("hel", truncateForWidth("hello", 3));
}

test "tailSlice keeps the rightmost characters" {
    try std.testing.expectEqualStrings("hello", tailSlice("hello", 10));
    try std.testing.expectEqualStrings("llo", tailSlice("hello", 3));
}
