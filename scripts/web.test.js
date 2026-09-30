import { test } from "bun:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { Worker } from "node:worker_threads";
import { parseMaps, normalizeSolution, initialState, advanceState, validateSolution, solveInWasm, loadSolverModule, searchLimitMessage, parseMemoryLimit, SOLVER_MEMORY_MIB } from "../script.js";

const source = await readFile(new URL("../sokoban-maps-60.txt", import.meta.url), "utf8");
const maps = parseMaps(source);
const module = await WebAssembly.compile(await readFile(new URL("../zig-out/web/solver.wasm", import.meta.url)));

test("all maps preserve source dimensions, box counts, and coordinates", () => {
  assert.equal(maps.length, 61);
  assert.deepEqual(maps.map(map => map.id), Array.from({ length: 61 }, (_, i) => i));
  assert.equal(Math.max(...maps.map(map => map.width)), 29);
  assert.equal(Math.max(...maps.map(map => map.height)), 20);
  assert.equal(maps[0].player, 7);
  assert.equal(maps[1].width, 22);
  assert.equal(maps[1].cells[4], "X"); // Leading whitespace is not trimmed.
  assert.equal(maps.filter(map => map.boxes.size > 24).length, 7);
  assert.deepEqual(parseMaps(source.replace(/\n/g, "\r\n")), maps);
});

test("manual playback validates push labels and never mutates the initial map", () => {
  const map = maps[0];
  assert.equal(normalizeSolution(" d\n D\t"), "dD");
  assert.equal(normalizeSolution(" \n\t"), "");
  const result = validateSolution(map, "dD");
  assert.equal(result.solved, true);
  assert.equal(result.state.steps, 2);
  assert.equal(result.state.pushes, 1);
  assert.equal(map.player, 7);
  assert.equal(validateSolution(map, "d").solved, false);
  assert.throws(() => validateSolution(map, "dd"), /Step 2.*uppercase/);
  assert.throws(() => validateSolution(map, "D"), /must push a box/);
  assert.throws(() => validateSolution(map, "u"), /wall/);
  assert.throws(() => validateSolution(map, "dD;alert(1)"), /Use only/);
  const state = initialState(map);
  const before = structuredClone(state);
  assert.throws(() => advanceState(map, state, "u"));
  assert.deepEqual(state, before);
});

for (const maze of [0, 1, 40]) {
  test(`WebAssembly solves map ${maze} and reports monotonic progress`, () => {
    const reports = [];
    const result = solveInWasm(module, source, maze, (expanded, queued) => reports.push({ expanded, queued }));
    assert.equal(result.status, "solved");
    const checked = validateSolution(maps[maze], result.solution);
    assert.equal(checked.solved, true);
    assert.equal(checked.state.pushes, { 0: 1, 1: 116, 40: 81 }[maze]);
    assert.ok(reports.length >= (maze ? 3 : 1));
    assert.ok(reports.at(-1).expanded > 0);
    for (let i = 1; i < reports.length; i++) assert.ok(reports[i].expanded >= reports[i - 1].expanded);
  });
}

test("WASM solves the supplied source rather than an embedded map", () => {
  const custom = "Maze: 0\n\nXXXXX\nX@*.X\nXXXXX\n";
  assert.deepEqual(solveInWasm(module, custom, 0), { status: "solved", solution: "R" });
  const solved = "Maze: 0\n\nXXXX\nX@&X\nXXXX\n";
  assert.deepEqual(solveInWasm(module, solved, 0), { status: "solved", solution: "" });
  const dead = "Maze: 0\n\nXXXXX\nX*@ X\nX . X\nXXXXX\n";
  assert.deepEqual(solveInWasm(module, dead, 0), { status: "unsolvable" });
  assert.deepEqual(solveInWasm(module, custom, 9999), { status: "error", reason: "MazeNotFound" });
});

// Execute the production worker branch in a real background thread. This small
// host adapter supplies browser globals and file fetching; search and messages
// come from script.js unchanged. No browser automation dependency is needed.
function makeWorker() {
  return new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const { readFile } = require('node:fs/promises');
    globalThis.self = { postMessage: data => parentPort.postMessage(data) };
    globalThis.fetch = async url => new Response(await readFile(url));
    import(workerData.script).then(() => {
      parentPort.on('message', data => self.onmessage({ data }));
      parentPort.postMessage({ type: 'ready' });
    }).catch(error => { throw error; });
  `, { eval: true, workerData: { script: new URL("../zig-out/web/script.js", import.meta.url).href } });
}

test("worker delivers progress and a playable solution", async () => {
  const worker = makeWorker();
  let sawProgress = false;
  try {
    const result = await new Promise((resolve, reject) => {
      worker.on("error", reject);
      worker.on("message", data => {
        if (data.type === "ready") worker.postMessage({ type: "solve", source, maze: 1 });
        if (data.type === "progress") sawProgress = true;
        if (data.type === "result") resolve(data);
      });
    });
    assert.equal(sawProgress, true);
    assert.equal(result.status, "solved");
    assert.equal(result.memoryMiB, 4095);
    assert.equal(result.memoryMiB, SOLVER_MEMORY_MIB);
    assert.equal(validateSolution(maps[1], result.solution).solved, true);
  } finally { await worker.terminate(); }
}, 15000);

test("a busy solver worker can be stopped after progress arrives", async () => {
  const worker = makeWorker();
  let resultReceived = false;
  try {
    await new Promise((resolve, reject) => {
      worker.on("error", reject);
      worker.on("message", data => {
        if (data.type === "ready") worker.postMessage({ type: "solve", source, maze: 2 });
        if (data.type === "result") { resultReceived = true; reject(new Error("Search ended before cancellation test")); }
        if (data.type === "progress" && data.expanded > 0) resolve();
      });
    });
    // Main-thread events continue to run while WASM is searching in the worker.
    await new Promise(resolve => setTimeout(resolve, 10));
    await worker.terminate();
    assert.equal(resultReceived, false);
  } finally { await worker.terminate(); }
}, 15000);


test("WASM loader supports both packaged and repository-root pages", async () => {
  const bytes = await readFile(new URL("../zig-out/web/solver.wasm", import.meta.url));
  for (const packaged of [true, false]) {
    const requested = [];
    const loaded = await loadSolverModule(async url => {
      requested.push(url.href);
      if (!packaged && requested.length === 1) return new Response(null, { status: 404 });
      return new Response(bytes);
    }, "https://example.test/sokoban/script.js");
    assert.ok(loaded instanceof WebAssembly.Module);
    assert.deepEqual(requested, packaged
      ? ["https://example.test/sokoban/solver.wasm"]
      : ["https://example.test/sokoban/solver.wasm", "https://example.test/sokoban/zig-out/web/solver.wasm"]);
    assert.equal(solveInWasm(loaded, source, 0).solution, "dD");
  }
});

test("WASM loader reports missing artifacts after bounded fallback attempts", async () => {
  let requests = 0;
  await assert.rejects(loadSolverModule(async () => {
    requests++;
    return new Response(null, { status: 404 });
  }, "https://example.test/sokoban/script.js"), /Run zig build web/);
  assert.equal(requests, 2);
});


test("resource messages distinguish search allocation budget from WASM exhaustion", () => {
  assert.match(searchLimitMessage("OutOfMemory", 1024), /1024 MiB/);
  assert.doesNotMatch(searchLimitMessage("OutOfMemory", 1024), /512 MiB/);
  assert.match(searchLimitMessage("MemoryLimitReached", 768), /768 MiB search-allocation/);
  assert.match(searchLimitMessage("OutOfMemory"), /not a timeout/);
});


test("WASM API rejects invalid or unsupported memory limits", () => {
  for (const value of [64, 512, 1024, 2048, 2049, 3072, 4095]) assert.equal(parseMemoryLimit(String(value)), value);
  for (const value of ["", "abc", "Infinity", "0", "63", "4096", "512.5", "-64"]) {
    assert.throws(() => parseMemoryLimit(value), /64 to 4095 MiB/);
  }
});

test("WASM accepts per-instance memory ceilings and enforces them", () => {
  for (const mib of [64, 1024, 2048, 3072, 4095]) {
    const memory = new WebAssembly.Memory({ initial: 64, maximum: mib * 16 });
    const instance = new WebAssembly.Instance(module, { env: { memory, report_progress() {} } });
    assert.equal(instance.exports.memory, memory);
    assert.equal(memory.buffer.byteLength, 4 * 1024 * 1024);
    // Beyond-maximum growth fails without allocating gigabytes in the test.
    assert.throws(() => memory.grow(mib * 16), RangeError);
    assert.equal(memory.buffer.byteLength, 4 * 1024 * 1024);
    assert.deepEqual(solveInWasm(module, source, 0, () => {}, mib), { status: "solved", solution: "dD" });
  }
  assert.throws(() => solveInWasm(module, source, 0, () => {}, 4096), /64 to 4095 MiB/);
});
