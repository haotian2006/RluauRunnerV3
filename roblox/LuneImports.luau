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
			local source = compiled[data] or data
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
			assert(typeof(result) == "buffer" and buffer.len(result) <= 16 * 1024 * 1024, "model output exceeds 16 MiB")
			return buffer.tostring(result)
		end,
		deserializeModel = function(contents)
			contents = bytes(contents)
			assert(#contents <= 16 * 1024 * 1024, "model input exceeds 16 MiB")
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
