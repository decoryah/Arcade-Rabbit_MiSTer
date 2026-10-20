-- Rabbit: every write to the I5000's sound registers (400900-4009ff) with its time, for the sound bench (sim/run_snd.sh), and the play
-- schedule of dump_state.lua (SCHED=play). Run with -wavwrite to record MAME's output of the same run.
--   SNDLOG=<file>  "<seconds> <reg> <data hex> <mask hex>" a line;  LASTFRAME=n ends the run
local mach = manager.machine
local sp = mach.devices[":maincpu"].spaces["program"]
local scr = mach.screens[":screen"]
local out = io.open(os.getenv("SNDLOG") or "snd.log", "w")
_G.SK = {}
_G.SK.t = sp:install_write_tap(0x400900, 0x4009ff, "snd", function(off, data, mask)
  -- a 32-bit bus: the high half is register (off - 0x400900) / 2, the low half the next one
  local t = mach.time:as_double()
  local r = (off - 0x400900) // 2
  if (mask & 0xffff0000) ~= 0 then out:write(string.format("%.9f %d %04x %04x\n", t, r, (data >> 16) & 0xffff, (mask >> 16) & 0xffff)) end
  if (mask & 0x0000ffff) ~= 0 then out:write(string.format("%.9f %d %04x %04x\n", t, r + 1, data & 0xffff, mask & 0xffff)) end
end)
-- reads (the playing channels, register 0x42): "R <seconds> <reg> <data>", checked by the bench against its own chip
_G.SK.r = sp:install_read_tap(0x400900, 0x4009ff, "sndr", function(off, data, mask)
  local t = mach.time:as_double()
  local r = (off - 0x400900) // 2
  if (mask & 0xffff0000) ~= 0 then out:write(string.format("R %.9f %d %04x\n", t, r, (data >> 16) & 0xffff)) end
  if (mask & 0x0000ffff) ~= 0 then out:write(string.format("R %.9f %d %04x\n", t, r + 1, data & 0xffff)) end
end)
local inp = mach.ioport.ports[":INPUTS"]
local function field(name) for n, f in pairs(inp.fields) do if n == name then return f end end end
local F = {}
for _, n in ipairs({"Coin 1", "1 Player Start", "P1 Button 1", "P1 Button 2", "P1 Button 3", "P1 Up", "P1 Left", "P1 Right"}) do F[n] = field(n) end
local LAST = tonumber(os.getenv("LASTFRAME") or "3000")
emu.register_frame_done(function()
  local f = scr:frame_number()
  local p = {}
  p["Coin 1"] = (f >= 300 and f < 306)
  p["1 Player Start"] = (f >= 400 and f < 406)
  if f >= 600 then
    p["P1 Button 1"] = ((f // 8) % 4 == 0)
    p["P1 Button 2"] = ((f // 8) % 4 == 2)
    p["P1 Button 3"] = ((f // 12) % 5 == 1)
    p["P1 Right"]    = ((f // 60) % 3 ~= 2)
    p["P1 Left"]     = ((f // 60) % 3 == 2)
    p["P1 Up"]       = ((f // 90) % 4 == 3) and (f % 90 < 10)
  end
  if os.getenv("NOSCHED") ~= "1" then for n, fld in pairs(F) do fld:set_value(p[n] and 1 or 0) end end
  if f >= LAST then out:close(); mach:exit() end
end)
