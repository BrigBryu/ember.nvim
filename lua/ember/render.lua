local M = {}

local DEFAULT_HEAT_LEVELS = 11
local DEFAULT_RAMP = { " ", ".", ":", "^", "*", "x", "#", "%", "@", "&" }

local scene_modules = {
  fire = require("ember.scenes.fire"),
  lava = require("ember.scenes.lava"),
  spiral = require("ember.scenes.spiral"),
}

function M.clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

function M.ensure_scene(name)
  if scene_modules[name] then
    return name
  end
  return "fire"
end

local function build_lookup(opts)
  local heat_levels = math.max(1, tonumber(opts and opts.heat_levels) or DEFAULT_HEAT_LEVELS)
  local ramp = opts and opts.char_ramp or DEFAULT_RAMP
  if #ramp < 2 then
    ramp = DEFAULT_RAMP
  end

  local glyph_lookup = {}
  local group_lookup = {}
  local max_index = #ramp - 1

  for level = 0, heat_levels do
    local mapped = M.clamp(math.floor((level / heat_levels) * max_index + 0.5), 0, max_index)
    glyph_lookup[level] = ramp[mapped + 1]
    group_lookup[level] = ("EmberFire%d"):format(level)
  end

  return heat_levels, glyph_lookup, group_lookup
end

local function new_grid(size)
  local grid = {}
  for index = 1, size do
    grid[index] = 0
  end
  return grid
end

local function new_chars(size, fill)
  local chars = {}
  for index = 1, size do
    chars[index] = fill
  end
  return chars
end

local function new_row_buffers(height, width)
  local rows = {}
  local lines = {}
  local runs = {}

  for row = 1, height do
    rows[row] = {}
    lines[row] = string.rep(" ", width)
    runs[row] = {}
  end

  return rows, lines, runs
end

local function clear_runs(runs)
  for index = 1, #runs do
    runs[index] = nil
  end
end

local function clear_row_cells(state, row)
  local row_offset = state.row_offsets[row]
  local curr_chars = state.curr_chars
  local curr_levels = state.curr_levels

  for col = 1, state.width do
    local index = row_offset + col
    curr_chars[index] = " "
    curr_levels[index] = 0
  end
end

local function begin_frame(state)
  state.frame_id = state.frame_id + 1
  state.touched_count = 0
  state.active_count = 0
end

local function ensure_row_touched(state, row)
  if state.touched_stamp[row] == state.frame_id then
    return
  end

  state.touched_stamp[row] = state.frame_id
  state.touched_count = state.touched_count + 1
  state.touched_rows[state.touched_count] = row
  clear_row_cells(state, row)
end

local function mark_row_active(state, row)
  if state.active_stamp[row] == state.frame_id then
    return
  end

  state.active_stamp[row] = state.frame_id
  state.active_count = state.active_count + 1
  state.active_rows[state.active_count] = row
end

local function build_row_runs(state, row, row_offset)
  local runs = state.row_runs[row]
  local levels = state.curr_levels
  local groups = state.group_lookup

  clear_runs(runs)

  local run_count = 0
  local start_col = 1
  local last_level = levels[row_offset + 1]

  for col = 2, state.width do
    local level = levels[row_offset + col]
    if level ~= last_level then
      run_count = run_count + 1
      local run = runs[run_count] or {}
      run.group = groups[last_level]
      run.start_col = start_col - 1
      run.end_col = col - 1
      runs[run_count] = run
      start_col = col
      last_level = level
    end
  end

  run_count = run_count + 1
  local run = runs[run_count] or {}
  run.group = groups[last_level]
  run.start_col = start_col - 1
  run.end_col = state.width
  runs[run_count] = run

  for index = run_count + 1, #runs do
    runs[index] = nil
  end

  return run_count
end

local function materialize_row(state, row)
  local row_offset = state.row_offsets[row]
  local row_chars = state.row_buffers[row]

  for col = 1, state.width do
    row_chars[col] = state.curr_chars[row_offset + col]
  end

  state.lines[row] = table.concat(row_chars)
  return build_row_runs(state, row, row_offset)
end

local function finalize_frame(state)
  local prev_chars = state.prev_chars
  local prev_levels = state.prev_levels
  local curr_chars = state.curr_chars
  local curr_levels = state.curr_levels
  local dirty_rows = state.dirty_rows
  local prev_active_rows = state.prev_active_rows
  local prev_active_count = state.prev_active_count
  local frame_id = state.frame_id

  local dirty_count = 0
  local total_runs = 0

  for index = 1, state.touched_count do
    local row = state.touched_rows[index]
    local row_offset = state.row_offsets[row]
    local dirty = false

    for col = 1, state.width do
      local cell_index = row_offset + col
      if curr_chars[cell_index] ~= prev_chars[cell_index] or curr_levels[cell_index] ~= prev_levels[cell_index] then
        dirty = true
        break
      end
    end

    if dirty then
      dirty_count = dirty_count + 1
      dirty_rows[dirty_count] = row
      total_runs = total_runs + materialize_row(state, row)
    end
  end

  for index = 1, prev_active_count do
    local row = prev_active_rows[index]
    if state.touched_stamp[row] ~= frame_id and state.active_stamp[row] ~= frame_id then
      clear_row_cells(state, row)
      dirty_count = dirty_count + 1
      dirty_rows[dirty_count] = row
      total_runs = total_runs + materialize_row(state, row)
    end
  end

  for index = dirty_count + 1, #dirty_rows do
    dirty_rows[index] = nil
  end

  if dirty_count > 1 then
    table.sort(dirty_rows, function(a, b)
      return a < b
    end)
  end

  state.prev_chars, state.curr_chars = curr_chars, prev_chars
  state.prev_levels, state.curr_levels = curr_levels, prev_levels
  state.prev_active_rows, state.active_rows = state.active_rows, prev_active_rows
  state.prev_active_count = state.active_count

  state.frame.dirty_count = dirty_count
  state.frame.dirty_rows = dirty_rows
  state.frame.lines = state.lines
  state.frame.row_runs = state.row_runs
  state.frame.total_runs = total_runs
  state.frame.dirty_ratio = dirty_count / math.max(1, state.height)

  return state.frame
end

function M.index(state, row, col)
  return state.row_offsets[row] + col
end

function M.grid_get(state, row, col)
  return state.grid[state.row_offsets[row] + col]
end

function M.grid_set(state, row, col, value)
  state.grid[state.row_offsets[row] + col] = value
end

function M.next_grid_set(state, row, col, value)
  state.next_grid[state.row_offsets[row] + col] = value
end

function M.clear_grid(state, decay)
  local keep = decay or 0
  local grid = state.grid
  for index = 1, state.size do
    grid[index] = grid[index] * keep
  end
end

function M.swap_grids(state)
  state.grid, state.next_grid = state.next_grid, state.grid
end

function M.clear_next_grid(state)
  local next_grid = state.next_grid
  for index = 1, state.size do
    next_grid[index] = 0
  end
end

function M.max_heat(state)
  return state.max_heat
end

function M.highlight_for(state, level)
  return state.group_lookup[M.clamp(level, 0, state.max_heat)]
end

function M.glyph_for(state, level)
  return state.glyph_lookup[M.clamp(level, 0, state.max_heat)]
end

function M.set_cell(state, row, col, char, level)
  if row < 1 or row > state.height or col < 1 or col > state.width then
    return
  end

  ensure_row_touched(state, row)
  local index = state.row_offsets[row] + col
  local clamped = M.clamp(level or 0, 0, state.max_heat)
  state.curr_chars[index] = char
  state.curr_levels[index] = clamped

  if char ~= " " or clamped > 0 then
    mark_row_active(state, row)
  end
end

function M.paint_heat(state, row, col, level)
  if row < 1 or row > state.height or col < 1 or col > state.width then
    return
  end

  ensure_row_touched(state, row)
  local clamped = M.clamp(math.floor(level + 0.5), 0, state.max_heat)
  local index = state.row_offsets[row] + col
  state.curr_chars[index] = state.glyph_lookup[clamped]
  state.curr_levels[index] = clamped

  if clamped > 0 then
    mark_row_active(state, row)
  end
end

function M.scene_for(state)
  return scene_modules[state.scene]
end

function M.new(width, height, opts)
  local scene = M.ensure_scene(opts and opts.scene or "fire")
  local size = width * height
  local heat_levels, glyph_lookup, group_lookup = build_lookup(opts)
  local row_buffers, lines, row_runs = new_row_buffers(height, width)
  local row_offsets = {}
  local left_cols = {}
  local right_cols = {}

  for row = 1, height do
    row_offsets[row] = (row - 1) * width
  end

  for col = 1, width do
    left_cols[col] = math.max(1, col - 1)
    right_cols[col] = math.min(width, col + 1)
  end

  local state = {
    scene = scene,
    width = width,
    height = height,
    size = size,
    max_heat = heat_levels,
    glyph_lookup = glyph_lookup,
    group_lookup = group_lookup,
    grid = new_grid(size),
    next_grid = new_grid(size),
    curr_chars = new_chars(size, " "),
    prev_chars = new_chars(size, " "),
    curr_levels = new_grid(size),
    prev_levels = new_grid(size),
    row_buffers = row_buffers,
    row_runs = row_runs,
    dirty_rows = {},
    lines = lines,
    row_offsets = row_offsets,
    left_cols = left_cols,
    right_cols = right_cols,
    touched_rows = {},
    touched_stamp = {},
    touched_count = 0,
    active_rows = {},
    prev_active_rows = {},
    active_stamp = {},
    active_count = 0,
    prev_active_count = 0,
    frame_id = 0,
    phase = 0,
    intensity = 1,
    wave = opts and vim.deepcopy(opts.wave or {}) or {},
    lava = opts and vim.deepcopy(opts.lava or {}) or {},
    spiral = opts and vim.deepcopy(opts.spiral or {}) or {},
    fuel = {},
    tongues = {},
    smoke = {
      col = nil,
      life = 0,
    },
    lava_state = {},
    spiral_state = {},
    frame = {},
  }

  local scene_module = M.scene_for(state)
  if scene_module and scene_module.init then
    scene_module.init(state, M)
  end

  return state
end

function M.step(state, intensity)
  state.intensity = M.clamp(intensity or state.intensity or 1, 0, 1)
  M.scene_for(state).step(state, state.intensity, M)
end

function M.frame(state, intensity)
  begin_frame(state)
  M.step(state, intensity)
  M.scene_for(state).render(state, M)
  return finalize_frame(state)
end

return M
