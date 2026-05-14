local layout = require("ember.layout")
local palette = require("ember.palette")
local render = require("ember.render")

local M = {}

local defaults = {
  width = 33,
  height = 12,
  fps = 10,
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
  custom_palette = nil,
  force_palette = false,
  attach = {
    mode = "nvim-tree",
    position = "bottom-left",
  },
}

local state = {
  opts = nil,
  buf = nil,
  win = nil,
  timer = nil,
  ns = vim.api.nvim_create_namespace("ember.nvim"),
  renderer = nil,
  active = false,
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

local function draw_frame()
  if stop_if_closed() then
    return
  end

  local opts = state.opts
  local buf = ensure_buffer()
  ensure_window(opts)

  render.step(state.renderer, opts.intensity)
  local lines, highlights = render.lines(state.renderer)

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)

  for row, columns in ipairs(highlights) do
    for col, group in ipairs(columns) do
      vim.api.nvim_buf_add_highlight(buf, state.ns, group, row - 1, col - 1, col)
    end
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function start_timer()
  clear_timer()

  local interval = math.max(16, math.floor(1000 / state.opts.fps))
  local timer = vim.uv.new_timer()

  timer:start(
    0,
    interval,
    vim.schedule_wrap(function()
      if state.active then
        draw_frame()
      end
    end)
  )

  state.timer = timer
end

local function setup_autocmds()
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = vim.api.nvim_create_augroup("ember.nvim", { clear = true }),
    callback = function()
      if state.opts then
        palette.apply({
          palette = state.opts.palette,
          custom_palette = state.opts.custom_palette,
          force = state.opts.force_palette,
        })
      end
    end,
  })
end

function M.setup(opts)
  state.opts = merge_opts(opts)

  palette.apply({
    palette = state.opts.palette,
    custom_palette = state.opts.custom_palette,
    force = state.opts.force_palette,
  })

  setup_autocmds()
  return state.opts
end

function M.start(opts)
  state.opts = merge_opts(opts)

  palette.apply({
    palette = state.opts.palette,
    custom_palette = state.opts.custom_palette,
    force = state.opts.force_palette,
  })

  state.renderer = render.new(state.opts.width, state.opts.height, {
    char_ramp = state.opts.char_ramp,
    heat_levels = state.opts.heat_levels,
    wave = state.opts.wave,
    fps = state.opts.fps,
  })
  state.active = true
  ensure_window(state.opts)
  draw_frame()
  start_timer()
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
  if state.renderer then
    state.renderer.intensity = state.opts.intensity
  end
end

function M.is_running()
  return state.active
end

return M
