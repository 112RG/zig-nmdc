const std = @import("std");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const stderr = std.io.getStdErr().writer();
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    const color = switch (level) {
        .err => "\x1b[31m", // red
        .warn => "\x1b[33m", // yellow
        .info => "\x1b[32m", // green
        .debug => "\x1b[36m", // cyan
    };
    const reset = "\x1b[0m";
    const level_txt = switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };

    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    nosuspend stderr.print("{s}[{s}] {s}{s}" ++ format ++ "\n", .{ color, level_txt, scope_txt, reset } ++ args) catch {};
}
