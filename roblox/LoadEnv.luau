--Put this under LuauBot

local sandboxModule = script:FindFirstChild("Sandbox")
if sandboxModule then
	sandboxModule = sandboxModule:Clone()
end

local RECREATED = { Camera = true }

local changes = {}
local function resetName(inst)
	local old = inst.Name
	if inst == game then
		inst.Name = "Game"
	elseif not pcall(inst.ResetPropertyToDefault, inst, "Name") or inst.Name == "Instance" then
		inst.Name = inst.ClassName
	end
	if inst.Name ~= old then
		table.insert(changes, `{inst.ClassName}.Name`)
	end
end

local services = {}
for _, service in game:GetChildren() do
	services[service] = true
end
local okClasses, classes = pcall(game:GetService("ReflectionService").GetClasses, game:GetService("ReflectionService"))
if okClasses and classes then
	for _, class in classes do
		local ok, service = pcall(game.FindService, game, class.Name)
		if ok and service then
			services[service] = true
		end
	end
end

resetName(game)
for service in services do
	resetName(service)
end

for i, v in game:GetDescendants() do
	if v.Parent ~= nil and pcall(v.Destroy, v) and not RECREATED[v.ClassName] then
		table.insert(changes, v.ClassName)
	end
	if i % 100 == 0 then
		task.wait()
	end
end

local remaining = { [game] = true }
for _, v in game:GetDescendants() do
	remaining[v] = true
end
for service in services do
	remaining[service] = true
end
for v in remaining do
	pcall(function()
		for key in v:GetAttributes() do
			-- RBX_ attributes are engine-owned and re-added every boot
			if key:sub(1, 4) ~= "RBX_" then
				v:SetAttribute(key, nil)
				table.insert(changes, `{v.ClassName} attribute {key}`)
			end
		end
	end)
end

if #changes > 0 then
	warn(`[LoadEnv] reset {#changes} change(s): {table.concat(changes, ", ", 1, math.min(#changes, 20))}`)
	local ok, err = pcall(game:GetService("AssetService").SavePlaceAsync, game:GetService("AssetService"))
	if not ok then
		warn(`[LoadEnv] SavePlaceAsync failed: {err}`)
	end
end

local Sandbox = sandboxModule and require(sandboxModule)

return function(thread, env, hooks)
	-- you can add custom environment variables here
	-- these will be global variables thats loaded into the environment (imported as module globals)
	env.GLOBAL = {}

	if Sandbox and hooks then
		if hooks.sandbox ~= false then
			Sandbox.getWorld(env.user.UserId):newContext(hooks, env):apply(env)
		else
			Sandbox.disabled(env, env.user.UserId)
		end
	end
end
