const std = @import("std");
const app_mod = @import("app.zig");
const commands = @import("commands.zig");

const c = @cImport({
    @cInclude("unistd.h");
});

pub fn inputLoop(app: *app_mod.App) !void {
    var buffer: [1]u8 = undefined;

    while (!app.isExiting()) {
        try app.processPendingEvents();

        const read_count = c.read(c.STDIN_FILENO, &buffer, 1);
        if (read_count < 0) return error.TerminalReadFailed;
        if (read_count == 0) continue;

        if (!try handleInputByte(app, buffer[0])) break;
    }

    try app.processPendingEvents();
}

fn handleInputByte(app: *app_mod.App, byte: u8) !bool {
    switch (byte) {
        3 => {
            app.requestExit();
            return false;
        },
        9 => {
            app.ui_mutex.lock();
            defer app.ui_mutex.unlock();

            app.ui.switchTab();
            try app.ui.render();
        },
        '\r', '\n' => {
            const maybe_message = blk: {
                app.ui_mutex.lock();
                defer app.ui_mutex.unlock();

                const input = try app.ui.takeInput();
                try app.ui.render();
                break :blk input;
            };

            if (maybe_message) |message| {
                defer app.allocator.free(message);
                try dispatchInputMessage(app, message);
            }
        },
        127, 8 => {
            app.ui_mutex.lock();
            defer app.ui_mutex.unlock();

            app.ui.popInputByte();
            try app.ui.render();
        },
        else => {
            if (std.ascii.isControl(byte)) return true;

            app.ui_mutex.lock();
            defer app.ui_mutex.unlock();

            try app.ui.appendInputByte(byte);
            try app.ui.render();
        },
    }

    return true;
}

fn dispatchInputMessage(app: *app_mod.App, message: []const u8) !void {
    const active_tab = blk: {
        app.ui_mutex.lock();
        defer app.ui_mutex.unlock();
        break :blk app.ui.activeTab();
    };

    switch (commands.parseInput(active_tab, message)) {
        .chat => |text| {
            if (text.len == 0) return;

            app.hub.sendChat(text) catch |err| {
                try app.logAndRender(.err, "chat", "Chat send failed: {}", .{err});
            };
        },
        .private_message => |private_message| {
            app.hub.sendPrivateMessage(private_message.nick, private_message.text) catch |err| {
                try app.logAndRender(.err, "chat", "Private message send failed: {}", .{err});
            };
        },
        .invalid => |reason| {
            try app.logAndRender(.warn, "ui", "{s}", .{reason});
        },
    }
}
