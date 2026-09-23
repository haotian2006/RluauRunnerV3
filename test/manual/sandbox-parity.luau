-- Parity check: run once normally and once with a leading --!nosandbox line, then diff the output.
-- Every line should match; a difference is a place the sandbox isn't 1:1 with the engine.
local out = {}
local function log(k, ...)
	local t = table.pack(...)
	for i = 1, t.n do
		t[i] = tostring(t[i])
	end
	table.insert(out, k .. ": " .. table.concat(t, " | "))
end
local function try(k, f)
	local r = table.pack(pcall(f))
	if r[1] then
		log(k, table.unpack(r, 2, r.n))
	else
		log(k, "ERR " .. tostring(r[2]):gsub("^.-:%d+: ", ""))
	end
end

local before = {}
for _, root in { workspace, game } do
	for _, c in root:GetChildren() do
		before[c] = true
	end
end

-- typeof / tostring / identity
local p = Instance.new("Part")
p.Parent = workspace
try("typeof", function()
	return typeof(p), type(p), tostring(p)
end)
try("getmetatable", function()
	return getmetatable(p)
end)
try("rawequal self", function()
	return rawequal(p, p), p == workspace.Part
end)

-- hierarchy
local model = Instance.new("Model")
model.Name = "M"
model.Parent = workspace
local inner = Instance.new("Part", model)
inner.Name = "Inner"
try("fullname nested", function()
	return inner:GetFullName()
end)
try("find recursive", function()
	return workspace:FindFirstChild("Inner", true) == inner, workspace:FindFirstChild("Inner") == nil
end)
try("ancestor", function()
	return inner:FindFirstAncestorOfClass("Model") == model, inner:FindFirstAncestorWhichIsA("WorldRoot") == workspace
end)
try("isdescendant", function()
	return inner:IsDescendantOf(workspace), inner:IsDescendantOf(game), workspace:IsAncestorOf(inner), model:IsAncestorOf(p)
end)
try("children order", function()
	local names = {}
	for _, c in model:GetChildren() do
		table.insert(names, c.Name)
	end
	Instance.new("Folder", model).Name = "F2"
	for _, c in model:GetChildren() do
		table.insert(names, c.Name)
	end
	return table.concat(names, ",")
end)
try("parent self", function()
	p.Parent = p
end)
try("parent circular", function()
	model.Parent = inner
end)
try("FindFirstChildWhichIsA", function()
	return model:FindFirstChildWhichIsA("BasePart") == inner, model:FindFirstChildOfClass("Folder").Name
end)

-- destroy semantics
local d = Instance.new("Part", workspace)
local child = Instance.new("Part", d)
local destroying = false
d.Destroying:Connect(function()
	destroying = true
end)
local childConn = child.Touched:Connect(function() end)
d:Destroy()
task.wait()
try("after destroy", function()
	return d.Parent, child.Parent, destroying, childConn.Connected
end)
try("reparent destroyed", function()
	d.Parent = workspace
end)
try("destroyed name read", function()
	return d.Name, d.ClassName
end)
try("clear all children", function()
	local f = Instance.new("Folder")
	Instance.new("Part", f)
	Instance.new("Part", f)
	f:ClearAllChildren()
	return #f:GetChildren()
end)

-- clone
try("clone archivable false", function()
	local x = Instance.new("Part")
	x.Archivable = false
	return x:Clone()
end)
try("clone deep", function()
	local x = model:Clone()
	return x.Name, #x:GetChildren(), x.Parent, x:FindFirstChild("Inner") ~= nil
end)
try("clone attributes", function()
	local x = Instance.new("Part")
	x:SetAttribute("a", 5)
	return x:Clone():GetAttribute("a")
end)

-- properties
try("size bad type", function()
	p.Size = "big"
end)
try("name number", function()
	p.Name = 5
	local n = p.Name
	p.Name = "Part"
	return n, typeof(n)
end)
try("enum from string", function()
	p.Material = "Neon"
	return p.Material
end)
try("enum bad", function()
	p.Material = "NotAMaterial"
end)
try("classname readonly", function()
	p.ClassName = "Model"
end)
try("brickcolor", function()
	p.BrickColor = BrickColor.new("Bright red")
	return p.BrickColor.Name, p.Color
end)
try("nonexistent prop read", function()
	return p.Nope
end)
try("nonexistent prop write", function()
	p.Nope = 1
end)
try("primarypart", function()
	model.PrimaryPart = inner
	return model.PrimaryPart == inner
end)
try("primarypart wrong model", function()
	model.PrimaryPart = p
	return model.PrimaryPart
end)
try("objectvalue changed arg", function()
	local ov = Instance.new("ObjectValue")
	local got
	ov.Changed:Connect(function(v)
		got = v
	end)
	ov.Value = p
	task.wait()
	return got == p
end)

-- methods and errors
try("dot call", function()
	p.Destroy()
end)
try("missing method", function()
	p:Nope()
end)
try("isa", function()
	return p:IsA("BasePart"), p:IsA("Model"), p:IsA("Instance")
end)
try("instance.new bad", function()
	return Instance.new("NotAClass")
end)
try("instance.new parent", function()
	local x = Instance.new("Folder", workspace)
	return x.Parent == workspace
end)
try("getservice bad", function()
	return game:GetService("NotAService")
end)
try("game member bad", function()
	return game.NotAChild
end)
try("waitforchild timeout", function()
	return workspace:WaitForChild("DoesNotExist", 0.2)
end)
try("propchanged bad prop", function()
	return p:GetPropertyChangedSignal("Nope")
end)

-- attributes and tags
try("attr bad type", function()
	p:SetAttribute("x", p)
end)
try("attr bad name", function()
	p:SetAttribute("bad name!", 1)
end)
try("attr roundtrip", function()
	p:SetAttribute("v", Vector3.new(1, 2, 3))
	local attrs = p:GetAttributes()
	return p:GetAttribute("v"), attrs.v
end)
try("attr changed", function()
	local got
	p.AttributeChanged:Connect(function(name)
		got = name
	end)
	p:SetAttribute("w", true)
	task.wait()
	return got
end)
try("tags", function()
	local CS = game:GetService("CollectionService")
	CS:AddTag(p, "parity")
	return p:HasTag("parity"), #CS:GetTagged("parity"), table.concat(p:GetTags(), ",")
end)

-- signals
try("connect non function", function()
	p.Touched:Connect(5)
end)
try("once", function()
	local n = 0
	local b = Instance.new("BindableEvent")
	local c = b.Event:Once(function()
		n += 1
	end)
	b:Fire()
	b:Fire()
	task.wait()
	return n, c.Connected
end)
try("wait args", function()
	local b = Instance.new("BindableEvent")
	task.delay(0.05, function()
		b:Fire(1, "two", p)
	end)
	local a, s, inst = b.Event:Wait()
	return a, s, inst == p
end)
try("bindable table copy", function()
	local b = Instance.new("BindableEvent")
	local t = { 1 }
	local got
	b.Event:Connect(function(v)
		got = v
	end)
	b:Fire(t)
	task.wait()
	return got ~= t, got[1]
end)
try("disconnect twice", function()
	local c = p.Touched:Connect(function() end)
	c:Disconnect()
	c:Disconnect()
	return c.Connected
end)
try("childadded arg", function()
	local f = Instance.new("Folder", workspace)
	local got
	f.ChildAdded:Connect(function(c)
		got = c
	end)
	local x = Instance.new("Part", f)
	task.wait()
	return got == x
end)
try("ancestrychanged", function()
	local x = Instance.new("Part")
	local got
	x.AncestryChanged:Connect(function(c, parent)
		got = { c == x, parent == workspace }
	end)
	x.Parent = workspace
	task.wait()
	return got and got[1], got and got[2]
end)
try("heartbeat wait", function()
	return typeof(game:GetService("RunService").Heartbeat:Wait())
end)

-- services and misc
try("json instance", function()
	return game:GetService("HttpService"):JSONEncode({ p, 1 })
end)
try("debris", function()
	local x = Instance.new("Part", workspace)
	game:GetService("Debris"):AddItem(x, 0.05)
	task.wait(0.3)
	return x.Parent
end)
try("tween", function()
	local x = Instance.new("Part", workspace)
	local tw = game:GetService("TweenService"):Create(x, TweenInfo.new(0.05), { Transparency = 1 })
	tw:Play()
	tw.Completed:Wait()
	return x.Transparency, typeof(tw), tw.ClassName
end)
try("task.spawn instance arg", function()
	local got
	task.spawn(function(x)
		got = x
	end, p)
	return got == p
end)
try("select/unpack instances", function()
	local kids = model:GetChildren()
	return #kids, select("#", table.unpack(kids))
end)
try("pivot", function()
	model:PivotTo(CFrame.new(10, 0, 0))
	return model:GetPivot().Position
end)
try("workspace props", function()
	return workspace.Gravity, workspace.Name, workspace.ClassName, workspace.Parent == game
end)
try("game name", function()
	return game.Name, game.ClassName, game.Parent
end)

-- batch 2: shared services and more hierarchy
local Lighting = game:GetService("Lighting")
try("linked clocktime", function()
	local old = Lighting.ClockTime
	Lighting.ClockTime = 3
	local tod = Lighting.TimeOfDay
	Lighting.ClockTime = old
	return tod
end)
try("linked timeofday", function()
	local old = Lighting.TimeOfDay
	Lighting.TimeOfDay = "06:30:00"
	local ct = Lighting.ClockTime
	Lighting.TimeOfDay = old
	return ct
end)
try("SetMinutesAfterMidnight", function()
	local old = Lighting.ClockTime
	Lighting:SetMinutesAfterMidnight(60)
	local ct = Lighting.ClockTime
	Lighting.ClockTime = old
	return ct
end)
try("service destroy", function()
	Lighting:Destroy()
end)
try("service reparent", function()
	Lighting.Parent = workspace
end)
try("game clone", function()
	return game:Clone()
end)
try("workspace clone", function()
	return workspace:Clone()
end)
try("rename workspace fullname", function()
	workspace.Name = "Renamed"
	local full = inner:GetFullName()
	local ts = tostring(workspace)
	workspace.Name = "Workspace"
	return full, ts
end)
try("tostring game", function()
	return tostring(game), tostring(workspace), tostring(Lighting)
end)
try("game.Workspace", function()
	return game.Workspace == workspace, game:GetService("Workspace") == workspace, game:FindService("Workspace") == workspace
end)
try("parent to service", function()
	local x = Instance.new("Folder", Lighting)
	local r = { x.Parent == Lighting, x:GetFullName(), Lighting:FindFirstChild(x.Name) == x }
	x:Destroy()
	return table.unpack(r)
end)
try("parent to game", function()
	local x = Instance.new("Folder", game)
	local r = { x.Parent == game, x:GetFullName() }
	x:Destroy()
	return table.unpack(r)
end)
try("game attribute", function()
	game:SetAttribute("parity", 1)
	local v = game:GetAttribute("parity")
	game:SetAttribute("parity", nil)
	return v
end)
try("same name first", function()
	local f = Instance.new("Folder")
	local a = Instance.new("Part", f)
	local b = Instance.new("Part", f)
	return f:FindFirstChild("Part") == a, f:FindFirstChild("Part") ~= b
end)
try("childremoved arg", function()
	local f = Instance.new("Folder")
	local x = Instance.new("Part", f)
	local got
	f.ChildRemoved:Connect(function(c)
		got = c
	end)
	x.Parent = nil
	task.wait()
	return got == x
end)
try("descendantadded nested", function()
	local f = Instance.new("Folder", workspace)
	local sub = Instance.new("Folder", f)
	local got
	f.DescendantAdded:Connect(function(dd)
		got = dd
	end)
	local x = Instance.new("Part", sub)
	task.wait()
	return got == x, #f:GetDescendants()
end)
try("changed prop name", function()
	local x = Instance.new("Part")
	local names = {}
	x.Changed:Connect(function(n)
		table.insert(names, n)
	end)
	x.Transparency = 0.5
	task.wait()
	return table.concat(names, ",")
end)
try("propchanged count", function()
	local x = Instance.new("Part")
	local n = 0
	x:GetPropertyChangedSignal("Transparency"):Connect(function()
		n += 1
	end)
	x.Transparency = 0.2
	x.Transparency = 0.3
	x.Name = "other"
	task.wait()
	return n
end)
try("clone parent nil", function()
	return p:Clone().Parent
end)
try("remove deprecated", function()
	local x = Instance.new("Part", workspace)
	x:Remove()
	return x.Parent
end)
try("objectvalue destroyed", function()
	local ov = Instance.new("ObjectValue")
	local x = Instance.new("Part")
	ov.Value = x
	x:Destroy()
	return ov.Value == x
end)
try("fromExisting", function()
	local x = Instance.fromExisting(p)
	return x.ClassName, x.Parent, x == p
end)
try("current camera", function()
	return workspace.CurrentCamera ~= nil, workspace.CurrentCamera and workspace.CurrentCamera.ClassName
end)
try("terrain", function()
	return workspace.Terrain.ClassName, workspace.Terrain.Parent == workspace
end)
try("workspace child classes", function()
	local classes = {}
	for _, c in workspace:GetChildren() do
		if c.ClassName == "Camera" or c.ClassName == "Terrain" then
			table.insert(classes, c.ClassName)
		end
	end
	table.sort(classes)
	return table.concat(classes, ",")
end)
try("players", function()
	return #game:GetService("Players"):GetPlayers()
end)
try("guid format", function()
	return #game:GetService("HttpService"):GenerateGUID(false)
end)

-- RaycastParams / OverlapParams instance arrays
local rp = RaycastParams.new()
try("params exclude", function()
	rp.ExcludeInstances = { p }
	local e = rp.ExcludeInstances
	return #e, e[1] == p, table.isfrozen(e)
end)
try("params exclude write", function()
	rp.ExcludeInstances[2] = p
end)
try("params include", function()
	rp.IncludeInstances = { p }
	return #rp.IncludeInstances, rp.IncludeInstances[1] == p
end)
try("params fdi", function()
	rp.FilterDescendantsInstances = { p }
	rp:AddToFilter(Instance.new("Folder"))
	local f = rp.FilterDescendantsInstances
	return #f, f[1] == p, typeof(f[2]), table.isfrozen(f)
end)
try("params dot call", function()
	rp.AddToFilter(nil, p)
end)
try("params bad type", function()
	rp.FilterDescendantsInstances = 5
end)
try("overlap fdi", function()
	local op = OverlapParams.new()
	op.FilterDescendantsInstances = { p }
	return typeof(op), op.FilterDescendantsInstances[1] == p
end)

-- --!nosandbox runs share a server, so leave nothing behind for the next one
for _, root in { workspace, game } do
	for _, c in root:GetChildren() do
		if not before[c] then
			pcall(c.Destroy, c)
		end
	end
end

print(table.concat(out, "\n"))
print("PARITY END")
