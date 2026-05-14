local M = {}

local DEFAULT_HEAT_LEVELS = 11
local default_ramp = { " ", ".", ":", "^", "*", "x", "#", "%", "@", "&" }
local tau = math.pi * 2

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function split_chars(line)
  return vim.fn.split(line, "\\zs")
end

local function resolve_wave(opts)
  local wave = opts and opts.wave or {}
  local fps = math.max(1, tonumber(opts and opts.fps) or 10)
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

local function ramp_for(state)
  local ramp = state.char_ramp or default_ramp
  if #ramp < 2 then
    return default_ramp
  end
  return ramp
end

function M.new(width, height, opts)
  local grid = {}

  for row = 1, height do
    grid[row] = {}
    for col = 1, width do
      grid[row][col] = 0
    end
  end

  return {
    width = width,
    height = height,
    grid = grid,
    fuel = {},
    tongues = {},
    phase = 0,
    wave = resolve_wave(opts),
    smoke = {
      col = nil,
      life = 0,
    },
    intensity = 1,
    char_ramp = opts and opts.char_ramp or nil,
    heat_levels = opts and opts.heat_levels or DEFAULT_HEAT_LEVELS,
  }
end

local function max_heat(state)
  return math.max(1, tonumber(state.heat_levels) or DEFAULT_HEAT_LEVELS)
end

local function update_tongues(state)
  state.phase = (state.phase or 0) + 1
  for col = 1, state.width do
    local target = math.random()
    local previous = state.tongues[col] or target
    state.tongues[col] = (previous * 0.88) + (target * 0.12)
  end
end

local function update_wave(state)
  local wave = state.wave
  if not wave or not wave.enabled then
    return
  end

  wave.phase = (wave.phase or 0) + 1
  local sway_theta = tau * (wave.phase / math.max(1, wave.sway_period_frames))
  local breathe_theta = tau * (wave.phase / math.max(1, wave.breathe_period_frames))

  wave.sway = math.sin(sway_theta) * wave.sway_amplitude
  wave.breathe = math.sin(breathe_theta)
end

local function seed_bottom(state)
  local fuel_row = math.max(1, state.height - 1)
  local center = (state.width + 1) / 2
  local band_half = math.max(2, math.floor(state.width * 0.16))
  local heat_max = max_heat(state)
  local wave = state.wave
  local sway = wave and wave.enabled and (wave.sway or 0) or 0
  local breathe = wave and wave.enabled and (wave.breathe or 0) or 0
  local energy = wave and wave.enabled and (1 + wave.energy_mod * breathe) or 1

  for col = 1, state.width do
    local distance = math.abs(col - (center + sway * 0.35))
    local target = 0

    if distance <= band_half then
      local falloff = 1 - (distance / (band_half + 1))
      local pulse = 0.95 + math.random() * 0.35
      local center_bias = 0.72 + falloff * 0.55
      target = clamp((heat_max * center_bias) * pulse * state.intensity * energy, 0, heat_max)
    elseif distance <= band_half + 1 and math.random() < 0.35 then
      target = clamp((1.0 + math.random() * 1.2) * state.intensity * energy, 0, heat_max * 0.22)
    end

    local previous = state.fuel[col] or state.grid[fuel_row][col] or 0
    local smoothed = (previous * 0.78) + (target * 0.22)
    if target == 0 and smoothed < 0.08 then
      smoothed = 0
    end

    state.fuel[col] = smoothed
    state.grid[fuel_row][col] = smoothed
  end
end

function M.step(state, intensity)
  state.intensity = clamp(intensity or state.intensity or 1, 0, 1)
  update_wave(state)
  update_tongues(state)
  seed_bottom(state)
  local heat_max = max_heat(state)

  for row = state.height - 2, 1, -1 do
    for col = 1, state.width do
      local sample_row = clamp(row + 1, 1, state.height)
      local below = state.grid[sample_row][col]
      local left = state.grid[sample_row][clamp(col - 1, 1, state.width)]
      local right = state.grid[sample_row][clamp(col + 1, 1, state.width)]
      local drift_col = clamp(col + math.random(-1, 1), 1, state.width)
      local drift = state.grid[sample_row][drift_col]
      local average = (below * 0.34) + (left * 0.18) + (right * 0.18) + (drift * 0.30)
      local cooling = 0.45 + math.random() * 0.75 + (1 - state.intensity) * 1.2
      if row <= 2 then
        cooling = cooling + 0.5
      end

      local next_heat = clamp(average - cooling, 0, heat_max)
      local previous = state.grid[row][col]
      local from_base = (state.height - row) / math.max(1, state.height - 2)
      local inertia = 0.25 + from_base * 0.35
      if row >= state.height - 3 then
        inertia = 0.18
      elseif row <= 3 then
        inertia = 0.42
      end

      state.grid[row][col] = (previous * inertia) + (next_heat * (1 - inertia))
    end
  end
end

local function flame_level(state, row, col)
  local center = (state.width + 1) / 2
  local wave = state.wave
  local from_bottom = state.height - row
  local max_flame_rows = math.max(3, state.height - 2)
  local heat_max = max_heat(state)

  if from_bottom < 1 or from_bottom > max_flame_rows then
    return nil
  end

  local normalized_height = (from_bottom - 1) / math.max(1, state.height - 3)
  local sway = wave and wave.enabled and (wave.sway or 0) or 0
  local breathe = wave and wave.enabled and (wave.breathe or 0) or 0
  local wave_center = center + sway * (0.35 + normalized_height * 0.85)
  local distance = math.abs(col - wave_center)
  local base_radius = state.width * 0.23
  local top_radius = state.width * 0.045
  local radius = base_radius * (1 - normalized_height) + top_radius * normalized_height
  if wave and wave.enabled then
    radius = radius * (1 + wave.radius_mod * breathe)
  end
  local tongue = state.tongues[col] or 0
  local tongue_boost = tongue * 0.28
  local effective_height = math.max(0, normalized_height - tongue_boost - ((wave and wave.enabled) and (wave.height_mod * breathe) or 0))
  local mask = 1 - (distance / math.max(0.6, radius))
  if mask <= 0 then
    return 0
  end
  mask = mask * mask

  local heat = state.grid[row][col]
  local height_fade = 1.05 - effective_height * 0.55
  local shaped = heat * (0.35 + mask * 1.15) * height_fade
  if normalized_height > 0.72 then
    shaped = shaped * (0.55 + tongue * 0.45)
  end

  return clamp(math.floor(shaped + 0.5), 0, heat_max)
end

local function glyph_for(state, level)
  local ramp = ramp_for(state)
  local max_index = #ramp - 1
  local mapped = clamp(math.floor((level / max_heat(state)) * max_index + 0.5), 0, max_index)
  return ramp[mapped + 1], mapped
end

local function highlight_for(state, level)
  return ("EmberFire%d"):format(clamp(level, 0, max_heat(state)))
end

function M.lines(state)
  local lines = {}
  local highlights = {}
  local center = math.floor((state.width + 1) / 2)
  local wave = state.wave
  local spark_row = math.max(1, state.height - 7)
  local log_row = state.height

  for row = 1, state.height do
    local chars = {}
    highlights[row] = {}

    for col = 1, state.width do
      chars[col] = " "
      highlights[row][col] = "EmberFire0"

      if row < log_row then
        local level = flame_level(state, row, col)
        if level and level > 0 then
          local glyph = glyph_for(state, level)
          chars[col] = glyph
          highlights[row][col] = highlight_for(state, level)
        end
      end
    end

    lines[row] = table.concat(chars)
  end

  if state.smoke.life > 0 then
    state.smoke.life = state.smoke.life - 1
  elseif math.random() < 0.14 then
    local sway = wave and wave.enabled and (wave.sway or 0) or 0
    local smoke_center = center + math.floor(sway + 0.5)
    state.smoke.col = clamp(smoke_center + math.random(-2, 2), 1, state.width)
    state.smoke.life = 3
  end

  if lines[spark_row] and state.smoke.life > 0 and state.smoke.col then
    local chars = split_chars(lines[spark_row])
    local col = state.smoke.col
    if chars[col] == " " then
      chars[col] = "."
      highlights[spark_row][col] = highlight_for(state, math.min(4, max_heat(state)))
      lines[spark_row] = table.concat(chars)
    end
  end

  if lines[log_row] then
    local chars = split_chars(lines[log_row])
    local log = { "/", "_", "_", "_", "_", "\\" }
    local start_col = center - 2
    for index = 1, 6 do
      local col = start_col + index - 1
      if chars[col] then
        chars[col] = log[index]
        local low = math.max(2, math.floor(max_heat(state) * 0.22))
        local mid = math.max(low + 1, math.floor(max_heat(state) * 0.36))
        local group = (index >= 2 and index <= 5) and highlight_for(state, mid) or highlight_for(state, low)
        highlights[log_row][col] = group
      end
    end
    lines[log_row] = table.concat(chars)
  end

  return lines, highlights
end

return M
