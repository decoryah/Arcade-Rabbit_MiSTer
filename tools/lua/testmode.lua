-- Rabbit: the test mode in MAME, for the core's whole-machine bench to compare (sim/tb_rabbit.cpp SCHED=test). The test switch from
-- frame TSW (default 300) for 10 frames, then PRESS ("frame:field,...", each held 6 frames; the bench's schedule is
-- "330:P1 Up,350:P1 Up,370:P1 Button 1": the test menu's MEMORY TEST), snapshots tm_<f>.png at SNAPS ("f,f,...") into SNAPDIR; exits
-- after the last. Prints the input fields' names.
local mach = manager.machine
local scr = mach.screens[":screen"]
local DIR = os.getenv("SNAPDIR")
local inp = mach.ioport.ports[":INPUTS"]
local fields = {}
for n, f in pairs(inp.fields) do fields[n] = f end
local press = {}
for f, name in string.gmatch(os.getenv("PRESS") or "", "(%d+):([^,]+)") do press[#press + 1] = {tonumber(f), name} end
local snaps, last = {}, 0
for n in string.gmatch(os.getenv("SNAPS"), "%d+") do snaps[tonumber(n)] = true; if tonumber(n) > last then last = tonumber(n) end end
local TSW = tonumber(os.getenv("TSW") or "300")
emu.register_frame_done(function()
  local f = scr:frame_number()
  local on = {}
  if f >= TSW and f < TSW + 10 then on["Service Mode"] = true end
  for _, p in ipairs(press) do if f >= p[1] and f < p[1] + 6 then on[p[2]] = true end end
  for n, fld in pairs(fields) do fld:set_value(on[n] and 1 or 0) end
  if snaps[f] then scr:snapshot(string.format("%s/tm_%d.png", DIR, f)) end
  if f >= last then mach:exit() end
end)
print("fields:")
for n, _ in pairs(fields) do print("  " .. n) end
