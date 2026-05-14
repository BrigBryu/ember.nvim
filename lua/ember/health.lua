local M = {}

function M.check()
  local health = vim.health or require("health")
  local ok = vim.fn.has("nvim-0.9") == 1

  if ok then
    health.ok("Neovim 0.9+ detected")
  else
    health.error("ember.nvim requires Neovim 0.9 or newer")
  end

  health.info("Floating window mode is always available")

  local has_tree, _ = pcall(require, "nvim-tree.api")
  if has_tree then
    health.ok("nvim-tree integration can be enabled when its window is open")
  else
    health.info("nvim-tree is optional; ember.nvim will fall back to float mode")
  end
end

return M
