local out = {}
local function log(k, v)
	table.insert(out, k .. ": " .. tostring(v))
end
local function try(k, f)
	local ok, r = pcall(f)
	log(k, ok and tostring(r) or ("ERR " .. tostring(r)))
end
local realWs = game:GetService("Workspace")

local function rayTest(label, parentTo, waitFirst)
	local wm = Instance.new("WorldModel")
	if parentTo then
		wm.Parent = parentTo
	end
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(10, 1, 10)
	part.CFrame = CFrame.new(0, 0, 0)
	part.Parent = wm
	if waitFirst then
		task.wait()
	end
	try(label .. ".raycast", function()
		local r = wm:Raycast(Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
		return r and (r.Instance == part) or "no hit"
	end)
	try(label .. ".boundsInBox", function()
		return #wm:GetPartBoundsInBox(CFrame.new(), Vector3.new(20, 20, 20))
	end)
	try(label .. ".partsInPart", function()
		local probe = Instance.new("Part")
		probe.Anchored = true
		probe.Size = Vector3.new(4, 4, 4)
		probe.CFrame = CFrame.new()
		probe.Parent = wm
		local n = #wm:GetPartsInPart(probe)
		probe:Destroy()
		return n
	end)
	wm:Destroy()
end
rayTest("unparented", nil, false)
rayTest("unparented+wait", nil, true)
rayTest("inWorkspace", realWs, false)
rayTest("inWorkspace+wait", realWs, true)
local holder = Instance.new("Folder")
rayTest("inUnparentedFolder+wait", holder, true)
holder:Destroy()

try("realWorkspace.SignalBehavior", function()
	return realWs.SignalBehavior
end)
try("serialize.realWorkspace", function()
	return typeof(game:GetService("SerializationService"):SerializeInstancesAsync({ realWs }))
end)
try("serialize.game", function()
	return typeof(game:GetService("SerializationService"):SerializeInstancesAsync({ game }))
end)
try("clone.game", function()
	return game:Clone()
end)
try("clone.realWorkspace", function()
	return realWs:Clone()
end)
try("parent.part.to.game", function()
	local p = Instance.new("Part")
	p.Parent = game
	local ok = p.Parent == game
	p:Destroy()
	return ok
end)

local capturedType, capturedMsg
local function wrapper()
	local ok, err = pcall(function()
		return realWs:FindFirstChild()
	end)
	capturedType = typeof(err)
	capturedMsg = err
	if not ok then
		error(err, 2)
	end
end
try("wrapper.rethrow", function()
	return select(2, pcall(function()
		wrapper()
	end))
end)
log("wrapper.errType", capturedType)
local function wrapper2()
	local ok, err = pcall(function()
		return realWs:FindFirstChild()
	end)
	if not ok then
		error(tostring(err), 2)
	end
end
try("wrapper.rethrow.tostring", function()
	return select(2, pcall(function()
		wrapper2()
	end))
end)
local function wrapper3()
	error("plain string", 2)
end
try("wrapper.plainString", function()
	return select(2, pcall(function()
		wrapper3()
	end))
end)
try("index.realError", function()
	return select(2, pcall(function()
		return realWs.NotAThing
	end))
end)
local function wrapper4()
	local ok, err = pcall(function()
		return realWs.NotAThing
	end)
	if not ok then
		error(err, 2)
	end
end
try("wrapper.rethrow.indexErr", function()
	return select(2, pcall(function()
		wrapper4()
	end))
end)

print(table.concat(out, "\n"))
