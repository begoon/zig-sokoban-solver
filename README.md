# Sokoban Solver

A Sokoban puzzle solver written in Zig 0.16. Reads mazes from a bundled map file and outputs a complete player movement sequence to solve the puzzle.

## Building

Requires Zig 0.16.0.

```sh
zig build
```

## Browser visualizer

```sh
zig build web
python3 -m http.server 8000 --bind 127.0.0.1 --directory zig-out/web
```

Open http://127.0.0.1:8000/ (or run `just serve`). The browser fetches
`sokoban-maps-60.txt`; the same fetched text is passed to the WebAssembly solver.

- Select a map from the menu, arrow buttons, or left/right arrow keys. Arrow keys
  keep their normal cursor behavior inside the solution text area. The selected
  map number is saved in localStorage and restored on the next visit.
- Maps share a preview area sized from the largest map, anchored at the top left.
- Paste a solution and choose **Run** to play at five steps per second. Whitespace
  is ignored; invalid moves are reported before playback starts.
- **Stop** stops playback or cancels an active solve. Run restarts from the initial
  position. Changing maps also stops active work and clears the solution.
- **Solve** runs the existing Zig algorithm in a Web Worker, displays analysed
  states, and fills the solution area when finished. Choose Run to play it.

The static site consists of `index.html`, `script.js`, `solver.wasm`, and the map
file, all emitted into `zig-out/web`. Serve that directory over HTTP; opening the
HTML as a `file://` URL will not work with module workers and fetch. Serving the
repository root also works: `just wasm` and `zig build web` refresh the root
`solver.wasm` as well as the copy in `zig-out/web`. For GitHub Pages, publish
`main` → `/ (root)` and commit the updated `solver.wasm` with source changes.
The root `.nojekyll` file disables Jekyll processing. No application
server, JavaScript framework, or external assets are required. The worker uses
no time limit or state-count caps: Stop controls cancellation. It uses a fixed
4095 MiB memory limit, shown beside Solve. This caps both live search allocations
and the imported WebAssembly memory. Memory grows as needed rather than being
fully allocated upfront. The maximum is one MiB below 4 GiB so WASM32 byte counts
remain representable. Browser overhead is additional.
Allocator growth and retained memory can exhaust the WASM ceiling before the
live allocation budget is reached. The UI reports which memory limit stopped
the search and its limit; neither result proves the puzzle unsolvable.

```sh
zig build web
bun test scripts/web.test.js
```

Browser integration logic is tested in Bun: all maps, playback validation,
WASM solutions and progress, custom fetched map data, and real worker-thread
cancellation. These tests do not automate the browser UI.

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
