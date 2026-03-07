const std = @import("std");
const nmdc = @import("nmdc").NMDC;

const hub_name = "Zig NMDC Hub";
const hub_lock = "EXTENDEDPROTOCOLZIGMINHUB";
const hub_pk = "ZigHub0.1";
const hub_bot = "Hub-Security";
const hub_supports = [_][]const u8{
    "NoHello",
    "NoGetINFO",
    "BotList",
};
const hub_bots = [_][]const u8{hub_bot};

pub const Client = struct {
    id: usize,
    stream: std.net.Stream,
    address: std.net.Address,
    buffer: nmdc.MessageBuffer = .{},
    nick: ?[]u8 = null,
    myinfo: ?nmdc.OwnedMyInfo = null,
    is_operator: bool = false,

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        if (self.nick) |nick| allocator.free(nick);
        if (self.myinfo) |*myinfo| myinfo.deinit(allocator);
        std.posix.shutdown(self.stream.handle, .both) catch {};
        self.stream.close();
    }
};

pub const Hub = struct {
    allocator: std.mem.Allocator,
    state_mutex: std.Thread.Mutex = .{},
    write_mutex: std.Thread.Mutex = .{},
    clients: std.ArrayList(*Client) = .empty,
    next_client_id: usize = 1,

    pub fn deinit(self: *Hub) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        for (self.clients.items) |client| {
            client.deinit(self.allocator);
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);
    }

    pub fn startClient(self: *Hub, stream: std.net.Stream, address: std.net.Address) !void {
        const client = try self.allocator.create(Client);
        errdefer self.allocator.destroy(client);

        self.state_mutex.lock();
        const client_id = self.next_client_id;
        self.next_client_id += 1;
        self.state_mutex.unlock();

        client.* = .{
            .id = client_id,
            .stream = stream,
            .address = address,
        };

        self.state_mutex.lock();
        var state_locked = true;
        errdefer if (state_locked) self.state_mutex.unlock();
        try self.clients.append(self.allocator, client);
        self.state_mutex.unlock();
        state_locked = false;

        const thread = std.Thread.spawn(.{}, clientThreadMain, .{ self, client }) catch |err| {
            self.write_mutex.lock();
            self.state_mutex.lock();
            for (self.clients.items, 0..) |item, index| {
                if (item.id == client.id) {
                    _ = self.clients.orderedRemove(index);
                    break;
                }
            }
            self.state_mutex.unlock();
            self.write_mutex.unlock();

            client.deinit(self.allocator);
            self.allocator.destroy(client);
            return err;
        };
        thread.detach();
    }

    pub fn runClient(self: *Hub, client: *Client) !void {
        try self.sendInitialHandshake(client);

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = client.stream.read(buffer[0..]) catch |err| switch (err) {
                error.ConnectionResetByPeer,
                error.SocketNotConnected,
                => return,
                else => return err,
            };
            if (bytes_read == 0) return;

            try client.buffer.append(self.allocator, buffer[0..bytes_read]);
            while (client.buffer.next()) |message| {
                if (message.len == 0) continue;
                try self.handleMessage(client, message);
            }
            client.buffer.compact();
        }
    }

    pub fn disconnectClient(self: *Hub, client: *Client) void {
        self.write_mutex.lock();

        var quit_message: ?[]u8 = null;
        var op_list_message: ?[]u8 = null;
        var recipients: std.ArrayList(*Client) = .empty;
        defer recipients.deinit(self.allocator);

        self.state_mutex.lock();
        for (self.clients.items, 0..) |item, index| {
            if (item.id == client.id) {
                _ = self.clients.orderedRemove(index);
                break;
            }
        }

        const was_operator = client.is_operator;
        if (client.nick) |nick| {
            quit_message = nmdc.makeQuit(self.allocator, nick) catch null;
        }
        if (was_operator) {
            _ = self.ensureOperatorLocked();
        }

        self.snapshotLoggedInClientsLocked(&recipients, null) catch {};
        op_list_message = self.makeCurrentOpListLocked() catch null;
        self.state_mutex.unlock();

        if (quit_message) |message| {
            self.sendManyUnlocked(recipients.items, message) catch {};
            self.allocator.free(message);
        }
        if (was_operator) {
            if (op_list_message) |message| {
                self.sendManyUnlocked(recipients.items, message) catch {};
                self.allocator.free(message);
            }
        }

        self.write_mutex.unlock();

        client.deinit(self.allocator);
        self.allocator.destroy(client);
    }

    fn handleMessage(self: *Hub, client: *Client, raw_message: []const u8) !void {
        switch (nmdc.parseMessage(raw_message)) {
            .chat => |chat| try self.handlePublicChat(client, chat, raw_message),
            .private_message => |message| try self.handlePrivateMessage(client, message, raw_message),
            .command => |command| try self.handleCommand(client, command),
            .unknown => {},
        }
    }

    fn handleCommand(self: *Hub, client: *Client, command: nmdc.ParsedCommand) !void {
        switch (command.kind) {
            .Lock,
            .Supports,
            .Key,
            .Version,
            .Hello,
            .HubName,
            .NickList,
            .OpList,
            .BotList,
            .LogedIn,
            .Quit,
            .Unknown,
            => {},
            .ValidateNick => try self.handleValidateNick(client, std.mem.trim(u8, command.payload, " ")),
            .GetNickList => try self.sendUserLists(client),
            .MyINFO => try self.handleMyInfo(client, command.payload),
        }
    }

    fn handleValidateNick(self: *Hub, client: *Client, requested_nick: []const u8) !void {
        if (requested_nick.len == 0) return;

        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var recipients: std.ArrayList(*Client) = .empty;
        defer recipients.deinit(self.allocator);
        var op_recipients: std.ArrayList(*Client) = .empty;
        defer op_recipients.deinit(self.allocator);

        var hello: ?[]u8 = null;
        defer if (hello) |message| self.allocator.free(message);
        var op_list: ?[]u8 = null;
        defer if (op_list) |message| self.allocator.free(message);

        self.state_mutex.lock();
        var state_locked = true;
        errdefer if (state_locked) self.state_mutex.unlock();

        if (client.nick) |existing| {
            self.state_mutex.unlock();
            state_locked = false;
            if (!std.mem.eql(u8, existing, requested_nick)) {
                const deny = try nmdc.makeValidateDenide(self.allocator, requested_nick);
                defer self.allocator.free(deny);
                try self.sendUnlocked(client, deny);
            }
            return;
        }

        if (self.findClientByNickLocked(requested_nick)) |_| {
            self.state_mutex.unlock();
            state_locked = false;
            const deny = try nmdc.makeValidateDenide(self.allocator, requested_nick);
            defer self.allocator.free(deny);
            try self.sendUnlocked(client, deny);
            return error.DuplicateNick;
        }

        client.nick = try self.allocator.dupe(u8, requested_nick);
        _ = self.ensureOperatorLocked();

        try self.snapshotLoggedInClientsLocked(&recipients, client.id);
        try self.snapshotLoggedInClientsLocked(&op_recipients, null);

        hello = try nmdc.makeHello(self.allocator, requested_nick);
        op_list = try self.makeCurrentOpListLocked();
        self.state_mutex.unlock();
        state_locked = false;

        try self.sendUnlocked(client, hello.?);
        try self.sendManyUnlocked(recipients.items, hello.?);
        try self.sendManyUnlocked(op_recipients.items, op_list.?);
    }

    fn handleMyInfo(self: *Hub, client: *Client, payload: []const u8) !void {
        const nick = client.nick orelse return;
        const parsed = nmdc.parseMyInfoPayload(payload) orelse {
            try self.sendStatusToClient(client, "Rejected malformed $MyINFO");
            return;
        };
        if (!std.mem.eql(u8, nick, parsed.nick)) {
            try self.sendStatusToClient(client, "Rejected $MyINFO with mismatched nick");
            return;
        }

        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var recipients: std.ArrayList(*Client) = .empty;
        defer recipients.deinit(self.allocator);
        var myinfo_message: ?[]u8 = null;
        defer if (myinfo_message) |message| self.allocator.free(message);

        self.state_mutex.lock();
        var state_locked = true;
        errdefer if (state_locked) self.state_mutex.unlock();

        if (client.myinfo) |*existing| existing.deinit(self.allocator);
        client.myinfo = null;
        client.myinfo = try nmdc.OwnedMyInfo.clone(self.allocator, parsed);
        myinfo_message = try nmdc.makeMyInfo(self.allocator, client.myinfo.?.view());
        try self.snapshotLoggedInClientsLocked(&recipients, client.id);
        self.state_mutex.unlock();
        state_locked = false;

        try self.sendManyUnlocked(recipients.items, myinfo_message.?);
    }

    fn handlePublicChat(self: *Hub, client: *Client, chat: nmdc.ChatLine, raw_message: []const u8) !void {
        const nick = client.nick orelse return;
        if (!std.mem.eql(u8, nick, chat.nick)) {
            try self.sendStatusToClient(client, "Rejected chat with mismatched nick");
            return;
        }

        const outbound = try std.fmt.allocPrint(self.allocator, "{s}|", .{raw_message});
        defer self.allocator.free(outbound);
        try self.broadcastLoggedIn(outbound, null);
    }

    fn handlePrivateMessage(
        self: *Hub,
        client: *Client,
        message: nmdc.PrivateMessage,
        raw_message: []const u8,
    ) !void {
        const sender = client.nick orelse return;
        if (!std.mem.eql(u8, sender, message.from)) {
            try self.sendStatusToClient(client, "Rejected private message with mismatched nick");
            return;
        }

        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var recipients: std.ArrayList(*Client) = .empty;
        defer recipients.deinit(self.allocator);
        var outbound: ?[]u8 = null;
        defer if (outbound) |message_text| self.allocator.free(message_text);

        self.state_mutex.lock();
        var state_locked = true;
        errdefer if (state_locked) self.state_mutex.unlock();

        if (self.findClientByNickLocked(message.target)) |target| {
            try recipients.append(self.allocator, target);
            if (target.id != client.id) {
                try recipients.append(self.allocator, client);
            }

            outbound = try std.fmt.allocPrint(self.allocator, "{s}|", .{raw_message});
            self.state_mutex.unlock();
            state_locked = false;
            try self.sendManyUnlocked(recipients.items, outbound.?);
            return;
        }

        self.state_mutex.unlock();
        state_locked = false;
        try self.sendStatusToClientUnlocked(client, "Requested user is offline");
    }

    fn sendInitialHandshake(self: *Hub, client: *Client) !void {
        const lock = try nmdc.makeLock(self.allocator, hub_lock, hub_pk);
        defer self.allocator.free(lock);

        const name = try nmdc.makeHubName(self.allocator, hub_name);
        defer self.allocator.free(name);

        const supports = try nmdc.makeSupports(self.allocator, &hub_supports);
        defer self.allocator.free(supports);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.sendUnlocked(client, lock);
        try self.sendUnlocked(client, name);
        try self.sendUnlocked(client, supports);
    }

    fn sendUserLists(self: *Hub, client: *Client) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var nick_slices: std.ArrayList([]const u8) = .empty;
        defer nick_slices.deinit(self.allocator);
        var myinfo_messages: std.ArrayList([]u8) = .empty;
        defer {
            for (myinfo_messages.items) |message| self.allocator.free(message);
            myinfo_messages.deinit(self.allocator);
        }
        var op_list: ?[]u8 = null;
        defer if (op_list) |message| self.allocator.free(message);
        var nick_list: ?[]u8 = null;
        defer if (nick_list) |message| self.allocator.free(message);

        self.state_mutex.lock();
        var state_locked = true;
        errdefer if (state_locked) self.state_mutex.unlock();

        for (self.clients.items) |other| {
            if (other.nick) |nick| {
                try nick_slices.append(self.allocator, nick);
            }
            if (other.myinfo) |*myinfo| {
                try myinfo_messages.append(self.allocator, try nmdc.makeMyInfo(self.allocator, myinfo.view()));
            }
        }

        nick_list = try nmdc.makeNickList(self.allocator, nick_slices.items);
        op_list = try self.makeCurrentOpListLocked();
        self.state_mutex.unlock();
        state_locked = false;

        try self.sendUnlocked(client, nick_list.?);
        try self.sendUnlocked(client, op_list.?);

        const bot_list = try nmdc.makeBotList(self.allocator, &hub_bots);
        defer self.allocator.free(bot_list);
        try self.sendUnlocked(client, bot_list);

        for (myinfo_messages.items) |message| {
            try self.sendUnlocked(client, message);
        }
    }

    fn sendStatusToClient(self: *Hub, client: *Client, text: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.sendStatusToClientUnlocked(client, text);
    }

    fn sendStatusToClientUnlocked(self: *Hub, client: *Client, text: []const u8) !void {
        const message = try nmdc.formatChatMessage(self.allocator, hub_bot, text);
        defer self.allocator.free(message);
        try self.sendUnlocked(client, message);
    }

    fn broadcastLoggedIn(self: *Hub, message: []const u8, excluded_id: ?usize) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        var recipients: std.ArrayList(*Client) = .empty;
        defer recipients.deinit(self.allocator);

        self.state_mutex.lock();
        var state_locked = true;
        errdefer if (state_locked) self.state_mutex.unlock();
        try self.snapshotLoggedInClientsLocked(&recipients, excluded_id);
        self.state_mutex.unlock();
        state_locked = false;

        try self.sendManyUnlocked(recipients.items, message);
    }

    fn ensureOperatorLocked(self: *Hub) bool {
        for (self.clients.items) |existing| {
            if (existing.is_operator and existing.nick != null) return false;
        }

        for (self.clients.items) |existing| {
            if (existing.nick != null) {
                existing.is_operator = true;
                return true;
            }
        }

        return false;
    }

    fn makeCurrentOpListLocked(self: *Hub) ![]u8 {
        var operators: std.ArrayList([]const u8) = .empty;
        defer operators.deinit(self.allocator);

        for (self.clients.items) |client| {
            if (!client.is_operator) continue;
            if (client.nick) |nick| {
                try operators.append(self.allocator, nick);
            }
        }

        return nmdc.makeOpList(self.allocator, operators.items);
    }

    fn snapshotLoggedInClientsLocked(
        self: *Hub,
        recipients: *std.ArrayList(*Client),
        excluded_id: ?usize,
    ) !void {
        for (self.clients.items) |other| {
            if (other.nick == null) continue;
            if (excluded_id) |id| {
                if (other.id == id) continue;
            }
            try recipients.append(self.allocator, other);
        }
    }

    fn findClientByNickLocked(self: *Hub, nick: []const u8) ?*Client {
        for (self.clients.items) |client| {
            if (client.nick) |existing| {
                if (std.mem.eql(u8, existing, nick)) return client;
            }
        }
        return null;
    }

    fn sendManyUnlocked(self: *Hub, recipients: []const *Client, message: []const u8) !void {
        for (recipients) |recipient| {
            try self.sendUnlocked(recipient, message);
        }
    }

    fn sendUnlocked(self: *Hub, client: *Client, message: []const u8) !void {
        _ = self;

        client.stream.writeAll(message) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            => {},
            else => return err,
        };
    }
};

fn clientThreadMain(hub: *Hub, client: *Client) void {
    hub.runClient(client) catch |err| {
        std.debug.print("Client session error for {any}: {}\n", .{ client.address, err });
    };
    hub.disconnectClient(client);
}

test "operator list includes promoted operator" {
    var hub = Hub{ .allocator = std.testing.allocator };
    const client = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(client);

    client.* = .{
        .id = 1,
        .stream = undefined,
        .address = undefined,
        .nick = try std.testing.allocator.dupe(u8, "alice"),
    };
    defer std.testing.allocator.free(client.nick.?);

    try hub.clients.append(std.testing.allocator, client);
    defer hub.clients.deinit(std.testing.allocator);

    try std.testing.expect(hub.ensureOperatorLocked());
    try std.testing.expect(client.is_operator);

    const op_list = try hub.makeCurrentOpListLocked();
    defer std.testing.allocator.free(op_list);

    try std.testing.expectEqualStrings("$OpList alice|", op_list);
}
