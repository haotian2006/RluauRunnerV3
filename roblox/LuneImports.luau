-- Trusted per-execution factory. Only frozen, scoped modules reach sandbox require.
-- backend is native.lune (three pure-data C++ functions), never the full native table.
return function(backend, env, createFs, hooks)
	local HttpService = game:GetService("HttpService")
	local modules = {}
	local function bytes(value)
		if typeof(value) == "buffer" then return buffer.tostring(value) end
		assert(type(value) == "string", "expected a string or buffer")
		return value
	end
	if backend then
		local compile, regex, serde = backend.compile, backend.regex, backend.serde
		local compiled, compileOrder, compiledBytes = {}, {}, 0
		local sourceLoader = env.loadstring
		local function compiler(source, options, dump)
			options = options or {}
			assert(type(options) == "table", "compile options must be a table")
			for key in options do
				assert(key == "optimizationLevel" or key == "debugLevel" or key == "coverageLevel", "unsupported compile option: " .. tostring(key))
			end
			local ok, result = pcall(compile, source, options.optimizationLevel, options.debugLevel, options.coverageLevel, dump)
			if not ok then
				-- Disassembly, and compile on a Studio build without a validated compiler, use the
				-- bundled compiler, which predates classes; luau.load always has them.
				if type(source) == "string" and #source <= 1024 * 1024 and string.find(source, "%f[%w_]class%s+[%a_]") and loadstring(source) then
					error("this bytecode compiler doesn't support classes; luau.load takes the source directly", 0)
				end
				error(result, 0)
			end
			if not dump and not compiled[result] then
				while #compileOrder >= 64 or compiledBytes + #result + #source > 32 * 1024 * 1024 do
					local removed = table.remove(compileOrder, 1)
					compiledBytes -= #removed + #compiled[removed]
					compiled[removed] = nil
				end
				compiled[result] = source; table.insert(compileOrder, result); compiledBytes += #result + #source
			end
			return result
		end
		local function loadCompiled(data, options)
			options = options or {}
			assert(type(options) == "table", "load options must be a table")
			for key in options do assert(key == "debugName" or key == "environment", "unsupported load option") end
			local target = options.environment or env
			assert(type(target) == "table", "environment must be a table")
			assert(type(data) == "string", "expected source or same-job compiled bytecode")
			local source = compiled[data]
			if not source and #data > 0 then
				local version, typesVersion = string.byte(data, 1, 2)
				-- Studio uses version 100 followed by a binary types-version byte. Tabs/newlines
				-- at the start of source are valid, so don't reject whitespace version bytes alone.
				if version < 9 or (typesVersion and typesVersion < 9) then
					error("luau.load: this bytecode wasn't produced by luau.compile in this run (or was changed), "
						.. "and only unchanged bytecode from luau.compile can be loaded; pass source instead", 2)
				end
			end
			source = source or data
			-- Never send bytecode to Roblox's private loader; recompile this job's source in the sandbox.
			local fn, err = sourceLoader(source, options.debugName)
			if not fn then error(err, 2) end
			-- A class chunk sets itself up from __rluauSetup in its own env; keep that reachable,
			-- without the imports that would land in target.
			local setup = rawget(getfenv(fn), "__rluauSetup")
			if setup then
				target = setmetatable({
					__rluauSetup = function()
						local imports, _, guards = setup()
						return imports, nil, guards
					end,
				}, { __index = target, __newindex = target })
			end
			setfenv(fn, target)
			return fn
		end
		modules["@lune/luau"] = table.freeze({
			compile = function(source, options) return compiler(source, options, false) end,
			disassemble = function(source, options) return compiler(source, options, true) end,
			load = loadCompiled,
		})
		local function first(pattern, text) return regex(pattern, text, "first")[1] end
		local function captures(raw)
			if not raw then return nil end
			for _, value in raw do if type(value) == "table" and not table.isfrozen(value) then table.freeze(value) end end
			local value = newproxy(true)
			local mt = getmetatable(value)
			mt.__len = function() return raw.count end
			mt.__index = table.freeze({
				get = function(_, index)
					assert(type(index) == "number" and index >= 0 and index % 1 == 0, "capture index must be a nonnegative integer")
					return raw[index + 1]
				end,
				group = function(_, name) assert(type(name) == "string"); return raw[name] end,
			})
			mt.__metatable = "RegexCaptures"
			return value
		end
		modules["@lune/regex"] = table.freeze({new = function(pattern)
			regex(pattern, "", "validate")
			local function replace(text, replacement, all)
				assert(type(replacement) == "string", "replacement must be a string")
				assert(#replacement <= 4 * 1024 * 1024, "replacement exceeds 4 MiB")
				local matches = regex(pattern, text, all and "all" or "first")
				assert(#replacement * #matches <= 64 * 1024 * 1024, "replacement work limit exceeded")
				local parts, offset, size = {}, 1, 0
				local function append(value)
					size += #value
					assert(size <= 16 * 1024 * 1024, "replacement output exceeds 16 MiB")
					if #value > 0 then table.insert(parts, value) end
				end
				for _, match in matches do
					local whole = match[1]
					append(text:sub(offset, whole.start - 1))
					local cursor = 1
					while cursor <= #replacement do
						local dollar = replacement:find("$", cursor, true)
						if not dollar then append(replacement:sub(cursor)); break end
						append(replacement:sub(cursor, dollar - 1))
						if replacement:sub(dollar + 1, dollar + 1) == "$" then
							append("$"); cursor = dollar + 2
						else
							local tail = replacement:sub(dollar + 1)
							local key = tail:match("^{([%w_]+)}") or tail:match("^([%w_]+)")
							if key then
								local found = tonumber(key) and match[tonumber(key) + 1] or match[key]
								append(found and found.text or "")
								cursor = dollar + 1 + #key + (tail:sub(1, 1) == "{" and 2 or 0)
							else append("$"); cursor = dollar + 1 end
						end
					end
					offset = whole.finish + 1
				end
				append(text:sub(offset))
				return table.concat(parts)
			end
			return table.freeze({
				isMatch = function(_, text) return first(pattern, text) ~= nil end,
				find = function(_, text) local m = first(pattern, text); return m and table.freeze(m[1]) end,
				captures = function(_, text) return captures(first(pattern, text)) end,
				split = function(_, text)
					local out, offset = {}, 1
					for _, match in regex(pattern, text, "all") do
						table.insert(out, text:sub(offset, match[1].start - 1)); offset = match[1].finish + 1
					end
					table.insert(out, text:sub(offset)); return out
				end,
				replace = function(_, text, replacement) return replace(text, replacement, false) end,
				replaceAll = function(_, text, replacement) return replace(text, replacement, true) end,
			})
		end})
		modules["@lune/serde"] = table.freeze({
			encode = function(format, value, pretty)
				if pretty ~= nil then assert(type(pretty) == "boolean", "pretty must be a boolean") end
				return serde("encode", format, HttpService:JSONEncode(value), pretty)
			end,
			decode = function(format, value) return HttpService:JSONDecode(serde("decode", format, bytes(value))) end,
			compress = function(format, value, level) return serde("compress", format, bytes(value), level) end,
			decompress = function(format, value) return serde("decompress", format, bytes(value)) end,
			hash = function(algorithm, value) return serde("hash", algorithm, bytes(value)) end,
			hmac = function(algorithm, value, secret) return serde("hmac", algorithm, bytes(value), bytes(secret)) end,
		})
	end
	-- Pure metadata from the running engine; no Instance getters/setters or addresses.
	local reflection = game:GetService("ReflectionService")
	local function freezeDeep(value)
		if type(value) == "table" and not table.isfrozen(value) then
			for _, child in value do freezeDeep(child) end
			table.freeze(value)
		end
		return value
	end
	local db = {}
	function db:GetClassNames()
		local names = {}
		for _, class in reflection:GetClasses() do table.insert(names, class.Name) end
		table.sort(names); return names
	end
	function db:GetClass(name)
		local class = reflection:GetClass(name)
		if not class then return nil end
		local properties = {}
		for _, prop in reflection:GetPropertiesOfClass(name) do
			properties[prop.Name] = {Name = prop.Name, Datatype = prop.Type, Tags = prop.Tags}
		end
		return freezeDeep({Name = class.Name, Superclass = class.Superclass, Properties = properties})
	end
	table.freeze(db)
	local function contextOperation(name, ...)
		assert(hooks and hooks.luneRoblox and hooks.luneRoblox[name], "Roblox sandbox context is unavailable")
		return hooks.luneRoblox[name](...)
	end
	modules["@lune/roblox"] = table.freeze({
		getReflectionDatabase = function() return db end,
		Instance = table.freeze({new = function(...) return contextOperation("newInstance", ...) end}),
		serializeModel = function(instances, xml)
			assert(xml == nil or xml == false, "XML model export is not supported by the Studio engine adapter")
			local result = contextOperation("serializeModel", instances)
			assert(typeof(result) == "buffer" and buffer.len(result) <= 64 * 1024 * 1024, "model output exceeds 64 MiB")
			return buffer.tostring(result)
		end,
		deserializeModel = function(contents)
			contents = bytes(contents)
			assert(#contents <= 64 * 1024 * 1024, "model input exceeds 64 MiB")
			return contextOperation("deserializeModel", buffer.fromstring(contents))
		end,
		implementMethod = function(class, name, callback) return contextOperation("implementMethod", class, name, callback) end,
		implementProperty = function(class, name, getter, setter) return contextOperation("implementProperty", class, name, getter, setter) end,
	})
	if env.task then
		local tasks = {}
		for _, name in {"spawn", "defer", "delay", "wait", "cancel"} do
			tasks[name] = function(...) return env.task[name](...) end
		end
		modules["@lune/task"] = table.freeze(tasks)
	end
	do
		-- Through the run's own game (set once the sandbox applies), so its host checks and stream
		-- limits apply.
		local function http()
			assert(env.game, "net is unavailable before the run starts")
			return env.game:GetService("HttpService")
		end
		local MAX_QUEUED = 4 * 1024 * 1024
		local function request(config)
			if type(config) == "string" then config = {url = config} end
			assert(type(config) == "table" and type(config.url) == "string", "net.request expects a url or a config table")
			local url = config.url
			if config.query ~= nil then
				assert(type(config.query) == "table", "query must be a table")
				local parts = {}
				for k, v in config.query do
					table.insert(parts, http():UrlEncode(tostring(k)) .. "=" .. http():UrlEncode(tostring(v)))
				end
				if #parts > 0 then url ..= (if string.find(url, "?", 1, true) then "&" else "?") .. table.concat(parts, "&") end
			end
			local res = http():RequestAsync({
				Url = url,
				Method = config.method or "GET",
				Headers = config.headers,
				Body = if config.body ~= nil then bytes(config.body) else nil,
			})
			return {
				ok = res.Success, statusCode = res.StatusCode, statusMessage = res.StatusMessage,
				headers = res.Headers, body = res.Body,
			}
		end
		local function socket(url)
			assert(type(url) == "string", "net.socket expects a url")
			local client = http():CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {Url = url, Method = "GET"})
			local queue, queued, state, failure = {}, 0, "connecting", nil
			local ws = {closeCode = nil}
			client.Opened:Connect(function() if state == "connecting" then state = "open" end end)
			client.MessageReceived:Connect(function(message)
				queued += #message
				if queued > MAX_QUEUED then
					failure = "more than 4 MiB of unread messages"
					pcall(client.Close, client)
					return
				end
				table.insert(queue, message)
			end)
			client.Error:Connect(function(code, message)
				failure = failure or `{code} {message}`
				state = "closed"
			end)
			client.Closed:Connect(function()
				state = "closed"
				ws.closeCode = ws.closeCode or 1000
			end)
			local deadline = os.clock() + 15
			while state == "connecting" and os.clock() < deadline do env.task.wait() end
			if state ~= "open" then
				pcall(client.Close, client)
				error("net.socket: could not connect" .. (if failure then ": " .. failure else ""), 2)
			end
			function ws.send(message)
				assert(state == "open", "the socket is closed")
				client:Send(bytes(message))
			end
			function ws.next()
				while #queue == 0 and state == "open" do env.task.wait() end
				local message = table.remove(queue, 1)
				if message then queued -= #message end
				return message
			end
			function ws.close(code)
				ws.closeCode = if type(code) == "number" then code else 1000
				state = "closed"
				pcall(client.Close, client)
			end
			return ws
		end
		modules["@lune/net"] = table.freeze({
			request = request,
			socket = socket,
			serve = function() error("net.serve is not available on this worker", 2) end,
			jsonEncode = function(value, pretty)
				local serdeModule = modules["@lune/serde"]
				return if serdeModule then serdeModule.encode("json", value, pretty) else HttpService:JSONEncode(value)
			end,
			jsonDecode = function(text) return HttpService:JSONDecode(bytes(text)) end,
			urlEncode = function(text) return HttpService:UrlEncode(bytes(text)) end,
			urlDecode = function(text)
				return (string.gsub(string.gsub(bytes(text), "%+", " "), "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
			end,
		})
	end
	local loadFs = script and script:FindFirstChild("VirtualFs")
	-- A supplied factory is used by source-embedded worker bootstraps/tests.
	createFs = createFs or (loadFs and require(loadFs))
	if createFs then modules["@lune/fs"] = createFs() end
	local function import(name)
		assert(type(name) == "string" and name:sub(1, 6) == "@lune/", "expected an @lune/ library name")
		local module = modules[name]
		if not module then error("library " .. name .. " is unavailable on this worker", 2) end
		return module
	end
	return import
end
