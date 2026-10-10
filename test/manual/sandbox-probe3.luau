local out = {}
local function log(k, v)
	table.insert(out, k .. ": " .. tostring(v))
end
local realWs = game:GetService("Workspace")

local localWrapper = function()
	error("from local", 2)
end
local holder = {
	w = function()
		error("from table", 2)
	end,
}
local p = newproxy(true)
getmetatable(p).__index = function(_, k)
	return function()
		error("from index-returned " .. k, 2)
	end
end
log("local", select(2, pcall(function()
	localWrapper()
end)))
log("table", select(2, pcall(function()
	holder.w()
end)))
log("indexReturned", select(2, pcall(function()
	p:Destroy()
end)))
log("indexReturned.direct", select(2, pcall(p.Destroy, p)))

local wm = Instance.new("WorldModel")
wm.Parent = realWs
local floor = Instance.new("Part")
floor.Anchored = true
floor.Size = Vector3.new(50, 1, 50)
floor.CFrame = CFrame.new(0, 0, 0)
floor.Parent = wm
local ball = Instance.new("Part")
ball.Anchored = false
ball.Size = Vector3.new(2, 2, 2)
ball.CFrame = CFrame.new(0, 20, 0)
ball.Parent = wm
local touched = false
ball.Touched:Connect(function()
	touched = true
end)
local y0 = ball.Position.Y
task.wait(3)
log("physics.fell", string.format("%.2f -> %.2f", y0, ball.Position.Y))
log("physics.touched", touched)
log("touchingParts", #ball:GetTouchingParts())
wm:Destroy()

local ref = Instance.new("Part", realWs)
ref.Anchored = false
ref.CFrame = CFrame.new(0, 50, 0)
local ry = ref.Position.Y
task.wait(2)
log("realWorkspace.physics.fell", string.format("%.2f -> %.2f", ry, ref.Position.Y))
ref:Destroy()

print(table.concat(out, "\n"))
