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
check("Stats alias", Stats() == stats())
local excludeFloor = RaycastParams.new()
excludeFloor.FilterType = Enum.RaycastFilterType.Exclude
excludeFloor.FilterDescendantsInstances = { floor }
check("RaycastParams typeof", typeof(excludeFloor) == "RaycastParams")
check("RaycastParams filter roundtrip", excludeFloor.FilterDescendantsInstances[1] == floor)
check("raycast exclude filter", workspace:Raycast(Vector3.new(100, 10, 0), Vector3.new(0, -20, 0), excludeFloor) == nil)
local includeFloor = RaycastParams.new()
includeFloor.FilterType = Enum.RaycastFilterType.Include
includeFloor:AddToFilter(floor)
local included = workspace:Raycast(Vector3.new(100, 10, 0), Vector3.new(0, -20, 0), includeFloor)
check("raycast include filter", included ~= nil and included.Instance == floor)
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
overlap.FilterDescendantsInstances = { floor }
local inBox = workspace:GetPartBoundsInBox(CFrame.new(100, 0, 0), Vector3.new(20, 20, 20), overlap)
check("OverlapParams filter", #inBox == 1 and inBox[1] == floor)

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

local DSS = game:GetService("DataStoreService")
local ds = DSS:GetDataStore("spec")
check("datastore typeof", typeof(ds) == "Instance" and ds.ClassName == "DataStore" and ds:IsA("GlobalDataStore"))
check("datastore same object", DSS:GetDataStore("spec") == ds)
local original = { 1, { x = 2 } }
ds:SetAsync("k", original)
local got, keyInfo = ds:GetAsync("k")
check("datastore roundtrip", type(got) == "table" and got[1] == 1 and got[2].x == 2 and got ~= original)
check("datastore keyinfo", typeof(keyInfo) == "Instance" and type(keyInfo.Version) == "string")
check("datastore rejects Instance", has(err(ds.SetAsync, ds, "bad", Instance.new("Part")), "Cannot store"))
check("datastore update", ds:UpdateAsync("n", function(old)
	return (old or 0) + 5
end) == 5)
check("datastore increment", ds:IncrementAsync("n", 2) == 7)
check("datastore remove", ds:RemoveAsync("n") == 7 and ds:GetAsync("n") == nil)
check("datastore key limit", has(err(ds.GetAsync, ds, string.rep("a", 51)), "50 character"))
local pages = ds:ListKeysAsync()
check("datastore listkeys", #pages:GetCurrentPage() >= 1 and pages:GetCurrentPage()[1].KeyName == "k")
local ods = DSS:GetOrderedDataStore("board")
ods:SetAsync("a", 3)
ods:SetAsync("b", 9)
local top = ods:GetSortedAsync(false, 10):GetCurrentPage()
check("ordered sorted", top[1] and top[1].key == "b" and top[1].value == 9)
local MSS = game:GetService("MemoryStoreService")
check("AI_CONTEXT unreachable", MSS:GetHashMap("AI_CONTEXT"):GetAsync("1") == nil)
local hm = MSS:GetHashMap("spec")
hm:SetAsync("k", "v", 60)
check("hashmap", hm:GetAsync("k") == "v")
local q = MSS:GetQueue("spec")
q:AddAsync("job", 60)
local items, readId = q:ReadAsync(1, false, 0)
check("queue read", items[1] == "job" and readId ~= nil)
q:RemoveAsync(readId)
check("queue empty", q:GetSizeAsync() == 0)
local received
game:GetService("MessagingService"):SubscribeAsync("spec", function(msg)
	received = msg.Data
end)
game:GetService("MessagingService"):PublishAsync("spec", { hi = true })
task.wait(0.1)
check("messaging", type(received) == "table" and received.hi == true)

local toucher, touchedPart = Instance.new("Part", workspace), Instance.new("Part", workspace)
local touchedBy, endedBy
toucher.Touched:Connect(function(hit)
	touchedBy = hit
end)
toucher.TouchEnded:Connect(function(hit)
	endedBy = hit
end)
firesignal(toucher.Touched, touchedPart)
firesignal(toucher.TouchEnded, touchedPart)
task.wait()
check("firesignal Touched/TouchEnded", touchedBy == touchedPart and endedBy == touchedPart)
local firedProp
toucher.Changed:Connect(function(prop)
	firedProp = prop
end)
fireevent(toucher, "Changed", "Fake")
task.wait()
check("fireevent", firedProp == "Fake")
check("fireevent bad name", has(err(fireevent, toucher, "Nope"), "Nope"))
local payload, received = {}, nil
toucher.Touched:Connect(function(x)
	received = x
end)
firesignal(toucher.Touched, payload)
task.wait()
check("firesignal keeps identity", received == payload)
local nameFired = false
toucher:GetPropertyChangedSignal("Name"):Connect(function()
	nameFired = true
end)
firesignal(toucher:GetPropertyChangedSignal("Name"))
task.wait()
check("firesignal method-returned signal", nameFired)

local doomed = Instance.new("Part")
local doomedFired = false
local doomedConn = doomed.Touched:Connect(function()
	doomedFired = true
end)
check("connected before Destroy", doomedConn.Connected == true)
doomed:Destroy()
check("Destroy disconnects", doomedConn.Connected == false)
firesignal(doomed.Touched)
task.wait()
check("destroyed connection doesn't fire", doomedFired == false)

local LS = game:GetService("LogService")
local logged = {}
local logConn = LS.MessageOut:Connect(function(message, messageType)
	table.insert(logged, { message, messageType })
end)
print("spec-log", 1)
warn("spec-warn")
task.wait()
logConn:Disconnect()
check("MessageOut print", logged[1] and logged[1][1] == "spec-log 1" and logged[1][2] == Enum.MessageType.MessageOutput, logged[1] and logged[1][1])
check("MessageOut warn", logged[2] and logged[2][1] == "spec-warn" and logged[2][2] == Enum.MessageType.MessageWarning)
local history = LS:GetLogHistory()
check("GetLogHistory", #history >= 2 and history[#history].message == "spec-warn")
if thread then
	local scriptError
	game:GetService("ScriptContext").Error:Connect(function(message)
		scriptError = message
	end)
	task.spawn(function()
		error("spec background error")
	end)
	task.wait(0.5)
	check("ScriptContext.Error", type(scriptError) == "string" and scriptError:find("spec background error", 1, true) ~= nil, scriptError)
end

if thread then
	local fx, m = _execute("return 5", "specmod")
	check("_execute module is a proxy", typeof(m) == "Instance" and m:IsA("ModuleScript"))
	local holder = Instance.new("ModuleScript", script)
	check("_execute module parent", pcall(function()
		m.Parent = holder
	end) and m.Parent == holder)
	check("_execute runs", fx() == 5)
	if PacketSizeCounter then
		check("PacketSizeCounter sees Instance", PacketSizeCounter.GetDataByteSize(p) == 5, PacketSizeCounter.GetDataByteSize(p))
	end
	local fn = loadstring("return game, ...")
	check("loadstring game", fn and select(1, fn(1)) == game)
	check("loadstring varargs", fn and select(2, fn(7)) == 7)
	local fn2 = loadstring("return 1 -- trailing comment")
	check("loadstring trailing comment", fn2 and fn2() == 1)

	local rm = Instance.new("ModuleScript")
	rm.Source = "return function() return game end"
	local rf = require(rm)
	check("require module is sandboxed", type(rf) == "function" and rf() == game)
	check("require caches per module", require(rm) == rf)
	local okId, errId = pcall(function()
		require(1055656097)
	end)
	check("require asset id looks for MainModule", not okId and tostring(errId):find("MainModule") ~= nil, errId)

	local pkg = Instance.new("Folder")
	local a = Instance.new("ModuleScript")
	a.Name = "A"
	a.Source = 'return { b = require("@self/B"), c = require("./C"), g = require("@game/ReplicatedStorage/G") }'
	a.Parent = pkg
	local b = Instance.new("ModuleScript")
	b.Name = "B"
	b.Source = 'return { up = require("../C"), viaDots = require("@self/../../C") }'
	b.Parent = a
	local c = Instance.new("ModuleScript")
	c.Name = "C"
	c.Source = "return { game = game }"
	c.Parent = pkg
	local gm = Instance.new("ModuleScript")
	gm.Name = "G"
	gm.Source = "return 'g'"
	gm.Parent = game:GetService("ReplicatedStorage")
	local bad = Instance.new("ModuleScript")
	bad.Name = "Bad"
	bad.Source = "return ("
	bad.Parent = pkg
	local okA, ra = pcall(require, a)
	check("string require resolves", okA and ra.c == require(c) and ra.b.up == ra.c and ra.b.viaDots == ra.c and ra.g == "g", ra)
	check("string required module is sandboxed", okA and ra.c.game == game)
	local badErr = err(require, bad)
	check("syntax error names module", has(badErr, "Syntax error in required module 'Bad' at line 1"), badErr)
	check("failed module keeps its error", err(require, bad) == badErr)
	local missing = Instance.new("ModuleScript")
	missing.Source = 'return require("@self/Nope")'
	missing.Parent = pkg
	check("missing child error", has(err(require, missing), 'could not resolve child component "Nope"'))
	gm:Destroy()
end

check("require @self is not the sandbox", has(err(require, "@self"), "recursively"))
check("require ./ needs a parent", has(err(require, "./image"), "could not get parent of requiring context"))
check("require needs a prefix", has(err(require, "image"), "valid prefix"))
check("require unknown alias", has(err(require, "@foo/x"), "not a valid alias"))
check("require @game non-module", has(err(require, "@game/Workspace"), "not a ModuleScript"))

check("getfenv self is sandbox", getfenv().game == game)
check("getfenv on foreign fn is sandboxed", getfenv(typeof).game == game, getfenv(typeof).game.PlaceId)
check("getfenv on C fn is sandboxed", getfenv(print).game == game)
check("getfenv cannot reach real game", getfenv(typeof).game.PlaceId == 0)
check("getfenv on C fn cannot reach real game", getfenv(print).game.PlaceId == 0)
do
	local custom = { marker = "mine" }
	local function uf() end
	setfenv(uf, custom)
	check("getfenv returns a setfenv'd custom env", getfenv(uf) == custom)
end
check("PlaceId masked", game.PlaceId == 0, game.PlaceId)
check("GameId masked", game.GameId == 0, game.GameId)
check("CreatorId masked", game.CreatorId == -1, game.CreatorId)
check("JobId is a guid", type(game.JobId) == "string" and #game.JobId == 36, game.JobId)
check("PrivateServerId masked", game.PrivateServerId == "", game.PrivateServerId)
check("identity is read only", not pcall(function()
	game.PlaceId = 5
end))
do
	local order = {}
	local w = coroutine.wrap(function()
		table.insert(order, "a")
		coroutine.yield(1)
		table.insert(order, "b")
		return 2
	end)
	check("coroutine.wrap first", w() == 1)
	check("coroutine.wrap second", w() == 2)
	check("coroutine.wrap order", table.concat(order) == "ab")
	local err = coroutine.wrap(function()
		error("boom")
	end)
	check("coroutine.wrap reraises", not pcall(err))
end

if Image then
	local AssetService = game:GetService("AssetService")
	local okE, ei = pcall(AssetService.CreateEditableImage, AssetService, { Size = Vector2.new(8, 8) })
	check("CreateEditableImage", okE and typeof(ei) == "Object" and ei:IsA("EditableImage") and ei.Size == Vector2.new(8, 8), ei)
	if okE then
		ei:DrawRectangle(Vector2.zero, Vector2.new(8, 8), Color3.new(1, 0, 0), 0, Enum.ImageCombineType.Overwrite)
		local px = ei:ReadPixelsBuffer(Vector2.zero, Vector2.new(1, 1))
		check("EditableImage draws", buffer.readu8(px, 0) == 255 and buffer.readu8(px, 1) == 0)
		local gui = Instance.new("ScreenGui")
		local label = Instance.new("ImageLabel")
		label.Size = UDim2.fromOffset(20, 20)
		label.BackgroundTransparency = 1
		label.ImageContent = Content.fromObject(ei)
		label.Parent = gui
		local c = Image.fromInstance(gui, { Size = Vector2.new(20, 20) }):GetPixel(10, 10)
		check("EditableImage renders in an ImageLabel", c ~= nil and c.R > 0.9 and c.G < 0.1, c)
		ei:Destroy()
		check("destroyed EditableImage errors", err(ei.ReadPixelsBuffer, ei, Vector2.zero, Vector2.one) ~= nil)
	end
end

print(#fails == 0 and `PASS {total}/{total}` or (`FAIL {#fails}/{total}\n` .. table.concat(fails, "\n")))
