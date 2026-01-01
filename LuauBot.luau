local IP = ""
local POLL_RATE = 1000 --ms
local DEFAULT_TIMEOUT = 25 -- seconds
local MAX_STR_HEIGHT = 25
local MAX_RESPONSES_BEFORE_TIMEOUT = 50
local MAX_FILE_CHUNK_SIZE = 25000

--[[
	Takes in the number of responses sent so far and returns how often should the next update be sent.
]]
local function UPDATE_INTERVAL_SCALE(count)
	if count <= 10 then
		return 0.1
	elseif count <= 25 then
		return 0.25
	elseif count <= 50 then
		return 0.5
	end
	return 1
end

local ServerNumber = 0
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

local function createEmbed(data, logs, image)
	local link = getLinkFromData(data)
	local msg = {
		content = `Running {link or ""}\n`,
		tts = false,
		embeds = {
			{
				id = 391161511,
				title = "Output",
				description = ("```ansi\n%s```"):format(logs),
				fields = {},
				image = image and {
					url = image,
				},
			},
		},
		components = {},
		actions = {},
	}

	return msg
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

local function sendFileInChunks(token, data)
	local numChunks = math.ceil(#data / MAX_FILE_CHUNK_SIZE)
	task.spawn(function()
		for i = 1, numChunks do
			local chunk = data:sub((i - 1) * MAX_FILE_CHUNK_SIZE + 1, i * MAX_FILE_CHUNK_SIZE)
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
	end)
	return numChunks
end

local function respondToInteraction(interactionToken, responseContent, logs, await)
	local url = IP .. "/respond"
	local headers = {
		["Content-Type"] = "application/json",
	}

	if #responseContent > 1900 then
		responseContent = responseContent:sub(1, 1900 - 10) .. "... [truncated]"
	end
	local sections = nil
	if logs and logs ~= "" then
		logs = encode(logs)
		if #logs > 1000 then
			sections = sendFileInChunks(interactionToken, logs)
			logs = "[Log too large to send]"
		else
			logs = encode(logs)
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
			sections = sections,
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

local function executeCode(id, code, env)
	local m = Instance.new("ModuleScript")
	local imports = ""
	local updates = ""
	for k in env do
		imports ..= `\t{k} = imports.{k}\n`
		updates ..= `\t\timports.{k} = {k}\n`
	end
	local fs = {}

	if code:find("--!native") then
		table.insert(fs, "--!native")
		env.native = true
	end
	env.optimize = code:match("%-%-!optimize%s*(%d+)") or 2
	table.insert(fs, `--!optimize {env.optimize}`)
	updates =
		`\t_ = coroutine.running()\n--Hi I see that you decided to log this file\n\ttask.spawn(function()\n\t\tlocal _=_ while coroutine.status(_) ~= 'dead' do\n{updates}\ntask.wait()\n\t\tend\n\tend)\n`

	m.Source =
		`{table.concat(fs, "\n")}\nreturn function(imports)\n{imports}\n{updates}\n\treturn function()\n_=(function ()\n--[[START OF CODE]]\n{code}\n--[[END OF CODE]]\nend)()\n\n\t\t\ntask.wait(1)\n\tend\nend`

	m.Name = id
	local f = require(m)
	--m.Parent = game
	return f, m
end
local function runCode(code, data)
	if code:sub(1, 1) == "=" then
		code = `print({code:sub(2)})`
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
	}
	env.loadstring = function(...)
		local f, e = loadstring(...)
		if f then
			setfenv(f, env)
		end
		return f, e
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
		respondToInteraction(data.token, warning .. err:match(":(%d+: .+)"), "")
		return false
	end
	local module
	fx, module = executeCode(id, code, env)
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
	table.insert(runningThreads, thread.running)
	task.wait(0.5)
	local numOfResponses = 0
	thread.timeOutThread = task.spawn(function()
		local waitTime = 0
		local TIMEOUT = env.TIMEOUT
		while
			(
				(os.clock() - thread.start < TIMEOUT or numOfResponses < MAX_RESPONSES_BEFORE_TIMEOUT)
				and sus
				and numRunning() > 1
			) or thread.blocked
		do
			TIMEOUT = env.TIMEOUT
			local outStr = table.concat(truncateArray(thread.output))
			if lastOutput ~= outStr then
				local truncated = truncateString(outStr)
				lastOutput = outStr
				numOfResponses += 1
				respondToInteraction(data.token, truncated)
			end
			waitTime += task.wait(UPDATE_INTERVAL_SCALE(numOfResponses))
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
		elseif shouldLog ~= "LOG" and hasRunning() then
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
				for i,v in parsedInputs do
					parsedInputs[i] = v:sub(1, 20) .. ( #v > 20 and "[TRUNCATED]" or "" )
				end
				table.insert(log, "Inputs: " .. table.concat(parsedInputs, " | ") .. "\n")
			end
			if #inputs > 0 then
				for i,v in inputs do
					inputs[i] = v:sub(1, 20) .. ( #v > 20 and "[TRUNCATED]" or "" )
				end
				table.insert(log, "Inputs in Queue: " .. table.concat(inputs, " | ") .. "\n")
			end
			table.insert(log, "------------------------------\n")
			table.insert(log, table.concat(thread.output))
			log = table.concat(log)
		elseif shouldLog == "LOG" then
			log = table.concat(thread.output)
		end
		if truncated == "" then
			truncated = "No Output"
		end
		respondToInteraction(data.token, truncated, log or "")

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

	runCode(decodedData.content, decodedData)
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
	local decodedData: { { input: string, id: number, uid: string } } = Https:JSONDecode(res.Body)
	for _, data in decodedData do
		local id = data.id
		local input = data.input
		table.insert(processedInputs, data.uid)
		for _, process in ProcessesByUser[id] or {} do
			table.insert(process.inputs, input)
		end
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
