local IP = ""
local SecretToken = ""
local POLL_RATE = 1000 --ms
local DEFAULT_TIMEOUT = 25 -- seconds
local EXECUTION_SETTLE_DELAY = 1 -- seconds
local MAX_STR_HEIGHT = 25
local MAX_STR_HEIGHT_WEB = 100
local MAX_RESPONSES_BEFORE_TIMEOUT = 50
local FILE_CHUNK_SIZE = 1024 * 90
local MAX_FILE_SIZE = 10 * 1024 * 1024
local MAX_WRITE_FILES = 8
local WEB_INLINE_FILE_SIZE = 1024 * 1024
local WEB_MAX_FRAMES_IN_FLIGHT = 2
local INPUT_WAIT_SECONDS = 20 -- the server holds /getInputs open this long
local STREAM_POLL_SECONDS = 10
-- Roblox caps HTTP at 500 requests/min per server.
local HTTP_RATE_PER_SECOND = 7
local HTTP_BURST = 60
local HTTP_RESERVED = 20

local function UPDATE_INTERVAL_SCALE(count, isweb)
	if count <= 10 then
		return 0.1
	end
	-- Discord rate limits edits.
	if isweb then
		return 0.1
	end
	if count <= 25 then
		return 0.25
	elseif count <= 35 then
		return 0.5
	end
	return 1
end

local ServerNumber = 0
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local Https = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local ServerId = Https:GenerateGUID()
local Closed = false
local Processes = {}
local ProcessHooks = {} -- not reachable from user code, unlike thread
local ProcessesByUser = {}
-- Headless Studio workers only: a game Script can't set Source, so a per-run broker makes the ModuleScripts.
local Capabilities = nil
local RunBrokers = setmetatable({}, { __mode = "k" })
local RunSnapshotTokens = setmetatable({}, { __mode = "k" })
-- In its own module so getfenv/setfenv don't turn off this script's import and fastcall optimizations.
local chunkEnvModule = script:FindFirstChild("ChunkEnv")
local isolateChunk = if chunkEnvModule then require(chunkEnvModule) else nil

local NativeLibrary = if type(native) == "table" then native else nil
local MB = 1024 * 1024
local Memory = nil
local MemoryLimits = {
	workerMb = 1024,
	runFloorMb = 128,
	processMb = nil, -- engine memory has no category
	stepSeconds = nil,
}
local CategoryRuns = {}
local CategoryFreedAt = {}

local function allowance(category)
	local others = 0
	for other, thread in CategoryRuns do
		if other ~= category and not thread.stopped then
			others += Memory.bytes(other)
		end
	end
	return math.max(MemoryLimits.runFloorMb, MemoryLimits.workerMb - others / MB) * MB
end

-- Freed memory stays charged until the next collection.
local function takeCategory(thread)
	if not Memory then
		return nil
	end
	local best, bestBytes, bestFreed
	for category = Memory.first, Memory.last do
		if not CategoryRuns[category] then
			local bytes, freed = Memory.bytes(category), CategoryFreedAt[category] or -math.huge
			if not best or bytes < bestBytes or (bytes == bestBytes and freed < bestFreed) then
				best, bestBytes, bestFreed = category, bytes, freed
			end
		end
	end
	if best then
		CategoryRuns[best] = thread
	end
	return best
end

local function releaseCategory(category)
	if category then
		CategoryRuns[category] = nil
		CategoryFreedAt[category] = os.clock()
		if Memory.release then
			Memory.release(category)
		end
	end
end

local function revokeRun(thread, reason)
	if not thread.stopped then
		thread.stopReason = reason
		thread.stopped = true
		if thread.memoryCategory and Memory.revoke then
			Memory.revoke(thread.memoryCategory)
		end
	end
end

local function trippedReason(why, held, limit)
	if why == "memory" then
		return `Memory limit exceeded: the run held {math.ceil(held / MB)} MB (limit {math.floor(limit / MB)} MB).`
	elseif why == "step" then
		return string.format(
			"CPU limit exceeded: the run kept the worker busy for %.1f s without a break (limit %.1f s).",
			held / 1000,
			limit / 1000
		)
	end
	return nil
end

local function watchMemory()
	local lastProcessRevoke = -math.huge
	local brakeStatus = nil
	while true do
		task.wait(0.25)
		if Memory.brake then
			-- also the tick the step guard counts from
			local status, why = Memory.brake()
			if status ~= brakeStatus and status ~= "checking" then
				brakeStatus = status
				task.spawn(pcall, sendDebug, `memory brake {status}{if status == "off" then ": " .. tostring(why) else ""}`)
			end
			for category, thread in CategoryRuns do
				if not thread.stopped then
					local reason = trippedReason(Memory.tripped(category))
					if reason then
						revokeRun(thread, reason)
					end
				end
			end
		end
		local held, total = {}, 0
		for category, thread in CategoryRuns do
			if not thread.stopped then
				local bytes = Memory.bytes(category)
				held[category] = bytes
				total += bytes
				thread.memoryPeak = math.max(thread.memoryPeak or 0, bytes)
			end
		end
		while total > MemoryLimits.workerMb * MB do
			local largest, most
			for category, bytes in held do
				if bytes > MemoryLimits.runFloorMb * MB and (not most or bytes > most) then
					largest, most = category, bytes
				end
			end
			if not largest then
				break
			end
			local others = total - most
			revokeRun(
				CategoryRuns[largest],
				`Memory limit exceeded: the run held {math.floor(most / MB)} MB (limit {math.floor(
					(MemoryLimits.workerMb * MB - others) / MB
				)} MB{if others > 0 then `, other runs held {math.floor(others / MB)} MB` else ""}).`
			)
			held[largest] = nil
			total = others
		end
		if Memory.limit then
			for category, bytes in held do
				Memory.limit(category, math.max(MemoryLimits.runFloorMb * MB, MemoryLimits.workerMb * MB - (total - bytes)))
			end
		end
		-- One at a time: a revoked run's memory takes a while to be collected.
		if MemoryLimits.processMb and os.clock() - lastProcessRevoke > 5 then
			local ok, usage = pcall(NativeLibrary.memory)
			if ok and type(usage) == "table" and (usage.commit or 0) > MemoryLimits.processMb * MB then
				local largest, most = nil, -1
				for category, thread in CategoryRuns do
					if not thread.stopped and held[category] > most then
						largest, most = thread, held[category]
					end
				end
				if largest then
					lastProcessRevoke = os.clock()
					revokeRun(largest, `Memory limit exceeded: the worker ran low and this run held the most ({math.floor(most / MB)} MB).`)
				end
			end
		end
	end
end

local function capability(broker, operation, ...)
	local result = table.pack(broker:Invoke(operation, ...))
	if not result[1] then
		error(result[2], 2)
	end
	return table.unpack(result, 2, result.n)
end

local encoder = function(data)
	return Https:JSONEncode(data)
end

local httpTokens = HTTP_BURST
local httpRefilledAt = os.clock()
local function takeHttpBudget(optional)
	local floor = if optional then HTTP_RESERVED else 0
	while true do
		local now = os.clock()
		httpTokens = math.min(HTTP_BURST, httpTokens + (now - httpRefilledAt) * HTTP_RATE_PER_SECOND)
		httpRefilledAt = now
		if httpTokens >= floor + 1 then
			httpTokens -= 1
			return
		end
		task.wait(0.05)
	end
end

local function request(options)
	takeHttpBudget(false)
	return Https:RequestAsync(options)
end

local function outputRequest(options)
	takeHttpBudget(true)
	return Https:RequestAsync(options)
end

local function makeHeaders()
	return {
		["Content-Type"] = "application/json",
		["x-secret-token"] = SecretToken,
	}
end

local ASSET_CACHE_BYTES = 16 * 1024 * 1024
local assetCache = {}
local assetCacheOrder = {}
local assetCacheSize = 0

local function cacheAsset(key, bytes)
	assetCache[key] = bytes
	table.insert(assetCacheOrder, key)
	assetCacheSize += #bytes
	while assetCacheSize > ASSET_CACHE_BYTES and #assetCacheOrder > 1 do
		local old = table.remove(assetCacheOrder, 1)
		assetCacheSize -= #assetCache[old]
		assetCache[old] = nil
	end
end

local function fetchAsset(id: string, size: number?): (boolean, string)
	local key = `{id}:{size or ""}`
	if assetCache[key] then
		return true, assetCache[key]
	end
	local url = `{IP}/asset/{id}?size={size or ""}`
	local headers = { ["x-secret-token"] = SecretToken }
	local ok, res = pcall(outputRequest, { Url = url, Method = "GET", Headers = headers })
	if not ok then
		return false, `asset lookup failed: {res}`
	end
	local decoded, body = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not decoded or type(body) ~= "table" then
		return false, `asset lookup failed: HTTP {res.StatusCode}`
	end
	if res.StatusCode ~= 200 or type(body.url) ~= "string" then
		return false, `asset {id} is unavailable ({body.state or body.message or res.StatusCode})`
	end
	local okCdn, cdn = pcall(outputRequest, { Url = body.url, Method = "GET" })
	if okCdn and cdn.StatusCode == 200 then
		cacheAsset(key, cdn.Body)
		return true, cdn.Body
	end
	local okRaw, raw = pcall(outputRequest, { Url = url .. "&raw=1", Method = "GET", Headers = headers })
	if okRaw and raw.StatusCode == 200 then
		cacheAsset(key, raw.Body)
		return true, raw.Body
	end
	return false, `asset {id} download failed`
end

local function fetchRepo(url: string): (boolean, string)
	local ok, res = pcall(outputRequest, {
		Url = `{IP}/github?url={HttpService:UrlEncode(url)}`,
		Method = "GET",
		Headers = { ["x-secret-token"] = SecretToken },
	})
	if not ok then
		return false, `request failed: {res}`
	end
	if res.StatusCode == 200 then
		return true, res.Body
	end
	local decoded, body = pcall(HttpService.JSONDecode, HttpService, res.Body)
	return false, if decoded and type(body) == "table" and body.message then body.message else `HTTP {res.StatusCode}`
end

local function sendDebug(message)
	request({
		Url = IP .. "/debug",
		Method = "POST",
		Headers = makeHeaders(),
		Body = encoder({ message = message }),
	})
end

local Colors = {
	Black = "[0;30m",
	Red = "[0;31m",
	Green = "[0;32m",
	Yellow = "[0;33m",
	Blue = "[0;34m",
	Purple = "[0;35m",
	Cyan = "[0;36m",
	White = "[0;37m",
}

local colorsLower = {}
for i, v in Colors do
	colorsLower[i:lower()] = v
end

local function createText(text, color)
	if color == 3 then
		return `[0;31m{text}[0m`
	elseif color == 2 then
		return `[0;33m{text}[0m`
	end
	return `[0;37m{text}[0m`
end

local function truncateArray(inputArray, maxHeight)
	maxHeight = maxHeight or MAX_STR_HEIGHT
	if #inputArray > maxHeight then
		local startLine = #inputArray - maxHeight + 1
		local truncatedLines = {}
		for i = startLine, #inputArray do
			table.insert(truncatedLines, inputArray[i])
		end

		return truncatedLines
	else
		return inputArray
	end
end

local function truncateString(inputString, maxHeight)
	maxHeight = maxHeight or MAX_STR_HEIGHT
	local lines = {}
	for line in inputString:gsub("\r", "\n"):gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end

	if #lines > maxHeight then
		local startLine = #lines - maxHeight + 1
		local truncatedLines = {}
		for i = startLine, #lines do
			table.insert(truncatedLines, lines[i])
		end

		return table.concat(truncatedLines, "\n")
	else
		return inputString
	end
end

local function sendMessageToAll(err)
	for i, v in Processes do
		local header = v.env.TIMESTAMP == false and "" or string.format(`[%.3f] `, os.clock() - v.start)
		table.insert(v.output, createText(`{header}{err}\n`, 3))
	end
end

local function sendMessageTo(process, err)
	local v = Processes[process]
	if v then
		local header = v.env.TIMESTAMP == false and "" or string.format(`[%.3f] `, os.clock() - v.start)
		table.insert(v.output, createText(`{header}{err}\n`, 3))
	end
end

local function tableToString(t, indent, lookup, bypass)
	if type(t) == "table" and not bypass then
		local str = tostring(t)
		if not string.find(str, "table:") then
			return tostring(t)
		end
	end

	lookup = lookup or {}
	indent = indent or 0
	local indentString = string.rep("  ", indent)
	local result = "{\n"
	lookup[t] = true
	local function inner(key, value)
		local key_ = typeof(key) == "string" and `"{key}"` or tostring(key)
		result = result .. indentString .. "  [" .. tostring(key_) .. "] = "

		if type(value) == "table" then
			if lookup[value] then
				result ..= "<Circular Reference>"
				return
			end

			result = result .. tableToString(value, indent + 1, lookup, bypass)
		else
			result = result .. "" .. tostring(value) .. ",\n"
		end
	end
	local array = {}
	for i = 1, rawlen(t) do
		array[i] = true
		inner(i, rawget(t, i))
	end
	for key, value in pairs(t) do
		if not array[key] then
			inner(key, value)
		end
	end

	result = result .. indentString .. "}\n"
	return result
end

local function getLinkFromData(data)
	local channel_id, msgID = data.channelId, data.targetId
	return msgID and `https://discord.com/channels/@me/{channel_id}/{msgID}` or ""
end

local function encode(data)
	return game:GetService("HttpService"):JSONEncode(buffer.fromstring(data))
end

local function attemptRequest(waitTime, maxAttempts, fx, ...)
	local attempt = 0
	local sus, res
	while attempt < maxAttempts do
		sus, res = pcall(fx, ...)
		if sus then
			return sus, res
		end
		attempt += 1
		task.wait(waitTime)
	end
	return sus, res
end

local SendingChunks = {}
local FinishedInteractions = {}
local WebTokens = {}
local function sendFileInChunks(interactionToken, fileId, data)
	local numChunks = math.ceil(#data / FILE_CHUNK_SIZE)
	SendingChunks[interactionToken] = true
	task.spawn(function()
		for i = 1, numChunks do
			local chunk = data:sub((i - 1) * FILE_CHUNK_SIZE + 1, i * FILE_CHUNK_SIZE)
			local requestData = {
				Url = IP .. "/uploadChunk",
				Method = "PATCH",
				Headers = makeHeaders(),
				Body = Https:JSONEncode({
					token = interactionToken,
					fileId = fileId,
					chunk = chunk,
					index = i - 1,
				}),
			}
			attemptRequest(0.5, 5, outputRequest, requestData)
			task.wait(0.1)
		end
		SendingChunks[interactionToken] = nil
	end)
	return numChunks
end

local FileIds = 1
local function respondToInteraction(interactionToken, responseContent, logs, await, fileType, finished, followUp)
	if finished then
		FinishedInteractions[interactionToken] = true
	end
	FileIds += 1
	if SendingChunks[interactionToken] then
		repeat
			task.wait()
		until not SendingChunks[interactionToken]
		if not finished and FinishedInteractions[interactionToken] then
			return
		end
	end
	local url = IP .. "/respond"
	local headers = makeHeaders()

	if not WebTokens[interactionToken] and #responseContent > 1900 then
		responseContent = responseContent:sub(1, 1900 - 10) .. "... [truncated]"
	end
	local fileId = FileIds
	local sections = nil
	if logs and logs ~= "" then
		logs = encode(logs)
		local inlineLimit = if WebTokens[interactionToken] then WEB_INLINE_FILE_SIZE else 10000
		if #logs > inlineLimit and #logs < MAX_FILE_SIZE then
			sections = sendFileInChunks(interactionToken, fileId, logs)
			logs = encode("[Log too large to send]")
		elseif #logs >= MAX_FILE_SIZE then
			logs = encode("[Log exceeded maximum size]")
		end
	end

	local requestData = {
		Url = url,
		Method = "PATCH",
		Headers = headers,
		Body = Https:JSONEncode({
			token = interactionToken,
			data = encode(responseContent),
			serverNum = ServerNumber,
			log = logs,
			fileId = fileId,
			fileType = fileType,
			sections = sections,
			runtime = type(finished) == "number" and finished or 0,
			finished = finished and true or false,
			followUp = followUp,
		}),
	}
	local send = if finished then request else outputRequest
	local a = function()
		local sus, msg
		if logs then
			sus, msg = attemptRequest(0.5, 5, send, requestData)
		else
			sus, msg = pcall(send, requestData)
		end
		if not sus then
			warn(msg)
		end
	end

	if await then
		a()
	else
		task.spawn(a)
	end
end
local CHUNK_ROOT_PATTERN = "RluauRunnerV3|PROCESS|[%w%-]+|"
local CHUNK_NAMED_PATTERN = "RluauRunnerV3|PROCESS|[%w%-]+|([%w%-_]+)|"
local function cleanChunkNames(text)
	-- A run compiled with loadstring (class code) reports as [string "<id>"].
	text = text:gsub('%[string "(' .. CHUNK_ROOT_PATTERN .. ')"%]', "%1")
	text = text:gsub(CHUNK_NAMED_PATTERN .. ":", "%1.")
	text = text:gsub(CHUNK_NAMED_PATTERN, "%1")
	text = text:match(CHUNK_ROOT_PATTERN .. ":(.+)") or text
	text = text:gsub(CHUNK_ROOT_PATTERN, "script")
	return text
end

local loadEnv
local smt = script:FindFirstChild("LoadEnv")
if smt then
	loadEnv = require(smt)
	smt:Destroy()
end

local GuardedEnvironments = setmetatable({}, { __mode = "k" })
local function executeCode(id, code, env, thread, delay, m, asFunction)
	local ownModule = m == nil
	m = m or Instance.new("ModuleScript")
	local environments = GuardedEnvironments[thread]
	if environments == nil then
		environments = {}
		GuardedEnvironments[thread] = environments
	end
	local guards = environments[env]
	if guards == nil and type(env.setfenv) == "function" then
		guards = table.freeze({ setfenv = env.setfenv, getfenv = env.getfenv, debug = env.debug })
		environments[env] = guards
	end
	local function guardFactory(factory)
		return function(imports, sync)
			return factory(imports, sync, guards)
		end
	end
	-- Unset, `native` falls through to luau_native's real table, whose hooks change Instances Studio-wide.
	if env.native == nil then
		env.native = false
	end
	local imports = ""
	local checks = ""
	local usesTypeof = code:find("typeof", 1, true) ~= nil
	local usesFenv = code:find("getfenv", 1, true) ~= nil
	for k in env do
		if k == "native" or (guards and (k == "setfenv" or k == "getfenv" or k == "debug")) then
			continue
		end
		if k == "typeof" and not usesTypeof then
			continue
		end
		if k == "getfenv" and not usesFenv then
			continue
		end
		imports ..= `{k} = imports.{k};`
		checks ..= `if _c.{k} ~= {k} then imports.{k} = {k}; end; {k} = imports.{k} _c.{k} = {k};`
	end
	local fs = {}

	if code:find("--!native") then
		table.insert(fs, "--!native")
		code = code:gsub("%-%-!native%s*\r?\n", "", 1)
		env.native = true
	end
	local optimize = code:match("%-%-!optimize%s*(%d+)")
	if optimize then
		optimize = math.clamp(tonumber(optimize) or 2, 0, 2)
		table.insert(fs, `--!optimize {optimize}`)
		code = code:gsub("%-%-!optimize%s*%d+%s*\r?\n", "", 1)
	end
	env.optimize = optimize or 2

	local updates = `local _c = {"{}"} __rluauSync(function() {checks} end, coroutine.running());`
	-- Locals cannot fall back to engine globals when user code deletes an import.
	local protected = "local native = imports.native == true;"
	if guards then
		protected ..= "local setfenv, getfenv, debug = __rluauGuards.setfenv, __rluauGuards.getfenv, __rluauGuards.debug;"
	end
	local header = #fs == 0 and "" or (table.concat(fs, "\n") .. "\n")
	local src = if asFunction
		then `{header}return function(imports, __rluauSync, __rluauGuards){imports}{protected}{updates}return function(...) --[[START OF CODE]] {code}\n--[[END OF CODE]]\nend\nend`
		else `{header}return function(imports, __rluauSync, __rluauGuards){imports}{protected}{updates}return function() return (function (...) --[[START OF CODE]] {code}\n--[[END OF CODE]]\nend)()\n\n\t\t\n\n\tend\nend`

	-- Classes are only allowed at a chunk's top level, and a ModuleScript's runs at require, so
	-- such code is a loadstring chunk (no native codegen) whose first line does the wrapper's setup.
	if isolateChunk and code:find("%f[%w_]class%s+[%a_]") then
		local _, wrapError = (loadstring :: any)(src)
		if wrapError and string.find(wrapError, "Cannot declare class", 1, true) then
			local chunk, compileError = (loadstring :: any)(
				`{header}local imports, __rluauSync, __rluauGuards = __rluauSetup();if __rluauSync then {imports}{updates}end;{protected}--[[START OF CODE]] {code}\n--[[END OF CODE]]`,
				id
			)
			if not chunk then
				error(cleanChunkNames(tostring(compileError)), 0)
			end
			local setup = {}
			isolateChunk(chunk, {
				__rluauSetup = function()
					-- Imports and syncs once per factory call, like a module's factory.
					local sync = setup.sync
					setup.sync = nil
					return setup.imports, sync, guards
				end,
			})
			return function(imports, sync)
				setup.imports, setup.sync = imports, sync
				return chunk
			end, m
		end
	end

	local pass, fx = pcall(function()
		m.Source = src
		m.Name = id
		local f = require(m)
		return f
	end)
	if pass then
		return guardFactory(fx), m
	end

	local broker = RunBrokers[thread]
	if broker then
		local created, result = pcall(function()
			local module = capability(broker, "createModule", src)
			module.Name = id
			return { require(module), module }
		end)
		if created then
			if ownModule then
				m:Destroy()
			end
			return guardFactory(result[1]), result[2]
		end
	end

	m:Destroy()
	table.insert(thread.output, colorsLower.yellow .. "[WARNING] Failed To initialize module. Using loadstring!\n")
	-- A chunk shares its caller's globals, so each run needs its own table.
	local chunk, compileError = (loadstring :: any)(src)
	if not chunk then
		-- The compile error itself, not ChunkEnv's complaint about a nil chunk, and without the
		-- generated wrapper as its chunk name.
		error((string.gsub(tostring(compileError), '^%[string ".-"%]:', "", 1)), 0)
	end
	if isolateChunk then
		isolateChunk(chunk)
	end
	return guardFactory(chunk()), m
end

local function decodeZstd(data)
	return pcall(function()
		return buffer.tostring(
			EncodingService:DecompressBuffer(
				EncodingService:Base64Decode(buffer.fromstring(data)),
				Enum.CompressionAlgorithm.Zstd,
				10
			)
		)
	end)
end

local function getContentFromChunks(chunks)
	local content = {}
	local recv = 0
	local failed = false
	for i = 1, #chunks do
		task.spawn(function()
			local pass, response = attemptRequest(0.5, 4, request, {
				Url = IP .. "/chunk",
				Method = "POST",
				Headers = makeHeaders(),
				Body = encoder({ id = chunks[i] }),
			})

			if pass then
				if type(response) ~= "table" then
					failed = "Invalid chunk response"
				elseif response.StatusCode ~= 200 then
					failed = `Chunk request failed: {response.StatusCode}`
				else
					local decodePass, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
					if not decodePass then
						failed = `Failed to decode chunk JSON: {decoded}`
					else
						content[i] = decoded.chunk
						if type(decoded.chunk) ~= "string" then
							failed = "Chunk returned invalid data"
						end
					end
				end
			else
				failed = response or "Failed to retrieve chunk"
			end
			recv += 1
		end)
	end
	while recv < #chunks and not failed do
		task.wait()
	end

	if failed then
		return false, failed
	end
	return true, table.concat(content)
end

local function normalizeQuotes(str)
	local out = {}

	for _, codepoint in utf8.codes(str) do
		if codepoint == 0x201C or codepoint == 0x201D then
			table.insert(out, '"')
		elseif codepoint == 0x2018 or codepoint == 0x2019 then
			table.insert(out, "'")
		else
			table.insert(out, utf8.char(codepoint))
		end
	end

	return table.concat(out)
end

local function hasHotComment(code, name)
	for line in code:gmatch("[^\r\n]*") do
		line = line:match("^%s*(.-)%s*$")
		if line ~= "" then
			if line:sub(1, 2) ~= "--" then
				return false
			end
			if line == "--!" .. name then
				return true
			end
		end
	end
	return false
end

local function runCode(compCode, data)
	local decodePass, code = decodeZstd(compCode)
	if not decodePass then
		respondToInteraction(
			data.token,
			`Error while decoding: {code} | {tableToString(compCode)}`,
			nil,
			nil,
			nil,
			true
		)
		return
	end
	if code:sub(1, 1) == "=" then
		code = `print({code:sub(2)})`
	end
	-- only a guess, for --!nosandbox runs; sandboxed runs ask the sandbox for live connections
	local foundSignalUsage = false
	if code:find("connect") or code:find("Connect") or code:find("once") or code:find("Once") then
		foundSignalUsage = true
	end
	local processID = game:GetService("HttpService"):GenerateGUID(false)
	local id = "RluauRunnerV3|PROCESS|" .. processID .. "|"
	local env = {}
	local hooks = {
		processId = processID,
		onCleanup = {},
		sandbox = not hasHotComment(code, "nosandbox"),
		module = Instance.new("ModuleScript"),
		source = code, -- what script.Source shows, not the generated wrapper
		fetchAsset = fetchAsset,
		fetchRepo = fetchRepo,
	}
	-- The bot's per-run storage token stays in these closures.
	if type(data.storageToken) == "string" then
		local storageToken = data.storageToken
		local function storageRequest(path, body)
			local ok, res = pcall(request, {
				Url = IP .. path,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["x-secret-token"] = SecretToken,
					["x-storage-token"] = storageToken,
				},
				Body = encoder(body or {}),
			})
			if not ok then
				return nil, `request failed: {res}`
			end
			local decoded, reply = pcall(HttpService.JSONDecode, HttpService, res.Body)
			if res.StatusCode ~= 200 then
				return nil, if decoded and type(reply) == "table" and reply.message then reply.message else `HTTP {res.StatusCode}`
			end
			return if decoded then reply else nil, if decoded then nil else "unreadable reply"
		end
		hooks.dataStore = {
			load = function()
				return storageRequest("/dataStore/load")
			end,
			save = function(changes)
				return storageRequest("/dataStore/save", { changes = changes })
			end,
			report = function(message)
				task.spawn(pcall, sendDebug, message)
			end,
		}
	end
	local syncs = {}
	local syncRunning = false
	local function registerSync(fn, th)
		table.insert(syncs, { fn, th })
		if syncRunning then
			return
		end
		syncRunning = true
		task.spawn(function()
			while #syncs > 0 do
				for i = #syncs, 1, -1 do
					local s = syncs[i]
					if coroutine.status(s[2]) == "dead" then
						table.remove(syncs, i)
					else
						s[1]()
					end
				end
				task.wait()
			end
			syncRunning = false
		end)
	end
	local lastOutput = ""
	local start = os.clock() + 3
	local thread = {}
	table.insert(hooks.onCleanup, function()
		GuardedEnvironments[thread] = nil
	end)
	local inputs = {}
	if Capabilities then
		local opened, broker, snapshotToken = pcall(Capabilities.Invoke, Capabilities, "open")
		if opened and broker then
			RunBrokers[thread] = broker
			RunSnapshotTokens[thread] = snapshotToken
			table.insert(hooks.onCleanup, function()
				RunBrokers[thread] = nil
				RunSnapshotTokens[thread] = nil
				pcall(Capabilities.Invoke, Capabilities, "close", broker)
			end)
		end
	end
	-- No raw Instance or broker token may reach sandboxed code.
	hooks.serializeModel = function(roots, sources)
		local broker = RunBrokers[thread]
		if broker then
			-- A Bindable drops Instance keys, so the broker gets { instance, source } pairs.
			local list = {}
			for instance, source in sources or {} do
				table.insert(list, { instance, source })
			end
			return capability(broker, "serializeSnapshot", roots, RunSnapshotTokens[thread], list)
		end
		for instance, source in sources or {} do
			instance.Source = source
		end
		return game:GetService("SerializationService"):SerializeInstancesAsync(roots)
	end
	hooks.readSource = function(instance)
		local broker = RunBrokers[thread]
		if broker then return capability(broker, "readSource", instance) end
		return instance.Source
	end
	hooks.deserializeModel = function(contents)
		assert(typeof(contents) == "buffer" and buffer.len(contents) <= 16 * 1024 * 1024, "model input exceeds 16 MiB")
		local broker = RunBrokers[thread]
		if broker then return capability(broker, "deserialize", contents) end
		local roots = game:GetService("SerializationService"):DeserializeInstancesAsync(contents)
		local count = 0
		for _, root in roots do
			local tree = root:GetDescendants()
			table.insert(tree, root)
			count += #tree
			for _, instance in tree do if instance:IsA("BaseScript") then instance.Enabled = false end end
		end
		if count > 10000 then for _, root in roots do root:Destroy() end; error("model exceeds 10000 instances") end
		return roots
	end
	thread.env = env
	thread.output = {}
	thread.inputs = inputs
	local output = thread.output
	thread.start = start
	thread.blocked = false
	local userid = data.userId
	local isCommand = data.isCommand

	local isweb = data.isWeb == true
	if isweb then
		WebTokens[data.token] = true
	end
	thread.isweb = isweb
	local maxHeight = isweb and MAX_STR_HEIGHT_WEB or MAX_STR_HEIGHT
	local runningThreads = {}
	-- Unstarted or self-yielded coroutines run only when resumed, so they don't keep the run alive.
	local parked = setmetatable({}, { __mode = "k" })

	local function wrapThread(fx)
		return function(f, ...)
			local t = fx(f, ...)
			-- a deferred coroutine.close stays "suspended" forever (Promise defers one per settled promise)
			if f ~= coroutine.close then
				table.insert(runningThreads, t)
			end
			return t
		end
	end

	local function numRunning()
		local count = 0
		for i, v in runningThreads do
			if coroutine.status(v) ~= "dead" and not parked[v] then
				count += 1
			end
		end
		return count
	end

	local function hasRunning()
		return numRunning() > 0
	end

	local function createParked(fx)
		if type(fx) ~= "function" then
			return coroutine.create(fx)
		end
		local co = coroutine.create(function(...)
			parked[coroutine.running()] = nil
			return fx(...)
		end)
		parked[co] = true
		table.insert(runningThreads, co)
		return co
	end

	local function stopAll()
		for i, v in runningThreads do
			pcall(coroutine.close, v)
			pcall(task.cancel, v)
		end
	end

	for block in code:gmatch("%-%-%[%[@(.-)%]%]") do
		table.insert(inputs, block)
	end

	for input in code:gmatch("%-%-@([^\n\r%[]+)") do
		table.insert(inputs, input)
	end

	ProcessesByUser[userid] = ProcessesByUser[userid] or {}
	ProcessesByUser[userid][processID] = thread
	env.user = table.freeze({
		Name = data.username,
		UserId = data.userId,
	})
	env.spawn = wrapThread(spawn)
	env.delay = wrapThread(delay)

	env.task = setmetatable({
		spawn = wrapThread(task.spawn),
		defer = wrapThread(task.defer),
		delay = wrapThread(task.delay),
	}, { __index = task })
	env.coroutine = setmetatable({
		create = createParked,
		yield = function(...)
			local co = coroutine.running()
			parked[co] = true
			local res = table.pack(coroutine.yield(...))
			parked[co] = nil
			return table.unpack(res, 1, res.n)
		end,
		wrap = function(fx)
			local co = createParked(fx)
			return function(...)
				local res = table.pack(coroutine.resume(co, ...))
				if not res[1] then
					error(res[2], 2)
				end
				return table.unpack(res, 2, res.n)
			end
		end,
	}, { __index = coroutine })
	env._G = {}
	env.setenvkey = function(key, value)
		env[key] = value
	end
	env.TIMESTAMP = false
	env.OUTPUT_LOGS = false
	thread.followUp = false
	thread.files = {}
	thread.filesByKey = {}
	thread.buttonCallbacks = {}
	local parsedInputs = {}
	env.io = {
		read = function()
			local info
			while task.wait() and not info do
				info = table.remove(inputs, 1)
			end
			table.insert(parsedInputs, info)
			return info
		end,
		write = function(...)
			local text = ""
			local array = { ... }
			local length = select("#", ...)
			local time = os.clock() - start
			for i = 1, length do
				local value = tostring(array[i])
				text ..= value
			end
			local noTimeStamp = (env :: any).TIMESTAMP == false
			table.insert(output, noTimeStamp and text or string.format(`[%.3f] %s\n`, time, text))
		end,
		-- Deprecated: use discord.followUpNext().
		followupnext = function()
			thread.followUp = true
		end,
		writefile = function(data, fileType)
			fileType = fileType or "output.txt"
			if type(data) == "buffer" then
				data = buffer.tostring(data)
			elseif type(data) ~= "string" then
				error("Data must be a string or buffer for writefile", 2)
			end
			local idx = thread.filesByKey[fileType]
			if idx and thread.files[idx] and thread.files[idx].fileType == fileType then
				thread.files[idx].data = data
			else
				if #thread.files >= MAX_WRITE_FILES then
					local firstKey = thread.files[1].fileType
					table.remove(thread.files, 1)
					thread.filesByKey[firstKey] = nil
					for k, v in thread.filesByKey do
						thread.filesByKey[k] = v - 1
					end
				end
				table.insert(thread.files, { data = data, fileType = fileType })
				thread.filesByKey[fileType] = #thread.files
			end
		end,
		readfile = function(fileType)
			if fileType then
				local idx = thread.filesByKey[fileType]
				if idx then
					local f = thread.files[idx]
					return f.data, f.fileType
				end
				return "", fileType
			end
			if #thread.files > 0 then
				return thread.files[1].data, thread.files[1].fileType
			end
			return "", "txt"
		end,
		getoutput = function()
			return table.concat(output)
		end,
		clearoutput = function()
			table.clear(output)
		end,
	}
	local loadCache = {}
	local loadModules = {}
	env.loadstring = function(src, chunkname)
		if type(src) ~= "string" then
			return loadstring(src, chunkname)
		end
		local chunk = id
		if chunkname ~= nil then
			local cleaned = tostring(chunkname):gsub("[^%w%-_]", "")
			if cleaned ~= "" then
				chunk ..= cleaned .. "|"
			end
		end
		local key = chunk .. "\0" .. src
		local cached = loadCache[key]
		if cached then
			return cached
		end
		local f, e = loadstring(src, chunk)
		if not f then
			return nil, cleanChunkNames(e)
		end
		local factory, m = executeCode(chunk, src, env, thread, 0, nil, true)
		table.insert(loadModules, m)
		f = factory(env, registerSync)
		loadCache[key] = f
		return f
	end
	table.insert(hooks.onCleanup, function()
		for _, m in loadModules do
			m:Destroy()
		end
	end)

	env.colorstring = function(text, color)
		color = color or ""
		return (colorsLower[color:lower()] or "") .. tostring(text) .. "\27[0m"
	end

	env.log = function(text, color, newLine)
		local time = os.clock() - start
		color = color or ""
		text = (colorsLower[color:lower()] or "") .. tostring(text) .. "\27[0m"
		local noTimeStamp = (env :: any).TIMESTAMP == false
		table.insert(
			thread.output,
			noTimeStamp and text .. "\n" or (string.format(`[%.3f] %s\n`, time, text .. (newLine and "\n" or "")))
		)
	end
	env.thread = thread
	env.println = function(str, line)
		str = tostring(str)
		if not line then
			table.insert(output, str .. "\n")
			return #output
		end

		output[line] = str .. "\n"
		return line
	end

	env.print = function(...)
		local text = ""
		local array = { ... }
		local length = select("#", ...)
		local time = os.clock() - start
		for i = 1, length do
			local value = type(array[i]) == "table" and tableToString(array[i]) or tostring(array[i])
			text ..= value .. " "
		end
		local noTimeStamp = (env :: any).TIMESTAMP == false
		table.insert(
			thread.output,
			noTimeStamp and text .. "\n" or createText(string.format(`[%.3f] %s\n`, time, text))
		)
	end

	env.warn = function(...)
		local text = ""
		local array = { ... }
		local length = select("#", ...)
		local time = os.clock() - start
		for i = 1, length do
			local value = type(array[i]) == "table" and tableToString(array[i]) or tostring(array[i])
			text ..= value .. " "
		end
		local noTimeStamp = (env :: any).TIMESTAMP == false
		table.insert(
			thread.output,
			noTimeStamp and createText(text, 2) .. "\n" or createText(string.format(`[%.3f] %s\n`, time, text), 2)
		)
	end

	local function requestButton(action, buttonId, changes)
		local body = {
			token = data.token,
			action = action,
			buttonId = buttonId,
			processId = processID,
		}
		for key, value in changes or {} do
			body[key] = value
		end

		local success, response = attemptRequest(0.25, 3, request, {
			Url = IP .. "/button",
			Method = "PATCH",
			Headers = makeHeaders(),
			Body = Https:JSONEncode(body),
		})
		if not success then
			error(`Failed to reach the Discord button endpoint: {response}`, 3)
		end
		if not response.Success then
			local message = `HTTP {response.StatusCode}`
			local decoded, result = pcall(Https.JSONDecode, Https, response.Body)
			if decoded and type(result) == "table" and type(result.message) == "string" then
				message = result.message
			end
			error(`Failed to update Discord button: {message}`, 3)
		end
	end

	local function option(options, upper, lower)
		local value = rawget(options, upper)
		if value == nil then
			value = rawget(options, lower)
		end
		return value
	end
	local function buttonChanges(options, creating)
		local changes = {}
		for _, names in { { "Label", "label" }, { "Style", "style" }, { "Disabled", "disabled" }, { "OwnerOnly", "ownerOnly" } } do
			local name, key = names[1], names[2]
			local value = option(options, name, key)
			if value ~= nil then
				if name == "Label" then
					if type(value) ~= "string" or not utf8.len(value) then
						error("Discord button Label must be a valid UTF-8 string", 3)
					end
				elseif name == "Style" then
					if type(value) ~= "string" or not utf8.len(value) then
						error("Discord button Style must be a valid UTF-8 string", 3)
					end
				elseif type(value) ~= "boolean" then
					error("Discord button flags must be booleans", 3)
				end
				changes[key] = value
			end
		end
		if creating then
			if changes.label == nil then error("Discord button Label is required", 3) end
			if changes.style == nil then changes.style = "Primary" end
		end
		return changes
	end

	local discord = {}
	discord.isWeb = isweb

	discord.button = function(options)
		if type(options) == "string" then
			options = { Label = options }
		elseif type(options) ~= "table" then
			error("discord.button expects a label or options table", 2)
		end

		local payload = buttonChanges(options, true)
		local buttonId = Https:GenerateGUID(false)
		local event = Instance.new("BindableEvent")
		event.Name = "DiscordButton_" .. buttonId
		thread.buttonCallbacks[buttonId] = event
		local created, createError = pcall(requestButton, "create", buttonId, payload)
		if not created then
			thread.buttonCallbacks[buttonId] = nil
			event:Destroy()
			error(createError, 2)
		end

		local destroyed = false
		local handle = {
			Clicked = event.Event,
			Event = event.Event,
		}
		function handle:Update(changes)
			if destroyed then
				error("Cannot update a destroyed Discord button", 2)
			end
			if type(changes) ~= "table" then
				error("DiscordButton:Update expects an options table", 2)
			end
			local update = buttonChanges(changes, false)
			requestButton("update", buttonId, update)
			return self
		end
		function handle:Destroy()
			if destroyed then
				return
			end
			requestButton("delete", buttonId)
			destroyed = true
			thread.buttonCallbacks[buttonId] = nil
			event:Destroy()
		end
		return table.freeze(handle)
	end
	discord.followUpNext = function()
		thread.followUp = true
	end

	env.discord = table.freeze(discord)
	env._execute = function(code, name)
		local chunk = id
		if name ~= nil then
			if type(name) ~= "string" then
				error("_execute: name must be a string", 2)
			end
			local cleaned = name:gsub("[^%w%-_]", "")
			if cleaned ~= "" then
				chunk ..= cleaned .. "|"
			end
		end
		local fx, err = loadstring(code, chunk)
		if not fx then
			return false, err
		end
		local m
		fx, m = executeCode(chunk, code, env, thread, 0)
		return function()
			fx = fx(env, registerSync)
			return fx()
		end, m
	end
	hooks.execute = function(name, source, moduleEnv)
		local chunk = id
		local cleaned = tostring(name):gsub("[^%w%-_]", "")
		if cleaned ~= "" then
			chunk ..= cleaned .. "|"
		end
		local fx, err = loadstring(source, chunk)
		if not fx then
			return false, err
		end
		local factory, m = executeCode(chunk, source, moduleEnv, thread, 0)
		table.insert(loadModules, m)
		return function()
			return factory(moduleEnv, registerSync)()
		end
	end

	env.TIMEOUT = DEFAULT_TIMEOUT

	local l_sus, l_err = pcall(function()
		if loadEnv then
			loadEnv(thread, env, hooks)
		end
	end)

	if not l_sus then
		table.insert(thread.output, createText(`Error loading environment: {l_err}`, 3) .. "\n")
	end
	if hooks.sandboxExpected and not hooks.sandboxApplied then
		local reason = if l_sus then "" else `: {cleanChunkNames(tostring(l_err))}`
		respondToInteraction(
			data.token,
			`The sandbox failed to load, so the code was not run{reason}`,
			nil,
			nil,
			nil,
			true
		)
		for _, fn in hooks.onCleanup do
			pcall(fn)
		end
		hooks.module:Destroy()
		return false
	end
	-- env.error = function(msg, context)
	-- 	local time = os.clock() - start
	-- 	local noTimeStamp = (env :: any).TIMESTAMP == false
	-- 	table.insert(thread.output, noTimeStamp and createText(msg,3) .. "\n" or createText(string.format(`[%.3f] %s\n`, time, msg), 3))
	-- 	local running = coroutine.running()
	-- 	task.defer(coroutine.close, running)
	-- 	coroutine.yield()
	-- end

	local fx, err = loadstring(code, id)

	if not fx then
		code = normalizeQuotes(code)
		fx, err = loadstring(code, id)
	end

	if not fx then
		local warning = ""
		if isCommand and code:find("%-%-") then
			warning = "Detected comments in command, try an application command instead or remove comments.\n"
		elseif isCommand and code:find("```") then
			warning =
				"Detected code block in command ['``lua {CODE} ``']. Remove code block or use an application command instead.\n"
		end
		respondToInteraction(data.token, warning .. err:match(":(%d+: .+)"), nil, nil, nil, true)
		for _, fn in hooks.onCleanup do
			pcall(fn)
		end
		hooks.module:Destroy()
		return false
	end
	local module
	fx, module = executeCode(id, code, env, thread, nil, hooks.module)
	thread.module = module

	if isCommand and code:find("%-%-") then
		table.insert(
			thread.output,
			"[2;33m[Warning] Detected comments in command this may cause issues, try an application command instead or remove comments.[0m\n"
		)
	end
	respondToInteraction(data.token, "Running", nil, true)
	task.wait(0.1)

	Processes[processID] = thread
	ProcessHooks[processID] = hooks

	thread.start = os.clock()
	start = thread.start
	local sus, msg = true, nil
	thread.running = task.defer(function()
		sus, msg = pcall(fx, env, registerSync)
		if sus then
			sus, msg = pcall(msg)
			task.wait(EXECUTION_SETTLE_DELAY)
		end
	end)
	thread.memoryCategory = takeCategory(thread)
	if thread.memoryCategory then
		Memory.assign(thread.running, thread.memoryCategory)
		if Memory.limit then
			Memory.limit(thread.memoryCategory, allowance(thread.memoryCategory))
		end
	end
	thread.stopped = false
	thread.forceStop = function()
		env.warn("Force Stop Triggered!")
		thread.stopped = true
	end
	table.insert(runningThreads, thread.running)
	task.wait(0.5)
	local numOfResponses = 0
	local lastSentFiles = {}
	local framesInFlight = 0
	local function hasNewFiles()
		for _, file in thread.files do
			if lastSentFiles[file.fileType] ~= file.data then
				return true
			end
		end
		return false
	end
	thread.timeOutThread = task.spawn(function()
		local waitTime = 0
		local TIMEOUT = env.TIMEOUT
		while
			(
				(
					(os.clock() - thread.start < TIMEOUT or numOfResponses < MAX_RESPONSES_BEFORE_TIMEOUT)
					and sus
					and (numRunning() > 0 or (if hooks.sandboxBusy then hooks.sandboxBusy() else foundSignalUsage))
				) or thread.blocked
			) and not thread.stopped
		do
			TIMEOUT = env.TIMEOUT
			local outputLength = #thread.output
			local outStr = table.concat(truncateArray(thread.output, maxHeight))
			if outStr == "" then
				outStr = "  "
			end
			if lastOutput ~= outStr or hasNewFiles() then
				local truncated = truncateString(outStr, maxHeight)
				lastOutput = outStr
				numOfResponses += 1
				local followUp = thread.followUp
				thread.followUp = false
				local sentAny = false
				local deferred = false
				for _, file in thread.files do
					if lastSentFiles[file.fileType] ~= file.data then
						local frame, fileType = file.data, file.fileType
						local followUpNow = not sentAny and followUp or false
						if not isweb then
							respondToInteraction(data.token, truncated, frame, true, fileType, nil, followUpNow)
						elseif framesInFlight < WEB_MAX_FRAMES_IN_FLIGHT then
							-- The server drops an older frame that lands after a newer one.
							framesInFlight += 1
							task.spawn(function()
								pcall(
									respondToInteraction,
									data.token,
									truncated,
									frame,
									true,
									fileType,
									nil,
									followUpNow
								)
								framesInFlight -= 1
							end)
						else
							deferred = true
							continue
						end
						lastSentFiles[fileType] = frame
						sentAny = true
					end
				end
				if not sentAny and not deferred then
					respondToInteraction(data.token, truncated, "", nil, nil, nil, followUp)
				end
			end
			local interval = UPDATE_INTERVAL_SCALE(numOfResponses, isweb)
			local waited = 0
			repeat
				waited += task.wait()
				if thread.inputArrived and (#thread.output ~= outputLength or hasNewFiles()) then
					thread.inputArrived = false
					break
				end
			until waited >= interval or thread.stopped
			waitTime += waited
		end

		if thread.stopped then
			sus = false
			msg = thread.stopReason or "Script was forcefully stopped."
		end
		local shouldLog = (env :: any).OUTPUT_LOGS
		if not sus then
			local str = ((env :: any).TIMESTAMP ~= false) and string.format("[%.3f] ", os.clock() - start) or ""
			local errorMessage = if type(msg) == "table" then tableToString(msg) else tostring(msg)
			if errorMessage:find("Script timeout: exhausted allowed execution time") then
				table.insert(thread.output, createText(str .. "Script timeout: exhausted allowed execution time", 3))
			else
				errorMessage = cleanChunkNames(errorMessage)
				table.insert(thread.output, createText(str .. errorMessage, 3))
				if hooks.onError then
					pcall(hooks.onError, errorMessage, "")
				end
			end
		elseif (env :: any).TIMESTAMP ~= false then
			table.insert(
				thread.output,
				string.format(`[2;36m[%.3f] %s[0m`, os.clock() - start, `Script Reached its lifespan ({TIMEOUT}s)`)
			)
		elseif shouldLog ~= "LOG" and hasRunning() and not thread.stopped then
			table.insert(thread.output, createText(`Script Reached its max lifespan ({TIMEOUT}s)\n`, 2))
			table.insert(thread.output, createText(`You can increase it by setting the "TIMEOUT" global`, 2))
		end

		local time = math.max(0, os.clock() - thread.start - EXECUTION_SETTLE_DELAY)
		pcall(task.cancel, thread.timeOutThread)
		stopAll()
		task.wait(0.5)
		local fileData = table.concat(thread.output)
		local truncated = truncateString(table.concat(truncateArray(thread.output, maxHeight)), maxHeight)
		local log
		if shouldLog == true then
			local id, name = data.userId, data.username
			local link = getLinkFromData(data)
			log = {}
			local date = DateTime.now():ToUniversalTime()
			table.insert(
				log,
				string.format(
					"Compiled at: %02d/%02d/%04d %02d:%02d:%02d\n",
					date.Month,
					date.Day,
					date.Year,
					date.Hour,
					date.Minute,
					date.Second
				)
			)
			table.insert(log, `User: {name} ({id})\n`)
			table.insert(log, `Run Time: {os.clock() - thread.start} Seconds\n`)
			table.insert(log, `Channel Link: {link}\n`)
			if #parsedInputs > 0 then
				for i, v in parsedInputs do
					parsedInputs[i] = v:sub(1, 20) .. (#v > 20 and "[TRUNCATED]" or "")
				end
				table.insert(log, "Inputs: " .. table.concat(parsedInputs, " | ") .. "\n")
			end
			if #inputs > 0 then
				for i, v in inputs do
					inputs[i] = v:sub(1, 20) .. (#v > 20 and "[TRUNCATED]" or "")
				end
				table.insert(log, "Inputs in Queue: " .. table.concat(inputs, " | ") .. "\n")
			end
			table.insert(log, "------------------------------\n")
			table.insert(log, fileData)
			log = table.concat(log)
		elseif shouldLog == "LOG" then
			log = fileData
		end
		if truncated == "" then
			truncated = "No Output"
		end
		for _, event in thread.buttonCallbacks do
			pcall(event.Destroy, event)
		end
		table.clear(thread.buttonCallbacks)

		for _, file in thread.files do
			if lastSentFiles[file.fileType] ~= file.data then
				respondToInteraction(data.token, truncated, file.data, true, file.fileType, nil, false)
				lastSentFiles[file.fileType] = file.data
			end
		end

		respondToInteraction(data.token, truncated, log or "", nil, log and "log.ansi", time, thread.followUp)

		Processes[processID] = nil
		ProcessHooks[processID] = nil
		ProcessesByUser[userid][processID] = nil
		WebTokens[data.token] = nil
		for _, fn in hooks.onCleanup do
			pcall(fn)
		end
		module:Destroy()
		local peak = thread.memoryPeak or 0
		if thread.memoryCategory then
			peak = math.max(peak, Memory.bytes(thread.memoryCategory))
		end
		releaseCategory(thread.memoryCategory)
		if thread.memoryCategory and (thread.stopReason or peak >= 64 * MB) then
			task.spawn(pcall, sendDebug, `run {processID}: memory peak {math.floor(peak / MB)} MB{if thread.stopReason then ", revoked" else ""}`)
		end
	end)

	return true
end

local function handleRequest(decodedData)
	local content = decodedData.content
	if type(content) == "table" then
		local pass, content_ = getContentFromChunks(content)
		if not pass then
			content = "Failed to retrieve all chunks: " .. content_
		else
			content = content_
		end
	end
	decodedData.content = content

	local runSus, runErr = pcall(runCode, decodedData.content, decodedData)
	if not runSus then
		respondToInteraction(decodedData.token, `Error while running code: {runErr}`, nil, nil, nil, true)
	end
end

local processedInputs = {}
local processedAt = {}
-- The bot drops an input 30 s after it was queued.
local PROCESSED_INPUT_SECONDS = 60
local function handleInputs()
	local now = os.clock()
	local kept = {}
	for _, uid in processedInputs do
		if now - processedAt[uid] < PROCESSED_INPUT_SECONDS then
			table.insert(kept, uid)
		else
			processedAt[uid] = nil
		end
	end
	processedInputs = kept
	local res = request({
		Url = IP .. "/getInputs",
		Method = "POST",
		Headers = makeHeaders(),
		Body = encoder({ i = processedInputs, wait = INPUT_WAIT_SECONDS }),
	})
	if res.StatusCode ~= 200 then
		return false
	end
	local decodedData: { { content: string, id: number, uid: string } } = Https:JSONDecode(res.Body)
	for _, data in decodedData do
		task.spawn(function()
			local id = data.id
			table.insert(processedInputs, data.uid)
			processedAt[data.uid] = os.clock()
			local content = data.content
			if type(content) == "table" then
				local pass, content_ = getContentFromChunks(content)
				if not pass then
					content = "Failed to retrieve all chunks: " .. content_
				else
					content = content_
				end
			end
			local sus, input = decodeZstd(content)
			if not sus then
				input = "[ERROR WHILE DECODING INPUT]: " .. input .. " " .. tableToString(content)
			end
			local isStop = input == "STOP_ALL_SESSIONS_PLS"
			if data.buttonId and data.targetProcessId then
				local process = Processes[data.targetProcessId]
				local callback = process and process.buttonCallbacks[data.buttonId]
				if callback then
					process.inputArrived = true
					callback:Fire(data.clickUserId, data.clickUsername)
				end
			elseif not isStop then
				for _, process in ProcessesByUser[id] or {} do
					process.inputArrived = true
					table.insert(process.inputs, input)
				end
			else
				for _, process in ProcessesByUser[id] or {} do
					-- A run that failed before it started has no forceStop.
					if process.forceStop then
						process.forceStop()
					end
				end
			end
		end)
	end
	return #decodedData > 0
end

local function poll()
	local res = request({
		Url = IP .. "/getNext",
		Method = "POST",
		Headers = makeHeaders(),
		Body = encoder({ ServerId = ServerId }),
	})
	if res.StatusCode == 201 then
		Closed = true
		return
	end
	if res.StatusCode == 204 then
		return false
	end

	local data = Https:JSONDecode(res.Body)
	task.spawn(handleRequest, data)
	return true
end

-- A fire with nobody waiting is kept for the next wait.
local function signal()
	local s = { pending = false, gen = 0 }
	local waiting
	local function resume()
		local thread = waiting
		waiting = nil
		task.spawn(thread)
	end
	function s.fire()
		if waiting then
			resume()
		else
			s.pending = true
		end
	end
	function s.wait(seconds)
		if s.pending then
			s.pending = false
			return
		end
		s.gen += 1
		local gen = s.gen
		waiting = coroutine.running()
		task.delay(seconds, function()
			if s.gen == gen and waiting then
				resume()
			end
		end)
		coroutine.yield()
	end
	return s
end

local taskWake = signal()
local streamOpen = false
local workerStream

-- The bot counts the open stream as this server's heartbeat, and its closing as the server dying.
local function openWorkerEvents()
	local ok, client = pcall(Https.CreateWebStreamClient, Https, Enum.WebStreamClientType.SSE, {
		Url = `{IP}/workerEvents?ServerId={HttpService:UrlEncode(ServerId)}`,
		Method = "GET",
		Headers = makeHeaders(),
	})
	if not ok then
		warn("workerEvents unavailable:", client)
		return
	end
	workerStream = client
	local lost = false
	local function onLost()
		if lost then
			return
		end
		lost = true
		streamOpen = false
		if workerStream == client then
			workerStream = nil
		end
		taskWake.fire()
		if not Closed then
			task.delay(5, openWorkerEvents)
		end
	end
	client.Opened:Connect(function(code)
		streamOpen = code == 200
	end)
	client.MessageReceived:Connect(function(message)
		local event = message:match("^event: (%w+)") or message:match("\nevent: (%w+)")
		if event == "task" then
			taskWake.fire()
		end
	end)
	client.Error:Connect(onLost)
	client.Closed:Connect(onLost)
end

local function notifyClosing(reason)
	pcall(request, {
		Url = IP .. "/retire",
		Method = "POST",
		Headers = makeHeaders(),
		Body = encoder({ ServerId = ServerId, Reason = tostring(reason) }),
	})
end

ScriptContext.Error:Connect(function(err, stackTrace)
	local msg = cleanChunkNames(err)
	local process = stackTrace:match("RluauRunnerV3|PROCESS|([%w%-]+)|")
	if process then
		sendMessageTo(process, `{msg}`)
		local h = ProcessHooks[process]
		if h and h.onError then
			pcall(h.onError, msg, cleanChunkNames(stackTrace))
		end
	end
end)

LogService.MessageOut:Connect(function(errmsg, type)
	if type == Enum.MessageType.MessageError then
		if errmsg:find("Script timeout:") then
			sendMessageToAll("Script timeout: One of the tasks exceeded the time limit")
		end
	end
end)
local ready = false
local function start(ip, secretToken, options)
	SecretToken = secretToken or ""
	if ready then
		error("Already started")
	end
	ready = true
	IP = ip or IP
	if options and type(options.httpRatePerSecond) == "number" and options.httpRatePerSecond > 0 then
		HTTP_RATE_PER_SECOND = options.httpRatePerSecond
	end
	if options and typeof(options.capabilities) == "Instance" and options.capabilities:IsA("BindableFunction") then
		Capabilities = options.capabilities
	end
	-- On a Studio worker the Sandbox needs luau_native to tell runs from the worker's own instances;
	-- without it every run that touches an Instance fails, so fail here and the worker restarts.
	if Capabilities and not NativeLibrary then
		error("luau_native is not loaded in this session's VM; the worker must restart")
	end
	-- The bootstrap opened a one-time claim; take it before any run exists.
	if options and type(options.memory) == "table" and NativeLibrary and NativeLibrary.claimMemoryAccounting then
		local claimed, controller = pcall(NativeLibrary.claimMemoryAccounting)
		if claimed then
			Memory = controller
			for _, key in { "workerMb", "runFloorMb", "processMb", "stepSeconds" } do
				local value = options.memory[key]
				if type(value) == "number" and value > 0 then
					MemoryLimits[key] = value
				end
			end
			if MemoryLimits.stepSeconds and Memory.stepLimit then
				Memory.stepLimit(MemoryLimits.stepSeconds)
			end
			-- The brake trusts its interrupt once it sees it called; each pass of this loop calls it.
			for _ = 1, 4096 do
			end
			task.spawn(watchMemory)
		else
			warn("memory accounting unavailable:", controller)
		end
	end
	task.wait()
	local res = request({
		Url = IP .. "/start",
		Method = "POST",
		Headers = makeHeaders(),
		Body = encoder({ ServerId = ServerId }),
	})
	res = res.Body
	task.spawn(function()
		local data = HttpService:JSONDecode(res)
		ServerNumber = data.id
	end)
	task.wait(0.5)
	if options and options.stream then
		openWorkerEvents()
		local opening = os.clock()
		while not streamOpen and os.clock() - opening < 2 do
			task.wait(0.05)
		end
	end

	task.spawn(function()
		while true do
			local started = os.clock()
			local ok, received = pcall(handleInputs)
			if not ok or (not received and os.clock() - started < 1) then
				task.wait(POLL_RATE / 1000)
			end
		end
	end)

	while not Closed do
		local sus, got = pcall(poll)
		if not sus then
			warn("Failed to poll:", got)
		end
		if Closed then
			break
		elseif streamOpen and not (sus and got) then
			taskWake.wait(STREAM_POLL_SECONDS)
		else
			task.wait(POLL_RATE / 1000)
		end
	end
	-- Studio caps open streams, and destroying the runner leaves this one open.
	local function ping()
		task.spawn(pcall, request, {
			Url = IP .. "/ping",
			Method = "POST",
			Headers = makeHeaders(),
			Body = encoder({ ServerId = ServerId }),
		})
	end
	ping()
	if workerStream then
		pcall(workerStream.Close, workerStream)
	end
	task.wait(1)
	local pinged = os.clock()
	while next(Processes) do
		if os.clock() - pinged >= 2 then
			pinged = os.clock()
			ping()
		end
		task.wait(0.1)
	end
end

print(pcall(function()
	game:BindToClose(function(reason: Enum.CloseReason)
		if reason ~= Enum.CloseReason.OutOfMemory then
			notifyClosing(reason)
		end
		sendMessageToAll(`Server closed | reason: {tostring(reason)}`)
		task.wait(1)
		while next(Processes) do
			task.wait()
		end
	end)
end))

return {
	start = start,
}
