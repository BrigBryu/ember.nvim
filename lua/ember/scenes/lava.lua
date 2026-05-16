local M = {}

local tau = math.pi * 2

local function resolve_lava(opts)
  opts = opts or {}
  return {
    blobs = math.max(1, math.floor(tonumber(opts.blobs) or 4)),
    speed = math.max(0.02, tonumber(opts.speed) or 0.16),
    pulse_amount = math.max(0, tonumber(opts.pulse_amount) or 0.08),
    center_bias_x = tonumber(opts.center_bias_x) or 0,
    center_bias_y = tonumber(opts.center_bias_y) or 0,
  }
end

local function build_kernel(radius)
  local reach = math.max(1, math.ceil(radius))
  local offsets = {}
  local count = 0

  for d_row = -reach, reach do
    for d_col = -reach, reach do
      local distance_sq = (d_col * d_col) + (d_row * d_row)
      local normalized = distance_sq / math.max(0.01, radius * radius)
      if normalized < 1 then
        local falloff = 1 - normalized
        count = count + 1
        offsets[count] = {
          d_row = d_row,
          d_col = d_col,
          weight = falloff * falloff,
        }
      end
    end
  end

  return offsets, count
end

local function safe_blob_count(state, requested)
  local area = state.width * state.height
  local max_blobs = math.max(1, math.floor(area / 28))
  return math.max(1, math.min(requested, max_blobs, 6))
end

local function clamp_blob_radius(state, radius)
  local max_radius = math.max(1.15, math.min(state.width * 0.2, state.height * 0.32))
  return math.max(1.15, math.min(radius, max_radius))
end

function M.init(state)
  state.lava = resolve_lava(state.lava)

  local lava_state = state.lava_state
  local count = safe_blob_count(state, state.lava.blobs)
  local center_x = (state.width + 1) / 2 + state.lava.center_bias_x
  local center_y = (state.height + 1) / 2 + state.lava.center_bias_y
  local horizontal_span = math.max(1.2, state.width * 0.16)
  local vertical_span = math.max(1.4, state.height * 0.22)

  lava_state.blobs = {}
  lava_state.blob_count = count
  lava_state.kernels = {}
  lava_state.kernel_counts = {}
  lava_state.radius_keys = {}

  for index = 1, count do
    local ratio = index / count
    local base_radius = clamp_blob_radius(state, 1.45 + (ratio * math.min(state.width, state.height) * 0.08))
    local radius_key = math.floor(base_radius * 100 + 0.5)

    if not lava_state.kernels[radius_key] then
      local kernel, kernel_count = build_kernel(base_radius)
      lava_state.kernels[radius_key] = kernel
      lava_state.kernel_counts[radius_key] = kernel_count
    end

    lava_state.blobs[index] = {
      base_x = center_x + math.cos(index * 1.7) * horizontal_span * 0.18,
      base_y = center_y + math.sin(index * 1.1) * vertical_span * 0.15,
      radius = base_radius,
      energy = 0.72 + ratio * 0.22,
      phase = index * 1.913,
      drift_x = horizontal_span * (0.5 + ratio * 0.3),
      drift_y = vertical_span * (0.8 + ratio * 0.25),
      rate_x = 0.55 + ratio * 0.22,
      rate_y = 0.36 + ratio * 0.18,
      pulse_rate = 0.42 + ratio * 0.14,
      radius_key = radius_key,
    }
  end
end

local function blend_heat(state, row, col, heat, render)
  if row < 1 or row > state.height or col < 1 or col > state.width then
    return
  end

  local index = state.row_offsets[row] + col
  local heat_max = render.max_heat(state)
  local grid = state.grid
  grid[index] = render.clamp(grid[index] + heat, 0, heat_max)
end

local function stamp_blob(state, blob, x, y, radius_scale, intensity, render)
  local lava_state = state.lava_state
  local kernel = lava_state.kernels[blob.radius_key]
  local kernel_count = lava_state.kernel_counts[blob.radius_key]
  local heat_max = render.max_heat(state)
  local row = math.floor(y + 0.5)
  local col = math.floor(x + 0.5)
  local heat = heat_max * blob.energy * intensity * radius_scale

  for index = 1, kernel_count do
    local glow = kernel[index]
    blend_heat(state, row + glow.d_row, col + glow.d_col, heat * glow.weight, render)
  end
end

local function smooth_grid(state, render)
  local grid = state.grid
  local next_grid = state.next_grid
  local width = state.width
  local height = state.height
  local left_cols = state.left_cols
  local right_cols = state.right_cols
  local heat_max = render.max_heat(state)

  for row = 1, height do
    local row_offset = state.row_offsets[row]
    local up_offset = state.row_offsets[math.max(1, row - 1)]
    local down_offset = state.row_offsets[math.min(height, row + 1)]

    for col = 1, width do
      local left = left_cols[col]
      local right = right_cols[col]
      local index = row_offset + col
      local current = grid[index]
      local smoothed = (current * 0.52)
        + (grid[row_offset + left] * 0.12)
        + (grid[row_offset + right] * 0.12)
        + (grid[up_offset + col] * 0.12)
        + (grid[down_offset + col] * 0.12)

      next_grid[index] = render.clamp(smoothed - 0.05, 0, heat_max)
    end
  end

  render.swap_grids(state)
end

function M.step(state, _, render)
  local lava = state.lava
  local lava_state = state.lava_state
  local center_x = (state.width + 1) / 2 + lava.center_bias_x
  local center_y = (state.height + 1) / 2 + lava.center_bias_y
  local horizontal_limit = math.max(1.2, state.width * 0.24)
  local vertical_limit = math.max(1.6, state.height * 0.28)

  state.phase = (state.phase or 0) + lava.speed
  render.clear_grid(state, 0.76)

  for index = 1, lava_state.blob_count do
    local blob = lava_state.blobs[index]
    local phase = state.phase + blob.phase
    local pulse = 1 + math.sin(phase * blob.pulse_rate) * lava.pulse_amount
    local drift_x = math.sin(phase * blob.rate_x) * blob.drift_x
    local drift_y = math.cos(phase * blob.rate_y) * blob.drift_y
    local x = center_x + math.max(-horizontal_limit, math.min(horizontal_limit, drift_x))
    local y = center_y + math.max(-vertical_limit, math.min(vertical_limit, drift_y))

    stamp_blob(state, blob, x, y, pulse, state.intensity, render)
  end

  smooth_grid(state, render)
end

function M.render(state, render)
  local grid = state.grid
  local heat_max = render.max_heat(state)
  local threshold = math.max(1, math.floor(heat_max * 0.12))

  for row = 1, state.height do
    local row_offset = state.row_offsets[row]
    for col = 1, state.width do
      local level = render.clamp(math.floor(grid[row_offset + col] + 0.5), 0, heat_max)
      if level > threshold then
        render.paint_heat(state, row, col, level)
      end
    end
  end
end

return M
