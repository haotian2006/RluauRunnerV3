-- Single-world Sandbox checks. Run as normal (sandboxed) user code; prints PASS n/n or the failures.
local total, fails = 0, {}
local function check(name, cond, detail)
	total += 1
	if not cond then
		table.insert(fails, name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
	end
end
local function err(f, ...)
	local ok, e = pcall(f, ...)
	if ok then
		return nil
	end
	return tostring(e)
end
local function has(s, sub)
	return type(s) == "string" and string.find(s, sub, 1, true) ~= nil
end

check("typeof game", typeof(game) == "Instance", typeof(game))
check("type game", type(game) == "userdata")
check("metatable locked", getmetatable(game) == "The metatable is locked")
check("game.Workspace", game.Workspace == workspace)
check("GetService Workspace", game:GetService("Workspace") == workspace)
check("Workspace global", Workspace == workspace)
check("FindFirstChildOfClass Workspace", game:FindFirstChildOfClass("Workspace") == workspace)
check("workspace.Parent", workspace.Parent == game)
check("stats", stats() == game:GetService("Stats"))

local p = Instance.new("Part")
p.Parent = workspace
check("part parent", p.Parent == workspace)
check("find part", workspace:FindFirstChild("Part") == p)
check("fullname", p:GetFullName() == "Workspace.Part", p:GetFullName())
check("descendant of game", p:IsDescendantOf(game))
check("in children", table.find(workspace:GetChildren(), p) ~= nil)
local leak
for _, d in game:GetDescendants() do
	local n = d.Name
	if n:sub(1, 5) == "__ws_" or n:sub(1, 6) == "__svc_" or n:sub(1, 6) == "__sbx_" then
		leak = d:GetFullName()
	end
end
check("no shadow leaks", leak == nil, leak)
check("descendants has part", table.find(game:GetDescendants(), p) ~= nil)

check("member error", err(function()
	return p.Nope
end) == 'Nope is not a valid member of Part "Workspace.Part"', err(function()
	return p.Nope
end))
check("read only", has(err(function()
	game.PlaceId = 1
end), "read only"))
check("arith error", has(err(function()
	return p + 1
end), "attempt to perform arithmetic (add) on Instance and number"))
check("len error", has(err(function()
	return #p
end), "attempt to get length of a Instance value"))
check("Instance table", typeof(Instance) == "table" and table.isfrozen(Instance))
check("Instance readonly", has(err(function()
	Instance.foo = 1
end), "readonly"))
local t = { [p] = 1 }
check("table key identity", t[workspace:FindFirstChild("Part")] == 1)

local c = p:Clone()
check("clone parentless", c.Parent == nil and typeof(c) == "Instance" and c ~= p)
game.Name = "Sandboxed"
check("overlay name", game.Name == "Sandboxed" and tostring(game) == "Sandboxed")
check("clone game error", has(err(game.Clone, game), "Sandboxed cannot be cloned"), err(game.Clone, game))
check("clone workspace error", has(err(workspace.Clone, workspace), "Workspace cannot be cloned"), err(workspace.Clone, workspace))

local f = Instance.new("Folder", game)
f.Name = "OnGame"
check("parent to game", f.Parent == game and game:FindFirstChild("OnGame") == f)
check("game child fullname", f:GetFullName() == "OnGame", f:GetFullName())
local rs = game:GetService("ReplicatedStorage")
local q = Instance.new("Part", rs)
q.Name = "InRS"
check("rs child", rs:FindFirstChild("InRS") == q and q:GetFullName() == "ReplicatedStorage.InRS", q:GetFullName())

local ov = Instance.new("ObjectValue")
ov.Value = p
check("objectvalue part", ov.Value == p)
ov.Value = workspace
check("objectvalue workspace", ov.Value == workspace)

check("signal typeof", typeof(p.Touched) == "RBXScriptSignal")
local fired
local conn = p.Changed:Connect(function(prop)
	fired = prop
end)
check("conn typeof", typeof(conn) == "RBXScriptConnection")
p.Name = "Renamed"
task.wait()
check("owned Changed", fired == "Name", fired)
conn:Disconnect()
check("disconnected", conn.Connected == false)

local lighting = game:GetService("Lighting")
local got = false
lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
	got = true
end)
lighting.ClockTime = 5
task.wait()
check("overlay prop", lighting.ClockTime == 5)
check("overlay prop signal", got)
lighting:SetAttribute("a", 1)
check("overlay attr", lighting:GetAttribute("a") == 1)
lighting:AddTag("t")
check("overlay tag", lighting:HasTag("t"))
check("GetTagged overlay", table.find(game:GetService("CollectionService"):GetTagged("t"), lighting) ~= nil)
check("service destroy locked", has(err(function()
	lighting:Destroy()
end), "locked"))

local floor = Instance.new("Part")
floor.Anchored = true
floor.Size = Vector3.new(10, 1, 10)
floor.CFrame = CFrame.new(100, 0, 0)
floor.Parent = workspace
local r = workspace:Raycast(Vector3.new(100, 10, 0), Vector3.new(0, -20, 0))
check("raycast hit", r ~= nil and r.Instance == floor, r and r.Instance)
check("raycast typeof", typeof(r) == "RaycastResult", typeof(r))
check("bounds query", table.find(workspace:GetPartBoundsInBox(CFrame.new(100, 0, 0), Vector3.new(20, 20, 20)), floor) ~= nil)

task.delay(0.1, function()
	Instance.new("Folder", workspace).Name = "Later"
end)
check("WaitForChild", workspace:WaitForChild("Later", 2) ~= nil)

check("json", game:GetService("HttpService"):JSONEncode({ p }) == "[null]")
local SS = game:GetService("SerializationService")
check("serialize workspace", has(err(function()
	return SS:SerializeInstancesAsync({ workspace })
end), "can't be serialized"))
local okS, buf = pcall(SS.SerializeInstancesAsync, SS, { p })
check("serialize owned", okS and typeof(buf) == "buffer", buf)
if okS then
	local copies = SS:DeserializeInstancesAsync(buf)
	check("deserialize proxy", typeof(copies[1]) == "Instance" and copies[1].Parent == nil)
end

local mod = Instance.new("ModuleScript")
local okSrc = pcall(function()
	mod.Source = "return { g = game }"
end)
if okSrc then
	local okR, res = pcall(require, mod)
	check("require owned module", okR and type(res) == "table" and res.g == game, res)
end

if thread then
	local fn = loadstring("return game, ...")
	check("loadstring game", fn and select(1, fn(1)) == game)
	check("loadstring varargs", fn and select(2, fn(7)) == 7)
	local fn2 = loadstring("return 1 -- trailing comment")
	check("loadstring trailing comment", fn2 and fn2() == 1)
end

print(#fails == 0 and `PASS {total}/{total}` or (`FAIL {#fails}/{total}\n` .. table.concat(fails, "\n")))
