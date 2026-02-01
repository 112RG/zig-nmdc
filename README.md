# Zig NMDC Workspace

A workspace containing a Direct Connect (NMDC) protocol implementation in Zig, featuring a client with a TUI and a basic referenced server.

## Projects

- **lib/**: Core NMDC protocol library (reusable package). Handles command parsing, key calculation ($Lock -> $Key), and formatting.
- **client/**: NMDC Client application.
  - Interactive TUI (Terminal User Interface) with raw mode.
  - Multi-threaded architecture (Input vs Network).
  - Implements Handshake ($Lock, $Key, $ValidateNick) and Login ($Version, $GetNickList, $MyINFO).
  - Supports Chat and Raw command injection (`/raw`).
- **server/**: Basic NMDC Server (Hub) implementation for testing.

## Prerequisites

- Zig `0.15.0-dev` (or compatible nightly).

## Usage

A `Makefile` is provided for convenience.

### Build All
```bash
make all
```

### Run Client
Connects to `127.0.0.1:411` by default.
```bash
make run-client
```
*Note: Make sure a local hub (like PtokaX or the `server` project) is running on port 411, or adjust `port` in `client/src/main.zig`.*

### Run Server
Listens on port `4111` (default).
```bash
make run-server
```

## Client Commands

Once running, the client supports the following input:

- **Chat**: standard text sent to the hub.
- **/quit**: Disconnect and exit.
- **/raw <cmd>**: Send raw protocol command (e.g., `/raw $GetNickList`).

## Development Status

- **Protocol**: Basic signaling and Handshake implemented. File transfers not yet supported.
- **TUI**: Raw mode enabled with clean log/prompt separation.

