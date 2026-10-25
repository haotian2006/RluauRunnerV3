local eTable = script:FindFirstChild("ExtendedTableLibrary")
if eTable then
	eTable = eTable:Clone()
end
local misc =  script:FindFirstChild("misc")
if misc then
	misc = misc:Clone()
end
local bench = script:FindFirstChild("Bench")
if bench then
	bench = bench:Clone()
end
local image = script:FindFirstChild("image")
if image then
	image = image:Clone()
end
-- luau_native's capped image functions (image/native.luau), on Studios that load the mod.
local nativeExports = if image and image:FindFirstChild("native") then require(image.native).exports else nil
local ask = script:FindFirstChild("Ask")
if ask then
	ask = require(ask)
end

local packetProfiler = script:FindFirstChild("PacketProfiler")
if packetProfiler then
	packetProfiler = packetProfiler:Clone()
end
local sandboxModule = script:FindFirstChild("Sandbox")
if sandboxModule then
	sandboxModule = sandboxModule:Clone()
end

-- Reset the place to a fresh server; a run may have saved a polluted place with SavePlaceAsync.
-- Engine-created on every boot; destroying them would make each boot look dirty.
local ENGINE_CREATED = {
	Camera = true,
	StarterPlayerScripts = true,
	StarterCharacterScripts = true,
	ChatWindowConfiguration = true,
	ChatInputBarConfiguration = true,
	ChannelTabsConfiguration = true,
	BubbleChatConfiguration = true,
	ScreenshotHud = true,
	StatsItem = true,
}

local changes = {}
local function resetName(inst)
	local name, class = inst.Name, inst.ClassName
	if inst == game then
		if name ~= "Game" then
			inst.Name = "Game"
			table.insert(changes, "DataModel.Name")
		end
		return
	end
	-- names a fresh server uses: "RunService", "Run Service", or "Instance" for a few services
	if class == "NetworkServer" or name == class or name == class:gsub("(%l)(%u)", "%1 %2") or name == "Instance" then
		return
	end
	if pcall(function()
		inst.Name = class
	end) then
		table.insert(changes, `{class}.Name`)
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
	-- non-archivable instances can't come from a saved place, so they're the engine's
	if v.Parent ~= nil and v.Archivable and not ENGINE_CREATED[v.ClassName] then
		local label = `{v:GetFullName()}({v.ClassName})`
		if pcall(v.Destroy, v) then
			table.insert(changes, label)
		end
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
end
-- Studio workers reopen their place each session, so there's nothing to save.
if #changes > 0 and not game:GetService("RunService"):IsStudio() then
	local ok, err = pcall(game:GetService("AssetService").SavePlaceAsync, game:GetService("AssetService"))
	if not ok then
		warn(`[LoadEnv] SavePlaceAsync failed: {err}`)
	end
end

-- required after the reset so the sandbox baseline is the clean DataModel
local bootReset = table.concat(changes, ", ")
local Sandbox = sandboxModule and require(sandboxModule)
-- Cloned like the libraries above: LuauBot destroys this module's children after requiring it,
-- and each run's importer needs LuneImports' VirtualFs child.
local luneImportsModule = script:FindFirstChild("LuneImports")
local createLuneImports = luneImportsModule and require(luneImportsModule:Clone())

return function(thread, env, hooks)
	if createLuneImports and hooks then
		hooks.luneRequire = createLuneImports(type(native) == "table" and native.lune or nil, env, nil, hooks)
	end
	-- filled once the sandbox context exists; lets libraries hand back sandboxed instances
	local sandboxBridge = {}
	-- Expected even when the bundle has no Sandbox (it's private), so LuauBot refuses the run.
	if hooks and hooks.sandbox ~= false then
		hooks.sandboxExpected = true
	end
	-- Custom environment variables go here; they become every run's globals (and module globals).
	env.GLOBAL = {}
	-- `native` (true under --!native, set by LuauBot) must always be set: unset, it falls through to
	-- luau_native's real `native` table, whose hookMethod/defineProperty change Instances Studio-wide.
	env.native = false
	env._native = nativeExports
	local aibot = ask.new(env._execute,env.print,env.io.read,env)
	local firstTime = true
	local userid = env.user.UserId
	local function save(sec,data,time)
		local success, result = pcall(function()	
			local mmms = game:GetService("MemoryStoreService")
			local hashMap = mmms:GetHashMap(sec)
			hashMap:SetAsync(userid,data,time)
			return true
		end)
	end
	local function _tryGetMem()
		if not env._G.AI_CONTEXT_TOKEN then
			local success, result = pcall(function()	
				local mmms = game:GetService("MemoryStoreService")
				local hashMap = mmms:GetHashMap("AI_CONTEXT")
				env._G.AI_CONTEXT_TOKEN = hashMap:GetAsync(userid)
			end)
		end
		aibot.contextToken = env._G.AI_CONTEXT_TOKEN or ""
	end
	env.ask = function(question,context)
		if firstTime then
			_tryGetMem()
		end
		firstTime = false
		if context == true then
			aibot:reset()
			env._G.AI_CONTEXT_TOKEN = nil
		elseif type(context) == "string" then
			aibot.contextToken = context
		end
		local start = #env.thread.output
		aibot:chat(question)
		
		local str = ""
		for i= start+1,#env.thread.output do
			str ..= '\n'..env.thread.output[i]
		end
		local _,ct = str:gsub("\r?\n", "")
		if ct > (env.thread.isweb and 100 or 28) then
			env.OUTPUT_LOGS = true
		end
		
		env._G.AI_CONTEXT_TOKEN = aibot.contextToken
		task.spawn(function()
			save("AI_CONTEXT",aibot.contextToken,60*60*24)
		end)
		return aibot.contextToken
	end
	env.matchcodeblock = function(content)
		local a,b = content:match("```(%w*)\n([%s%S]-)```") 
		if not (a or b) then
			return nil,content
		end
		return a,b
	end
	env.etable = if eTable then require(eTable:Clone()) else table
	env.misc = if misc
		then require(misc:Clone()) else nil
	if env.misc then
		local c = env.misc.calculate
		env.misc.calculate = function(...)
			return c(env.print,...)
		end
	end
	env.PacketSizeCounter = if packetProfiler then require(packetProfiler:Clone()) else nil
	env.Image = if image then require(image:Clone())(env.println,env.io,hooks and hooks.fetchAsset,sandboxBridge) else nil
	if hooks and env.Image then
		hooks.editableImages = env.Image._editable
	end
	-- Writes an Image as .png, a list of Images as .gif, or renders an Instance first.
	if env.Image and env.io then
		local Img, writefile = env.Image, env.io.writefile
		env.io.writeimage = function(value, name, options)
			if name ~= nil and type(name) ~= "string" then
				error("writeimage: arg 2 must be a file name string", 2)
			end
			if options ~= nil and type(options) ~= "table" then
				error("writeimage: arg 3 must be a table of options", 2)
			end
			local data, ext
			local editable = Img._editable and Img._editable.imageOf(value)
			if editable then
				data, ext = Img.toPng(editable), "png"
			elseif type(value) == "table" and value.imageBuffer then
				data, ext = Img.toPng(value), "png"
			elseif type(value) == "table" and type(value[1]) == "table" and value[1].imageBuffer then
				local delay = if options and options.Delay ~= nil then options.Delay else 0.1
				local delays = {}
				for i, frame in value do
					if type(frame) ~= "table" or not frame.imageBuffer then
						error(`writeimage: frame {i} is not an Image`, 2)
					end
					delays[i] = if type(delay) == "table" then delay[i] or 0.1 else delay
				end
				data, ext = Img.toGif(value, delays, { loop = options and options.Loop or 0 }), "gif"
			else
				local t = typeof(value)
				if t ~= "userdata" and t ~= "Instance" then
					error("writeimage: arg 1 must be an Image, a list of Images or an Instance", 2)
				end
				local ok, img = pcall(Img.fromInstance, value, options)
				if not ok then
					error("writeimage: " .. (string.gsub(tostring(img), "^fromInstance: ", "")), 2)
				end
				data, ext = Img.toPng(img), "png"
			end
			name = name or ("image." .. ext)
			if not string.find(name, "%.%w+$") then
				name ..= "." .. ext
			end
			writefile(data, name)
			return name
		end
	end
	if env.io then
		-- Builds a GitHub repo, folder or file (Rojo's rules), a release .rbxm, or a Wally package into an Instance.
		env.io.import = function(url)
			if type(url) ~= "string" then
				error("import: arg 1 must be a GitHub or Wally URL string", 2)
			end
			if not (hooks and hooks.fetchRepo) then
				error("import: imports aren't available here", 2)
			end
			local ok, bytes = hooks.fetchRepo(url)
			if not ok then
				error(`import: {bytes}`, 2)
			end
			-- SerializationService is out of reach on Studio workers; these go through the run's broker.
			-- The sandbox's own deserializeModel also adopts what it loads.
			local deserialize = if hooks.luneRoblox and hooks.luneRoblox.deserializeModel
				then hooks.luneRoblox.deserializeModel
				else hooks.deserializeModel
			if not deserialize then
				error("import: imports aren't available here", 2)
			end
			local loaded, roots = pcall(deserialize, buffer.fromstring(bytes))
			if not loaded or #roots ~= 1 then
				error("import: the built model couldn't be loaded", 2)
			end
			return roots[1]
		end
	end
	local benches = 0
	env.bench = if bench
		then function(data, printMode, iterations, waitPerIter)
			local module = require((bench :: any):Clone())
			benches += 1
			thread.blocked = true
			local running = true
			local tracker = {} :: any
			local line = env.println(`Benching: {0}/{0}`)
			task.spawn(function()
				while running do
					env.println(
						`Benching: {tracker.iterations}/{tracker.totalIterations} | FPS: {tracker.fps or 0}`,
						line
					)
					task.wait(0.1)
				end
			end)
			task.wait(1)
			local info, str = module.Run(data, printMode, iterations, waitPerIter, tracker)
			info.Native = env.native
			info.Optimize = env.optimize
			task.wait(0.1)
			env.println(`Done Benching`, line)
			running = false
			if str then
				table.insert(thread.output, `NATIVE: {env.native and "true" or "false"} | OPTIMIZE: {env.optimize}\n`)
				table.insert(thread.output, str .. "\n")
			end
			task.delay(1, function()
				benches -= 1
				if benches <= 0 then
					thread.blocked = false
				end
				
			end)
			local pass,err = pcall(function()
				local image = module.generateBenchmarkVisualization(info, env.Image)
				local img = env.Image.toPng(image)
				env.io.writefile(img, 'bench.png')
			end)
			if not pass then
				env.warn(err)
			end
			
			return info
		end
		else nil

	if Sandbox and hooks then
		if hooks.sandbox ~= false then
			local ctx = Sandbox.getWorld(env.user.UserId):newContext(hooks, env)
			sandboxBridge.resolve = function(v)
				return ctx:renderTarget(v)
			end
			sandboxBridge.adopt = function(inst)
				return ctx:adopt(inst)
			end
			ctx:apply(env)
		else
			Sandbox.disabled(env, env.user.UserId, hooks)
			env.BOOT_RESET = bootReset
		end
	end
end
