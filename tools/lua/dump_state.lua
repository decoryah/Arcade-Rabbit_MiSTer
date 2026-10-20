-- Rabbit: freeze frames and write the video chip's state with MAME's own snapshot of the same frame (the frame bench, sim/run_frames.sh).
--   DUMPFRAMES=<f,f,...>  frames to capture;  DUMPDIR=<dir>  output (state_<f>.bin, snap_<f>.png)
--   WORKRAM=1             also wram_<f>.bin: the work RAM (ff0000-ffffff, 64 KB)
--   SCHED=coin|play       scripted inputs, the same as the system bench's (sim/tb_rabbit.cpp sched()): a coin at frame 300, start at
--                         400; coin: button A every other second from 600; play: from 600 walking, jumping and buttons A-C in a fixed
--                         pattern of the frame number
-- At frame_done MAME has just drawn the frame (screen_update at the start of vblank) and the CPU has not run since, so the memories
-- read now are the ones the frame was drawn from.
-- state_<f>.bin, big-endian dwords: tilemaps 0-3 (4 x 4096), sprite RAM (4096), palette (16384), tilemap_regs (4 x 6), spriteregs (7)
local mach = manager.machine
local sp   = mach.devices[":maincpu"].spaces["program"]
local scr  = mach.screens[":screen"]
local FR, LAST = {}, 0
for n in string.gmatch(os.getenv("DUMPFRAMES") or "", "%d+") do FR[tonumber(n)] = true; if tonumber(n) > LAST then LAST = tonumber(n) end end
local DIR = os.getenv("DUMPDIR") or "."
local SCHED = os.getenv("SCHED")
if SCHED == "" then SCHED = nil end

local inp = mach.ioport.ports[":INPUTS"]
local function field(name) for n, f in pairs(inp.fields) do if n == name then return f end end end
local F = {}
for _, n in ipairs({"Coin 1", "1 Player Start", "P1 Button 1", "P1 Button 2", "P1 Button 3", "P1 Button 4", "P1 Up", "P1 Down", "P1 Left", "P1 Right"}) do F[n] = field(n) end

-- the schedule: a table of field name -> pressed, for frame f (the same function as tb_rabbit.cpp's sched)
local function sched(f)
  local p = {}
  p["Coin 1"] = (f >= 300 and f < 306)
  p["1 Player Start"] = (f >= 400 and f < 406)
  if SCHED == "coin" then
    p["P1 Button 1"] = (f >= 600 and (f // 30) % 2 == 1)
  elseif SCHED == "play" and f >= 600 then
    p["P1 Button 1"] = ((f // 8) % 4 == 0)
    p["P1 Button 2"] = ((f // 8) % 4 == 2)
    p["P1 Button 3"] = ((f // 12) % 5 == 1)
    p["P1 Right"]    = ((f // 60) % 3 ~= 2)
    p["P1 Left"]     = ((f // 60) % 3 == 2)
    p["P1 Up"]       = ((f // 90) % 4 == 3) and (f % 90 < 10)
  end
  return p
end

local function be32(v) return string.char((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff) end
local function dump(f)
  local t = {}
  for a = 0x480000, 0x48fffc, 4 do t[#t + 1] = be32(sp:read_u32(a)) end
  for a = 0x494000, 0x497ffc, 4 do t[#t + 1] = be32(sp:read_u32(a)) end
  for a = 0x4a0000, 0x4afffc, 4 do t[#t + 1] = be32(sp:read_u32(a)) end
  for l = 0, 3 do
    local sh = mach.memory.shares[":tilemap_regs." .. l]
    for n = 0, 5 do t[#t + 1] = be32(sh:read_u32(n * 4)) end
  end
  local sh = mach.memory.shares[":spriteregs"]
  for n = 0, 6 do t[#t + 1] = be32(sh:read_u32(n * 4)) end
  local fh = io.open(string.format("%s/state_%d.bin", DIR, f), "wb"); fh:write(table.concat(t)); fh:close()
  if os.getenv("WORKRAM") == "1" then
    local w = {}
    for a = 0xff0000, 0xfffffc, 4 do w[#w + 1] = be32(sp:read_u32(a)) end
    fh = io.open(string.format("%s/wram_%d.bin", DIR, f), "wb"); fh:write(table.concat(w)); fh:close()
  end
  scr:snapshot(string.format("%s/snap_%d.png", DIR, f))
end

emu.register_frame_done(function()
  local f = scr:frame_number()
  if SCHED then
    local p = sched(f)
    for n, fld in pairs(F) do fld:set_value(p[n] and 1 or 0) end
  end
  if FR[f] then dump(f) end
  if f >= LAST then mach:exit() end
end)
