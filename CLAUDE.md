# CLAUDE.md

## Project overview

Zig 0.16 Sokoban puzzle solver. Core solver in `main.zig`; browser UI in `index.html` and `script.js`, with a thin WASM adapter in `wasm.zig`.

## Build & run

```
zig build              # build (ReleaseFast)
zig build run -- 1     # solve maze 1
zig build test         # solutions, small-board oracle, matching, limits, parser tests
zig build web          # static site + solver.wasm in zig-out/web
just serve             # build and serve browser UI on localhost:8000
just test-web          # WASM/playback/worker tests (Bun)
```

## Map file

`sokoban-maps-60.txt` - 61 mazes (0-60), embedded at compile time via `@embedFile`.

Encoding: `X` wall, `@` player, `*` box (off target), `.` target, `&` box on target, space = empty.

## Architecture

- **State representation**: Player position (`Pos`) + box positions (`BitBoard` - array of u64 bitmask over grid cells).
- **Search**: A* with priority queue. Full states keyed by normalized player + box bitboard, with hash collisions resolved by equality. Track best paths, reopen cheaper states, and skip stale queue entries. Equal f scores prefer deeper states.
- **Heuristic**: Exact box-to-target assignment: bitmask DP up to 8 boxes, O(n³) Hungarian above that. Infeasible matchings are pruned.
- **Deadlock pruning**: Dead cell detection (reverse BFS from targets), assignment infeasibility, 2x2 freeze deadlock, conservative immovable-group detection.
- **Player normalization**: Bitboard flood-fill over precomputed neighbors, pick minimum cell index. Deduplicates states where player is in same reachable region.
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
- Default budgets: 5M expansions, 1M stored nodes, 256 MiB live search allocations. CLI flags override them; exhaustion exits 2 and does not imply unsolvability.
- Larger/open puzzles still have large equal-f search frontiers. Benchmark changes with `python3 scripts/benchmark.py --timeout 2 --output /tmp/results.json`.

## Key files

- `main.zig` - shared parser, solver, native CLI, tests
- `wasm.zig` - fetched map input, exported solver/result API, progress import
- `index.html` / `script.js` - map preview, playback, Web Worker solver
- `scripts/web.test.js` - WASM and playback integration tests
- `sokoban-maps-60.txt` - puzzle data
- `build.zig` / `build.zig.zon` - build config
- `scripts/benchmark.py` - timeout-bounded full-map benchmark with independent solution verification
