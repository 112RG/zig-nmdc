# NMDC Server

Minimal NMDC hub implemented in Zig.

## Features

- accepts multiple clients
- validates nicknames
- rebroadcasts public chat
- routes private messages
- stores and rebroadcasts `$MyINFO`
- sends `$NickList`, `$OpList`, and `$BotList`
- uses shared protocol code from `../lib`

## Run

```bash
zig build run -- 127.0.0.1 4111
```

Arguments:

1. host
2. port

## Test

```bash
zig build test
```
