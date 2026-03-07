const std = @import("std");
const hub_mod = @import("hub.zig");
const logger = @import("logger");
const ui_mod = @import("ui.zig");
const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const input_mod = @import("input.zig");
const network_loop = @import("network_loop.zig");
const commands = @import("commands.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logger.logFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("memory leak detected");
    }
    const allocator = gpa.allocator();

    var config = try config_mod.parseConfig(allocator);
    defer config.deinit(allocator);

    const address = try std.net.Address.parseIp4(config.host, config.port);

    var app = app_mod.App{
        .allocator = allocator,
        .hub = try hub_mod.DccHub.connect(allocator, address, config.nick),
        .ui = try ui_mod.Ui.init(allocator, config.host, config.port, config.nick),
    };
    defer app.deinit();

    {
        app.ui_mutex.lock();
        defer app.ui_mutex.unlock();

        try app.ui.addAppLog(.info, "client", "Starting client for {s}:{d} as {s}", .{ app.ui.host, app.ui.port, app.ui.nick });
        try app.ui.addAppLog(.info, "network", "Connecting to {s}:{d}", .{ app.ui.host, app.ui.port });
        try app.ui.addAppLog(.info, "ui", "Type messages and press Enter. Use /msg <nick> <text> for PMs.", .{});
        try app.ui.addAppLog(.info, "ui", "Press Tab to switch between Logs, Chat, and PMs. Press Ctrl+C to exit.", .{});
        try app.ui.render();
    }

    const network_thread = try std.Thread.spawn(.{}, network_loop.networkThreadMain, .{&app});
    defer network_thread.join();

    try input_mod.inputLoop(&app);
    app.requestExit();
    app.hub.close();
}

test "parseInput behavior is available from commands module" {
    const parsed = commands.parseInput(.chat, "/msg alice hello");

    switch (parsed) {
        .private_message => |message| {
            try std.testing.expectEqualStrings("alice", message.nick);
            try std.testing.expectEqualStrings("hello", message.text);
        },
        else => return error.UnexpectedInputKind,
    }
}
