# NMDC Client

Terminal NMDC client implemented in Zig.

## Features

- raw terminal UI
- tabs for **Logs**, **Chat**, and **PMs**
- public chat send/receive
- private message receive and `/msg <nick> <message>` send support
- op and bot highlighting
- shared protocol handling via `../lib`

## Run

```bash
zig build run -- 127.0.0.1 4111 TestBot
```

Arguments:

1. host
2. port
3. nick

## Test

```bash
zig build test
```
