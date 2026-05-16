local layout = require("ember.layout")
local palette = require("ember.palette")
local render = require("ember.render")

local M = {}

local defaults = {
  width = 33,
  height = 12,
  fps = 8,
  adaptive_fps = {
    enabled = false,
    idle_fps = 4,
    active_fps = 8,
  },
  full_rewrite_threshold = 0.6,
  scene = "fire",
  zindex = 40,
  border = "none",
  row_offset = 1,
  col_offset = 0,
  intensity = 0.65,
  palette = "auto",
  heat_levels = 11,
  char_ramp = { " ", ".", ":", "^", "*", "x", "#", "%", "@", "&" },
  wave = {
    enabled = true,
    style = "sway_breathe",
    amount = "subtle",
  },
  lava = {
    blobs = 4,
    speed = 0.16,
    pulse_amount = 0.08,
    center_bias_x = 0,
    center_bias_y = 0,
  },
  spiral = {
    turns = 1.85,
    thickness = 1.15,
    rotation_speed = 0.24,
    pulse_amount = 0.08,
    center_bias_x = 0,
    center_bias_y = 0,
  },
  custom_palette = nil,
  force_palette = false,
  attach = {
    mode = "nvim-tree",
    position = "bottom-left",
  },
}

local function new_stats()
  return {
    frames = 0,
    frame_time_ns = 0,
    render_frame_ns = 0,
    set_lines_ns = 0,
    clear_namespace_ns = 0,
    highlight_ns = 0,
    dirty_rows = 0,
    rows_rewritten = 0,
    set_lines_calls = 0,
    highlight_calls = 0,
    full_rewrites = 0,
    last = {
      dirty_rows = 0,
      rows_rewritten = 0,
      set_lines_calls = 0,
      highlight_calls = 0,
      full_rewrite = false,
      frame_time_ns = 0,
      render_frame_ns = 0,
      set_lines_ns = 0,
      clear_namespace_ns = 0,
      highlight_ns = 0,
      dirty_ratio = 0,
      interval_ms = 0,
    },
  }
end

local state = {
  opts = nil,
  buf = nil,
  win = nil,
  timer = nil,
  timer_cb = nil,
  timer_interval = nil,
  ns = vim.api.nvim_create_namespace("ember.nvim"),
  renderer = nil,
  active = false,
  stats = new_stats(),
  activity_boost = 0,
  update_scratch = {
    segments = {},
    line_slice = {},
  },
}

local function merge_opts(opts)
  return vim.tbl_deep_extend("force", {}, defaults, state.opts or {}, opts or {})
end

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function highlight_exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl and next(hl) ~= nil
end

local function clear_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
    state.timer_cb = nil
    state.timer_interval = nil
  end
end

local function close_window()
  if is_valid_win(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

local function ensure_buffer()
  if is_valid_buf(state.buf) then
    return state.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_name(buf, "ember://fire")

  state.buf = buf
  return buf
end

local function window_config(opts)
  local resolved = layout.resolve(opts)
  if resolved.config then
    return resolved.config
  end
  return resolved
end

local function ensure_window(opts)
  local buf = ensure_buffer()
  local config = window_config(opts)
  local use_tree_hl = opts.attach.mode == "nvim-tree" and highlight_exists("NvimTreeNormal")
  local normal_hl = use_tree_hl and "NvimTreeNormal" or "Normal"
  local border_hl = use_tree_hl and "NvimTreeNormal" or "FloatBorder"
  local winblend = use_tree_hl and 8 or 0

  if is_valid_win(state.win) then
    config.noautocmd = nil
    vim.api.nvim_win_set_config(state.win, config)
    vim.api.nvim_set_option_value("winhl", ("Normal:%s,FloatBorder:%s"):format(normal_hl, border_hl), { win = state.win })
    vim.api.nvim_set_option_value("winblend", winblend, { win = state.win })
    return state.win
  end

  local win = vim.api.nvim_open_win(buf, false, config)
  vim.api.nvim_set_option_value("winhl", ("Normal:%s,FloatBorder:%s"):format(normal_hl, border_hl), { win = win })
  vim.api.nvim_set_option_value("winblend", winblend, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })

  state.win = win
  return win
end

local function stop_if_closed()
  if state.active and not is_valid_win(state.win) then
    M.stop()
    return true
  end
  return false
end

local function apply_palette(opts)
  palette.apply({
    palette = opts.palette,
    custom_palette = opts.custom_palette,
    force = opts.force_palette,
  })
end

local function mark_active(frames)
  state.activity_boost = math.max(state.activity_boost or 0, frames or 6)
end

local function current_fps(opts)
  local adaptive = opts.adaptive_fps or {}
  local configured = math.max(1, tonumber(opts.fps) or defaults.fps)

  if adaptive.enabled ~= true then
    return configured
  end

  local active_fps = math.max(1, tonumber(adaptive.active_fps) or configured)
  local idle_fps = math.max(1, tonumber(adaptive.idle_fps) or math.min(active_fps, 4))

  if state.activity_boost and state.activity_boost > 0 then
    return active_fps
  end

  local dirty_ratio = state.stats.last.dirty_ratio or 1
  if dirty_ratio <= 0.35 or (opts.intensity or 0) <= 0.35 then
    return math.min(active_fps, idle_fps)
  end

  return active_fps
end

local function interval_for(opts)
  return math.max(16, math.floor(1000 / current_fps(opts)))
end

local function build_renderer_opts(opts)
  local adaptive = opts.adaptive_fps or {}
  local active_fps = math.max(1, tonumber(adaptive.active_fps) or tonumber(opts.fps) or defaults.fps)

  return {
    scene = opts.scene,
    char_ramp = opts.char_ramp,
    heat_levels = opts.heat_levels,
    wave = vim.tbl_extend("force", {}, opts.wave, { fps = active_fps }),
    lava = opts.lava,
    spiral = opts.spiral,
  }
end

local function rewrite_threshold(opts)
  local threshold = tonumber(opts.full_rewrite_threshold) or defaults.full_rewrite_threshold
  if opts.scene == "spiral" then
    threshold = math.min(0.8, threshold + 0.12)
  end
  return threshold
end

local function should_full_rewrite(frame, opts)
  if frame.dirty_count == 0 then
    return false
  end
  if frame.dirty_count == opts.height then
    return true
  end
  return frame.dirty_ratio >= rewrite_threshold(opts)
end

local function build_segments(rows, row_count, scratch)
  local segments = scratch.segments
  local segment_count = 0
  local start_row = nil
  local previous = nil

  for index = 1, row_count do
    local row = rows[index]
    if not start_row then
      start_row = row
      previous = row
    elseif row == previous + 1 then
      previous = row
    else
      segment_count = segment_count + 1
      local segment = segments[segment_count] or {}
      segment.start_row = start_row
      segment.end_row = previous
      segments[segment_count] = segment
      start_row = row
      previous = row
    end
  end

  if start_row then
    segment_count = segment_count + 1
    local segment = segments[segment_count] or {}
    segment.start_row = start_row
    segment.end_row = previous
    segments[segment_count] = segment
  end

  for index = segment_count + 1, #segments do
    segments[index] = nil
  end

  return segments, segment_count
end

local function line_slice(lines, start_row, end_row, scratch)
  local subset = scratch.line_slice
  local index = 1

  for row = start_row, end_row do
    subset[index] = lines[row]
    index = index + 1
  end

  for clear_index = index, #subset do
    subset[clear_index] = nil
  end

  return subset
end

local function apply_row_highlights(buf, row, runs)
  local applied = 0
  for index = 1, #runs do
    local run = runs[index]
    vim.api.nvim_buf_add_highlight(buf, state.ns, run.group, row - 1, run.start_col, run.end_col)
    applied = applied + 1
  end
  return applied
end

local function new_metrics()
  return {
    rows_rewritten = 0,
    set_lines_calls = 0,
    highlight_calls = 0,
    set_lines_ns = 0,
    clear_namespace_ns = 0,
    highlight_ns = 0,
  }
end

local function apply_frame_updates(buf, opts, frame, scratch, metrics)
  local full_rewrite = should_full_rewrite(frame, opts)

  if frame.dirty_count == 0 then
    return full_rewrite
  end

  if full_rewrite then
    local start_ns = vim.uv.hrtime()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, frame.lines)
    metrics.set_lines_ns = metrics.set_lines_ns + (vim.uv.hrtime() - start_ns)

    start_ns = vim.uv.hrtime()
    vim.api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
    metrics.clear_namespace_ns = metrics.clear_namespace_ns + (vim.uv.hrtime() - start_ns)

    start_ns = vim.uv.hrtime()
    for row = 1, opts.height do
      metrics.highlight_calls = metrics.highlight_calls + apply_row_highlights(buf, row, frame.row_runs[row])
    end
    metrics.highlight_ns = metrics.highlight_ns + (vim.uv.hrtime() - start_ns)
    metrics.rows_rewritten = opts.height
    metrics.set_lines_calls = 1

    return full_rewrite
  end

  local segments, segment_count = build_segments(frame.dirty_rows, frame.dirty_count, scratch)

  for index = 1, segment_count do
    local segment = segments[index]
    local start_ns = vim.uv.hrtime()
    vim.api.nvim_buf_set_lines(
      buf,
      segment.start_row - 1,
      segment.end_row,
      false,
      line_slice(frame.lines, segment.start_row, segment.end_row, scratch)
    )
    metrics.set_lines_ns = metrics.set_lines_ns + (vim.uv.hrtime() - start_ns)
    metrics.set_lines_calls = metrics.set_lines_calls + 1
    metrics.rows_rewritten = metrics.rows_rewritten + (segment.end_row - segment.start_row + 1)

    start_ns = vim.uv.hrtime()
    vim.api.nvim_buf_clear_namespace(buf, state.ns, segment.start_row - 1, segment.end_row)
    metrics.clear_namespace_ns = metrics.clear_namespace_ns + (vim.uv.hrtime() - start_ns)

    start_ns = vim.uv.hrtime()
    for row = segment.start_row, segment.end_row do
      metrics.highlight_calls = metrics.highlight_calls + apply_row_highlights(buf, row, frame.row_runs[row])
    end
    metrics.highlight_ns = metrics.highlight_ns + (vim.uv.hrtime() - start_ns)
  end

  return full_rewrite
end

local function record_frame(frame_ns, render_frame_ns, dirty_count, metrics, full_rewrite)
  local stats = state.stats
  stats.frames = stats.frames + 1
  stats.frame_time_ns = stats.frame_time_ns + frame_ns
  stats.render_frame_ns = stats.render_frame_ns + render_frame_ns
  stats.set_lines_ns = stats.set_lines_ns + metrics.set_lines_ns
  stats.clear_namespace_ns = stats.clear_namespace_ns + metrics.clear_namespace_ns
  stats.highlight_ns = stats.highlight_ns + metrics.highlight_ns
  stats.dirty_rows = stats.dirty_rows + dirty_count
  stats.rows_rewritten = stats.rows_rewritten + metrics.rows_rewritten
  stats.set_lines_calls = stats.set_lines_calls + metrics.set_lines_calls
  stats.highlight_calls = stats.highlight_calls + metrics.highlight_calls

  if full_rewrite then
    stats.full_rewrites = stats.full_rewrites + 1
  end

  stats.last.dirty_rows = dirty_count
  stats.last.rows_rewritten = metrics.rows_rewritten
  stats.last.set_lines_calls = metrics.set_lines_calls
  stats.last.highlight_calls = metrics.highlight_calls
  stats.last.full_rewrite = full_rewrite
  stats.last.frame_time_ns = frame_ns
  stats.last.render_frame_ns = render_frame_ns
  stats.last.set_lines_ns = metrics.set_lines_ns
  stats.last.clear_namespace_ns = metrics.clear_namespace_ns
  stats.last.highlight_ns = metrics.highlight_ns
  stats.last.dirty_ratio = dirty_count / math.max(1, state.opts and state.opts.height or 1)
  stats.last.interval_ms = state.timer_interval or 0
end

local function rearm_timer(interval, immediate)
  if not state.active then
    return
  end

  if state.timer and state.timer_interval == interval then
    return
  end

  if state.timer then
    state.timer:stop()
    state.timer:close()
  end

  local timer = vim.uv.new_timer()
  state.timer = timer
  state.timer_interval = interval
  state.timer_cb = vim.schedule_wrap(function()
    if state.active then
      M._draw_frame()
    end
  end)

  timer:start(immediate and 0 or interval, interval, state.timer_cb)
end

function M._draw_frame()
  if stop_if_closed() then
    return
  end

  local opts = state.opts
  local buf = ensure_buffer()
  ensure_window(opts)

  local frame_start = vim.uv.hrtime()
  local render_start = vim.uv.hrtime()
  local frame = render.frame(state.renderer, opts.intensity)
  local render_frame_ns = vim.uv.hrtime() - render_start
  local dirty_count = frame.dirty_count
  local metrics = new_metrics()
  local full_rewrite = false

  if dirty_count > 0 then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    full_rewrite = apply_frame_updates(buf, opts, frame, state.update_scratch, metrics)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end

  local frame_ns = vim.uv.hrtime() - frame_start
  record_frame(frame_ns, render_frame_ns, dirty_count, metrics, full_rewrite)

  if state.activity_boost and state.activity_boost > 0 then
    state.activity_boost = state.activity_boost - 1
  end

  local next_interval = interval_for(opts)
  if next_interval ~= state.timer_interval then
    rearm_timer(next_interval, false)
  end
end

local function setup_autocmds()
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = vim.api.nvim_create_augroup("ember.nvim", { clear = true }),
    callback = function()
      if state.opts then
        apply_palette(state.opts)
      end
    end,
  })
end

function M.setup(opts)
  state.opts = merge_opts(opts)
  apply_palette(state.opts)
  setup_autocmds()
  return state.opts
end

function M.start(opts)
  state.opts = merge_opts(opts)
  state.stats = new_stats()
  state.renderer = render.new(state.opts.width, state.opts.height, build_renderer_opts(state.opts))
  state.active = true

  apply_palette(state.opts)
  mark_active(8)
  ensure_window(state.opts)
  rearm_timer(interval_for(state.opts), true)
end

function M.stop()
  state.active = false
  clear_timer()
  close_window()
  state.renderer = nil
end

function M.toggle(opts)
  if state.active then
    M.stop()
  else
    M.start(opts)
  end
end

function M.set_intensity(value)
  local numeric = tonumber(value)
  if not numeric then
    return
  end

  state.opts = merge_opts()
  state.opts.intensity = math.max(0, math.min(numeric, 1))
  mark_active(8)

  if state.renderer then
    state.renderer.intensity = state.opts.intensity
  end
end

function M.is_running()
  return state.active
end

function M.stats()
  return vim.deepcopy(state.stats)
end

function M.benchmark(opts)
  local merged = vim.tbl_deep_extend("force", {}, state.opts or defaults, opts or {})
  local frames = math.max(1, tonumber(merged.frames) or 180)
  local renderer = render.new(merged.width, merged.height, build_renderer_opts(merged))
  local bench_buf = vim.api.nvim_create_buf(false, true)
  local scratch = {
    segments = {},
    line_slice = {},
  }
  local stats = {
    frames = frames,
    avg_frame_ms = 0,
    avg_render_frame_ms = 0,
    avg_set_lines_ms = 0,
    avg_clear_namespace_ms = 0,
    avg_highlight_ms = 0,
    avg_dirty_rows = 0,
    avg_rows_rewritten = 0,
    avg_set_lines_calls = 0,
    avg_highlight_calls = 0,
    full_rewrites = 0,
  }

  local frame_time_ns = 0
  local render_frame_ns = 0
  local set_lines_ns = 0
  local clear_namespace_ns = 0
  local highlight_ns = 0
  local dirty_rows = 0
  local rows_rewritten = 0
  local set_lines_calls = 0
  local highlight_calls = 0

  vim.api.nvim_set_option_value("modifiable", true, { buf = bench_buf })

  for _ = 1, frames do
    local frame_start = vim.uv.hrtime()
    local render_start = vim.uv.hrtime()
    local frame = render.frame(renderer, merged.intensity)
    local render_ns = vim.uv.hrtime() - render_start
    local metrics = new_metrics()
    local full_rewrite = apply_frame_updates(bench_buf, merged, frame, scratch, metrics)

    frame_time_ns = frame_time_ns + (vim.uv.hrtime() - frame_start)
    render_frame_ns = render_frame_ns + render_ns
    set_lines_ns = set_lines_ns + metrics.set_lines_ns
    clear_namespace_ns = clear_namespace_ns + metrics.clear_namespace_ns
    highlight_ns = highlight_ns + metrics.highlight_ns
    dirty_rows = dirty_rows + frame.dirty_count
    rows_rewritten = rows_rewritten + metrics.rows_rewritten
    set_lines_calls = set_lines_calls + metrics.set_lines_calls
    highlight_calls = highlight_calls + metrics.highlight_calls

    if full_rewrite then
      stats.full_rewrites = stats.full_rewrites + 1
    end
  end

  pcall(vim.api.nvim_buf_delete, bench_buf, { force = true })

  stats.avg_frame_ms = (frame_time_ns / frames) / 1000000
  stats.avg_render_frame_ms = (render_frame_ns / frames) / 1000000
  stats.avg_set_lines_ms = (set_lines_ns / frames) / 1000000
  stats.avg_clear_namespace_ms = (clear_namespace_ns / frames) / 1000000
  stats.avg_highlight_ms = (highlight_ns / frames) / 1000000
  stats.avg_dirty_rows = dirty_rows / frames
  stats.avg_rows_rewritten = rows_rewritten / frames
  stats.avg_set_lines_calls = set_lines_calls / frames
  stats.avg_highlight_calls = highlight_calls / frames

  return stats
end

return M
