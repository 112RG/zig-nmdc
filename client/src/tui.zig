const std = @import("std");
const posix = std.posix;

// Global state for accessibility from logFn
var input_buffer: std.ArrayList(u8) = undefined;
var mutex: std.Thread.Mutex = .{};
var orig_termios: posix.termios = undefined;
var is_raw_mode = false;
var g_allocator: std.mem.Allocator = undefined;

// Buffer for stderr output
var stderr_buffer: [4096]u8 = undefined;

const stdin_file = std.fs.File.stdin();

pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    input_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);

    // Enable raw mode
    try enableRawMode();
}

pub fn deinit() void {
    disableRawMode();
    input_buffer.deinit(g_allocator);
}

fn enableRawMode() !void {
    if (is_raw_mode) return;
    orig_termios = try posix.tcgetattr(stdin_file.handle);
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

    try posix.tcsetattr(stdin_file.handle, .FLUSH, raw);
    is_raw_mode = true;
}

pub fn disableRawMode() void {
    if (!is_raw_mode) return;
    posix.tcsetattr(stdin_file.handle, .FLUSH, orig_termios) catch {};
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

    var stderr_file_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr_w = &stderr_file_writer.interface;

    // Clear current line
    // \r: Move to begin of line
    // \x1b[2K: Clear entire line
    stderr_w.print("\r\x1b[2K", .{}) catch {};

    // Print log
    const color = switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
    };
    const reset = "\x1b[0m";
    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    stderr_w.print("{s}[{s}] {s}{s}" ++ format ++ "\n", .{ color, @tagName(level), scope_txt, reset } ++ args) catch {};

    // Redraw prompt and input
    renderInput(stderr_w) catch {};
}

fn renderInput(writer: anytype) !void {
    // Print the prompt and buffer.
    // NOTE: If buffer is very long, it might wrap, which this simple TUI doesn't handle gracefully.
    writer.print("\r> {s}", .{input_buffer.items}) catch {};
}

// Returns a complete line if Enter is pressed, empty slice on error
pub fn processInput() anyerror![]u8 {
    // Blocking read for 1 byte using deprecated read method
    var byte_buf: [1]u8 = undefined;
    const bytes_read = stdin_file.read(&byte_buf) catch return &.{};
    if (bytes_read == 0) return &.{};
    const byte = byte_buf[0];

    mutex.lock();
    defer mutex.unlock();

    var stderr_file_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr_w = &stderr_file_writer.interface;

    switch (byte) {
        13 => { // Enter (\r)
            // Print newline so the command stays in history block
            try stderr_w.print("\r\n", .{});

            const line = input_buffer.toOwnedSlice(g_allocator);
            // Re-init buffer
            input_buffer = try std.ArrayList(u8).initCapacity(g_allocator, 0);

            // Redraw prompt
            try renderInput(stderr_w);

            return line;
        },
        127, 8 => { // Backspace
            if (input_buffer.items.len > 0) {
                _ = input_buffer.pop();
                try stderr_w.print("\r\x1b[2K", .{});
                try renderInput(stderr_w);
            }
        },
        3 => { // Ctrl-C
            disableRawMode();
            std.process.exit(0);
        },
        else => {
            if (byte >= 32 and byte < 127) {
                try input_buffer.append(g_allocator, byte);
                // Optimization: just print the char instead of full redraw if at end
                try stderr_w.print("{c}", .{byte});
            }
        },
    }
    return &.{};
}
