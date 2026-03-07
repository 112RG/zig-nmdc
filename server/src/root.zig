const std = @import("std");

pub const Hub = @import("hub.zig").Hub;

test "root exports hub" {
    var hub = Hub{ .allocator = std.testing.allocator };
    defer hub.clients.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), hub.next_client_id);
}
