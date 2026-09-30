export const SOLVER_MEMORY_MIB = 4095;

// Shared map/playback logic is also used by the Bun integration tests.
export function parseMaps(source) {
  const lines = source.replace(/\r/g, "").split("\n");
  const maps = [];
  const ids = new Set();
  for (let i = 0; i < lines.length; i++) {
    const header = /^Maze:\s*(\d+)\s*$/.exec(lines[i].trim());
    if (!header) continue;
    const id = Number(header[1]);
    while (++i < lines.length && lines[i].trim() !== "") { /* metadata */ }
    const rows = [];
    while (++i < lines.length && lines[i] !== "" && !lines[i].startsWith("***")) rows.push(lines[i]);
    const width = Math.max(0, ...rows.map(row => row.length));
    const height = rows.length;
    if (!width || !height || width > 30 || height > 22 || ids.has(id)) throw new Error(`Invalid dimensions or duplicate ID for map ${id}.`);
    const cells = rows.flatMap(row => [...row.padEnd(width, " ")]);
    const walls = new Set(), targets = new Set(), boxes = new Set();
    let player = -1;
    cells.forEach((cell, index) => {
      if (!"X@*.& ".includes(cell)) throw new Error(`Unknown map symbol in map ${id}.`);
      if (cell === "X") walls.add(index);
      if (cell === "." || cell === "&") targets.add(index);
      if (cell === "*" || cell === "&") boxes.add(index);
      if (cell === "@") {
        if (player !== -1) throw new Error(`Multiple players in map ${id}.`);
        player = index;
      }
    });
    if (player < 0 || boxes.size !== targets.size || boxes.size > 40) throw new Error(`Invalid player or box count in map ${id}.`);
    // Hide whitespace outside the walls while retaining the source coordinates.
    const exterior = new Set(), queue = [];
    const visit = index => {
      if (cells[index] === " " && !exterior.has(index)) { exterior.add(index); queue.push(index); }
    };
    for (let x = 0; x < width; x++) { visit(x); visit((height - 1) * width + x); }
    for (let y = 0; y < height; y++) { visit(y * width); visit(y * width + width - 1); }
    for (let q = 0; q < queue.length; q++) {
      const index = queue[q], x = index % width, y = Math.floor(index / width);
      if (x) visit(index - 1);
      if (x + 1 < width) visit(index + 1);
      if (y) visit(index - width);
      if (y + 1 < height) visit(index + width);
    }
    ids.add(id);
    maps.push({ id, width, height, cells, walls, targets, boxes, player, exterior });
  }
  if (!maps.length) throw new Error("No maps were found in sokoban-maps-60.txt.");
  return maps;
}

export function normalizeSolution(text) {
  const path = text.replace(/\s+/g, "");
  if (/[^udlrUDLR]/.test(path)) throw new Error("Use only u, d, l, r and U, D, L, R. Whitespace is allowed.");
  return path;
}

export function initialState(map) {
  return { player: map.player, boxes: new Set(map.boxes), steps: 0, pushes: 0 };
}

export function advanceState(map, state, move) {
  const delta = { u: [0, -1], d: [0, 1], l: [-1, 0], r: [1, 0] }[move.toLowerCase()];
  if (!delta) throw new Error("Invalid movement character.");
  const [dx, dy] = delta;
  const x = state.player % map.width, y = Math.floor(state.player / map.width);
  const inside = (cx, cy) => cx >= 0 && cy >= 0 && cx < map.width && cy < map.height;
  const nx = x + dx, ny = y + dy, next = ny * map.width + nx;
  if (!inside(nx, ny) || map.walls.has(next)) throw new Error("The player would walk into a wall.");
  const pushes = state.boxes.has(next);
  if (pushes !== (move === move.toUpperCase())) throw new Error(pushes ? "A box push must be uppercase." : "An uppercase move must push a box.");
  if (pushes) {
    const bx = nx + dx, by = ny + dy, boxNext = by * map.width + bx;
    if (!inside(bx, by) || map.walls.has(boxNext) || state.boxes.has(boxNext)) throw new Error("The box cannot move there.");
    state.boxes.delete(next);
    state.boxes.add(boxNext);
    state.pushes++;
  }
  state.player = next;
  state.steps++;
  return state;
}

export function validateSolution(map, text) {
  const path = normalizeSolution(text);
  const state = initialState(map);
  for (let i = 0; i < path.length; i++) {
    try { advanceState(map, state, path[i]); }
    catch (error) { throw new Error(`Step ${i + 1}: ${error.message}`); }
  }
  return { path, state, solved: [...map.targets].every(target => state.boxes.has(target)) };
}

export function parseMemoryLimit(value) {
  const mib = Number(value);
  if (!Number.isInteger(mib) || mib < 64 || mib > 4095) {
    throw new Error("Memory must be a whole number from 64 to 4095 MiB.");
  }
  return mib;
}

// The very same Zig search used by the CLI, with input from the fetched map file.
export function solveInWasm(module, source, maze, onProgress = () => {}, memoryMiB = SOLVER_MEMORY_MIB) {
  memoryMiB = parseMemoryLimit(memoryMiB);
  // Import memory so each solve has its own actual WASM ceiling. Only 4 MiB is
  // allocated initially; the selected maximum is a growth limit, not a reserve.
  const memory = new WebAssembly.Memory({ initial: 64, maximum: memoryMiB * 16 });
  const instance = new WebAssembly.Instance(module, { env: { memory, report_progress: onProgress } });
  const api = instance.exports;
  const bytes = new TextEncoder().encode(source);
  const pointer = api.input_alloc(bytes.length) >>> 0;
  if (!pointer) throw new Error("Not enough memory to load the maps.");
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  const code = api.solve_map(maze, memoryMiB);
  const read = (ptr, len) => len ? new TextDecoder().decode(new Uint8Array(api.memory.buffer, ptr >>> 0, len)) : "";
  if (code === 0) return { status: "solved", solution: read(api.solution_ptr(), api.solution_len()) };
  if (code === 1) return { status: "unsolvable" };
  return { status: code === 2 ? "limit" : "error", reason: read(api.error_ptr(), api.error_len()) };
}

// The source page can be served from the repository root, while packaged builds
// place the module next to script.js. Both use the same generated WASM artifact.
export async function loadSolverModule(fetcher = fetch, base = import.meta.url) {
  const failures = [];
  for (const path of ["./solver.wasm", "./zig-out/web/solver.wasm"]) {
    try {
      const response = await fetcher(new URL(path, base));
      if (!response.ok) {
        failures.push(`${path}: HTTP ${response.status}`);
        continue;
      }
      return await WebAssembly.compile(await response.arrayBuffer());
    } catch (error) {
      failures.push(`${path}: ${error.message}`);
    }
  }
  throw new Error(`Could not load solver.wasm. Run zig build web, then reload this page. (${failures.join("; ")})`);
}

export function searchLimitMessage(reason, memoryMiB = SOLVER_MEMORY_MIB) {
  const detail = {
    MemoryLimitReached: `The solver reached its ${memoryMiB} MiB search-allocation budget.`,
    OutOfMemory: `The solver ran out of memory; its WebAssembly memory ceiling is ${memoryMiB} MiB.`,
    ExpansionLimitReached: "The solver reached its explored-state limit.",
    StoredStateLimitReached: "The solver reached its stored-state limit.",
  }[reason] || "The solver reached a resource limit.";
  return `${detail} A solution may still exist. This was not a timeout.`;
}

function startWorker() {
  self.onmessage = async ({ data }) => {
    if (data.type !== "solve") return;
    try {
      const memoryMiB = SOLVER_MEMORY_MIB;
      const module = await loadSolverModule();
      let lastUpdate = -Infinity, expanded = 0, queued = 0;
      const result = solveInWasm(module, data.source, data.maze, (count, waiting) => {
        expanded = count; queued = waiting;
        if (performance.now() - lastUpdate >= 100) {
          self.postMessage({ type: "progress", expanded, queued });
          lastUpdate = performance.now();
        }
      }, memoryMiB);
      self.postMessage({ type: "result", ...result, expanded, queued, memoryMiB });
    } catch (error) {
      self.postMessage({ type: "result", status: "error", reason: error.message });
    }
  };
}

function startUI() {
  const savedMapKey = "sokoban.currentMap";
  const $ = id => document.getElementById(id);
  const canvas = $("board"), context = canvas.getContext("2d");
  const select = $("map-select"), textarea = $("solution");
  const run = $("run"), stop = $("stop"), solve = $("solve");
  const previous = $("previous"), next = $("next"), progress = $("progress");
  let source = "", maps = [], selected = 0, state = null;
  let timer = null, worker = null, mode = "idle", playPath = "";
  let maxWidth = 29, maxHeight = 20;
  const cell = 32;
  const map = () => maps[selected];
  const number = value => value.toLocaleString();

  function setStatus(message, error = false) {
    $("status").textContent = message;
    $("status").dataset.error = String(error);
  }
  function updateControls() {
    const ready = maps.length > 0;
    select.disabled = !ready;
    previous.disabled = !ready || selected === 0;
    next.disabled = !ready || selected === maps.length - 1;
    textarea.disabled = !ready;
    textarea.readOnly = mode !== "idle";
    run.disabled = !ready || mode !== "idle" || !textarea.value.trim();
    solve.disabled = !ready || mode !== "idle";
    stop.disabled = mode === "idle";
  }
  function draw() {
    if (!state || !context) return;
    context.clearRect(0, 0, canvas.width, canvas.height);
    const current = map();
    const rounded = (x, y, w, h, r, color) => {
      context.fillStyle = color; context.beginPath(); context.roundRect(x, y, w, h, r); context.fill();
    };
    for (let y = 0; y < current.height; y++) {
      for (let x = 0; x < current.width; x++) {
        const index = y * current.width + x, px = x * cell, py = y * cell;
        if (current.exterior.has(index)) continue;
        if (current.walls.has(index)) {
          rounded(px + 1, py + 1, cell - 2, cell - 2, 3, "#435965");
          context.fillStyle = "#607681"; context.fillRect(px + 4, py + 3, cell - 8, 2);
          continue;
        }
        rounded(px + 1, py + 1, cell - 2, cell - 2, 2, "#faf9f3");
        if (current.targets.has(index)) {
          context.beginPath(); context.arc(px + 16, py + 16, 6, 0, Math.PI * 2);
          context.strokeStyle = "#438572"; context.lineWidth = 2; context.stroke();
          context.fillStyle = "#bdd3c3"; context.fill();
        }
      }
    }
    for (const index of state.boxes) {
      const px = (index % current.width) * cell, py = Math.floor(index / current.width) * cell;
      const onTarget = current.targets.has(index);
      rounded(px + 4, py + 5, 24, 24, 3, onTarget ? "#3d7967" : "#966634");
      rounded(px + 4, py + 3, 24, 24, 3, onTarget ? "#79aa89" : "#d9a65e");
      context.strokeStyle = onTarget ? "#3d7967" : "#966634"; context.lineWidth = 1.5;
      context.strokeRect(px + 8, py + 7, 16, 16);
      context.beginPath(); context.moveTo(px + 8, py + 7); context.lineTo(px + 24, py + 23); context.stroke();
    }
    const px = (state.player % current.width) * cell + 16, py = Math.floor(state.player / current.width) * cell + 16;
    context.fillStyle = "#0e5b54"; context.beginPath(); context.arc(px, py + 2, 11, 0, Math.PI * 2); context.fill();
    context.fillStyle = "#198b7e"; context.beginPath(); context.arc(px, py, 11, 0, Math.PI * 2); context.fill();
    context.fillStyle = "#fff"; context.beginPath(); context.arc(px - 3, py - 2, 1.7, 0, Math.PI * 2); context.arc(px + 3, py - 2, 1.7, 0, Math.PI * 2); context.fill();
    canvas.setAttribute("aria-label", `Map ${current.id}, ${current.width} by ${current.height}, ${state.boxes.size} boxes. Player at column ${state.player % current.width + 1}, row ${Math.floor(state.player / current.width) + 1}. Step ${state.steps}.`);
  }
  function cancel() {
    if (mode === "solving") $("metrics").textContent = "";
    if (timer !== null) clearInterval(timer);
    timer = null;
    if (worker) worker.terminate();
    worker = null;
    mode = "idle";
    progress.hidden = true;
    updateControls();
  }
  function choose(index) {
    if (index < 0 || index >= maps.length) return;
    cancel();
    selected = index;
    try { window.localStorage.setItem(savedMapKey, String(map().id)); }
    catch { /* Selection still works when storage is unavailable. */ }
    select.value = String(index);
    textarea.value = "";
    state = initialState(map());
    $("map-info").textContent = `${map().width} × ${map().height} · ${map().boxes.size} boxes`;
    $("metrics").textContent = "";
    setStatus("Ready. Paste a solution or choose Solve.");
    draw(); updateControls();
  }
  previous.addEventListener("click", () => choose(selected - 1));
  next.addEventListener("click", () => choose(selected + 1));
  select.addEventListener("change", () => choose(Number(select.value)));
  document.addEventListener("keydown", event => {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || event.isComposing) return;
    if (event.target.closest?.("textarea, input, [contenteditable]")) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      choose(selected + (event.key === "ArrowLeft" ? -1 : 1));
    }
  });
  textarea.addEventListener("input", () => {
    cancel();
    state = initialState(map());
    $("metrics").textContent = "";
    setStatus(textarea.value.trim() ? "Ready to run from the starting position." : "Paste a solution or choose Solve.");
    draw(); updateControls();
  });
  stop.addEventListener("click", () => {
    const wasSolving = mode === "solving";
    cancel();
    setStatus(wasSolving ? "Solver stopped." : `Stopped at step ${state.steps}. Run restarts from the beginning.`);
  });
  run.addEventListener("click", () => {
    let checked;
    try { checked = validateSolution(map(), textarea.value); }
    catch (error) { setStatus(error.message, true); return; }
    if (!checked.path) return;
    cancel();
    state = initialState(map()); playPath = checked.path; mode = "playing";
    progress.hidden = false; progress.max = playPath.length; progress.value = 0;
    progress.setAttribute("aria-label", "Playback progress");
    setStatus("Playing solution…");
    $("metrics").textContent = `Step 0 / ${number(playPath.length)} · 0 pushes`;
    draw(); updateControls();
    timer = setInterval(() => {
      advanceState(map(), state, playPath[state.steps]);
      progress.value = state.steps;
      $("metrics").textContent = `Step ${number(state.steps)} / ${number(playPath.length)} · ${number(state.pushes)} pushes`;
      draw();
      if (state.steps === playPath.length) {
        cancel();
        setStatus(checked.solved ? "Solved. Every box is on a target." : "Sequence finished. Some boxes are still off target.");
      }
    }, 200);
  });
  solve.addEventListener("click", () => {
    cancel();
    state = initialState(map()); draw(); mode = "solving";
    progress.hidden = false; progress.removeAttribute("value"); progress.setAttribute("aria-label", "Solver running");
    setStatus("Solving…"); $("metrics").textContent = "Loading solver…";
    updateControls();
    let active;
    try { active = new Worker(new URL("./script.js", import.meta.url), { type: "module" }); }
    catch (error) { cancel(); setStatus(`Could not start solver: ${error.message}`, true); return; }
    worker = active;
    active.onmessage = ({ data }) => {
      if (worker !== active) return; // Ignore replies from a cancelled/previous map.
      if (data.type === "progress") {
        $("metrics").textContent = `${number(data.expanded)} states analysed · ${number(data.queued)} queued`;
        return;
      }
      if (data.type !== "result") return;
      cancel();
      if (Number.isFinite(data.expanded)) $("metrics").textContent = `${number(data.expanded)} states analysed`;
      if (data.status === "solved") {
        try {
          const checked = validateSolution(map(), data.solution);
          if (!checked.solved) throw new Error("Solver returned an incomplete solution.");
          textarea.value = data.solution;
          setStatus(data.solution.length ? `Solution found: ${number(data.solution.length)} steps, ${number(checked.state.pushes)} pushes. Choose Run to play.` : "This map is already solved.");
        } catch (error) { setStatus(error.message, true); }
      } else if (data.status === "unsolvable") {
        setStatus("No solution exists for this map.");
      } else if (data.status === "limit") {
        setStatus(searchLimitMessage(data.reason));
      } else {
        setStatus(`Solver failed: ${data.reason || "Unknown error"}`, true);
      }
      updateControls();
    };
    active.onerror = event => {
      if (worker !== active) return;
      cancel(); setStatus(`Could not run the solver: ${event.message || "Worker failed to load."}`, true);
    };
    active.postMessage({ type: "solve", source, maze: map().id });
  });
  window.addEventListener("pagehide", cancel);
  (async () => {
    try {
      const response = await fetch(new URL("./sokoban-maps-60.txt", import.meta.url));
      if (!response.ok) throw new Error(`Map request failed (HTTP ${response.status}).`);
      source = await response.text(); maps = parseMaps(source);
      maxWidth = Math.max(...maps.map(m => m.width)); maxHeight = Math.max(...maps.map(m => m.height));
      canvas.width = maxWidth * cell; canvas.height = maxHeight * cell;
      canvas.style.aspectRatio = `${maxWidth} / ${maxHeight}`;
      select.replaceChildren(...maps.map((m, index) => new Option(`Map ${m.id}`, String(index))));
      let restoredIndex = 0;
      try {
        const savedId = window.localStorage.getItem(savedMapKey);
        const index = maps.findIndex(m => String(m.id) === savedId);
        if (index >= 0) restoredIndex = index;
      } catch { /* Fall back to the first map when storage is unavailable. */ }
      choose(restoredIndex);
    } catch (error) {
      maps = [];
      $("map-info").textContent = "Maps unavailable";
      setStatus(`Could not load maps: ${error.message} Serve this page over HTTP rather than opening it as a file.`, true);
      updateControls();
    }
  })();
}

if (typeof document !== "undefined") startUI();
else if (typeof self !== "undefined" && typeof self.postMessage === "function") startWorker();
