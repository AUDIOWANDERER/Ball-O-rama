-- (AW) presents:
-- BALL-o-RAMA 
-- Be the ball
-- each block hit by
-- the ball triggers a note
--
-- (best with grid)
-- No Grid? K2+Enc1
-- to add blocks
-- Enc1 with
-- K1 held:
-- Move them randomly
-- (Enc1 controls speed)
--
-- BALL CONTROL
-- E2 changes ball speed
-- E3 changes pitch factor
--
-- SOUND CONTROL (K3 held)
-- E2 changes cutoff
-- E3 changes release
--
-- GRID
-- press to toggle blocks
-- K2 clears all blocks
-- blocks explode if
-- ball stuck > 1 sec
-- (can be disabled on menu)

engine.name = "PolyPerc"
MusicUtil = require "musicutil"
hs = include("lib/halfsecond")

g = grid.connect()
m = midi.connect()
local MIDI_CHANNEL = 1
local MIDI_VELOCITY = 100

local GRID_W = 16
local GRID_H = 8
local DT = 1/30

-- PERF: localize hot functions
local abs = math.abs
local floor = math.floor
local random = math.random
local clamp = util.clamp
local linlin = util.linlin

-- ball
local ball = {
  x = random(1, GRID_W),
  y = random(1, GRID_H),
  vx = (random() - 0.5) * 0.6,
  vy = (random() - 0.5) * 0.6,

  -- stuck detection (time inside same active block)
  stuck_timer = 0,

  -- debounce so one block triggers once until ball leaves it
  last_block_x = -1,
  last_block_y = -1
}

local cells = {}
for x = 1, GRID_W do
  cells[x] = {}
  for y = 1, GRID_H do
    cells[x][y] = false
  end
end

local ball_flash = 0
local BALL_FLASH_FRAMES = 4

local block_flash = {}
for x = 1, GRID_W do
  block_flash[x] = {}
  for y = 1, GRID_H do
    block_flash[x][y] = 0
  end
end
local BLOCK_FLASH_FRAMES = 6

-- scale_notes only used for root; keep it but simplify usage
local scale_notes = MusicUtil.generate_scale(60, 1, 2)
local root_note = scale_notes[1]
local freq_base = MusicUtil.note_num_to_freq(root_note)

local enc_mode = 1 -- 1=ball control, 2=sound control
local ball_speed_factor = 1
local pitch_factor = 1
local min_speed = 0.2
local cutoff = 1000
local release = 0.5

local key1_held = false
local key2_held = false

-- block move
local block_move_rate = 0
local block_move_counter = 0
local max_block_move_rate = 10

-- ------------------------------------------------------------
-- INIT
-- ------------------------------------------------------------
function init()
  hs.init()

  engine.cutoff(cutoff)
  engine.release(release)

  params:add_separator("BALL-o-RAMA")

  -- DELAY MODULATION
  params:add_group("DELAY MODULATION", 3)
  params:add_option("auto_map", "auto map ball > delay", {"off", "on"}, 1)
  params:add_control("auto_map_depth", "map depth", controlspec.new(0.1, 2.0, "lin", 0, 1.0))
  params:add_option("mod_target", "controls", {"rate (x)", "feedback (y)", "both (x,y)"}, 3)

  -- BLOCK DESTRUCTION
  params:add_group("BLOCK DESTRUCTION", 1)
  params:add_option("block_destroy", "destroy blocks", {"off", "on"}, 2)

  params:bang()
  clock.run(update_loop)
end

-- ------------------------------------------------------------
-- FLASH DECAY (moved out of update_ball to keep update_ball cheap)
-- ------------------------------------------------------------
local function decay_flashes()
  if ball_flash > 0 then ball_flash = ball_flash - 1 end
  for x = 1, GRID_W do
    local col = block_flash[x]
    for y = 1, GRID_H do
      if col[y] > 0 then col[y] = col[y] - 1 end
    end
  end
end

-- ------------------------------------------------------------
-- BLOCK MOVEMENT (fixed: no replacing `cells` table reference)
-- Moves one random filled cell by one step if possible.
-- ------------------------------------------------------------
local function collect_filled_positions()
  local pos = {}
  for x = 1, GRID_W do
    for y = 1, GRID_H do
      if cells[x][y] then
        pos[#pos + 1] = {x = x, y = y}
      end
    end
  end
  return pos
end

function move_blocks_randomly()
  local filled = collect_filled_positions()
  if #filled == 0 then return end

  -- do N micro-moves per call (scaled by rate)
  local moves = math.max(1, math.floor(block_move_rate))
  for _ = 1, moves do
    local c = filled[random(#filled)]
    local x, y = c.x, c.y

    local dir = random(4)
    local nx, ny = x, y
    if dir == 1 then ny = y - 1
    elseif dir == 2 then ny = y + 1
    elseif dir == 3 then nx = x - 1
    else nx = x + 1 end

    if nx >= 1 and nx <= GRID_W and ny >= 1 and ny <= GRID_H and (not cells[nx][ny]) then
      cells[x][y] = false
      cells[nx][ny] = true
      c.x, c.y = nx, ny -- keep picked cell roughly in sync
    end
  end
end

-- ------------------------------------------------------------
-- EXPLOSION
-- ------------------------------------------------------------
function explode_block(x, y)
  for i = math.max(1, x - 1), math.min(GRID_W, x + 1) do
    for j = math.max(1, y - 1), math.min(GRID_H, y + 1) do
      cells[i][j] = false
    end
  end

  -- kick ball away + reset debounce
  ball.vx = (random() - 0.5) * 2
  ball.vy = (random() - 0.5) * 2
  ball.stuck_timer = 0
  ball.last_block_x = -1
  ball.last_block_y = -1
end

-- ------------------------------------------------------------
-- SOUND
-- ------------------------------------------------------------
function play_cell_sound(x, y)
  local freq = freq_base * pitch_factor * (1 + (y - 1) / GRID_H * 2)
  local cutoff_val = linlin(1, GRID_W, 500, cutoff, x)

  engine.hz(freq)
  engine.cutoff(cutoff_val)
  engine.amp(0.3)
  engine.release(release)

  local note_num = root_note + (y - 1)
  m:note_on(note_num, MIDI_VELOCITY, MIDI_CHANNEL)
  clock.run(function()
    clock.sleep(0.2)
    m:note_off(note_num, MIDI_VELOCITY, MIDI_CHANNEL)
  end)
end

-- ------------------------------------------------------------
-- BALL UPDATE (fixed: debounced trigger + proper stuck timer)
-- ------------------------------------------------------------
function update_ball()
  ball.x = ball.x + ball.vx * ball_speed_factor
  ball.y = ball.y + ball.vy * ball_speed_factor

  if ball.x < 1 then ball.x = 1; ball.vx = abs(ball.vx) end
  if ball.x > GRID_W then ball.x = GRID_W; ball.vx = -abs(ball.vx) end
  if ball.y < 1 then ball.y = 1; ball.vy = abs(ball.vy) end
  if ball.y > GRID_H then ball.y = GRID_H; ball.vy = -abs(ball.vy) end

  local ix = floor(ball.x + 0.5)
  local iy = floor(ball.y + 0.5)

  if cells[ix][iy] then
    -- staying in same active block? -> stuck timer, no retrigger
    if ix == ball.last_block_x and iy == ball.last_block_y then
      ball.stuck_timer = ball.stuck_timer + DT
      if ball.stuck_timer >= 1.0 and params:get("block_destroy") == 2 then
        explode_block(ix, iy)
      end
      return
    end

    -- entered a new active block -> trigger
    ball.last_block_x = ix
    ball.last_block_y = iy
    ball.stuck_timer = 0

    play_cell_sound(ix, iy)
    ball_flash = BALL_FLASH_FRAMES
    block_flash[ix][iy] = BLOCK_FLASH_FRAMES

    -- bounce (simple but stable)
    ball.vx = -ball.vx * (0.8 + random() * 0.4)
    ball.vy = -ball.vy * (0.8 + random() * 0.4)

    -- speed floor
    if abs(ball.vx) < min_speed then ball.vx = min_speed * (ball.vx < 0 and -1 or 1) end
    if abs(ball.vy) < min_speed then ball.vy = min_speed * (ball.vy < 0 and -1 or 1) end

    -- push out so it can leave the cell
    ball.x = ball.x + ball.vx * 0.15
    ball.y = ball.y + ball.vy * 0.15

  else
    -- left an active block -> reset debounce
    if ball.last_block_x ~= -1 then
      ball.last_block_x = -1
      ball.last_block_y = -1
      ball.stuck_timer = 0
    end
  end
end

-- ------------------------------------------------------------
-- MAIN LOOP
-- ------------------------------------------------------------
function update_loop()
  while true do
    clock.sleep(DT)

    -- Dynamic Mapping Logic
    if params:get("auto_map") == 2 then
      local depth = params:get("auto_map_depth")
      local target = params:get("mod_target")

      if target == 1 or target == 3 then
        local rate_val = linlin(1, GRID_W, 0.05, 1.5, ball.x)
        params:set("delay_rate", clamp(rate_val * depth, 0.05, 2.0))
      end

      if target == 2 or target == 3 then
        local fb_val = linlin(1, GRID_H, 0.1, 0.9, GRID_H - ball.y + 1)
        params:set("delay_feedback", clamp(fb_val * depth, 0.0, 0.95))
      end
    end

    -- block move scheduling
    if block_move_rate > 0 then
      block_move_counter = block_move_counter + 1
      local step_frames = math.floor(max_block_move_rate / block_move_rate)
      if step_frames < 1 then step_frames = 1 end
      if block_move_counter >= step_frames then
        move_blocks_randomly()
        block_move_counter = 0
      end
    end

    update_ball()
    decay_flashes()

    redraw()
    if g then gridredraw() end
  end
end

-- ------------------------------------------------------------
-- SCREEN
-- ------------------------------------------------------------
function redraw()
  local RECT_SIZE = 5
  local OFFSET = 2
  screen.clear()

  for x = 1, GRID_W do
    local col = cells[x]
    local fcol = block_flash[x]
    for y = 1, GRID_H do
      if col[y] then
        screen.level(15)
        screen.rect((x - 1) * 8 + OFFSET, (y - 1) * 8 + OFFSET, RECT_SIZE, RECT_SIZE)
        if fcol[y] > 0 then screen.fill() else screen.stroke() end
      end
    end
  end

  screen.level(15)
  screen.circle((ball.x - 1) * 8 + 4, (ball.y - 1) * 8 + 4, 3)
  if ball_flash > 0 then screen.fill() else screen.stroke() end

  screen.update()
end

-- ------------------------------------------------------------
-- GRID
-- ------------------------------------------------------------
function gridredraw()
  if not g then return end
  g:all(0)

  for x = 1, GRID_W do
    local col = cells[x]
    local fcol = block_flash[x]
    for y = 1, GRID_H do
      if col[y] then
        local lvl = (fcol[y] > 0) and 0 or 8
        g:led(x, y, lvl)
      end
    end
  end

  local bx = floor(ball.x + 0.5)
  local by = floor(ball.y + 0.5)
  g:led(bx, by, 15)

  g:refresh()
end

function g.key(x, y, z)
  if z > 0 then
    cells[x][y] = not cells[x][y]
    gridredraw()
  end
end

-- ------------------------------------------------------------
-- ENCODERS
-- ------------------------------------------------------------
function enc(n, d)
  if key1_held and n == 1 then
    -- K1 + E1: random move speed (0 = static)
    block_move_rate = clamp(block_move_rate + d, 0, max_block_move_rate)

  elseif key2_held and n == 1 then
    -- K2 + E1: random add/remove blocks
    local empty_cells = {}
    local filled_cells = {}
    for x = 1, GRID_W do
      for y = 1, GRID_H do
        if not cells[x][y] then
          empty_cells[#empty_cells + 1] = {x = x, y = y}
        else
          filled_cells[#filled_cells + 1] = {x = x, y = y}
        end
      end
    end

    local count = math.ceil(2 ^ math.abs(d) - 1)
    if d > 0 then
      count = math.min(count, #empty_cells)
      for i = 1, count do
        local idx = random(1, #empty_cells)
        local c = empty_cells[idx]
        cells[c.x][c.y] = true
        table.remove(empty_cells, idx)
      end
    elseif d < 0 then
      count = math.min(count, #filled_cells)
      for i = 1, count do
        local idx = random(1, #filled_cells)
        local c = filled_cells[idx]
        cells[c.x][c.y] = false
        table.remove(filled_cells, idx)
      end
    end

    gridredraw()

  elseif enc_mode == 1 then
    -- BALL CONTROL
    if n == 2 then
      ball_speed_factor = clamp(ball_speed_factor + d * 0.05, 0.1, 3)
    elseif n == 3 then
      pitch_factor = clamp(pitch_factor + d * 0.05, 0.1, 3)
    end

  else
    -- SOUND CONTROL (K3 held)
    if n == 2 then
      cutoff = clamp(cutoff - d * 200, 500, 10000)
      engine.cutoff(cutoff)
    elseif n == 3 then
      release = clamp(release + d * 0.05, 0.01, 8)
      engine.release(release)
    end
  end
end

-- ------------------------------------------------------------
-- KEYS
-- ------------------------------------------------------------
function key(n, z)
  if n == 1 then
    key1_held = (z > 0)

  elseif n == 2 then
    key2_held = (z > 0)
    if z > 0 then
      for x = 1, GRID_W do
        for y = 1, GRID_H do
          cells[x][y] = false
        end
      end
      gridredraw()
    end

  elseif n == 3 then
    enc_mode = (z > 0) and 2 or 1
  end
end
