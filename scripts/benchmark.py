#!/usr/bin/env python3
"""Benchmark bundled mazes with a per-maze timeout and verify every solution."""
import argparse
import json
import re
import subprocess
import time
from pathlib import Path


def verify(board, path):
    walls, targets, boxes = set(), set(), set()
    player = None
    for y, row in enumerate(board.splitlines()):
        for x, ch in enumerate(row):
            pos = (x, y)
            if ch == "X":
                walls.add(pos)
            if ch in ".&":
                targets.add(pos)
            if ch in "*&":
                boxes.add(pos)
            if ch == "@":
                player = pos
    assert player is not None
    width = max(map(len, board.splitlines()))
    height = len(board.splitlines())
    for ch in path:
        dx, dy = {"u": (0, -1), "d": (0, 1), "l": (-1, 0), "r": (1, 0)}[ch.lower()]
        dest = (player[0] + dx, player[1] + dy)
        assert 0 <= dest[0] < width and 0 <= dest[1] < height
        assert dest not in walls
        assert ch.isupper() == (dest in boxes)
        if dest in boxes:
            box_dest = (dest[0] + dx, dest[1] + dy)
            assert 0 <= box_dest[0] < width and 0 <= box_dest[1] < height
            assert box_dest not in walls and box_dest not in boxes
            boxes.remove(dest)
            boxes.add(box_dest)
        player = dest
    assert boxes == targets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/sokoban-solver")
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mazes", type=int, nargs="+")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    root = Path(__file__).resolve().parent.parent
    maps = (root / "sokoban-maps-60.txt").read_text()
    boards = {}
    for match in re.finditer(r"Maze: (\d+)\n.*?\n\n(.*?)(?:\n\n|\Z)", maps, re.S):
        boards[int(match[1])] = match[2]
    results = []
    for maze in args.mazes if args.mazes is not None else sorted(boards):
        start = time.perf_counter()
        row = {"maze": maze}
        try:
            proc = subprocess.run(
                [str(Path(args.binary).resolve()), str(maze)],
                capture_output=True, text=True, timeout=args.timeout,
            )
            output = proc.stdout + proc.stderr
            solution = re.search(r"Solution \((\d+) steps, (\d+) pushes\):\n([udlrUDLR]*)", output)
            if solution:
                assert proc.returncode == 0, output
                verify(boards[maze], solution[3])
                assert len(solution[3]) == int(solution[1])
                assert sum(ch.isupper() for ch in solution[3]) == int(solution[2])
                row.update(status="solved", steps=int(solution[1]), pushes=int(solution[2]))
            elif "Search limit reached" in output or "state limit reached" in output:
                row["status"] = "limit"
            elif proc.returncode == 0 and "No solution found" in output:
                row["status"] = "unsolvable"
            else:
                row.update(status="error", exit_code=proc.returncode, output=output)
            expanded = re.search(r"solved after (\d+) states", output)
            if expanded:
                row["expanded"] = int(expanded[1])
        except subprocess.TimeoutExpired:
            row["status"] = "timeout"
        row["seconds"] = round(time.perf_counter() - start, 4)
        results.append(row)
        args.output.write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(row), flush=True)
    if any(row["status"] == "error" for row in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
