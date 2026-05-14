local M = {}

local palettes = {
  gruvbox = {
    { fg = "#282828" },
    { fg = "#3c3836" },
    { fg = "#504945" },
    { fg = "#665c54" },
    { fg = "#7c6f64" },
    { fg = "#8f3f1f" },
    { fg = "#af3a03" },
    { fg = "#cc241d" },
    { fg = "#d65d0e" },
    { fg = "#fe8019" },
    { fg = "#fabd2f" },
    { fg = "#fbf1c7" },
  },
  default = {
    { link = "Normal" },
    { link = "NonText" },
    { link = "Comment" },
    { link = "LineNr" },
    { link = "Folded" },
    { link = "DiagnosticHint" },
    { link = "DiagnosticWarn" },
    { link = "WarningMsg" },
    { link = "DiagnosticError" },
    { link = "String" },
    { link = "Constant" },
    { link = "Normal" },
    { link = "Normal" },
  },
}

local function deep_copy(value)
  return vim.deepcopy(value)
end

local function resolve_palette(name, custom)
  if type(custom) == "table" then
    return deep_copy(custom)
  end

  if name == "auto" then
    local colors_name = (vim.g.colors_name or ""):lower()
    if colors_name:find("gruvbox", 1, true) then
      return deep_copy(palettes.gruvbox)
    end
    return deep_copy(palettes.default)
  end

  return deep_copy(palettes[name] or palettes.default)
end

local function highlight_defined(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or not hl then
    return false
  end

  return next(hl) ~= nil
end

function M.apply(opts)
  opts = opts or {}

  local palette = resolve_palette(opts.palette or "auto", opts.custom_palette)
  local force = opts.force == true

  for index, spec in ipairs(palette) do
    local group = ("EmberFire%d"):format(index - 1)
    if force or not highlight_defined(group) then
      vim.api.nvim_set_hl(0, group, spec)
    end
  end
end

function M.available()
  return vim.tbl_keys(palettes)
end

return M
