local M = {}

local tau = math.pi * 2
local LOG_CHARS = { "/", "_", "_", "_", "_", "\\" }

local function resolve_wave(opts)
  local wave = opts or {}
  local fps = math.max(1, tonumber(wave.fps) or 8)
  local amount = wave.amount or "subtle"

  local profile = {
    enabled = wave.enabled ~= false,
    style = wave.style or "sway_breathe",
    amount = amount,
    sway_period_frames = math.floor(fps * 6),
    breathe_period_frames = math.floor(fps * 8.5),
    sway_amplitude = 1.35,
    radius_mod = 0.08,
    height_mod = 0.07,
    energy_mod = 0.05,
    phase = wave.phase or 0,
    sway = wave.sway or 0,
    breathe = wave.breathe or 0,
  }

  if amount == "medium" then
    profile.sway_amplitude = 1.8
    profile.radius_mod = 0.1
    profile.height_mod = 0.09
    profile.energy_mod = 0.07
  elseif amount == "pronounced" then
    profile.sway_amplitude = 2.25
    profile.radius_mod = 0.13
    profile.height_mod = 0.12
    profile.energy_mod = 0.1
  end

  return profile
end

function M.init(state)
  state.wave = resolve_wave(state.wave)
end

local function update_tongues(state)
  state.phase = (state.phase or 0) + 1
  local tongues = state.tongues

  for col = 1, state.width do
    local target = math.random()
    local previous = tongues[col] or target
    tongues[col] = (previous * 0.88) + (target * 0.12)
  end
end

local function update_wave(state)
  local wave = state.wave
  if not wave.enabled then
    return
  end

  wave.phase = (wave.phase or 0) + 1
  local sway_theta = tau * (wave.phase / math.max(1, wave.sway_period_frames))
  local breathe_theta = tau * (wave.phase / math.max(1, wave.breathe_period_frames))

  wave.sway = math.sin(sway_theta) * wave.sway_amplitude
  wave.breathe = math.sin(breathe_theta)
end

local function seed_bottom(state, render)
  local fuel_row = math.max(1, state.height - 1)
  local fuel_index = state.row_offsets[fuel_row]
  local center = (state.width + 1) / 2
  local band_half = math.max(2, math.floor(state.width * 0.16))
  local heat_max = render.max_heat(state)
  local wave = state.wave
  local sway = wave.enabled and (wave.sway or 0) or 0
  local breathe = wave.enabled and (wave.breathe or 0) or 0
  local energy = wave.enabled and (1 + wave.energy_mod * breathe) or 1
  local fuel = state.fuel
  local grid = state.grid

  for col = 1, state.width do
    local distance = math.abs(col - (center + sway * 0.35))
    local target = 0

    if distance <= band_half then
      local falloff = 1 - (distance / (band_half + 1))
      local pulse = 0.95 + math.random() * 0.35
      local center_bias = 0.72 + falloff * 0.55
      target = render.clamp((heat_max * center_bias) * pulse * state.intensity * energy, 0, heat_max)
    elseif distance <= band_half + 1 and math.random() < 0.35 then
      target = render.clamp((1.0 + math.random() * 1.2) * state.intensity * energy, 0, heat_max * 0.22)
    end

    local index = fuel_index + col
    local previous = fuel[col] or grid[index] or 0
    local smoothed = (previous * 0.78) + (target * 0.22)
    if target == 0 and smoothed < 0.08 then
      smoothed = 0
    end

    fuel[col] = smoothed
    grid[index] = smoothed
  end
end

local function flame_level(state, row, col, render)
  local center = (state.width + 1) / 2
  local wave = state.wave
  local from_bottom = state.height - row
  local max_flame_rows = math.max(3, state.height - 2)
  local heat_max = render.max_heat(state)

  if from_bottom < 1 or from_bottom > max_flame_rows then
    return nil
  end

  local normalized_height = (from_bottom - 1) / math.max(1, state.height - 3)
  local sway = wave.enabled and (wave.sway or 0) or 0
  local breathe = wave.enabled and (wave.breathe or 0) or 0
  local wave_center = center + sway * (0.35 + normalized_height * 0.85)
  local distance = math.abs(col - wave_center)
  local base_radius = state.width * 0.23
  local top_radius = state.width * 0.045
  local radius = base_radius * (1 - normalized_height) + top_radius * normalized_height

  if wave.enabled then
    radius = radius * (1 + wave.radius_mod * breathe)
  end

  local tongue = state.tongues[col] or 0
  local tongue_boost = tongue * 0.28
  local effective_height = math.max(0, normalized_height - tongue_boost - (wave.enabled and (wave.height_mod * breathe) or 0))
  local mask = 1 - (distance / math.max(0.6, radius))

  if mask <= 0 then
    return 0
  end

  mask = mask * mask

  local heat = state.grid[state.row_offsets[row] + col]
  local height_fade = 1.05 - effective_height * 0.55
  local shaped = heat * (0.35 + mask * 1.15) * height_fade

  if normalized_height > 0.72 then
    shaped = shaped * (0.55 + tongue * 0.45)
  end

  return render.clamp(math.floor(shaped + 0.5), 0, heat_max)
end

function M.step(state, _, render)
  update_wave(state)
  update_tongues(state)
  seed_bottom(state, render)

  local grid = state.grid
  local width = state.width
  local height = state.height
  local left_cols = state.left_cols
  local right_cols = state.right_cols
  local heat_max = render.max_heat(state)

  for row = height - 2, 1, -1 do
    local row_offset = state.row_offsets[row]
    local sample_offset = state.row_offsets[row + 1]
    local from_base = (height - row) / math.max(1, height - 2)
    local inertia = 0.25 + from_base * 0.35

    if row >= height - 3 then
      inertia = 0.18
    elseif row <= 3 then
      inertia = 0.42
    end

    for col = 1, width do
      local below = grid[sample_offset + col]
      local left = grid[sample_offset + left_cols[col]]
      local right = grid[sample_offset + right_cols[col]]
      local drift_col = render.clamp(col + math.random(-1, 1), 1, width)
      local drift = grid[sample_offset + drift_col]
      local average = (below * 0.34) + (left * 0.18) + (right * 0.18) + (drift * 0.30)
      local cooling = 0.45 + math.random() * 0.75 + (1 - state.intensity) * 1.2

      if row <= 2 then
        cooling = cooling + 0.5
      end

      local next_heat = render.clamp(average - cooling, 0, heat_max)
      local index = row_offset + col
      local previous = grid[index]
      grid[index] = (previous * inertia) + (next_heat * (1 - inertia))
    end
  end
end

function M.render(state, render)
  local center = math.floor((state.width + 1) / 2)
  local wave = state.wave
  local spark_row = math.max(1, state.height - 7)
  local log_row = state.height

  for row = 1, state.height - 1 do
    for col = 1, state.width do
      local level = flame_level(state, row, col, render)
      if level and level > 0 then
        render.paint_heat(state, row, col, level)
      end
    end
  end

  if state.smoke.life > 0 then
    state.smoke.life = state.smoke.life - 1
  elseif math.random() < 0.14 then
    local sway = wave.enabled and (wave.sway or 0) or 0
    local smoke_center = center + math.floor(sway + 0.5)
    state.smoke.col = render.clamp(smoke_center + math.random(-2, 2), 1, state.width)
    state.smoke.life = 3
  end

  if state.smoke.life > 0 and state.smoke.col then
    render.set_cell(state, spark_row, state.smoke.col, ".", math.min(4, render.max_heat(state)))
  end

  local start_col = center - 2
  local low = math.max(2, math.floor(render.max_heat(state) * 0.22))
  local mid = math.max(low + 1, math.floor(render.max_heat(state) * 0.36))

  for index = 1, 6 do
    local col = start_col + index - 1
    local level = (index >= 2 and index <= 5) and mid or low
    render.set_cell(state, log_row, col, LOG_CHARS[index], level)
  end
end

return M
