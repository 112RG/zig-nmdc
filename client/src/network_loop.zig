const std = @import("std");
const hub_mod = @import("hub.zig");
const app_mod = @import("app.zig");

pub fn networkThreadMain(app: *app_mod.App) void {
    var events: std.ArrayList(hub_mod.Event) = .empty;
    defer events.deinit(app.allocator);

    while (!app.isExiting()) {
        for (events.items) |*event| {
            hub_mod.deinitEvent(app.allocator, event);
        }
        events.clearRetainingCapacity();

        const bytes_read = app.hub.readEvents(&events) catch |err| {
            app.enqueueLogEvent("Network error: {}", .{err}) catch {};
            app.requestExit();
            app.hub.close();
            return;
        };

        if (bytes_read == 0) {
            app.enqueueLogEvent("Connection closed by hub", .{}) catch {};
            app.requestExit();
            app.hub.close();
            return;
        }

        for (events.items) |*event| {
            app.enqueueEvent(event.*) catch {
                hub_mod.deinitEvent(app.allocator, event);
                app.enqueueLogEvent("Dropping event due to queue failure", .{}) catch {};
                app.requestExit();
                app.hub.close();
                return;
            };
        }
        events.clearRetainingCapacity();
    }
}
