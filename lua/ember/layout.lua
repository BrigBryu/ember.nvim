local M = {}

local function tree_window()
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok or not api or not api.tree then
    return nil
  end

  local winid = api.tree.winid and api.tree.winid()
  if winid and vim.api.nvim_win_is_valid(winid) then
    return winid
  end

  return nil
end

local function float_config(opts)
  return {
    relative = "editor",
    anchor = "NW",
    width = opts.width,
    height = opts.height,
    row = math.max(0, vim.o.lines - opts.height - 3 + opts.row_offset),
    col = math.max(0, opts.col_offset),
    style = "minimal",
    border = opts.border,
    zindex = opts.zindex,
    focusable = false,
    noautocmd = true,
  }
end

local function editor_config(opts)
  return float_config(opts)
end

local function nvim_tree_config(opts)
  local tree_win = tree_window()
  if not tree_win then
    return float_config(opts)
  end

  local width = vim.api.nvim_win_get_width(tree_win)
  local height = vim.api.nvim_win_get_height(tree_win)

  return {
    win = tree_win,
    config = {
      relative = "win",
      win = tree_win,
      anchor = "NW",
      width = math.min(opts.width, width),
      height = math.min(opts.height, height),
      row = math.max(0, height - opts.height - 2 + opts.row_offset),
      col = math.max(0, math.floor((width - opts.width) / 2) + opts.col_offset),
      style = "minimal",
      border = opts.border,
      zindex = opts.zindex,
      focusable = false,
      noautocmd = true,
    },
  }
end

function M.resolve(opts)
  local mode = opts.attach.mode

  if mode == "nvim-tree" then
    return nvim_tree_config(opts)
  end

  if mode == "editor" then
    return editor_config(opts)
  end

  return float_config(opts)
end

return M
