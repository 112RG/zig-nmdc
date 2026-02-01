const std = @import("std");
const posix = std.posix;

// Global state for accessibility from logFn
var input_buffer: std.ArrayList(u8) = undefined;
var mutex: std.Thread.Mutex = .{};
var orig_termios: posix.termios = undefined;
var is_raw_mode = false;
var g_allocator: std.mem.Allocator = undefined;
const stdin_fd = std.io.getStdIn().handle;

pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    input_buffer = std.ArrayList(u8).init(allocator);

    // Enable raw mode
    try enableRawMode();
}

pub fn deinit() void {
    disableRawMode();
    input_buffer.deinit();
}

fn enableRawMode() !void {
    if (is_raw_mode) return;
    orig_termios = try posix.tcgetattr(stdin_fd);
    var raw = orig_termios;
    // ECHO | ICANON | ISIG | IEXTEN
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false; // Disable Ctrl-C/Z signal processing to handle manually
    raw.lflag.IEXTEN = false;

    // IXON
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false; // Fix: Ctrl-J vs Enter

    // OPOST - turning this off causes newlines to staircase (\n vs \r\n)
    // We want output processing so \n becomes \r\n
    // raw.oflag.OPOST = false;

    // CS8
    raw.cflag.CSIZE = .CS8;

    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
    is_raw_mode = true;
}

pub fn disableRawMode() void {
    if (!is_raw_mode) return;
    posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
    is_raw_mode = false;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    mutex.lock();
    defer mutex.unlock();

    const stderr = std.io.getStdErr().writer();

    // Clear current line
    // \r: Move to begin of line
    // \x1b[2K: Clear entire line
    stderr.print("\r\x1b[2K", .{}) catch {};

    // Print log
    const color = switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
    };
    const reset = "\x1b[0m";
    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    stderr.print("{s}[{s}] {s}{s}" ++ format ++ "\n", .{ color, @tagName(level), scope_txt, reset } ++ args) catch {};

    // Redraw prompt and input
    renderInput(stderr) catch {};
}

fn renderInput(writer: anytype) !void {
    // Print the prompt and buffer.
    // NOTE: If buffer is very long, it might wrap, which this simple TUI doesn't handle gracefully.
    writer.print("\r> {s}", .{input_buffer.items}) catch {};
}

// Returns a complete line if Enter is pressed, null otherwise
pub fn processInput() !?[]u8 {
    const stdin = std.io.getStdIn().reader();

    // Blocking read for 1 byte (Main thread blocks here, logFn in other threads can take mutex)
    const byte = stdin.readByte() catch return null;

    mutex.lock();
    defer mutex.unlock();

    const stderr = std.io.getStdErr().writer();

    switch (byte) {
        13 => { // Enter (\r)
            // Print newline so the command stays in history block
            try stderr.print("\r\n", .{});

            const line = try input_buffer.toOwnedSlice();
            // Re-init buffer
            input_buffer = std.ArrayList(u8).init(g_allocator);

            // Redraw prompt
            try renderInput(stderr);

            return line;
        },
        127, 8 => { // Backspace
            if (input_buffer.items.len > 0) {
                _ = input_buffer.pop();
                try stderr.print("\r\x1b[2K", .{});
                try renderInput(stderr);
            }
        },
        3 => { // Ctrl-C
            disableRawMode();
            std.process.exit(0);
        },
        else => {
            if (byte >= 32 and byte < 127) {
                try input_buffer.append(byte);
                // Optimization: just print the char instead of full redraw if at end
                try stderr.print("{c}", .{byte});
            }
        },
    }
    return null;
}
