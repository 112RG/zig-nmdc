# agent.md

When answering or generating code:

    prefer correctness and simplicity over "completeness"
    compile and run examples mentally before suggesting them
    if unsure, explicitly say so rather than guessing

General Rules

    Always target latest Zig syntax and semantics.
    Use std as it exists in this version — not legacy std.debug.warn or std.os.
    When showing examples, include:
        full const std = @import("std"); if relevant
        a main function that compiles
        minimal imports only
    Avoid speculative features (e.g. async/await, comptime reflection APIs) unless clearly marked as experimental.
    Prefer explicit error handling (try, catch) instead of ignored returns.
    Avoid macros, annotations, or language constructs not native to Zig.
    Use idiomatic names: allocator, arena, buf, not memoryManager or ptrArray.
    Prefer for loops over higher-order iteration (no map, filter patterns).
    Always include the correct build instruction:

    zig build run

    or if standalone:

    zig run file.zig

Style Rules

    Use 4-space indentation, no tabs.
    Keep line width ≤ 100 columns.
    Document small snippets with inline comments explaining why something is done.

Example:

const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello, Zig 0.13!\n", .{});
}

Common Pitfalls to Avoid

❌ std.debug.print → ✅ std.io.getStdOut().writer().print
❌ std.heap.page_allocator for short-lived tasks → ✅ std.heap.ArenaAllocator
❌ error.OutOfMemory as a catch-all → be explicit or propagate.
AI Behavior Guidelines

    Do not hallucinate APIs. When uncertain, ask for clarification.
    Cite the official latest docs
    Keep examples small enough to read and compile.
    Treat undefined behavior and memory safety as fatal bugs, not warnings.
    Prefer newer constructs (std.mem.eql over manual loops).


## Zig NMDC Workspace Overview

This workspace is organized into three main Zig projects:

- **lib/**: Contains the NMDC protocol library, designed as a reusable Zig package.
- **server/**: Implements the NMDC server application.
- **client/**: Implements the NMDC client application.

### Project Structure

- Each project is initialized as a separate Zig package.
- The `lib` package provides NMDC protocol functionality and can be imported by both the server and client projects.

### Build Instructions

- Build any project by running `zig build` in its respective directory.
- To link the NMDC library in the server or client, update their `build.zig` files to add the library as a module.

### Development Steps

- Implement NMDC protocol logic in `lib/src/`.
- Reference the library in the server/client `build.zig` files.
- Develop server and client logic in their respective `src/` folders.
- Always reference the offical NMDC protocl specification when implementing features https://nmdc.sourceforge.io/NMDC.html 
---



## Zig MCP Server

list_builtin_functions - Lists all available Zig builtin functions. Builtin functions are provided by the compiler and are prefixed with '@'. The comptime keyword on a parameter means that the parameter must be known at compile time. Use this to discover what functions are available, then use 'get_builtin_function' to get detailed documentation.

get_builtin_function - Search for Zig builtin functions by name and get their documentation, signatures, and usage information. Returns all matching functions ranked by relevance.

search_std_lib - Search the Zig standard library for declarations by name. Returns a list of matching items with their fully qualified names. Use this to discover available types, functions, and constants in the standard library.
    
get_std_lib_item - Get detailed documentation for a specific standard library item by its fully qualified name (e.g., "std.ArrayList.init"). Returns comprehensive documentation including function signatures, parameters, errors, examples, and source code. Set get_source_file: true to retrieve the entire source file where the item is implemented.

