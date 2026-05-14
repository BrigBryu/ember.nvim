if vim.g.loaded_ember_nvim == 1 then
  return
end

vim.g.loaded_ember_nvim = 1

vim.api.nvim_create_user_command("EmberStart", function()
  require("ember").start()
end, {})

vim.api.nvim_create_user_command("EmberStop", function()
  require("ember").stop()
end, {})

vim.api.nvim_create_user_command("EmberToggle", function()
  require("ember").toggle()
end, {})
