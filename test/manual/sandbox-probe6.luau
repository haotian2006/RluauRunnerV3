--!nosandbox
-- Probe: does ResetPropertyToDefault actually change service properties? Restores values afterwards.
local out = {}
local function step(label, inst, prop, value)
	local before = inst[prop]
	local setOk, setErr = pcall(function()
		inst[prop] = value
	end)
	local afterSet = inst[prop]
	local resetOk, resetErr = pcall(inst.ResetPropertyToDefault, inst, prop)
	local afterReset = inst[prop]
	pcall(function()
		inst[prop] = before
	end)
	table.insert(
		out,
		`{label}: before={before} set={setOk and "ok" or setErr} afterSet={afterSet} reset={resetOk and "ok" or resetErr} afterReset={afterReset}`
	)
end
local L = game:GetService("Lighting")
step("Lighting.Name", L, "Name", "tmp")
step("Lighting.ClockTime", L, "ClockTime", 3)
step("Lighting.TimeOfDay", L, "TimeOfDay", "03:00:00")
local WS = game:GetService("Workspace")
step("Workspace.Name", WS, "Name", "tmpws")
step("Workspace.Gravity", WS, "Gravity", 10)
step("game.Name", game, "Name", "tmpgame")
local HS = game:GetService("HttpService")
step("HttpService.Name", HS, "Name", "tmphttp")
local part = Instance.new("Part")
step("Part.Name", part, "Name", "tmppart")
print(table.concat(out, "\n"))
