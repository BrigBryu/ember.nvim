# Changelog

## Unreleased

### Added
- Added `require("ember").stats()` runtime counters for frame activity, rewrite behavior, and API-call timing breakdowns.
- Added `require("ember").benchmark(opts)` and `:EmberBenchmark [frames]` for offscreen performance measurement.
- Added `adaptive_fps` and `full_rewrite_threshold` configuration for battery-friendly pacing and smarter buffer updates.
- Added `spiral` scene configuration and documentation alongside the existing fire scene.
- Added a new `lava` scene with slow metaball-style blob motion using the same optimized renderer pipeline and ember palette.

### Changed
- Lowered the default FPS from `10` to `8` to reduce idle power use.
- Reworked the renderer around dirty-row updates, contiguous highlight runs, and reused scratch buffers.
- Switched rendering internals to flat reusable arrays and row-aware frame materialization.
- Tuned the spiral scene to reduce expensive math, cut down full rewrites, and improve large-canvas performance.

### Performance
- Reduced Neovim API overhead by batching highlights and updating only dirty row ranges when possible.
- Added live timing breakdowns for render, `nvim_buf_set_lines`, namespace clears, and highlight work.
- Improved the benchmarked `spiral 80x24` path from roughly `0.48ms` to `0.26ms` average frame time in the current optimization pass.
