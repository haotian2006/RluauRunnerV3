-- Capability probe for the Sandbox design. Run as a normal bot run; read-only on the shared DataModel.
local out = {}
local function log(k, v)
	table.insert(out, k .. ": " .. tostring(v))
end
local function try(k, f)
	local ok, r = pcall(f)
	log(k, ok and r or ("ERR " .. tostring(r)))
end

local RS = game:GetService("ReflectionService")
try("reflect.GetClass(Part).Superclass", function()
	return RS:GetClass("Part").Superclass
end)
try("reflect.DataModel.Name", function()
	for _, p in RS:GetPropertiesOfClass("DataModel") do
		if p.Name == "Name" then
			return `{p.Type.ScriptType} write={p.Permits.Write ~= nil}`
		end
	end
	return "missing"
end)
try("reflect.ObjectValue.Value", function()
	for _, p in RS:GetPropertiesOfClass("ObjectValue") do
		if p.Name == "Value" then
			return `{p.Type.ScriptType} {p.Type.InstanceType}`
		end
	end
	return "missing"
end)
try("reflect.FindFirstChild params", function()
	for _, m in RS:GetMethodsOfClass("Instance") do
		if m.Name == "FindFirstChild" then
			local ps = {}
			for _, p in m.Parameters do
				table.insert(ps, `{p.Name}:{p.Type and p.Type.ScriptType}`)
			end
			return table.concat(ps, ",")
		end
	end
	return "missing"
end)
try("reflect.aliases", function()
	local s = {}
	for _, m in RS:GetMethodsOfClass("Instance") do
		s[m.Name] = true
	end
	return `clone={s.clone} findFirstChild={s.findFirstChild} isA={s.isA} remove={s.remove}`
end)
try("reflect.SerializationService methods", function()
	return typeof(RS:GetMethodsOfClass("SerializationService"))
end)

local p = newproxy(true)
local mt = getmetatable(p)
mt.__index = function(_, k)
	error("bad member " .. k, 2)
end
mt.__type = "Instance"
mt.__metatable = "The metatable is locked"
try("proxy.error.level2", function()
	return select(2, pcall(function()
		return p.Foo
	end))
end)
log("proxy.typeof", typeof(p))
log("proxy.getmetatable", getmetatable(p))
local wrapper = function()
	local ok, err = pcall(function()
		return workspace:FindFirstChild()
	end)
	if not ok then
		error(err, 2)
	end
end
try("wrapper.error.level2", function()
	return select(2, pcall(function()
		wrapper()
	end))
end)
try("debug.info source", function()
	return debug.info(1, "s")
end)

local wm = Instance.new("WorldModel")
local part = Instance.new("Part")
part.Anchored = true
part.Position = Vector3.new(0, 0, 0)
part.Parent = wm
try("worldmodel.raycast", function()
	local r = wm:Raycast(Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	return r and r.Instance == part
end)
local SS = game:GetService("SerializationService")
try("serialize.workspace", function()
	return typeof(SS:SerializeInstancesAsync({ workspace }))
end)
try("serialize.worldmodel", function()
	return typeof(SS:SerializeInstancesAsync({ wm }))
end)

for _, name in { "settings", "UserSettings", "PluginManager", "DebuggerManager", "stats" } do
	try("global." .. name, function()
		local f = ({
			settings = settings,
			UserSettings = UserSettings,
			PluginManager = PluginManager,
			DebuggerManager = DebuggerManager,
			stats = stats,
		})[name]
		local r = f()
		return `{typeof(r)} {r.ClassName} inGame={r:IsDescendantOf(game)}`
	end)
end

local children = {}
for _, c in game:GetChildren() do
	table.insert(children, c.ClassName)
end
table.sort(children)
log("game.children", #children .. " " .. table.concat(children, ","))
log("game.descendants", #game:GetDescendants())
local wsKids = {}
for _, c in workspace:GetChildren() do
	table.insert(wsKids, c.ClassName .. ":" .. c.Name)
end
log("workspace.children", table.concat(wsKids, ","))
try("workspace.SignalBehavior", function()
	return workspace.SignalBehavior
end)
try("bindable.immediate", function()
	local be = Instance.new("BindableEvent")
	local fired = false
	be.Event:Connect(function()
		fired = true
	end)
	be:Fire()
	local now = fired
	be:Destroy()
	return now
end)

local holder = Instance.new("Folder")
for i = 1, 200 do
	Instance.new("Part", holder).Name = "p" .. i
end
local weakK = setmetatable({}, { __mode = "k" })
for _, c in holder:GetChildren() do
	weakK[c] = true
end
for _ = 1, 30 do
	local junk = {}
	for i = 1, 2e5 do
		junk[i] = { i }
	end
	task.wait()
end
local n = 0
for _ in weakK do
	n += 1
end
log("gc.weakInstanceKeys.after", n .. "/200")
holder:Destroy()

local G = {
	Axes = Axes, BrickColor = BrickColor, CFrame = CFrame, CatalogSearchParams = CatalogSearchParams,
	Color3 = Color3, ColorSequence = ColorSequence, ColorSequenceKeypoint = ColorSequenceKeypoint,
	Content = Content, DateTime = DateTime, DebuggerManager = DebuggerManager, Delay = Delay,
	DockWidgetPluginGuiInfo = DockWidgetPluginGuiInfo, ElapsedTime = ElapsedTime, Enum = Enum,
	Faces = Faces, FloatCurveKey = FloatCurveKey, Font = Font, Instance = Instance,
	InstanceHandle = InstanceHandle, NumberRange = NumberRange, NumberSequence = NumberSequence,
	NumberSequenceKeypoint = NumberSequenceKeypoint, OverlapParams = OverlapParams,
	Path2DControlPoint = Path2DControlPoint, PathWaypoint = PathWaypoint,
	PhysicalProperties = PhysicalProperties, PluginManager = PluginManager, Random = Random,
	Ray = Ray, RaycastParams = RaycastParams, Rect = Rect, Region3 = Region3,
	Region3int16 = Region3int16, RotationCurveKey = RotationCurveKey, Secret = Secret,
	SecurityCapabilities = SecurityCapabilities, SharedTable = SharedTable, Stats = Stats,
	TweenInfo = TweenInfo, UDim = UDim, UDim2 = UDim2, User = User, UserSettings = UserSettings,
	ValueCurveKey = ValueCurveKey, Vector2 = Vector2, Vector2int16 = Vector2int16, Vector3 = Vector3,
	Vector3int16 = Vector3int16, Version = Version, Wait = Wait, collectgarbage = collectgarbage,
	debug = debug, delay = delay, elapsedTime = elapsedTime, game = game, plugin = plugin,
	script = script, settings = settings, shared = shared, spawn = spawn, stats = stats,
	task = task, tick = tick, time = time, utf8 = utf8, wait = wait, warn = warn,
	workspace = workspace, Game = Game, Workspace = Workspace, printidentity = printidentity,
	version = version, gcinfo = gcinfo,
}
local names = {
	"Axes", "BrickColor", "CFrame", "CatalogSearchParams", "Color3", "ColorSequence",
	"ColorSequenceKeypoint", "Content", "DateTime", "DebuggerManager", "Delay",
	"DockWidgetPluginGuiInfo", "ElapsedTime", "Enum", "Faces", "FloatCurveKey", "Font", "Instance",
	"InstanceHandle", "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "OverlapParams",
	"Path2DControlPoint", "PathWaypoint", "PhysicalProperties", "PluginManager", "Random", "Ray",
	"RaycastParams", "Rect", "Region3", "Region3int16", "RotationCurveKey", "Secret",
	"SecurityCapabilities", "SharedTable", "Stats", "TweenInfo", "UDim", "UDim2", "User",
	"UserSettings", "ValueCurveKey", "Vector2", "Vector2int16", "Vector3", "Vector3int16", "Version",
	"Wait", "collectgarbage", "debug", "delay", "elapsedTime", "game", "plugin", "script", "settings",
	"shared", "spawn", "stats", "task", "tick", "time", "utf8", "wait", "warn", "workspace", "Game",
	"Workspace", "printidentity", "version", "gcinfo",
}
local present = {}
for _, k in names do
	table.insert(present, k .. "=" .. typeof(G[k]))
end
log("globals", table.concat(present, " "))
log("script", `{typeof(script)} {script and script.ClassName} parent={script and script.Parent}`)

wm:Destroy()
print(table.concat(out, "\n"))
