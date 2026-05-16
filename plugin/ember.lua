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

vim.api.nvim_create_user_command("EmberBenchmark", function(command)
  local frames = tonumber(command.args)
  local stats = require("ember").benchmark(frames and { frames = frames } or nil)

  vim.notify(
    ("ember.nvim benchmark: %.3fms avg frame (render %.3fms, set_lines %.3fms, clear %.3fms, highlight %.3fms), %.2f dirty rows, %.2f rows rewritten, %.2f set_lines calls, %.2f highlight calls, %d full rewrites across %d frames"):format(
      stats.avg_frame_ms,
      stats.avg_render_frame_ms,
      stats.avg_set_lines_ms,
      stats.avg_clear_namespace_ms,
      stats.avg_highlight_ms,
      stats.avg_dirty_rows,
      stats.avg_rows_rewritten,
      stats.avg_set_lines_calls,
      stats.avg_highlight_calls,
      stats.full_rewrites,
      stats.frames
    )
  )
end, {
  nargs = "?",
})
