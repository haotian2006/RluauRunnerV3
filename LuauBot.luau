local IP = ""
local POLL_RATE = 1000 --ms
local DEFAULT_TIMEOUT = 25 -- seconds
local MAX_STR_HEIGHT = 25
local MAX_RESPONSES_BEFORE_TIMEOUT = 50
local FILE_CHUNK_SIZE = 50000
local MAX_FILE_SIZE = 2 * 1024 * 1024 -- 2 MB

--[[
	Takes in the number of responses sent so far and returns how often should the next update be sent.
]]
local function UPDATE_INTERVAL_SCALE(count)
	if count <= 10 then
		return 0.1
	elseif count <= 25 then
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
local ProcessesByUser = {}

local encoder = function(data)
	return Https:JSONEncode(data)
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

local function truncateArray(inputArray)
	if #inputArray > MAX_STR_HEIGHT then
		local startLine = #inputArray - MAX_STR_HEIGHT + 1
		local truncatedLines = {}
		for i = startLine, #inputArray do
			table.insert(truncatedLines, inputArray[i])
		end

		return truncatedLines
	else
		return inputArray
	end
end

local function truncateString(inputString)
	local lines = {}
	for line in inputString:gsub("\r", "\n"):gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end

	if #lines > MAX_STR_HEIGHT then
		local startLine = #lines - MAX_STR_HEIGHT + 1
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
	for key, value in t do
		local key_ = typeof(key) == "string" and `"{key}"` or tostring(key)
		result = result .. indentString .. "  [" .. tostring(key_) .. "] = "

		if type(value) == "table" then
			if lookup[value] then
				result ..= "<Circular Reference>"
				continue
			end

			result = result .. tableToString(value, indent + 1, lookup, bypass)
		else
			result = result .. "" .. tostring(value) .. ",\n"
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
local function sendFileInChunks(token, data)
	local numChunks = math.ceil(#data / FILE_CHUNK_SIZE)
	SendingChunks[token] = true
	task.spawn(function()
		for i = 1, numChunks do
			local chunk = data:sub((i - 1) * FILE_CHUNK_SIZE + 1, i * FILE_CHUNK_SIZE)
			local requestData = {
				Url = IP .. "/uploadChunk",
				Method = "PATCH",
				Headers = {
					["Content-Type"] = "application/json",
				},
				Body = Https:JSONEncode({
					token = token,
					chunk = chunk,
					index = i - 1,
				}),
			}
			attemptRequest(0.5, 5, Https.RequestAsync, Https, requestData)
			task.wait(0.1)
		end
		SendingChunks[token] = nil
	end)
	return numChunks
end

local FileIds = 1
local function respondToInteraction(interactionToken, responseContent, logs, await, fileType, finished, followUp)
	if finished then
		FinishedInteractions[interactionToken] = true
	end
	if SendingChunks[interactionToken] then
		repeat
			task.wait()
		until not SendingChunks[interactionToken]
		if not finished and FinishedInteractions[interactionToken] then
			return
		end
	end
	local url = IP .. "/respond"
	local headers = {
		["Content-Type"] = "application/json",
	}

	if #responseContent > 1900 then
		responseContent = responseContent:sub(1, 1900 - 10) .. "... [truncated]"
	end
	FileIds += 1
	local fileId = FileIds
	local sections = nil
	if logs and logs ~= "" then
		logs = encode(logs)
		if #logs > 10000 and #logs < MAX_FILE_SIZE then
			sections = sendFileInChunks(fileId, logs)
			logs = "[Log too large to send]"
		elseif #logs >= MAX_FILE_SIZE then
			logs = "[Log exceeded maximum size]"
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
	local a = function()
		local sus, msg
		if logs then
			sus, msg = attemptRequest(0.5, 5, Https.RequestAsync, Https, requestData)
		else
			sus, msg = pcall(Https.RequestAsync, Https, requestData)
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
local loadEnv
local smt = script:FindFirstChild("LoadEnv")
if smt then
	loadEnv = require(smt)
	smt:Destroy()
end

local function executeCode(id, code, env,thread)
	local m = Instance.new("ModuleScript")
	local imports = ""
	local updates = ""
	for k in env do
		imports ..= `{k} = imports.{k};`
		updates ..= `imports.{k} = {k};`
	end
	local fs = {}

	if code:find("--!native") then
		table.insert(fs, "--!native")
		env.native = true
	end
	env.optimize = code:match("%-%-!optimize%s*(%d+)") or 2
	table.insert(fs, `--!optimize {env.optimize}`)
	updates =
		`local _ = coroutine.running();task.spawn(function()local _=_ while coroutine.status(_) ~= 'dead' do {updates} task.wait();end;end);`

	local src =
		`{table.concat(fs, "\n")}\nreturn function(imports){imports}{updates}return function() local _=(function () --[[START OF CODE]] \n{code}\n--[[END OF CODE]]\nend)()\n\n\t\t\ntask.wait(1)\n\tend\nend`
	
	if #src < 200000 then
		m.Source = src
		m.Name = id
		local f = require(m)
		return f, m
	else
		table.insert(thread.output,colorsLower.yellow .. '[WARNING] Script to long for normal execution. Using loadstring!')
		return (loadstring::any)(src)(), m
	end
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

local function sendDebug(message)
	Https:PostAsync(IP .. "/debug", encoder({ message = message }), Enum.HttpContentType.ApplicationJson)
end

local function getContentFromChunks(chunks)
	local content = {}
	local recv = 0
	local failed = false
	for i = 1, #chunks do
		task.spawn(function()
			local pass, data = attemptRequest(
				0.5,
				4,
				HttpService.PostAsync,
				HttpService,
				IP .. "/chunk",
				encoder({ id = chunks[i] }),
				Enum.HttpContentType.ApplicationJson
			)

			
			if pass then
				local decoded = HttpService:JSONDecode(data)
				content[i] = decoded.chunk
				if not decoded.chunk then
					failed = "Chunk returned no data"
				end
	
			else
				failed = data or "Failed to retrieve chunk"
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
	local foundSignalUsage = false
	if code:find("connect") or code:find("Connect") or code:find("once") or code:find("Once") then
		foundSignalUsage = true
	end
	local processID = game:GetService("HttpService"):GenerateGUID(false)
	local env = {}
	local lastOutput = ""
	local start = os.clock() + 3
	local thread = {}
	local inputs = {}
	thread.env = env
	thread.output = {}
	thread.inputs = inputs
	local output = thread.output
	thread.start = start
	thread.blocked = false
	local userid = data.userId
	local isCommand = data.isCommand
	local runningThreads = {}

	local function wrapThread(fx)
		return function(...)
			local t = fx(...)
			table.insert(runningThreads, t)
			return t
		end
	end

	local function numRunning()
		local count = 0
		for i, v in runningThreads do
			if coroutine.status(v) ~= "dead" then
				count += 1
			end
		end
		return count
	end

	local function hasRunning()
		for i, v in runningThreads do
			if coroutine.status(v) ~= "dead" then
				return true
			end
		end
		return false
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
		create = wrapThread(coroutine.create),
		wrap = function(fx)
			fx = coroutine.wrap(fx)
			return wrapThread(fx)
		end,
	}, { __index = coroutine })
	env.TIMESTAMP = false
	env.OUTPUT_LOGS = false
	thread.followUp = false
	thread.fileType = ""
	thread.fileData = ""
	local parsedInputs = {}
	env.io = {
		read = function()
			local info
			while task.wait() and not info do --ik this is bad but i'm lazy and this works
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
		followupnext = function()
			thread.followUp = true
		end,
		writefile = function(data, fileType)
			thread.fileType = fileType
			thread.fileData = data
		end,
		readfile = function()
			return thread.fileData or "", thread.fileType or "txt"
		end,
		getoutput = function()
			return table.concat(output)
		end,
		clearoutput = function()
			table.clear(output)
		end,
	}
	env.loadstring = function(...)
		local f, e = loadstring(...)
		if f then
			local meta = setmetatable(env, { __index = getfenv() })
			setfenv(f, meta)
		end
		return f, e
	end

	env.colorstring = function(text, color)
		color = color or ""
		return (colorsLower[color:lower()] or "") .. tostring(text)
	end

	env.log = function(text, color, newLine)
		local time = os.clock() - start
		color = color or ""
		text = (colorsLower[color:lower()] or "") .. tostring(text)
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
			text ..= tostring(array[i]) .. " "
		end
		local noTimeStamp = (env :: any).TIMESTAMP == false
		table.insert(
			thread.output,
			noTimeStamp and createText(text, 2) .. "\n" or createText(string.format(`[%.3f] %s\n`, time, text), 2)
		)
	end

	env.TIMEOUT = DEFAULT_TIMEOUT

	local l_sus, l_err = pcall(function()
		if loadEnv then
			loadEnv(thread, env)
		end
	end)

	if not l_sus then
		table.insert(thread.output, createText(`Error loading environment: {l_err}`, 3) .. "\n")
	end
	-- env.error = function(msg, context)
	-- 	local time = os.clock() - start
	-- 	local noTimeStamp = (env :: any).TIMESTAMP == false
	-- 	table.insert(thread.output, noTimeStamp and createText(msg,3) .. "\n" or createText(string.format(`[%.3f] %s\n`, time, msg), 3))
	-- 	local running = coroutine.running()
	-- 	task.defer(coroutine.close, running)
	-- 	coroutine.yield()
	-- end
	local id = "RluauRunnerV3|PROCESS|" .. processID .. "|"
	local fx, err = loadstring(code, id)
	if not fx then
		local warning = ""
		if isCommand and code:find("%-%-") then
			warning = "Detected comments in command, try an application command instead or remove comments.\n"
		end
		respondToInteraction(data.token, warning .. err:match(":(%d+: .+)"), nil, nil, nil, true)
		return false
	end
	local module
	fx, module = executeCode(id, code, env,thread)
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

	thread.start = os.clock()
	start = thread.start
	local sus, msg = true, nil
	thread.running = task.defer(function()
		sus, msg = pcall(fx, env)
		if sus then
			sus, msg = pcall(msg)
		end
	end)
	thread.stopped = false
	thread.forceStop = function()
		env.warn("Force Stop Triggered!")
		thread.stopped = true
	end
	table.insert(runningThreads, thread.running)
	task.wait(0.5)
	local numOfResponses = 0
	thread.timeOutThread = task.spawn(function()
		local waitTime = 0
		local TIMEOUT = env.TIMEOUT
		local lastFlushFile = nil
		local lastFileType = nil
		while
			(
				(
					(os.clock() - thread.start < TIMEOUT or numOfResponses < MAX_RESPONSES_BEFORE_TIMEOUT)
					and sus
					and (numRunning() > 0 or foundSignalUsage)
				) or thread.blocked
			) and not thread.stopped
		do
			TIMEOUT = env.TIMEOUT
			local outStr = table.concat(truncateArray(thread.output))
			if outStr == "" then
				outStr = "  "
			end
			if lastOutput ~= outStr or (lastFlushFile ~= thread.fileData or lastFileType ~= thread.fileType) then
				local truncated = truncateString(outStr)
				lastOutput = outStr
				numOfResponses += 1
				local fileToSend = thread.fileData
				local fileTypeToSend = thread.fileType
				if fileToSend == lastFlushFile and lastFileType == fileTypeToSend then
					fileToSend = nil
					fileTypeToSend = nil
				end
				lastFlushFile = thread.fileData
				lastFileType = thread.fileType
				local followUp = thread.followUp
				thread.followUp = false
				respondToInteraction(data.token, truncated, fileToSend or "", nil, fileTypeToSend, nil, followUp)
			end
			waitTime += task.wait(UPDATE_INTERVAL_SCALE(numOfResponses))
		end

		local fileType
		local fileData = table.concat(thread.output)
		if thread.fileType ~= "" then
			(env :: any).OUTPUT_LOGS = "LOG"
			fileType = tostring(thread.fileType):lower()
			if thread.fileData ~= "" then
				fileData = tostring(thread.fileData)
			end
		end

		if thread.stopped then
			sus = false
			msg = "Script was forcefully stopped."
		end
		local shouldLog = (env :: any).OUTPUT_LOGS
		if not sus then
			local str = ((env :: any).TIMESTAMP ~= false) and string.format("[%.3f] ", os.clock() - start) or ""
			if msg:find("Script timeout: exhausted allowed execution time") then
				table.insert(thread.output, createText(str .. "Script timeout: exhausted allowed execution time", 3))
			else
				local msg = msg:match("RluauRunnerV3|PROCESS|[%w%-]+|:(.+)") or msg
				msg = msg:gsub("RluauRunnerV3|PROCESS|[%w%-]+|", "script")
				table.insert(thread.output, createText(str .. msg, 3))
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

		local truncated = truncateString(table.concat(truncateArray(thread.output)))
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
		respondToInteraction(
			data.token,
			truncated,
			log or "",
			nil,
			fileType,
			os.clock() - thread.start,
			thread.followUp
		)

		Processes[processID] = nil
		ProcessesByUser[userid][processID] = nil
		--// ![AFAIK] theres no way to fully cleanup a thread (this included sub-threads). If this was in a live environment I could execute it from a script and destroy it later but
		--// for now we just have to keep the sub-threads running. Either way, this session only runs for a max of 5 mins.
		--// 10/30/25, wrapped tasks and coroutine creations to be tracked and closed on script end.
		pcall(task.cancel, thread.timeOutThread)
		stopAll()
		module:Destroy()
	end)

	return true
end

local function handleRequest(uuid)
	local sus, data = pcall(function()
		return Https:PostAsync(IP .. "/get", encoder({ TaskId = uuid }), Enum.HttpContentType.ApplicationJson)
	end)
	if not sus then
		return
	end
	local decodedData = Https:JSONDecode(data)
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
local function handleInputs()
	local res = Https:RequestAsync({
		Url = IP .. "/getInputs",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
		},
		Body = encoder({ i = processedInputs }),
	})
	if res.StatusCode ~= 200 then
		return
	end
	local decodedData: { { content: string, id: number, uid: string } } = Https:JSONDecode(res.Body)
	for _, data in decodedData do
		task.spawn(function()
			local id = data.id
			table.insert(processedInputs, data.uid)
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
				input = "[ERROR WHILE DECODING INPUT]: " .. input ..' ' ..tableToString(content)
			end
			local isStop = input == "STOP_ALL_SESSIONS_PLS"
			if not isStop then
				for _, process in ProcessesByUser[id] or {} do
					table.insert(process.inputs, input)
				end
			else
				for _, process in ProcessesByUser[id] or {} do
					process.forceStop()
				end
			end
		end)
	end
end

local function poll()
	local res = Https:RequestAsync({
		Url = IP .. "/getAll",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
		},
		Body = encoder({ ServerId = ServerId }),
	})
	if res.StatusCode == 201 then
		Closed = true
		return
	end

	local data = Https:JSONDecode(res.Body)

	for i, id in data do
		task.spawn(handleRequest, id)
		task.wait(0.1)
	end
end

ScriptContext.Error:Connect(function(err, stackTrace)
	local msg = err:match("RluauRunnerV3|PROCESS|[%w%-]+|:(.+)") or err
	msg = msg:gsub("RluauRunnerV3|PROCESS|[%w%-]+|", "script")
	local process = stackTrace:match("RluauRunnerV3|PROCESS|([%w%-]+)|")
	if process then
		sendMessageTo(process, `{msg}`)
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
local function start(ip)
	if ready then
		error("Already started")
	end
	ready = true
	IP = ip or IP
	task.wait()
	local res = Https:PostAsync(IP .. "/start", encoder({ ServerId = ServerId }))
	task.spawn(function()
		local data = HttpService:JSONDecode(res)
		ServerNumber = data.id
	end)
	task.wait(0.5)

	task.spawn(function()
		while true do
			pcall(handleInputs)
			task.wait(POLL_RATE / 1000)
		end
	end)

	while not Closed do
		local sus, err = pcall(poll)
		if not sus then
			warn("Failed to poll:", err)
		end
		task.wait(POLL_RATE / 1000)
	end
	task.wait(1)
	while next(Processes) do
		task.wait()
	end
end

print(pcall(function()
	game:BindToClose(function(reason: Enum.CloseReason)
		sendMessageToAll("BindToClose Triggered! Session reached its 5 minute limit and will close soon!")
		task.wait(1)
		while next(Processes) do
			task.wait()
		end
	end)
end))

return {
	start = start,
}
