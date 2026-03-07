# NMDC Library

Shared NMDC protocol library for the client and server packages.

## Includes

- message framing helpers
- command and chat parsing
- `$Lock` key calculation
- public chat escaping/decoding
- private message parsing/building
- `$MyINFO` parsing/building
- common NMDC message builders for hub/client traffic

## Test

```bash
zig build test
```
