-- Rabbit: every CPU write to a range of the address space with the frame, the time since that frame's vblank began and the instruction's
-- PC, under the same scripted inputs as dump_state.lua; the system bench's +WATCHLO/+WATCHHI (sim/tb_top.sv) prints the core's side.
--   WATCHLO, WATCHHI=<hex>  the range;  FROM, TO=<frame>  the frames logged (the run ends after TO);  WATCHLOG=<file>
--   SCHED=coin|play         as dump_state.lua
-- A line: "<frame> <us since vblank> <PC> <address> <data> <mask>", the address and mask of the 32-bit bus (big-endian lanes).
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local scr  = mach.screens[":screen"]
local LO, HI = tonumber(os.getenv("WATCHLO") or "ff0000", 16), tonumber(os.getenv("WATCHHI") or "ffffff", 16)
local FROM, TO = tonumber(os.getenv("FROM") or "0"), tonumber(os.getenv("TO") or "600")
local SCHED = os.getenv("SCHED")
if SCHED == "" then SCHED = nil end
local out = io.open(os.getenv("WATCHLOG") or "watch.log", "w")

local inp = mach.ioport.ports[":INPUTS"]
local function field(name) for n, f in pairs(inp.fields) do if n == name then return f end end end
local F = {}
for _, n in ipairs({"Coin 1", "1 Player Start", "P1 Button 1", "P1 Button 2", "P1 Button 3", "P1 Up", "P1 Left", "P1 Right"}) do F[n] = field(n) end
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

local t0, frame = 0, 0
local pcreg = cpu.state["CURPC"] or cpu.state["PC"]
_G.WT = sp:install_write_tap(LO & ~3, HI | 3, "watch", function(off, data, mask)
  if frame >= FROM and frame <= TO then
    out:write(string.format("%d %.1f %06x %06x %08x %08x\n", frame, (mach.time:as_double() - t0) * 1e6, pcreg.value & 0xffffff, off, data, mask))
  end
end)
emu.register_frame_done(function()
  frame = scr:frame_number()
  t0 = mach.time:as_double()
  if SCHED then
    local p = sched(frame)
    for n, fld in pairs(F) do if fld then fld:set_value(p[n] and 1 or 0) end end
  end
  if frame > TO then out:close(); mach:exit() end
end)
