const std = @import("std");
const hub_mod = @import("hub.zig");
const ui_mod = @import("ui.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    hub: hub_mod.DccHub,
    ui: ui_mod.Ui,
    ui_mutex: std.Thread.Mutex = .{},
    event_mutex: std.Thread.Mutex = .{},
    event_queue: std.ArrayList(hub_mod.Event) = .empty,
    should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn deinit(self: *App) void {
        for (self.event_queue.items) |*event| {
            hub_mod.deinitEvent(self.allocator, event);
        }
        self.event_queue.deinit(self.allocator);
        self.ui.deinit();
        self.hub.deinit();
    }

    pub fn processPendingEvents(self: *App) !void {
        var pending: std.ArrayList(hub_mod.Event) = .empty;

        self.event_mutex.lock();
        std.mem.swap(std.ArrayList(hub_mod.Event), &pending, &self.event_queue);
        self.event_mutex.unlock();

        defer {
            pending.clearRetainingCapacity();
            self.event_mutex.lock();
            std.mem.swap(std.ArrayList(hub_mod.Event), &pending, &self.event_queue);
            self.event_mutex.unlock();
        }

        for (pending.items) |*event| {
            self.handleEvent(event) catch |err| {
                self.logAndRender(.err, "ui", "Event processing failed: {}", .{err}) catch {};
            };
            hub_mod.deinitEvent(self.allocator, event);
        }
    }

    pub fn enqueueEvent(self: *App, event: hub_mod.Event) !void {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        try self.event_queue.append(self.allocator, event);
    }

    pub fn enqueueLogEvent(self: *App, comptime format: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.allocator, format, args);
        errdefer self.allocator.free(line);
        try self.enqueueEvent(.{ .log = line });
    }

    pub fn logAndRender(
        self: *App,
        level: ui_mod.AppLogLevel,
        scope: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();

        try self.ui.addAppLog(level, scope, format, args);
        try self.ui.render();
    }

    pub fn requestExit(self: *App) void {
        self.should_exit.store(true, .seq_cst);
    }

    pub fn isExiting(self: *App) bool {
        return self.should_exit.load(.seq_cst);
    }

    fn handleEvent(self: *App, event: *hub_mod.Event) !void {
        self.ui_mutex.lock();
        defer self.ui_mutex.unlock();

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
};
