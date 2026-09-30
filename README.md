# Sokoban Solver

A Sokoban puzzle solver written in Zig 0.16. Reads mazes from a bundled map file and outputs a complete player movement sequence to solve the puzzle.

## Building

Requires Zig 0.16.0.

```sh
zig build
```

## Usage

```sh
zig build run -- <maze_number>
```

The maze number corresponds to the "Maze: N" entries in `sokoban-maps-60.txt` (0-60). All bundled maps fit the supported limits of 30×22 cells and 40 boxes. Oversized maps and invalid player/box counts are rejected.

### Example

```sh
$ zig build run -- 1
Maze 1 (22x11, 6 boxes)
Solving...
  solved after 38337 states explored
Solution (578 steps, 116 pushes):
```

The next line contains the complete movement sequence.

### Search limits

Defaults are 5 million expanded states, 1 million stored nodes (including replaced
paths retained for reconstruction), and 256 MiB of live search allocations.
Allocator metadata and stack memory are additional, so the allocation budget is
not a strict process RSS limit.

```sh
zig build run -- 40 --max-expanded 5000000 --max-stored 2000000 --memory-mib 512
```

The executable exits with status 2 and reports that solvability is unknown when a
limit is reached. `No solution found.` means the search proved the puzzle
unsolvable, rather than exhausting a resource budget. Invalid arguments exit 1.

### Output format

The solution is a string of movement characters:

- **Lowercase** (`u`, `d`, `l`, `r`) — player walks (no box pushed)
- **Uppercase** (`U`, `D`, `L`, `R`) — player pushes a box

Directions: **U**p, **D**own, **L**eft, **R**ight.

## Map encoding

| Symbol | Meaning |
|--------|---------|
| `X` | Wall |
| `@` | Player |
| `*` | Box (not on target) |
| `.` | Target |
| `&` | Box on target |
| ` ` | Empty floor |

## Algorithm

The solver uses **A\* search** over the push state space, minimizing pushes rather than total player steps:

1. **State**: (normalized player position, set of box positions). Hash collisions are resolved by comparing the complete state. The best known push count is tracked; cheaper paths reopen states, and stale queue entries are skipped. Equal `f` scores prefer deeper states, with insertion order as a deterministic final tie-break.
2. **Player normalization**: Two states with the same box layout where the player is in the same reachable region are treated as identical. This is computed via a bitboard flood-fill over precomputed floor neighbors, picking the smallest reachable cell index.
3. **Heuristic**: Minimum-weight bipartite matching of boxes to targets. Up to 8 boxes use bitmask DP; larger puzzles use the `O(n³)` Hungarian algorithm. Both give an exact assignment cost and an admissible lower bound on remaining pushes.
4. **Deadlock pruning**:
   - **Dead cells**: Precomputed via reverse BFS from targets. A cell is "dead" if a single box placed there can never reach any target through any sequence of pushes.
   - **Assignment deadlock**: Prunes states with no complete assignment of boxes to distinct reachable targets.
   - **Freeze deadlock**: Detects blocked 2×2 regions and immovable groups of boxes. The group check repeatedly removes boxes that could move with other removed boxes absent; any remaining off-target box proves a deadlock.
5. **Path reconstruction**: After finding the push sequence, the solver reconstructs the full player path by BFS-pathing between consecutive push positions.

## Performance

Local Apple Silicon/macOS measurements with Zig 0.16.0, ReleaseFast, median of
five runs (September 2026). Baseline is commit `31f0658`; timings vary by machine.

| Maze | Baseline time | Improved time | States before → after | Pushes |
|------|---------------|---------------|-----------------------|--------|
| 1 | 0.235s | 0.069s | 98,019 → 38,337 | 116 |
| 40 | 1.445s | 0.273s | 254,011 → 52,190 | 81 |

A single full-suite run with a two-second timeout per map solved mazes 0, 1, and 40
in both builds. The baseline timed out on 51 maps and crashed on 7 maps whose box
counts exceeded its arrays. The improved build hit a resource budget on 15
maps and timed out on 43, with no crashes. Every returned solution was verified.
This short benchmark demonstrates faster existing solves and safe handling of
large maps, not increased coverage of the difficult puzzles.

Larger puzzles can still exhaust the configured search limits. Exact matching avoids the old exponential assignment cost, but the number of box arrangements remains large.

## Tests

```sh
zig build test
```

Tests verify solutions for mazes 0, 1, and 40, parse all 61 bundled maps, and compare
A* with an independent player-step Dijkstra solver on 348 small boards. Assignment
algorithms are checked against exhaustive permutations. Tests also cover hash
collisions, search limits, parser validation, and cleanup at every allocation
failure point in a small search.

To benchmark all maps with a per-map timeout and independently verify each
returned movement sequence (Python 3 required):

```sh
zig build
python3 scripts/benchmark.py --timeout 2 --output /tmp/sokoban-results.json
```

Use `--mazes 0 1 40` for a subset or `--binary /path/to/sokoban-solver` to compare
another build. Results distinguish solutions, proven unsolvability, resource
limits, timeouts, and errors.
