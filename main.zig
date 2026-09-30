const std = @import("std");

const Cell = enum(u2) { empty = 0, wall = 1, target = 2 };

const Dir = enum(u2) {
    up = 0,
    down = 1,
    left = 2,
    right = 3,

    fn delta(self: Dir) [2]i8 {
        return switch (self) {
            .up => .{ -1, 0 },
            .down => .{ 1, 0 },
            .left => .{ 0, -1 },
            .right => .{ 0, 1 },
        };
    }

    fn pushLabel(self: Dir) u8 {
        return switch (self) {
            .up => 'U',
            .down => 'D',
            .left => 'L',
            .right => 'R',
        };
    }

    fn walkLabel(self: Dir) u8 {
        return switch (self) {
            .up => 'u',
            .down => 'd',
            .left => 'l',
            .right => 'r',
        };
    }
};
const dirs = [_]Dir{ .up, .down, .left, .right };

const MAX_W = 30;
const MAX_H = 22;
const MAX_CELLS = MAX_W * MAX_H;
const MAX_BOXES = 24;

const Pos = packed struct {
    row: u8,
    col: u8,

    fn eql(a: Pos, b: Pos) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }

    fn move(self: Pos, dir: Dir) ?Pos {
        const d = dir.delta();
        const nr = @as(i16, self.row) + d[0];
        const nc = @as(i16, self.col) + d[1];
        if (nr < 0 or nc < 0 or nr >= MAX_H or nc >= MAX_W) return null;
        return .{ .row = @intCast(nr), .col = @intCast(nc) };
    }

    fn idx(self: Pos) u16 {
        return @as(u16, self.row) * MAX_W + self.col;
    }
};

// Bitboard for box positions: 660 cells fits in 11 u64s
const BB_WORDS = (MAX_CELLS + 63) / 64;
const BitBoard = [BB_WORDS]u64;

fn bbEmpty() BitBoard {
    return .{0} ** BB_WORDS;
}

fn bbSet(bb: *BitBoard, i: u16) void {
    bb[i / 64] |= @as(u64, 1) << @intCast(i % 64);
}

fn bbClear(bb: *BitBoard, i: u16) void {
    bb[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
}

fn bbTest(bb: *const BitBoard, i: u16) bool {
    return (bb[i / 64] & (@as(u64, 1) << @intCast(i % 64))) != 0;
}

fn bbEql(a: *const BitBoard, b: *const BitBoard) bool {
    return std.mem.eql(u64, a, b);
}

fn bbHash(bb: *const BitBoard) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(bb));
    return h.final();
}

fn bbCount(bb: *const BitBoard) u32 {
    var c: u32 = 0;
    for (bb.*) |w| c += @popCount(w);
    return c;
}

const Grid = struct {
    cells: [MAX_H][MAX_W]Cell,
    targets: [MAX_BOXES]Pos,
    target_count: u8,
    width: u8,
    height: u8,
    dead_cell: [MAX_CELLS]bool,
    // BFS distance from each target to every cell (ignoring boxes, just walls)
    target_dist: [MAX_BOXES][MAX_CELLS]u16,

    fn isWall(self: *const Grid, p: Pos) bool {
        if (p.row >= self.height or p.col >= self.width) return true;
        return self.cells[p.row][p.col] == .wall;
    }

    fn isTarget(self: *const Grid, p: Pos) bool {
        if (p.row >= self.height or p.col >= self.width) return false;
        return self.cells[p.row][p.col] == .target;
    }

    fn computeDeadCells(self: *Grid) void {
        @memset(&self.dead_cell, true);
        var alive: [MAX_CELLS]bool = .{false} ** MAX_CELLS;

        for (self.targets[0..self.target_count]) |target| {
            if (alive[target.idx()]) continue;
            var queue: [MAX_CELLS]Pos = undefined;
            var head: u16 = 0;
            var tail: u16 = 0;
            alive[target.idx()] = true;
            queue[tail] = target;
            tail += 1;

            while (head < tail) {
                const cur = queue[head];
                head += 1;
                for (dirs) |dir| {
                    const d = dir.delta();
                    const from_r = @as(i16, cur.row) - d[0];
                    const from_c = @as(i16, cur.col) - d[1];
                    const player_r = @as(i16, cur.row) - 2 * @as(i16, d[0]);
                    const player_c = @as(i16, cur.col) - 2 * @as(i16, d[1]);
                    if (from_r < 0 or from_c < 0 or from_r >= self.height or from_c >= self.width) continue;
                    if (player_r < 0 or player_c < 0 or player_r >= self.height or player_c >= self.width) continue;
                    const from_pos = Pos{ .row = @intCast(from_r), .col = @intCast(from_c) };
                    const player_pos = Pos{ .row = @intCast(player_r), .col = @intCast(player_c) };
                    if (self.isWall(from_pos) or self.isWall(player_pos)) continue;
                    if (!alive[from_pos.idx()]) {
                        alive[from_pos.idx()] = true;
                        queue[tail] = from_pos;
                        tail += 1;
                    }
                }
            }
        }

        for (0..MAX_CELLS) |i| {
            const r: u8 = @intCast(i / MAX_W);
            const c: u8 = @intCast(i % MAX_W);
            if (r >= self.height or c >= self.width) {
                self.dead_cell[i] = true;
            } else if (self.cells[r][c] == .wall) {
                self.dead_cell[i] = true;
            } else {
                self.dead_cell[i] = !alive[i];
            }
        }
    }

    /// Precompute BFS distances from each target to all cells (push distance).
    /// This computes how many pushes a single box needs to reach target t from cell c.
    fn computeTargetDistances(self: *Grid) void {
        for (0..self.target_count) |ti| {
            @memset(&self.target_dist[ti], 0xFFFF);
            const target = self.targets[ti];
            var queue: [MAX_CELLS]Pos = undefined;
            var head: u16 = 0;
            var tail: u16 = 0;

            self.target_dist[ti][target.idx()] = 0;
            queue[tail] = target;
            tail += 1;

            while (head < tail) {
                const cur = queue[head];
                head += 1;
                const cur_dist = self.target_dist[ti][cur.idx()];

                for (dirs) |dir| {
                    const d = dir.delta();
                    // Reverse push: box at cur was pushed from cur-D, player at cur-2D
                    const from_r = @as(i16, cur.row) - d[0];
                    const from_c = @as(i16, cur.col) - d[1];
                    const player_r = @as(i16, cur.row) - 2 * @as(i16, d[0]);
                    const player_c = @as(i16, cur.col) - 2 * @as(i16, d[1]);
                    if (from_r < 0 or from_c < 0 or from_r >= self.height or from_c >= self.width) continue;
                    if (player_r < 0 or player_c < 0 or player_r >= self.height or player_c >= self.width) continue;
                    const from_pos = Pos{ .row = @intCast(from_r), .col = @intCast(from_c) };
                    const player_pos = Pos{ .row = @intCast(player_r), .col = @intCast(player_c) };
                    if (self.isWall(from_pos) or self.isWall(player_pos)) continue;
                    if (self.target_dist[ti][from_pos.idx()] == 0xFFFF) {
                        self.target_dist[ti][from_pos.idx()] = cur_dist + 1;
                        queue[tail] = from_pos;
                        tail += 1;
                    }
                }
            }
        }
    }

    fn hasFreezeDeadlock(self: *const Grid, boxes: *const BitBoard, new_box: Pos) bool {
        const offsets = [_][2]i8{ .{ 0, 0 }, .{ 0, -1 }, .{ -1, 0 }, .{ -1, -1 } };
        for (offsets) |off| {
            const base_r = @as(i16, new_box.row) + off[0];
            const base_c = @as(i16, new_box.col) + off[1];
            if (base_r < 0 or base_c < 0) continue;
            if (base_r + 1 >= self.height or base_c + 1 >= self.width) continue;
            var all_blocked = true;
            var has_non_target_box = false;
            for ([_]u8{ 0, 1 }) |dr| {
                for ([_]u8{ 0, 1 }) |dc| {
                    const p = Pos{ .row = @intCast(base_r + dr), .col = @intCast(base_c + dc) };
                    const is_wall_here = self.isWall(p);
                    const is_box_here = bbTest(boxes, p.idx());
                    if (!is_wall_here and !is_box_here) {
                        all_blocked = false;
                    }
                    if (is_box_here and !self.isTarget(p)) {
                        has_non_target_box = true;
                    }
                }
            }
            if (all_blocked and has_non_target_box) return true;
        }
        return false;
    }

    /// Admissible heuristic: optimal assignment of boxes to targets using bitmask DP.
    /// O(n * 2^n) where n = number of boxes. Fine for n ≤ 20.
    fn heuristic(self: *const Grid, boxes: *const BitBoard) u32 {
        // Collect box positions
        var box_cells: [MAX_BOXES]u16 = undefined;
        var n: u8 = 0;
        for (0..MAX_CELLS) |i| {
            if (bbTest(boxes, @intCast(i))) {
                box_cells[n] = @intCast(i);
                n += 1;
            }
        }
        if (n == 0) return 0;

        // cost[bi][ti] = push distance from box bi to target ti
        var cost: [MAX_BOXES][MAX_BOXES]u16 = undefined;
        for (0..n) |bi| {
            for (0..self.target_count) |ti| {
                cost[bi][ti] = self.target_dist[ti][box_cells[bi]];
            }
        }

        // For large n, fall back to sum of individual minimums
        if (n > 16) {
            var total: u32 = 0;
            for (0..n) |bi| {
                var best: u32 = 0xFFFF;
                for (0..self.target_count) |ti| {
                    if (cost[bi][ti] < best) best = cost[bi][ti];
                }
                total += if (best >= 0xFFFF) 100 else best;
            }
            return total;
        }

        // Bitmask DP: dp[mask] = min cost to assign targets in mask to first popcount(mask) boxes
        // Max 2^16 = 65536 entries = 256KB on stack
        const mask_count = @as(u32, 1) << @intCast(n);
        var dp: [1 << 16]u32 = undefined;
        dp[0] = 0;
        for (1..mask_count) |mask| {
            dp[mask] = 0xFFFFFF;
            const bi: u8 = @intCast(@popCount(mask) - 1);
            var m = mask;
            while (m != 0) {
                const bit: u5 = @intCast(@ctz(m));
                const ti: u8 = @intCast(bit);
                const prev_mask = mask & ~(@as(usize, 1) << bit);
                const c: u32 = if (cost[bi][ti] >= 0xFFFF) 10000 else cost[bi][ti];
                const val = dp[prev_mask] + c;
                if (val < dp[mask]) dp[mask] = val;
                m &= m - 1;
            }
        }
        return dp[mask_count - 1];
    }
};

fn parseMap(data: []const u8, maze_num: u32) !struct { grid: Grid, player: Pos, boxes: BitBoard } {
    var lines = std.mem.splitScalar(u8, data, '\n');

    var found = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "Maze:")) {
            const num_str = std.mem.trim(u8, trimmed["Maze:".len..], " \r\t");
            const num = std.fmt.parseInt(u32, num_str, 10) catch continue;
            if (num == maze_num) {
                found = true;
                break;
            }
        }
    }
    if (!found) return error.MazeNotFound;

    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) break;
    }

    var grid: Grid = undefined;
    @memset(&grid.cells, .{.empty} ** MAX_W);
    grid.target_count = 0;
    grid.width = 0;
    grid.height = 0;

    var player: Pos = .{ .row = 0, .col = 0 };
    var boxes = bbEmpty();

    var row: u8 = 0;
    while (lines.next()) |line| {
        const cleaned = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (cleaned.len == 0) break;
        if (std.mem.startsWith(u8, cleaned, "***")) break;

        for (cleaned, 0..) |ch, ci| {
            const col: u8 = @intCast(ci);
            const pos = Pos{ .row = row, .col = col };
            switch (ch) {
                'X' => grid.cells[row][col] = .wall,
                '@' => {
                    grid.cells[row][col] = .empty;
                    player = pos;
                },
                '*' => {
                    grid.cells[row][col] = .empty;
                    bbSet(&boxes, pos.idx());
                },
                '.' => {
                    grid.cells[row][col] = .target;
                    grid.targets[grid.target_count] = pos;
                    grid.target_count += 1;
                },
                '&' => {
                    grid.cells[row][col] = .target;
                    grid.targets[grid.target_count] = pos;
                    grid.target_count += 1;
                    bbSet(&boxes, pos.idx());
                },
                else => grid.cells[row][col] = .empty,
            }
            if (col + 1 > grid.width) grid.width = col + 1;
        }
        row += 1;
    }
    grid.height = row;
    grid.computeDeadCells();
    grid.computeTargetDistances();

    return .{ .grid = grid, .player = player, .boxes = boxes };
}

fn isSolved(boxes: *const BitBoard, grid: *const Grid) bool {
    for (grid.targets[0..grid.target_count]) |t| {
        if (!bbTest(boxes, t.idx())) return false;
    }
    return true;
}

fn normalizePlayer(player: Pos, boxes: *const BitBoard, grid: *const Grid) Pos {
    var visited: [MAX_CELLS]bool = .{false} ** MAX_CELLS;
    var queue: [MAX_CELLS]Pos = undefined;
    var head: u16 = 0;
    var tail: u16 = 0;
    queue[tail] = player;
    tail += 1;
    visited[player.idx()] = true;
    var min_pos = player;

    while (head < tail) {
        const cur = queue[head];
        head += 1;
        if (@as(u16, @bitCast(cur)) < @as(u16, @bitCast(min_pos))) min_pos = cur;
        for (dirs) |dir| {
            if (cur.move(dir)) |np| {
                if (!visited[np.idx()] and !grid.isWall(np) and !bbTest(boxes, np.idx())) {
                    visited[np.idx()] = true;
                    queue[tail] = np;
                    tail += 1;
                }
            }
        }
    }
    return min_pos;
}

const State = struct {
    player: Pos, // Canonical representative of the reachable player region.
    boxes: BitBoard,
};

const StateContext = struct {
    pub fn hash(_: StateContext, state: State) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&state.player));
        h.update(std.mem.sliceAsBytes(&state.boxes));
        return h.final();
    }

    pub fn eql(_: StateContext, a: State, b: State) bool {
        return a.player.eql(b.player) and bbEql(&a.boxes, &b.boxes);
    }
};

const StateMap = std.HashMap(State, u32, StateContext, std.hash_map.default_max_load_percentage);

const BfsNode = struct {
    player: Pos,
    boxes: BitBoard,
    parent: u32,
    dir: Dir,
    norm_player: Pos,
    pushes: u32, // g-cost: number of pushes so far
};

const MAX_STATES = 5_000_000;

fn solve(grid: *const Grid, initial_player: Pos, initial_boxes: *const BitBoard, allocator: std.mem.Allocator) !?[]u8 {
    if (isSolved(initial_boxes, grid)) {
        return try allocator.alloc(u8, 0);
    }

    const QItem = struct {
        idx: u32,
        f: u32,
        g: u32,
    };

    var nodes = std.array_list.Managed(BfsNode).init(allocator);
    defer nodes.deinit();

    var visited = StateMap.init(allocator);
    defer visited.deinit();

    const norm0 = normalizePlayer(initial_player, initial_boxes, grid);
    try visited.put(.{ .player = norm0, .boxes = initial_boxes.* }, 0);

    const h0 = grid.heuristic(initial_boxes);
    try nodes.append(.{
        .player = initial_player,
        .boxes = initial_boxes.*,
        .parent = 0xFFFFFFFF,
        .dir = .up,
        .norm_player = norm0,
        .pushes = 0,
    });

    var pq = std.PriorityQueue(QItem, void, struct {
        fn lessThan(_: void, a: QItem, b: QItem) std.math.Order {
            if (a.f != b.f) return std.math.order(a.f, b.f);
            if (a.g != b.g) return std.math.order(b.g, a.g);
            return std.math.order(a.idx, b.idx);
        }
    }.lessThan).initContext({});
    defer pq.deinit(allocator);
    try pq.push(allocator, .{ .idx = 0, .f = h0, .g = 0 });

    var expanded: u32 = 0;

    while (pq.pop()) |item| {
        const node_idx = item.idx;
        const node = nodes.items[node_idx];
        const g = node.pushes;
        const state = State{ .player = node.norm_player, .boxes = node.boxes };
        // A cheaper path may have replaced this queue entry. Parent nodes remain
        // immutable so already-generated paths can still be reconstructed.
        if (visited.get(state).? != node_idx) continue;
        if (isSolved(&node.boxes, grid)) {
            writeStdout("  solved after {d} states explored\n", .{expanded});
            return try reconstructFullPath(grid, &nodes, node_idx, initial_player, allocator);
        }

        expanded += 1;
        if (expanded % 100_000 == 0) {
            writeStdout("  explored {d} states, queue {d}, f={d}\n", .{
                expanded, pq.count(), item.f,
            });
        }
        if (expanded > MAX_STATES) {
            writeStdout("  state limit reached ({d} states explored)\n", .{expanded});
            return null;
        }

        // Flood fill reachable cells
        var reachable: [MAX_CELLS]bool = .{false} ** MAX_CELLS;
        {
            var queue: [MAX_CELLS]Pos = undefined;
            var qh: u16 = 0;
            var qt: u16 = 0;
            queue[qt] = node.player;
            qt += 1;
            reachable[node.player.idx()] = true;
            while (qh < qt) {
                const cur = queue[qh];
                qh += 1;
                for (dirs) |dir| {
                    if (cur.move(dir)) |np| {
                        if (!reachable[np.idx()] and !grid.isWall(np) and !bbTest(&node.boxes, np.idx())) {
                            reachable[np.idx()] = true;
                            queue[qt] = np;
                            qt += 1;
                        }
                    }
                }
            }
        }

        // Iterate only over actual box positions
        const box_iter = node.boxes;
        for (0..BB_WORDS) |wi| {
            var word = box_iter[wi];
            while (word != 0) {
                const bit: u6 = @intCast(@ctz(word));
                word &= word - 1;
                const ci: u16 = @intCast(wi * 64 + bit);
                const box_pos = Pos{ .row = @intCast(ci / MAX_W), .col = @intCast(ci % MAX_W) };

                for (dirs) |push_dir| {
                    const d = push_dir.delta();
                    const pr = @as(i16, box_pos.row) - d[0];
                    const pc = @as(i16, box_pos.col) - d[1];
                    if (pr < 0 or pc < 0 or pr >= MAX_H or pc >= MAX_W) continue;
                    const player_pos = Pos{ .row = @intCast(pr), .col = @intCast(pc) };
                    if (!reachable[player_pos.idx()]) continue;

                    const new_box = box_pos.move(push_dir) orelse continue;
                    if (grid.isWall(new_box)) continue;
                    if (bbTest(&node.boxes, new_box.idx())) continue;
                    if (grid.dead_cell[new_box.idx()]) continue;

                    var new_boxes = node.boxes;
                    bbClear(&new_boxes, box_pos.idx());
                    bbSet(&new_boxes, new_box.idx());

                    if (grid.hasFreezeDeadlock(&new_boxes, new_box)) continue;

                    const new_norm = normalizePlayer(box_pos, &new_boxes, grid);
                    const new_state = State{ .player = new_norm, .boxes = new_boxes };
                    const new_g = g + 1;
                    const gop = try visited.getOrPut(new_state);
                    if (gop.found_existing and nodes.items[gop.value_ptr.*].pushes <= new_g) continue;

                    const new_idx: u32 = @intCast(nodes.items.len);
                    gop.value_ptr.* = new_idx;
                    try nodes.append(.{
                        .player = box_pos,
                        .boxes = new_boxes,
                        .parent = node_idx,
                        .dir = push_dir,
                        .norm_player = new_norm,
                        .pushes = new_g,
                    });

                    const h = grid.heuristic(&new_boxes);
                    try pq.push(allocator, .{ .idx = new_idx, .f = new_g + h, .g = new_g });
                }
            }
        }
    }
    return null;
}

fn reconstructFullPath(
    grid: *const Grid,
    nodes: *const std.array_list.Managed(BfsNode),
    solution_idx: u32,
    initial_player: Pos,
    allocator: std.mem.Allocator,
) ![]u8 {
    var push_indices = std.array_list.Managed(u32).init(allocator);
    defer push_indices.deinit();

    var idx = solution_idx;
    while (nodes.items[idx].parent != 0xFFFFFFFF) {
        try push_indices.append(idx);
        idx = nodes.items[idx].parent;
    }
    std.mem.reverse(u32, push_indices.items);

    var full_path = std.array_list.Managed(u8).init(allocator);
    errdefer full_path.deinit();
    var current_player = initial_player;

    for (push_indices.items) |pi| {
        const node = nodes.items[pi];
        const d = node.dir.delta();
        const push_from = Pos{
            .row = @intCast(@as(i16, node.player.row) - d[0]),
            .col = @intCast(@as(i16, node.player.col) - d[1]),
        };

        const parent_boxes = if (node.parent != 0xFFFFFFFF)
            &nodes.items[node.parent].boxes
        else
            &nodes.items[0].boxes;

        const walk = try findWalkPath(current_player, push_from, grid, parent_boxes, allocator);
        defer allocator.free(walk);
        try full_path.appendSlice(walk);
        try full_path.append(node.dir.pushLabel());
        current_player = node.player;
    }

    return try full_path.toOwnedSlice();
}

fn findWalkPath(from: Pos, to: Pos, grid: *const Grid, boxes: *const BitBoard, allocator: std.mem.Allocator) ![]u8 {
    if (from.eql(to)) return try allocator.alloc(u8, 0);

    var came_from: [MAX_CELLS]u16 = .{0xFFFF} ** MAX_CELLS;
    var came_dir: [MAX_CELLS]Dir = undefined;
    var queue: [MAX_CELLS]Pos = undefined;
    var head: u16 = 0;
    var tail: u16 = 0;

    came_from[from.idx()] = from.idx();
    queue[tail] = from;
    tail += 1;

    while (head < tail) {
        const cur = queue[head];
        head += 1;
        for (dirs) |dir| {
            if (cur.move(dir)) |np| {
                if (came_from[np.idx()] == 0xFFFF and !grid.isWall(np) and !bbTest(boxes, np.idx())) {
                    came_from[np.idx()] = cur.idx();
                    came_dir[np.idx()] = dir;
                    if (np.eql(to)) {
                        var path = std.array_list.Managed(u8).init(allocator);
                        errdefer path.deinit();
                        var pos = to;
                        while (!pos.eql(from)) {
                            try path.append(came_dir[pos.idx()].walkLabel());
                            const prev = came_from[pos.idx()];
                            pos = .{ .row = @intCast(prev / MAX_W), .col = @intCast(prev % MAX_W) };
                        }
                        std.mem.reverse(u8, path.items);
                        return try path.toOwnedSlice();
                    }
                    queue[tail] = np;
                    tail += 1;
                }
            }
        }
    }
    return error.NoPath;
}

fn writeStdout(comptime fmt: []const u8, fmtargs: anytype) void {
    std.debug.print(fmt, fmtargs);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        writeStdout("Usage: sokoban <maze_number>\n", .{});
        std.process.exit(1);
    }

    const maze_num = std.fmt.parseInt(u32, args[1], 10) catch {
        writeStdout("Invalid maze number: {s}\n", .{args[1]});
        std.process.exit(1);
    };

    const map_data = @embedFile("sokoban-maps-60.txt");

    const parsed = parseMap(map_data, maze_num) catch |err| {
        writeStdout("Failed to parse maze {d}: {}\n", .{ maze_num, err });
        std.process.exit(1);
    };

    writeStdout("Maze {d} ({d}x{d}, {d} boxes)\n", .{
        maze_num, parsed.grid.width, parsed.grid.height, bbCount(&parsed.boxes),
    });

    writeStdout("Solving...\n", .{});

    const solution = try solve(&parsed.grid, parsed.player, &parsed.boxes, allocator);

    if (solution) |path| {
        defer allocator.free(path);
        var pushes: usize = 0;
        for (path) |ch| {
            if (ch >= 'A' and ch <= 'Z') pushes += 1;
        }
        writeStdout("Solution ({d} steps, {d} pushes):\n{s}\n", .{ path.len, pushes, path });
    } else {
        writeStdout("No solution found.\n", .{});
    }
}

fn verifyPath(grid: *const Grid, initial_player: Pos, initial_boxes: *const BitBoard, path: []const u8) !void {
    var player = initial_player;
    var boxes = initial_boxes.*;

    for (path) |ch| {
        const dir: Dir = switch (ch) {
            'u', 'U' => .up,
            'd', 'D' => .down,
            'l', 'L' => .left,
            'r', 'R' => .right,
            else => return error.InvalidStep,
        };
        const is_push = (ch >= 'A' and ch <= 'Z');
        const new_player = player.move(dir) orelse return error.MoveOutOfBounds;
        if (grid.isWall(new_player)) return error.WalkedIntoWall;

        if (bbTest(&boxes, new_player.idx())) {
            if (!is_push) return error.WalkIntoBoxWithoutPush;
            const new_box = new_player.move(dir) orelse return error.PushOutOfBounds;
            if (grid.isWall(new_box)) return error.PushIntoWall;
            if (bbTest(&boxes, new_box.idx())) return error.PushIntoBox;
            bbClear(&boxes, new_player.idx());
            bbSet(&boxes, new_box.idx());
        } else {
            if (is_push) return error.PushWithNoBox;
        }
        player = new_player;
    }

    if (!isSolved(&boxes, grid)) return error.NotSolved;
}

fn countPushes(path: []const u8) usize {
    var pushes: usize = 0;
    for (path) |ch| {
        if (ch >= 'A' and ch <= 'Z') pushes += 1;
    }
    return pushes;
}

test "parse maze 0 correctly" {
    const map_data = @embedFile("sokoban-maps-60.txt");
    const parsed = try parseMap(map_data, 0);
    try std.testing.expectEqual(@as(u8, 5), parsed.grid.width);
    try std.testing.expectEqual(@as(u8, 7), parsed.grid.height);
    try std.testing.expectEqual(@as(u32, 2), bbCount(&parsed.boxes));
    try std.testing.expectEqual(@as(u8, 1), parsed.player.row);
    try std.testing.expectEqual(@as(u8, 2), parsed.player.col);
    // Two targets: (4,2) the '.' and (5,2) where '&' is
    try std.testing.expectEqual(@as(u8, 2), parsed.grid.target_count);
}

test "solve maze 0" {
    const allocator = std.testing.allocator;
    const map_data = @embedFile("sokoban-maps-60.txt");
    const parsed = try parseMap(map_data, 0);

    const solution = try solve(&parsed.grid, parsed.player, &parsed.boxes, allocator);
    try std.testing.expect(solution != null);
    const path = solution.?;
    defer allocator.free(path);
    try verifyPath(&parsed.grid, parsed.player, &parsed.boxes, path);
    try std.testing.expectEqual(@as(usize, 1), countPushes(path));
    std.debug.print("Maze 0: {s}\n", .{path});
}

test "solve maze 1" {
    const allocator = std.testing.allocator;
    const map_data = @embedFile("sokoban-maps-60.txt");
    const parsed = try parseMap(map_data, 1);

    try std.testing.expectEqual(@as(u32, 6), bbCount(&parsed.boxes));
    try std.testing.expectEqual(@as(u8, 6), parsed.grid.target_count);

    const solution = try solve(&parsed.grid, parsed.player, &parsed.boxes, allocator);
    try std.testing.expect(solution != null);
    const path = solution.?;
    defer allocator.free(path);
    try verifyPath(&parsed.grid, parsed.player, &parsed.boxes, path);

    const pushes = countPushes(path);
    try std.testing.expect(pushes <= 120); // should find solution with ~116 pushes
    try std.testing.expect(path.len > 0);
    std.debug.print("Maze 1: {d} steps, {d} pushes\n", .{ path.len, pushes });
}

test "solve maze 40" {
    const allocator = std.testing.allocator;
    const map_data = @embedFile("sokoban-maps-60.txt");
    const parsed = try parseMap(map_data, 40);

    try std.testing.expectEqual(@as(u32, 8), bbCount(&parsed.boxes));
    try std.testing.expectEqual(@as(u8, 8), parsed.grid.target_count);
    try std.testing.expectEqual(@as(u8, 11), parsed.grid.width);
    try std.testing.expectEqual(@as(u8, 11), parsed.grid.height);

    const solution = try solve(&parsed.grid, parsed.player, &parsed.boxes, allocator);
    try std.testing.expect(solution != null);
    const path = solution.?;
    defer allocator.free(path);
    try verifyPath(&parsed.grid, parsed.player, &parsed.boxes, path);

    const pushes = countPushes(path);
    try std.testing.expect(pushes <= 90); // should find solution with ~81 pushes
    std.debug.print("Maze 40: {d} steps, {d} pushes\n", .{ path.len, pushes });
}

test "dead cell detection" {
    const map_data = @embedFile("sokoban-maps-60.txt");
    const parsed = try parseMap(map_data, 0);
    // Corners next to walls should be dead (not targets)
    // Cell (1,1) is a corner: wall above (0,1) and wall left (1,0)
    try std.testing.expect(parsed.grid.dead_cell[Pos.idx(.{ .row = 1, .col = 1 })]);
    // Target cells should not be dead
    try std.testing.expect(!parsed.grid.dead_cell[Pos.idx(.{ .row = 4, .col = 2 })]);
}

test "verify rejects invalid solution" {
    const map_data = @embedFile("sokoban-maps-60.txt");
    const parsed = try parseMap(map_data, 0);
    // "U" would push into wall from starting position
    const result = verifyPath(&parsed.grid, parsed.player, &parsed.boxes, "U");
    try std.testing.expectError(error.WalkedIntoWall, result);
}

test "parse nonexistent maze returns error" {
    const map_data = @embedFile("sokoban-maps-60.txt");
    const result = parseMap(map_data, 9999);
    try std.testing.expectError(error.MazeNotFound, result);
}

// Independent small-board oracle: Dijkstra over individual player steps, with
// zero cost for walking and unit cost for pushing. No normalization or pruning.
fn referencePushCount(grid: *const Grid, player: Pos, boxes: BitBoard) !?u32 {
    const allocator = std.testing.allocator;
    const Entry = struct { state: State, pushes: u32 };
    var queue = std.PriorityQueue(Entry, void, struct {
        fn compare(_: void, a: Entry, b: Entry) std.math.Order {
            return std.math.order(a.pushes, b.pushes);
        }
    }.compare).initContext({});
    defer queue.deinit(allocator);
    var best = StateMap.init(allocator);
    defer best.deinit();
    const initial = State{ .player = player, .boxes = boxes };
    try best.put(initial, 0);
    try queue.push(allocator, .{ .state = initial, .pushes = 0 });
    while (queue.pop()) |entry| {
        if (best.get(entry.state).? != entry.pushes) continue;
        if (isSolved(&entry.state.boxes, grid)) return entry.pushes;
        for (dirs) |dir| {
            const next = entry.state.player.move(dir) orelse continue;
            if (grid.isWall(next)) continue;
            var state = entry.state;
            state.player = next;
            var cost = entry.pushes;
            if (bbTest(&state.boxes, next.idx())) {
                const dest = next.move(dir) orelse continue;
                if (grid.isWall(dest) or bbTest(&state.boxes, dest.idx())) continue;
                bbClear(&state.boxes, next.idx());
                bbSet(&state.boxes, dest.idx());
                cost += 1;
            }
            const entry_best = try best.getOrPut(state);
            if (entry_best.found_existing and entry_best.value_ptr.* <= cost) continue;
            entry_best.value_ptr.* = cost;
            try queue.push(allocator, .{ .state = state, .pushes = cost });
        }
    }
    return null;
}

test "A star matches unpruned Dijkstra on small two-box boards" {
    const data = "Maze: 0\n\nXXXXX\nX @ X\nX   X\nX. .X\nXXXXX\n";
    const parsed = try parseMap(data, 0);
    for (0..9) |a| {
        for (a + 1..9) |b| {
            var boxes = bbEmpty();
            const pa = Pos{ .row = @intCast(1 + a / 3), .col = @intCast(1 + a % 3) };
            const pb = Pos{ .row = @intCast(1 + b / 3), .col = @intCast(1 + b % 3) };
            bbSet(&boxes, pa.idx());
            bbSet(&boxes, pb.idx());
            // Different player regions must remain distinct search states.
            for (0..9) |pi| {
                const player = Pos{ .row = @intCast(1 + pi / 3), .col = @intCast(1 + pi % 3) };
                if (bbTest(&boxes, player.idx())) continue;
                const expected = try referencePushCount(&parsed.grid, player, boxes);
                const path = try solve(&parsed.grid, player, &boxes, std.testing.allocator);
                if (path) |p| {
                    defer std.testing.allocator.free(p);
                    try verifyPath(&parsed.grid, player, &boxes, p);
                    try std.testing.expectEqual(expected, @as(?u32, @intCast(countPushes(p))));
                } else {
                    try std.testing.expectEqual(@as(?u32, null), expected);
                }
            }
        }
    }
}

test "state equality resolves hash collisions" {
    const CollidingContext = struct {
        pub fn hash(_: @This(), _: State) u64 {
            return 0;
        }
        pub fn eql(_: @This(), a: State, b: State) bool {
            return (StateContext{}).eql(a, b);
        }
    };
    var map = std.HashMap(State, u32, CollidingContext, 80).init(std.testing.allocator);
    defer map.deinit();
    const a = State{ .player = .{ .row = 1, .col = 1 }, .boxes = bbEmpty() };
    var b = a;
    bbSet(&b.boxes, 42);
    var c = a;
    c.player.col = 2;
    try map.put(a, 3);
    try map.put(b, 7);
    try map.put(c, 9);
    try std.testing.expectEqual(@as(u32, 3), map.get(a).?);
    try std.testing.expectEqual(@as(u32, 7), map.get(b).?);
    try std.testing.expectEqual(@as(u32, 9), map.get(c).?);
}
