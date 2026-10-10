--!nosandbox
-- Probe: where must a WorldModel live for spatial queries to work?
local out = {}
local function test(label, parent)
	local wm = Instance.new("WorldModel")
	wm.Parent = parent
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = Vector3.new(10, 1, 10)
	part.CFrame = CFrame.new(0, 0, 0)
	part.Parent = wm
	task.wait()
	local r = wm:Raycast(Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	local box = #wm:GetPartBoundsInBox(CFrame.new(), Vector3.new(20, 20, 20))
	table.insert(out, `{label}: raycast={r ~= nil and r.Instance == part} box={box}`)
	wm:Destroy()
end
test("nil", nil)
test("Workspace", game:GetService("Workspace"))
test("ServerStorage", game:GetService("ServerStorage"))
test("ReplicatedStorage", game:GetService("ReplicatedStorage"))
local folder = Instance.new("Folder")
folder.Parent = game:GetService("ServerStorage")
test("Folder in ServerStorage", folder)
folder:Destroy()
local gui = Instance.new("ScreenGui")
local vpf = Instance.new("ViewportFrame", gui)
test("ViewportFrame (unparented gui)", vpf)
gui.Parent = game:GetService("StarterGui")
test("ViewportFrame in StarterGui", vpf)
gui:Destroy()
print(table.concat(out, "\n"))
print("end")
