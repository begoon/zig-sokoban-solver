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
const MAX_BOXES = 40;

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
    neighbors: [MAX_CELLS][4]u16,
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

    fn computeNeighbors(self: *Grid) void {
        for (0..MAX_CELLS) |i| {
            const p = Pos{ .row = @intCast(i / MAX_W), .col = @intCast(i % MAX_W) };
            self.neighbors[i] = .{UNREACHABLE} ** 4;
            if (self.isWall(p)) continue;
            for (dirs, 0..) |dir, di| {
                const next = p.move(dir) orelse continue;
                if (!self.isWall(next)) self.neighbors[i][di] = next.idx();
            }
        }
    }

    // Remove any box that could move if all previously removed boxes vanished.
    // Boxes left at the fixed point cannot make even a first move. Ignoring
    // player access makes this conservative: it can miss deadlocks, not invent them.
    fn hasFrozenGroup(self: *const Grid, boxes: *const BitBoard) bool {
        var frozen = boxes.*;
        var changed = true;
        while (changed) {
            changed = false;
            for (frozen, 0..) |value, wi| {
                var word = value;
                while (word != 0) {
                    const bit = @ctz(word);
                    word &= word - 1;
                    const cell: u16 = @intCast(wi * 64 + bit);
                    const adjacent = self.neighbors[cell];
                    for ([_][2]usize{ .{ 0, 1 }, .{ 2, 3 } }) |axis| {
                        const a = adjacent[axis[0]];
                        const b = adjacent[axis[1]];
                        if (a != UNREACHABLE and b != UNREACHABLE and !bbTest(&frozen, a) and !bbTest(&frozen, b)) {
                            bbClear(&frozen, cell);
                            changed = true;
                            break;
                        }
                    }
                }
            }
        }
        for (self.targets[0..self.target_count]) |target| bbClear(&frozen, target.idx());
        return bbCount(&frozen) != 0;
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

    /// Exact box-to-target assignment in the relaxed single-box push graph.
    /// An impossible matching proves a deadlock, even when every individual
    /// box can reach some target. Small boards use DP; larger ones Hungarian.
    fn heuristic(self: *const Grid, boxes: *const BitBoard) ?u32 {
        var cost: AssignmentCosts = undefined;
        var n: usize = 0;
        for (boxes, 0..) |word_value, wi| {
            var word = word_value;
            while (word != 0) {
                const bit = @ctz(word);
                word &= word - 1;
                const cell = wi * 64 + bit;
                for (0..self.target_count) |ti| cost[n][ti] = self.target_dist[ti][cell];
                n += 1;
            }
        }
        std.debug.assert(n == self.target_count);
        return if (n <= 8) assignmentDP(&cost, n) else assignmentHungarian(&cost, n);
    }
};

const AssignmentCosts = [MAX_BOXES][MAX_BOXES]u16;
const UNREACHABLE = std.math.maxInt(u16);
const MATCH_INF: u32 = 1 << 28;

fn assignmentDP(cost: *const AssignmentCosts, n: usize) ?u32 {
    std.debug.assert(n <= 8);
    var dp: [1 << 8]u32 = undefined;
    const count = @as(usize, 1) << @intCast(n);
    dp[0] = 0;
    for (1..count) |mask| {
        dp[mask] = MATCH_INF;
        const bi = @popCount(mask) - 1;
        var remaining = mask;
        while (remaining != 0) {
            const ti = @ctz(remaining);
            remaining &= remaining - 1;
            if (cost[bi][ti] == UNREACHABLE) continue;
            const prev = mask & ~(@as(usize, 1) << @intCast(ti));
            dp[mask] = @min(dp[mask], dp[prev] + cost[bi][ti]);
        }
    }
    return if (dp[count - 1] == MATCH_INF) null else dp[count - 1];
}

// Shortest augmenting path Hungarian algorithm, O(n^3) time and O(n) scratch.
// Rows/columns are one-based; column zero represents the augmenting root.
fn assignmentHungarian(cost: *const AssignmentCosts, n: usize) ?u32 {
    var u = [_]i32{0} ** (MAX_BOXES + 1);
    var v = [_]i32{0} ** (MAX_BOXES + 1);
    var matched = [_]usize{0} ** (MAX_BOXES + 1);
    var previous: [MAX_BOXES + 1]usize = undefined;
    const inf: i32 = MATCH_INF;
    for (1..n + 1) |row| {
        matched[0] = row;
        var col: usize = 0;
        var min_cost = [_]i32{inf} ** (MAX_BOXES + 1);
        var used = [_]bool{false} ** (MAX_BOXES + 1);
        while (true) {
            used[col] = true;
            const r = matched[col];
            var delta = inf;
            var next: usize = 0;
            for (1..n + 1) |j| {
                if (used[j]) continue;
                if (cost[r - 1][j - 1] != UNREACHABLE) {
                    const reduced = @as(i32, cost[r - 1][j - 1]) - u[r] - v[j];
                    if (reduced < min_cost[j]) {
                        min_cost[j] = reduced;
                        previous[j] = col;
                    }
                }
                if (min_cost[j] < delta) {
                    delta = min_cost[j];
                    next = j;
                }
            }
            if (delta == inf) return null;
            for (0..n + 1) |j| {
                if (used[j]) {
                    u[matched[j]] += delta;
                    v[j] -= delta;
                } else if (min_cost[j] != inf) {
                    min_cost[j] -= delta;
                }
            }
            col = next;
            if (matched[col] == 0) break;
        }
        while (col != 0) {
            const prev = previous[col];
            matched[col] = matched[prev];
            col = prev;
        }
    }
    var total: u32 = 0;
    for (1..n + 1) |j| total += cost[matched[j] - 1][j - 1];
    return total;
}

pub fn parseMap(data: []const u8, maze_num: u32) !struct { grid: Grid, player: Pos, boxes: BitBoard } {
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
    var player_found = false;

    var row: u8 = 0;
    while (lines.next()) |line| {
        const cleaned = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (cleaned.len == 0) break;
        if (std.mem.startsWith(u8, cleaned, "***")) break;
        if (row >= MAX_H or cleaned.len > MAX_W) return error.MapTooLarge;

        for (cleaned, 0..) |ch, ci| {
            const col: u8 = @intCast(ci);
            const pos = Pos{ .row = row, .col = col };
            switch (ch) {
                'X' => grid.cells[row][col] = .wall,
                '@' => {
                    if (player_found) return error.MultiplePlayers;
                    player_found = true;
                    grid.cells[row][col] = .empty;
                    player = pos;
                },
                '*' => {
                    grid.cells[row][col] = .empty;
                    bbSet(&boxes, pos.idx());
                },
                '.' => {
                    if (grid.target_count >= MAX_BOXES) return error.TooManyTargets;
                    grid.cells[row][col] = .target;
                    grid.targets[grid.target_count] = pos;
                    grid.target_count += 1;
                },
                '&' => {
                    if (grid.target_count >= MAX_BOXES) return error.TooManyTargets;
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
    if (!player_found) return error.MissingPlayer;
    if (bbCount(&boxes) > MAX_BOXES) return error.TooManyBoxes;
    if (bbCount(&boxes) != grid.target_count) return error.InvalidBoxCount;
    grid.computeNeighbors();
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

const Reachable = struct { cells: BitBoard, canonical: Pos };

fn reachableCells(player: Pos, boxes: *const BitBoard, grid: *const Grid) Reachable {
    var cells = bbEmpty();
    var queue: [MAX_CELLS]u16 = undefined;
    var head: usize = 0;
    var tail: usize = 1;
    const start = player.idx();
    queue[0] = start;
    bbSet(&cells, start);
    var minimum = start;
    while (head < tail) : (head += 1) {
        const cur = queue[head];
        minimum = @min(minimum, cur);
        for (grid.neighbors[cur]) |next| {
            if (next == UNREACHABLE or bbTest(&cells, next) or bbTest(boxes, next)) continue;
            bbSet(&cells, next);
            queue[tail] = next;
            tail += 1;
        }
    }
    return .{ .cells = cells, .canonical = .{ .row = @intCast(minimum / MAX_W), .col = @intCast(minimum % MAX_W) } };
}

fn normalizePlayer(player: Pos, boxes: *const BitBoard, grid: *const Grid) Pos {
    return reachableCells(player, boxes, grid).canonical;
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

pub const SearchLimits = struct {
    progress: ?*const fn (expanded: u32, queued: u32) void = null,
    max_expanded: ?u32 = 5_000_000,
    max_stored: ?u32 = 1_000_000,
    memory_bytes: usize = 256 * 1024 * 1024,
};

// Bounds live allocation requests, including spare capacities and the temporary
// overlap when a container grows. Allocator metadata and stack are not included.
const BudgetAllocator = struct {
    child: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    denied: bool = false,

    fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn permits(self: *BudgetAllocator, old: usize, new: usize) bool {
        if (new > self.limit - (self.used - old)) {
            self.denied = true;
            return false;
        }
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (!self.permits(0, len)) return null;
        const ptr = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, len)) return false;
        if (!self.child.rawResize(memory, alignment, len, ra)) return false;
        self.used = self.used - memory.len + len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, len)) return null;
        const ptr = self.child.rawRemap(memory, alignment, len, ra) orelse return null;
        self.used = self.used - memory.len + len;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.used -= memory.len;
    }
};

fn solve(grid: *const Grid, initial_player: Pos, initial_boxes: *const BitBoard, allocator: std.mem.Allocator) !?[]u8 {
    return solveWithLimits(grid, initial_player, initial_boxes, allocator, .{});
}

pub fn solveWithLimits(grid: *const Grid, initial_player: Pos, initial_boxes: *const BitBoard, allocator: std.mem.Allocator, limits: SearchLimits) !?[]u8 {
    var budget = BudgetAllocator{ .child = allocator, .limit = limits.memory_bytes };
    // The wrapper adds no allocation headers. The returned path can be freed
    // directly through the caller's allocator after the search wrapper expires.
    return search(grid, initial_player, initial_boxes, budget.allocator(), limits) catch |err| {
        if (err == error.OutOfMemory and budget.denied) return error.MemoryLimitReached;
        return err;
    };
}

fn search(grid: *const Grid, initial_player: Pos, initial_boxes: *const BitBoard, allocator: std.mem.Allocator, limits: SearchLimits) !?[]u8 {
    if (bbCount(initial_boxes) != grid.target_count) return error.InvalidBoxCount;
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

    const h0 = grid.heuristic(initial_boxes) orelse return null;
    if (limits.max_stored == 0) return error.StoredStateLimitReached;
    const norm0 = normalizePlayer(initial_player, initial_boxes, grid);
    try visited.put(.{ .player = norm0, .boxes = initial_boxes.* }, 0);

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
    if (limits.progress) |report| report(0, @intCast(pq.count()));

    while (pq.pop()) |item| {
        const node_idx = item.idx;
        const node = nodes.items[node_idx];
        const g = node.pushes;
        const state = State{ .player = node.norm_player, .boxes = node.boxes };
        // A cheaper path may have replaced this queue entry. Parent nodes remain
        // immutable so already-generated paths can still be reconstructed.
        if (visited.get(state).? != node_idx) continue;
        if (isSolved(&node.boxes, grid)) {
            if (limits.progress) |report| report(expanded, @intCast(pq.count()));
            writeStdout("  solved after {d} states explored\n", .{expanded});
            return try reconstructFullPath(grid, &nodes, node_idx, initial_player, allocator);
        }

        if (limits.max_expanded) |maximum| {
            if (expanded >= maximum) return error.ExpansionLimitReached;
        }
        expanded += 1;
        if (expanded % 1024 == 0) {
            if (limits.progress) |report| report(expanded, @intCast(pq.count()));
        }
        if (expanded % 100_000 == 0) {
            writeStdout("  explored {d} states, queue {d}, f={d}\n", .{
                expanded, pq.count(), item.f,
            });
        }

        const reachable = reachableCells(node.player, &node.boxes, grid).cells;

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
                    if (!bbTest(&reachable, player_pos.idx())) continue;

                    const new_box = box_pos.move(push_dir) orelse continue;
                    if (grid.isWall(new_box)) continue;
                    if (bbTest(&node.boxes, new_box.idx())) continue;
                    if (grid.dead_cell[new_box.idx()]) continue;

                    var new_boxes = node.boxes;
                    bbClear(&new_boxes, box_pos.idx());
                    bbSet(&new_boxes, new_box.idx());

                    if (grid.hasFreezeDeadlock(&new_boxes, new_box)) continue;
                    // A new group freeze needs contact with another box; the
                    // static dead-cell table already handles isolated boxes.
                    var touches_box = false;
                    for (grid.neighbors[new_box.idx()]) |neighbor| {
                        if (neighbor != UNREACHABLE and bbTest(&new_boxes, neighbor)) touches_box = true;
                    }
                    if (touches_box and grid.hasFrozenGroup(&new_boxes)) continue;

                    const new_norm = normalizePlayer(box_pos, &new_boxes, grid);
                    const new_state = State{ .player = new_norm, .boxes = new_boxes };
                    const new_g = g + 1;
                    if (visited.get(new_state)) |old_idx| {
                        if (nodes.items[old_idx].pushes <= new_g) continue;
                    }
                    const h = grid.heuristic(&new_boxes) orelse continue;
                    if (limits.max_stored) |maximum| {
                        if (nodes.items.len >= maximum) return error.StoredStateLimitReached;
                    }
                    const gop = try visited.getOrPut(new_state);
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
    if (@import("builtin").is_test or @import("builtin").os.tag == .freestanding) return;
    std.debug.print(fmt, fmtargs);
}

fn parseSearchLimits(args: []const [:0]const u8) !SearchLimits {
    var limits: SearchLimits = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.MissingLimitValue;
        const value = std.fmt.parseInt(u32, args[i + 1], 10) catch return error.InvalidLimitValue;
        if (std.mem.eql(u8, args[i], "--max-expanded")) {
            limits.max_expanded = value;
        } else if (std.mem.eql(u8, args[i], "--max-stored")) {
            limits.max_stored = value;
        } else if (std.mem.eql(u8, args[i], "--memory-mib")) {
            limits.memory_bytes = std.math.mul(usize, value, 1024 * 1024) catch return error.InvalidLimitValue;
        } else return error.UnknownOption;
    }
    return limits;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        writeStdout("Usage: sokoban-solver <maze_number> [--max-expanded N] [--max-stored N] [--memory-mib N]\n", .{});
        std.process.exit(1);
    }

    const maze_num = std.fmt.parseInt(u32, args[1], 10) catch {
        writeStdout("Invalid maze number: {s}\n", .{args[1]});
        std.process.exit(1);
    };

    const limits = parseSearchLimits(args[2..]) catch |err| {
        writeStdout("Invalid search limits: {}\n", .{err});
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

    const solution = solveWithLimits(&parsed.grid, parsed.player, &parsed.boxes, allocator, limits) catch |err| switch (err) {
        error.ExpansionLimitReached, error.StoredStateLimitReached, error.MemoryLimitReached => {
            writeStdout("Search limit reached: {}. Solvability is unknown.\n", .{err});
            std.process.exit(2);
        },
        else => return err,
    };

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
    const data = "Maze: 0\n\nXXXXX\nX*@*X\nX   X\nX. .X\nXXXXX\n";
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

fn bruteAssignment(cost: *const AssignmentCosts, n: usize, row: usize, used: u32) ?u32 {
    if (row == n) return 0;
    var best: ?u32 = null;
    for (0..n) |col| {
        const bit = @as(u32, 1) << @intCast(col);
        if (used & bit != 0 or cost[row][col] == UNREACHABLE) continue;
        const tail = bruteAssignment(cost, n, row + 1, used | bit) orelse continue;
        const total = tail + cost[row][col];
        best = if (best) |b| @min(b, total) else total;
    }
    return best;
}

test "assignment algorithms agree with exhaustive permutations" {
    var random = std.Random.DefaultPrng.init(42);
    var cost: AssignmentCosts = undefined;
    for (0..7) |n| {
        for (0..40) |_| {
            for (0..n) |i| {
                for (0..n) |j| {
                    const value = random.random().intRangeLessThan(u16, 0, 30);
                    cost[i][j] = if (value < 8) UNREACHABLE else value - 8;
                }
            }
            const expected = bruteAssignment(&cost, n, 0, 0);
            try std.testing.expectEqual(expected, assignmentDP(&cost, n));
            try std.testing.expectEqual(expected, assignmentHungarian(&cost, n));
        }
    }
}

test "large matching preserves unique targets and detects assignment deadlocks" {
    var cost: AssignmentCosts = undefined;
    for (0..MAX_BOXES) |i| {
        for (0..MAX_BOXES) |j| cost[i][j] = if (i == j) 60000 else UNREACHABLE;
    }
    try std.testing.expectEqual(@as(?u32, MAX_BOXES * 60000), assignmentHungarian(&cost, MAX_BOXES));
    // Every box individually has a target, but two need the same target.
    cost[MAX_BOXES - 1][MAX_BOXES - 1] = UNREACHABLE;
    cost[MAX_BOXES - 1][MAX_BOXES - 2] = 1;
    try std.testing.expectEqual(@as(?u32, null), assignmentHungarian(&cost, MAX_BOXES));
}

test "heuristic uses distinct targets beyond sixteen boxes" {
    var grid: Grid = undefined;
    grid.target_count = 17;
    var boxes = bbEmpty();
    for (0..17) |i| {
        bbSet(&boxes, @intCast(i));
        for (0..17) |j| grid.target_dist[i][j] = if (i == 0) 0 else 1;
    }
    try std.testing.expectEqual(@as(?u32, 16), grid.heuristic(&boxes));
}

test "all bundled mazes fit validated board and box capacities" {
    for (0..61) |maze| {
        const parsed = try parseMap(@embedFile("sokoban-maps-60.txt"), @intCast(maze));
        try std.testing.expectEqual(bbCount(&parsed.boxes), parsed.grid.target_count);
        try std.testing.expect(parsed.grid.heuristic(&parsed.boxes) != null);
    }
}

test "parser rejects oversized and malformed maps" {
    try std.testing.expectError(error.MapTooLarge, parseMap("Maze: 0\n\n" ++ "X" ** (MAX_W + 1) ++ "\n", 0));
    try std.testing.expectError(error.MapTooLarge, parseMap("Maze: 0\n\n" ++ "X\n" ** (MAX_H + 1), 0));
    try std.testing.expectError(error.MissingPlayer, parseMap("Maze: 0\n\nXXX\nX X\nXXX\n", 0));
    try std.testing.expectError(error.MultiplePlayers, parseMap("Maze: 0\n\n@@\n", 0));
    try std.testing.expectError(error.InvalidBoxCount, parseMap("Maze: 0\n\n@*\n", 0));
    try std.testing.expectError(error.TooManyTargets, parseMap("Maze: 0\n\n" ++ "..........\n" ** 5, 0));
    try std.testing.expectError(error.TooManyBoxes, parseMap("Maze: 0\n\n@\n" ++ "X**********\n" ** 5, 0));
}

test "deadlock pruning preserves solutions on boards with internal walls" {
    var random = std.Random.DefaultPrng.init(1234);
    const base = try parseMap("Maze: 0\n\nXXXXXX\nX@   X\nX    X\nX    X\nX    X\nXXXXXX\n", 0);
    for (0..96) |iteration| {
        var grid = base.grid;
        var positions: [16]Pos = undefined;
        for (&positions, 0..) |*p, i| p.* = .{ .row = @intCast(1 + i / 4), .col = @intCast(1 + i % 4) };
        random.random().shuffle(Pos, &positions);
        const n = 2 + iteration % 2;
        var boxes = bbEmpty();
        for (positions[1..][0..n]) |p| bbSet(&boxes, p.idx());
        grid.target_count = @intCast(n);
        for (positions[1 + n ..][0..n], 0..) |p, i| {
            grid.targets[i] = p;
            grid.cells[p.row][p.col] = .target;
        }
        for (positions[1 + 2 * n ..]) |p| {
            if (random.random().intRangeLessThan(u8, 0, 4) == 0) grid.cells[p.row][p.col] = .wall;
        }
        grid.computeNeighbors();
        grid.computeDeadCells();
        grid.computeTargetDistances();
        const expected = try referencePushCount(&grid, positions[0], boxes);
        if (expected) |pushes| {
            try std.testing.expect(grid.heuristic(&boxes).? <= pushes);
            try std.testing.expect(!grid.hasFrozenGroup(&boxes));
        }
        const path = try solve(&grid, positions[0], &boxes, std.testing.allocator);
        if (path) |p| {
            defer std.testing.allocator.free(p);
            try verifyPath(&grid, positions[0], &boxes, p);
            try std.testing.expectEqual(expected, @as(?u32, @intCast(countPushes(p))));
        } else {
            try std.testing.expectEqual(@as(?u32, null), expected);
        }
    }
}

test "search limits report exhaustion separately from unsolvability" {
    const parsed = try parseMap(@embedFile("sokoban-maps-60.txt"), 0);
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ExpansionLimitReached, solveWithLimits(&parsed.grid, parsed.player, &parsed.boxes, allocator, .{ .max_expanded = 0 }));
    try std.testing.expectError(error.StoredStateLimitReached, solveWithLimits(&parsed.grid, parsed.player, &parsed.boxes, allocator, .{ .max_stored = 1 }));
    try std.testing.expectError(error.MemoryLimitReached, solveWithLimits(&parsed.grid, parsed.player, &parsed.boxes, allocator, .{ .memory_bytes = 0 }));
    // Exactly one expansion and two stored nodes suffice; popping the goal
    // requires no further expansion even when the expansion budget is spent.
    const corridor = try parseMap("Maze: 0\n\nXXXXX\nX@*.X\nXXXXX\n", 0);
    const path = (try solveWithLimits(&corridor.grid, corridor.player, &corridor.boxes, allocator, .{ .max_expanded = 1, .max_stored = 2 })).?;
    defer allocator.free(path);
    try verifyPath(&corridor.grid, corridor.player, &corridor.boxes, path);
    const dead = try parseMap("Maze: 0\n\nXXXXX\nX*@ X\nX . X\nXXXXX\n", 0);
    try std.testing.expectEqual(@as(?[]u8, null), try solveWithLimits(&dead.grid, dead.player, &dead.boxes, allocator, .{ .max_expanded = 0, .max_stored = 0, .memory_bytes = 0 }));
}

fn allocationFailureSearch(allocator: std.mem.Allocator) !void {
    const parsed = try parseMap(@embedFile("sokoban-maps-60.txt"), 0);
    const path = (try solve(&parsed.grid, parsed.player, &parsed.boxes, allocator)).?;
    defer allocator.free(path);
    try verifyPath(&parsed.grid, parsed.player, &parsed.boxes, path);
}

test "search releases memory at every allocation failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureSearch, .{});
}

test "allocation budget accounts for growth shrink and frees" {
    var storage: [64]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&storage);
    var budget = BudgetAllocator{ .child = backing.allocator(), .limit = 16 };
    const allocator = budget.allocator();
    var memory = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), budget.used);
    memory = try allocator.realloc(memory, 16);
    try std.testing.expectEqual(@as(usize, 16), budget.used);
    try std.testing.expectError(error.OutOfMemory, allocator.realloc(memory, 17));
    try std.testing.expectEqual(@as(usize, 16), budget.used);
    memory = try allocator.realloc(memory, 4);
    try std.testing.expectEqual(@as(usize, 4), budget.used);
    const other = try allocator.alloc(u8, 12);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    allocator.free(other);
    allocator.free(memory);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "parse search limit options" {
    const limits = try parseSearchLimits(&.{ "--max-expanded", "42", "--max-stored", "99", "--memory-mib", "8" });
    try std.testing.expectEqual(@as(?u32, 42), limits.max_expanded);
    try std.testing.expectEqual(@as(?u32, 99), limits.max_stored);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), limits.memory_bytes);
    try std.testing.expectError(error.UnknownOption, parseSearchLimits(&.{ "--unknown", "1" }));
    try std.testing.expectError(error.MissingLimitValue, parseSearchLimits(&.{"--max-stored"}));
    try std.testing.expectError(error.InvalidLimitValue, parseSearchLimits(&.{ "--max-stored", "-1" }));
}
