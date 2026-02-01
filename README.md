# Zig NMDC Workspace

This workspace contains three Zig projects:

- **lib/**: NMDC protocol library (reusable Zig package)
- **server/**: NMDC server application
- **client/**: NMDC client application

Each project is initialized as a separate Zig package. The library can be imported by the server and client for NMDC protocol functionality.

## Build Instructions

- To build any project, run `zig build` in its directory.
- To link the library in server/client, edit their `build.zig` files to add the library as a module.

## Next Steps

- Implement NMDC protocol logic in `lib/src/`
- Reference the library in server/client `build.zig`
- Develop server and client logic in their respective `src/` folders
