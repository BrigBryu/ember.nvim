local M = {}

local tau = math.pi * 2

local function resolve_spiral(opts)
  opts = opts or {}
  return {
    turns = math.max(1.0, tonumber(opts.turns) or 1.85),
    thickness = math.max(0.75, tonumber(opts.thickness) or 1.35),
    rotation_speed = tonumber(opts.rotation_speed) or 0.24,
    pulse_amount = tonumber(opts.pulse_amount) or 0.08,
    center_bias_x = tonumber(opts.center_bias_x) or 0,
    center_bias_y = tonumber(opts.center_bias_y) or 0,
  }
end

local function build_glow_kernel(thickness)
  local radius = math.max(1.35, thickness)
  local reach = math.max(1, math.ceil(radius))
  local offsets = {}
  local count = 0

  for d_row = -reach, reach do
    for d_col = -reach, reach do
      local distance = math.sqrt((d_col * d_col) + (d_row * d_row))
      local falloff = 1 - (distance / radius)
      if falloff > 0 then
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

local function sample_count_for(state)
  local area_scaled = math.floor(state.width * state.height * 0.55)
  return math.max(96, math.min(512, area_scaled))
end

function M.init(state)
  state.spiral = resolve_spiral(state.spiral)
  local kernel, kernel_count = build_glow_kernel(state.spiral.thickness)
  state.spiral_state.glow_kernel = kernel
  state.spiral_state.glow_kernel_count = kernel_count
  state.spiral_state.thickness = state.spiral.thickness
end

local function ensure_kernel(state)
  local spiral_state = state.spiral_state
  local spiral = state.spiral

  if spiral_state.thickness == spiral.thickness then
    return
  end

  local kernel, kernel_count = build_glow_kernel(spiral.thickness)
  spiral_state.glow_kernel = kernel
  spiral_state.glow_kernel_count = kernel_count
  spiral_state.thickness = spiral.thickness
end

local function blend_heat(state, row, col, heat, render)
  if row < 1 or row > state.height or col < 1 or col > state.width then
    return
  end

  local index = state.row_offsets[row] + col
  local heat_max = render.max_heat(state)
  state.grid[index] = render.clamp(math.max(state.grid[index], heat), 0, heat_max)
end

local function diffuse(state, render)
  local heat_max = render.max_heat(state)
  local width = state.width
  local height = state.height
  local grid = state.grid
  local next_grid = state.next_grid
  local left_cols = state.left_cols
  local right_cols = state.right_cols

  for row = 1, height do
    local row_offset = state.row_offsets[row]
    local up_offset = state.row_offsets[math.max(1, row - 1)]
    local down_offset = state.row_offsets[math.min(height, row + 1)]

    for col = 1, width do
      local left = left_cols[col]
      local right = right_cols[col]
      local index = row_offset + col
      local total = grid[index] * 0.42
      local weight = 0.42

      total = total + (grid[row_offset + left] * 0.09)
      total = total + (grid[row_offset + right] * 0.09)
      total = total + (grid[up_offset + col] * 0.09)
      total = total + (grid[down_offset + col] * 0.09)
      weight = weight + 0.36

      total = total + (grid[up_offset + left] * 0.045)
      total = total + (grid[up_offset + right] * 0.045)
      total = total + (grid[down_offset + left] * 0.045)
      total = total + (grid[down_offset + right] * 0.045)
      weight = weight + 0.18

      local smoothed = total / weight
      local cooling = 0.18 + math.random() * 0.32 + (1 - state.intensity) * 0.68
      next_grid[index] = render.clamp(smoothed - cooling, 0, heat_max)
    end
  end

  render.swap_grids(state)
end

local function enrich_hotspots(state, render)
  local heat_max = render.max_heat(state)
  local grid = state.grid

  for index = 1, state.size do
    local current = grid[index]
    if current > heat_max * 0.3 then
      local normalized = current / heat_max
      local boost = 1 + ((normalized - 0.3) / 0.7) * 0.28
      grid[index] = render.clamp(current * boost, 0, heat_max)
    end
  end
end

local function seed_spiral(state, render)
  state.phase = (state.phase or 0) + 1
  ensure_kernel(state)

  local spiral = state.spiral
  local spiral_state = state.spiral_state
  local heat_max = render.max_heat(state)
  local center_x = (state.width + 1) / 2 + spiral.center_bias_x
  local center_y = (state.height + 1) / 2 + spiral.center_bias_y
  local max_radius = math.max(2.2, math.min(state.width, state.height) * 0.47)
  local phase = (spiral_state.angle or 0) + math.abs(spiral.rotation_speed)
  local pulse = 1 + math.sin(state.phase * 0.09) * spiral.pulse_amount
  local samples = sample_count_for(state)
  local trail_length = tau * spiral.turns
  local angle_step = -trail_length / samples
  local cos_step = math.cos(angle_step)
  local sin_step = math.sin(angle_step)
  local cos_theta = math.cos(phase)
  local sin_theta = math.sin(phase)
  local radius_step = max_radius / samples
  local radius = 0.65 * pulse
  local kernel = spiral_state.glow_kernel
  local kernel_count = spiral_state.glow_kernel_count

  spiral_state.angle = phase
  spiral_state.pulse = pulse

  for index = 0, samples do
    local progress = index / samples
    local x = center_x + cos_theta * radius
    local y = center_y + sin_theta * radius * 0.72
    local row = math.floor(y + 0.5)
    local col = math.floor(x + 0.5)
    local lead = 1 - progress
    local heat = heat_max * (0.5 + lead * 0.5) * state.intensity

    for kernel_index = 1, kernel_count do
      local glow = kernel[kernel_index]
      local glow_heat = heat * glow.weight * (0.92 + math.random() * 0.12)
      blend_heat(state, row + glow.d_row, col + glow.d_col, glow_heat, render)
    end

    local next_cos = cos_theta * cos_step - sin_theta * sin_step
    local next_sin = sin_theta * cos_step + cos_theta * sin_step
    cos_theta = next_cos
    sin_theta = next_sin
    radius = radius + radius_step * pulse
  end
end

function M.step(state, _, render)
  render.clear_grid(state, 0.82)
  seed_spiral(state, render)
  diffuse(state, render)
  enrich_hotspots(state, render)
end

function M.render(state, render)
  local grid = state.grid
  local heat_max = render.max_heat(state)

  for row = 1, state.height do
    local row_offset = state.row_offsets[row]
    for col = 1, state.width do
      local level = render.clamp(math.floor(grid[row_offset + col] + 0.5), 0, heat_max)
      if level > 1 then
        render.paint_heat(state, row, col, level)
      end
    end
  end
end

return M
