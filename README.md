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

The maze number corresponds to the "Maze: N" entries in `sokoban-maps-60.txt` (0-60).

### Example

```sh
$ zig build run -- 1
Maze 1 (22x11, 6 boxes)
Solving...
  solved after 98019 states explored
Solution (746 steps, 116 pushes):
ullluuuLLUllDlldddrRR...
```

or

```sh
zig build run -- 40
Maze 40 (11x11, 8 boxes)
Solving...
  explored 100000 states, queue 219689, f=81
  explored 200000 states, queue 450241, f=81
  solved after 254011 states explored
Solution (546 steps, 81 pushes):
dDulLLLDDrdrrrdDuullullulluRdrdrddrddLruuuulluluRddrddldlluuUdddrddlUUUUddrruruuluullldRurrddrddrddlLuuruulDrdrddllulluuRRurDrrrddrdLLruuullulluuRldddrrrrdddlLLruuullllddrrUdllddrUluRluurRuuurRllddrrddddlLrruuuulluurrRllllldRurrrrdrDDllullddRUrrrDDuullllllddddrUrUUrurrrddrdLLLrruuullldlddlluRdrUlluurRllUdrruRldllddrrUrUrrruululllDurrrdrdddddllLLulluurRddllddrUluRdrrrrruuuuuluurDDDuullllllldRddrrRllluuurrdDuulldddrRuuurrrdrdDuuulllldddlldddrrUlluuuuurrrrrdrddDuuuulllllldRlddddrrUdlluuuuurrrrrdrdddDrdLLruuuuuullllDurrrdrdddddlLLLullddrUluRdrU
```

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
2. **Player normalization**: Two states with the same box layout where the player is in the same reachable region are treated as identical. This is computed via flood-fill, picking the lexicographically smallest reachable cell.
3. **Heuristic**: Minimum-weight bipartite matching of boxes to targets using bitmask DP — `O(n * 2^n)` where n is the number of boxes. This gives an admissible lower bound on remaining pushes.
4. **Deadlock pruning**:
   - **Dead cells**: Precomputed via reverse BFS from targets. A cell is "dead" if a single box placed there can never reach any target through any sequence of pushes.
   - **Freeze deadlock**: Detects 2x2 blocks of walls/boxes where at least one box is not on a target (frozen and unsolvable).
5. **Path reconstruction**: After finding the push sequence, the solver reconstructs the full player path by BFS-pathing between consecutive push positions.

## Performance

| Maze | Boxes | States explored | Time |
|------|-------|----------------|------|
| 0 | 2 | 1 | instant |
| 1 | 6 | 98K | ~2s |
| 40 | 8 | 254K | ~6s |

Puzzles with up to ~8 boxes typically solve within seconds. Puzzles with 10+ boxes may exceed the 5 million state limit due to combinatorial state space growth.

## Tests

```sh
zig build test
```

Tests parse and solve mazes 0, 1, and 40, verifying each solution by simulating every step. Additional unit tests cover dead cell detection, error handling, and input validation.
