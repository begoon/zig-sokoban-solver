# CLAUDE.md

## Project overview

Zig 0.16 Sokoban puzzle solver. Single-file implementation in `main.zig`.

## Build & run

```
zig build              # build (ReleaseFast)
zig build run -- 1     # solve maze 1
zig build test         # run tests (mazes 0, 1, 40 + unit tests)
```

## Map file

`sokoban-maps-60.txt` - 61 mazes (0-60), embedded at compile time via `@embedFile`.

Encoding: `X` wall, `@` player, `*` box (off target), `.` target, `&` box on target, space = empty.

## Architecture

- **State representation**: Player position (`Pos`) + box positions (`BitBoard` - array of u64 bitmask over grid cells).
- **Search**: A* with priority queue. States keyed by normalized player + box bitboard hash (u64).
- **Heuristic**: Optimal box-to-target assignment via bitmask DP (O(n * 2^n), admissible for n <= 16 boxes).
- **Deadlock pruning**: Dead cell detection (reverse BFS from targets), 2x2 freeze deadlock.
- **Player normalization**: Flood-fill reachable area, pick minimum position. Deduplicates states where player is in same reachable region.
- **Output**: Lowercase `udlr` = walk steps, uppercase `UDLR` = push steps. Full path verified by `verifyPath`.

## Zig 0.16 API notes

- `std.ArrayList(T)` is now unmanaged (no allocator stored). Use `std.array_list.Managed(T)` for managed version.
- `main` accepts `std.process.Init`. Use `init.gpa` for temporary allocations and `init.arena.allocator()` for process-lifetime allocations.
- Read command-line arguments with `init.minimal.args.toSlice(init.arena.allocator())`.
- `std.debug.print` writes to stderr. For stdout, use `std.Io.File.Writer.init(.stdout(), init.io, &buffer)`, access `.interface`, and flush after writing.
- `std.AutoHashMap` is still managed (stores allocator).
- `std.PriorityQueue` is unmanaged: use `initContext`, pass an allocator to `push` and `deinit`, and remove items with `pop`.

## Performance

- Mazes up to ~8 boxes: seconds.
- 10+ boxes: may hit 5M state limit. State space grows combinatorially.
- Main bottleneck: A* heuristic doesn't discriminate enough for large open maps - degrades toward BFS.

## Key files

- `main.zig` - everything: parser, solver, tests
- `sokoban-maps-60.txt` - puzzle data
- `build.zig` / `build.zig.zon` - build config
