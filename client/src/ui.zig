const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
});

const max_log_lines: usize = 256;

const ansi_reset = "\x1b[0m";
const ansi_dim = "\x1b[90m";
const ansi_red = "\x1b[31m";
const ansi_yellow = "\x1b[33m";
const ansi_green = "\x1b[32m";
const ansi_cyan = "\x1b[36m";
const ansi_blue = "\x1b[34m";
const ansi_magenta = "\x1b[35m";
const ansi_bold_green = "\x1b[1;32m";
const ansi_bold_red = "\x1b[1;31m";
const ansi_bold_magenta = "\x1b[1;35m";
const ansi_bold_white = "\x1b[1;37m";

pub const AppLogLevel = enum {
    err,
    warn,
    info,
    debug,
};

pub const ViewTab = enum {
    logs,
    chat,
    pms,

    pub fn next(self: ViewTab) ViewTab {
        return switch (self) {
            .logs => .chat,
            .chat => .pms,
            .pms => .logs,
        };
    }
};

pub const NickList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *NickList) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *NickList) void {
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn contains(self: *const NickList, nick: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item, nick)) return true;
        }
        return false;
    }

    pub fn replaceFromPayload(self: *NickList, payload: []const u8) !usize {
        self.clear();

        var count: usize = 0;
        var iterator = std.mem.splitSequence(u8, payload, "$$");
        while (iterator.next()) |entry| {
            if (entry.len == 0) continue;
            try self.items.append(self.allocator, try self.allocator.dupe(u8, entry));
            count += 1;
        }

        return count;
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

pub const Ui = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    port: u16,
    nick: []u8,
    terminal: Terminal,
    app_logs: LogBuffer,
    chat_logs: LogBuffer,
    pm_logs: LogBuffer,
    op_nicks: NickList,
    bot_nicks: NickList,
    input: std.ArrayList(u8) = .empty,
    active_tab: ViewTab = .chat,
    connected: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        nick: []const u8,
    ) !Ui {
        var terminal = try Terminal.init();
        errdefer terminal.deinit();

        return .{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .nick = try allocator.dupe(u8, nick),
            .terminal = terminal,
            .app_logs = .{ .allocator = allocator, .capacity = max_log_lines },
            .chat_logs = .{ .allocator = allocator, .capacity = max_log_lines },
            .pm_logs = .{ .allocator = allocator, .capacity = max_log_lines },
            .op_nicks = .{ .allocator = allocator },
            .bot_nicks = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Ui) void {
        self.input.deinit(self.allocator);
        self.bot_nicks.deinit();
        self.op_nicks.deinit();
        self.pm_logs.deinit();
        self.chat_logs.deinit();
        self.app_logs.deinit();
        self.terminal.deinit();
        self.allocator.free(self.nick);
        self.allocator.free(self.host);
    }

    pub fn addAppLog(
        self: *Ui,
        level: AppLogLevel,
        scope: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(message);

        const line = try formatAppLogLine(self.allocator, level, scope, message);
        try self.app_logs.appendOwned(line);
    }

    pub fn addChatLog(self: *Ui, nick: []const u8, text: []const u8) !void {
        const line = try formatChatLine(
            self.allocator,
            self.nick,
            &self.op_nicks,
            &self.bot_nicks,
            nick,
            text,
        );
        try self.chat_logs.appendOwned(line);
    }

    pub fn addPrivateMessageLog(self: *Ui, nick: []const u8, text: []const u8) !void {
        const line = try formatPrivateMessageLine(
            self.allocator,
            self.nick,
            &self.op_nicks,
            &self.bot_nicks,
            nick,
            text,
        );
        try self.pm_logs.appendOwned(line);
    }

    pub fn updateOpList(self: *Ui, payload: []const u8) !usize {
        return self.op_nicks.replaceFromPayload(payload);
    }

    pub fn updateBotList(self: *Ui, payload: []const u8) !usize {
        return self.bot_nicks.replaceFromPayload(payload);
    }

    pub fn setConnected(self: *Ui, connected: bool) void {
        self.connected = connected;
    }

    pub fn switchTab(self: *Ui) void {
        self.active_tab = self.active_tab.next();
    }

    pub fn activeTab(self: *const Ui) ViewTab {
        return self.active_tab;
    }

    pub fn appendInputByte(self: *Ui, byte: u8) !void {
        try self.input.append(self.allocator, byte);
    }

    pub fn popInputByte(self: *Ui) void {
        if (self.input.items.len != 0) {
            _ = self.input.pop();
        }
    }

    pub fn takeInput(self: *Ui) !?[]u8 {
        if (self.input.items.len == 0) return null;

        const owned = try self.allocator.dupe(u8, self.input.items);
        self.input.clearRetainingCapacity();
        return owned;
    }

    pub fn render(self: *Ui) !void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const screen = Terminal.size();
        const width: usize = @max(@as(usize, screen.cols), 20);
        const height: usize = @max(@as(usize, screen.rows), 10);

        const tabs_row: usize = 2;
        const content_header_row: usize = 3;
        const content_start_row: usize = 4;
        const input_row = height;
        const content_rows = if (input_row > content_start_row) input_row - content_start_row else 0;

        const header = try std.fmt.allocPrint(
            self.allocator,
            "NMDC client — {s}:{d} — nick {s} — {s}",
            .{ self.host, self.port, self.nick, if (self.connected) "connected" else "connecting" },
        );
        defer self.allocator.free(header);

        const tab_bar = try self.formatTabBar();
        defer self.allocator.free(tab_bar);

        try stdout.writeAll("\x1b[H\x1b[2J");
        try writeAt(stdout, 1, width, header);
        try writeAt(stdout, tabs_row, width, tab_bar);
        try writeAt(stdout, content_header_row, width, activeTabHeader(self.active_tab));
        try renderLines(stdout, content_start_row, content_rows, width, self.activeLines());

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

    fn activeLines(self: *Ui) []const []u8 {
        return switch (self.active_tab) {
            .logs => self.app_logs.lines.items,
            .chat => self.chat_logs.lines.items,
            .pms => self.pm_logs.lines.items,
        };
    }

    fn formatTabBar(self: *Ui) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}  {s}  {s}  {s}",
            .{
                formatTabLabel(self.active_tab == .logs, "Logs"),
                formatTabLabel(self.active_tab == .chat, "Chat"),
                formatTabLabel(self.active_tab == .pms, "PMs"),
                ansi_dim ++ "Tab switches view" ++ ansi_reset,
            },
        );
    }
};

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

fn writeAt(writer: anytype, row: usize, width: usize, text: []const u8) !void {
    try writer.print("\x1b[{d};1H", .{row});
    try writeStyledWidth(writer, text, width);
    try writer.writeAll(ansi_reset ++ "\x1b[K");
}

fn writeStyledWidth(writer: anytype, text: []const u8, width: usize) !void {
    if (width == 0) return;

    var visible: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\x1b' and index + 1 < text.len and text[index + 1] == '[') {
            const end = std.mem.indexOfScalarPos(u8, text, index, 'm') orelse break;
            try writer.writeAll(text[index .. end + 1]);
            index = end + 1;
            continue;
        }

        if (visible >= width) break;

        try writer.writeByte(text[index]);
        visible += 1;
        index += 1;
    }
}

fn tailSlice(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[text.len - width ..];
}

fn activeTabHeader(tab: ViewTab) []const u8 {
    return switch (tab) {
        .logs => ansi_bold_white ++ "Logs" ++ ansi_reset,
        .chat => ansi_bold_white ++ "Chat" ++ ansi_reset,
        .pms => ansi_bold_white ++ "Private messages" ++ ansi_reset,
    };
}

fn formatTabLabel(is_active: bool, comptime label: []const u8) []const u8 {
    return if (is_active)
        ansi_bold_green ++ "[" ++ label ++ "]" ++ ansi_reset
    else
        ansi_dim ++ label ++ ansi_reset;
}

fn formatAppLogLine(
    allocator: std.mem.Allocator,
    level: AppLogLevel,
    scope: []const u8,
    message: []const u8,
) ![]u8 {
    const timestamp = try makeTimestamp(allocator);
    defer allocator.free(timestamp);

    const level_label = switch (level) {
        .err => "ERROR",
        .warn => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
    };
    const level_color = switch (level) {
        .err => ansi_bold_red,
        .warn => ansi_yellow,
        .info => ansi_green,
        .debug => ansi_cyan,
    };

    return std.fmt.allocPrint(
        allocator,
        "{s}[{s}]{s} {s}[{s}]{s} {s}({s}){s} {s}",
        .{ ansi_dim, timestamp, ansi_reset, level_color, level_label, ansi_reset, ansi_blue, scope, ansi_reset, message },
    );
}

fn formatChatLine(
    allocator: std.mem.Allocator,
    my_nick: []const u8,
    op_nicks: *const NickList,
    bot_nicks: *const NickList,
    nick: []const u8,
    text: []const u8,
) ![]u8 {
    const timestamp = try makeTimestamp(allocator);
    defer allocator.free(timestamp);

    const nick_color = if (std.mem.eql(u8, nick, my_nick))
        ansi_bold_green
    else if (op_nicks.contains(nick))
        ansi_bold_red
    else if (bot_nicks.contains(nick))
        ansi_bold_magenta
    else
        ansi_cyan;

    const role_tag = if (std.mem.eql(u8, nick, my_nick))
        " " ++ ansi_green ++ "[me]" ++ ansi_reset
    else if (op_nicks.contains(nick))
        " " ++ ansi_red ++ "[op]" ++ ansi_reset
    else if (bot_nicks.contains(nick))
        " " ++ ansi_magenta ++ "[bot]" ++ ansi_reset
    else
        "";

    return std.fmt.allocPrint(
        allocator,
        "{s}[{s}]{s} {s}<{s}>{s}{s} {s}",
        .{ ansi_dim, timestamp, ansi_reset, nick_color, nick, ansi_reset, role_tag, text },
    );
}

fn formatPrivateMessageLine(
    allocator: std.mem.Allocator,
    my_nick: []const u8,
    op_nicks: *const NickList,
    bot_nicks: *const NickList,
    nick: []const u8,
    text: []const u8,
) ![]u8 {
    const timestamp = try makeTimestamp(allocator);
    defer allocator.free(timestamp);

    const nick_color = if (std.mem.eql(u8, nick, my_nick))
        ansi_bold_green
    else if (op_nicks.contains(nick))
        ansi_bold_red
    else if (bot_nicks.contains(nick))
        ansi_bold_magenta
    else
        ansi_cyan;

    return std.fmt.allocPrint(
        allocator,
        "{s}[{s}]{s} {s}[pm]{s} {s}{s}{s} {s}",
        .{ ansi_dim, timestamp, ansi_reset, ansi_magenta, ansi_reset, nick_color, nick, ansi_reset, text },
    );
}

fn makeTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const now = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(@max(now, 0))) };
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

test "truncateForWidth clips long lines" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    try writeStyledWidth(list.writer(std.testing.allocator), "hello", 10);
    try std.testing.expectEqualStrings("hello", list.items);

    list.clearRetainingCapacity();
    try writeStyledWidth(list.writer(std.testing.allocator), "hello", 3);
    try std.testing.expectEqualStrings("hel", list.items);
}

test "writeStyledWidth ignores ansi escape length" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    try writeStyledWidth(list.writer(std.testing.allocator), ansi_red ++ "hello" ++ ansi_reset, 3);
    try std.testing.expectEqualStrings(ansi_red ++ "hel", list.items);
}

test "formatPrivateMessageLine includes pm marker" {
    var ops = NickList{ .allocator = std.testing.allocator };
    defer ops.deinit();
    var bots = NickList{ .allocator = std.testing.allocator };
    defer bots.deinit();

    const line = try formatPrivateMessageLine(std.testing.allocator, "me", &ops, &bots, "alice", "secret");
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "[pm]") != null);
}

test "tailSlice keeps the rightmost characters" {
    try std.testing.expectEqualStrings("hello", tailSlice("hello", 10));
    try std.testing.expectEqualStrings("llo", tailSlice("hello", 3));
}

test "view tab cycles in order" {
    try std.testing.expectEqual(ViewTab.chat, ViewTab.logs.next());
    try std.testing.expectEqual(ViewTab.pms, ViewTab.chat.next());
    try std.testing.expectEqual(ViewTab.logs, ViewTab.pms.next());
}
