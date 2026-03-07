<h1 align="center">zig-nmdc</h1>
<div align="center"

[![license](https://img.shields.io/github/license/112RG/zig-nmdc)](https://github.com/112RG/zig-nmdc/blob/master/LICENSE)
![GitHub repo size](https://img.shields.io/github/repo-size/112RG/zig-nmdc)
![Lines of Code](https://aschey.tech/tokei/github/112RG/zig-nmdc)
</div>

# Zig NMDC Workspace

A small Zig workspace for experimenting with the NMDC (Direct Connect) protocol.

It currently includes:

- a shared NMDC protocol library
- a terminal client with a tabbed TUI
- a minimal multi-user hub focused on chat and private messages

File transfer is intentionally not implemented yet.

## Workspace layout

- **lib/** — shared NMDC protocol code used by both client and server
- **client/** — terminal NMDC client
- **server/** — minimal NMDC hub

## Current features

### Shared library

The shared library in **lib/** provides reusable NMDC helpers for:

- command classification and parsing
- stream framing with pipe-delimited message buffering
- `$Lock` → `$Key` calculation
- public chat formatting and decoding
- private message parsing and formatting
- `$MyINFO` parsing and rebuilding
- `$NickList`, `$OpList`, `$BotList`, `$Quit`, `$Hello`, and related helpers

### Client

The client in **client/** currently supports:

- raw terminal TUI
- tabbed views for **Logs**, **Chat**, and **PMs**
- public chat send/receive
- private message receive and send via `/msg <nick> <message>`
- op and bot list highlighting
- NMDC login flow:
  - `$Lock`
  - `$Key`
  - `$ValidateNick`
  - `$Hello`
  - `$Version`
  - `$GetNickList`
  - `$MyINFO`

### Server

The server in **server/** is a minimal hub intended for local testing and development.

It currently supports:

- multiple connected clients
- nickname validation
- public chat rebroadcast
- private message routing
- storing and rebroadcasting `$MyINFO`
- generated `$NickList`, `$OpList`, and `$BotList`
- simple operator assignment

## Zig version

Target the current Zig toolchain used by this workspace.

If you are building manually, use:

```bash
zig build
zig build test
```

## Quick start

### Run the hub

From the server package:

```bash
cd server
zig build run
```

Default listen address:

- host: `127.0.0.1`
- port: `4111`

You can also pass a custom host and port:

```bash
cd server
zig build run -- 127.0.0.1 4111
```

### Run the client

From the client package:

```bash
cd client
zig build run -- 127.0.0.1 4111 TestBot
```

Arguments are:

1. host
2. port
3. nick

If omitted, the client uses its built-in defaults.

## Client usage

Inside the client:

- type plain text in the **Chat** tab to send public chat
- use `Tab` to switch between **Logs**, **Chat**, and **PMs**
- use `/msg <nick> <message>` to send a private message
- in the **PMs** tab, plain text is not sent as public chat
- press `Ctrl+C` to exit

## Testing

Run tests per package:

```bash
cd lib && zig build test
cd client && zig build test
cd server && zig build test
```

## Scope

This workspace is focused on the NMDC chat/login side of the protocol.

Not implemented yet:

- file transfers
- search
- download/upload management
- richer hub administration

