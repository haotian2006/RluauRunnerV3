local IP = ""
local POLL_RATE = 1000
local UPDATE_INTERVAL = 1 / 5
local DEFAULT_TIMEOUT = 15
local MAX_STR_HEIGHT = 20

local Https = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local ServerId = Https:GenerateGUID()
local Closed = false
local Processes = {}
local IDinputs = {}

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
		v.output ..= createText(string.format(`[%.3f] %s\n`, os.clock() - v.start, err), 3)
	end
end

local function sendMessageTo(process, err)
	local v = Processes[process]
	if v then
		v.output ..= createText(string.format(`[%.3f] %s\n`, os.clock() - v.start, err), 3)
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

local function respondToInteraction(interactionToken, responseContent, logs)
	local url = IP .. "/respond"
	local headers = {
		["Content-Type"] = "application/json",
	}

	if #responseContent > 1900 then
		responseContent = responseContent:sub(1, 1900 - 10) .. "... [truncated]"
	end

	if logs and logs ~= "" then
		logs = encode(logs)
	end

	local requestData = {
		Url = url,
		Method = "PATCH",
		Headers = headers,
		Body = Https:JSONEncode({ token = interactionToken, data = encode(responseContent), log = logs }),
	}

	task.spawn(function()
		local sus, msg = pcall(function()
			Https:RequestAsync(requestData)
		end)
		if not sus then
			warn(msg)
		end
	end)
end

local function runCode(code, data)
	local processID = game:GetService("HttpService"):GenerateGUID(false)
	local env = setmetatable({}, { __index = getfenv() })
	local lastOutput = ""
	local start = os.clock() + 3
	local thread = {}
	thread.output = ""
	thread.start = start
	local userid = data.userId
	local isCommand = data.isCommand

	IDinputs[userid] = {}
	env.TIMESTAMP = false
	env.io = {
		read = function()
			local info 
			while task.wait() and not info do --ik this is bad but i'm lazy and this works
				info = IDinputs[userid] and table.remove(IDinputs[userid], 1)
			end
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
			thread.output ..= noTimeStamp and text or createText(string.format(`[%.3f] %s\n`, time, text))
		end,
	}
	env.loadstring = function(...)
		local f, e = loadstring(...)
		if f then
			setfenv(f, env)
		end
		return f, e
	end
	env.table = if workspace:FindFirstChild("ExtendedTableLibrary")
		then require(workspace:FindFirstChild("ExtendedTableLibrary"))
		else table
	env.misc = if workspace:FindFirstChild("misc")
		then require(workspace:FindFirstChild("misc"):Clone())
		else table

	if env.misc then
		for i, v in env.misc do
			if type(v) == "function" then
				setfenv(v, env)
			end
		end
	end
	env.log = function(text, color, newLine)
		local time = os.clock() - start
		color = color or ""
		local noTimeStamp = (env :: any).TIMESTAMP == false
		thread.output ..= noTimeStamp and text .. "\n" or (string.format(
			`[%.3f] %s\n`,
			time,
			(colorsLower[color:lower()] or "") .. text .. (newLine and "\n" or "")
			))
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
		thread.output ..= noTimeStamp and text .. "\n" or createText(string.format(`[%.3f] %s\n`, time, text))
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
		thread.output ..= noTimeStamp and text .. "\n" or createText(string.format(`[%.3f] %s\n`, time, text), 2)
	end

	env.error = function(msg, context)
		local time = os.clock() - start
		local noTimeStamp = (env :: any).TIMESTAMP == false
		thread.output ..= noTimeStamp and msg .. "\n" or createText(string.format(`[%.3f] %s\n`, time, msg), 3)
		local running = coroutine.running()
		task.defer(coroutine.close, running)
		coroutine.yield()
	end

	local fx, err = loadstring(code, "RluauRunnerV3|PROCESS|" .. processID .. "|")
	if not fx then
		local warning = ''
		if isCommand and code:find('%-%-') then
			warning = 'Detected comments in command, try an application command instead or remove comments.\n'
		end
		respondToInteraction(data.token, warning..err:match(":(%d+: .+)"), "")
		return false
	end
	if isCommand and code:find('%-%-') then
		thread.output ..= '[2;33m[Warning] Detected comments in command this may cause issues, try an application command instead or remove comments.[0m\n'
	end
	respondToInteraction(data.token, "Running")
	task.wait(0.5)
	setfenv(fx, env)
	Processes[processID] = thread

	thread.start = os.clock()
	start = thread.start
	local sus, msg = true, nil
	thread.running = task.defer(function()
		sus, msg = pcall(fx)
	end)

	thread.timeOutThread = task.spawn(function()
		local waitTime = 0
		local TIMEOUT = (env :: any).TIMEOUT or DEFAULT_TIMEOUT
		while os.clock() - thread.start < TIMEOUT and sus do
			TIMEOUT = (env :: any).TIMEOUT or DEFAULT_TIMEOUT
			if lastOutput ~= thread.output then
				local truncated = truncateString(thread.output)
				lastOutput = thread.output
				respondToInteraction(data.token, truncated)
			end
			waitTime += task.wait(UPDATE_INTERVAL)
		end

		if not sus then
			if msg:find("Script timeout: exhausted allowed execution time") then
				thread.output ..= string.format(
					`[2;31m[%.3f] %s[0m`,
					os.clock() - start,
					"Script timeout: exhausted allowed execution time"
				)
			else
				thread.output ..= string.format(
					`[2;31m[%.3f] %s[0m`,
					os.clock() - start,
					"An error occurred: " .. msg:match(":(%d+: .+)")
				)
			end
		elseif (env :: any).TIMESTAMP ~= false then
			thread.output ..= string.format(
				`[2;36m[%.3f] %s[0m`,
				os.clock() - start,
				`Script Reached its lifespan ({TIMEOUT or 15}s)`
			)
		end

		local shouldLog = (env :: any).OUTPUT_LOGS or false

		local truncated = truncateString(thread.output)
		local log
		if shouldLog then
			local id, name = data.userId, data.username
			local link = getLinkFromData(data)
			log = {}
			local date = DateTime.now():ToUniversalTime()
			table.insert(log, "Logs For Compilation")
			table.insert(
				log,
				string.format(
					"Compiled at: %02d/%02d/%04d %02d:%02d:%02d",
					date.Month,
					date.Day,
					date.Year,
					date.Hour,
					date.Minute,
					date.Second
				)
			)
			table.insert(log, `User: {name} ({id})`)
			table.insert(log, `Run Time: {os.clock() - thread.start} Seconds`)
			table.insert(log, `Channel Link: {link}`)
			table.insert(log, "------------------------------")
			table.insert(log, thread.output)
			log = table.concat(log, "\n")
		end
		respondToInteraction(data.token, truncated, log or "")

		Processes[processID] = nil
		--// AFAIK theres no way to fully cleanup a thread (this included sub-threads). If this was in a live environment I could execute it from a script and destroy it later but
		--// for now we just have to keep the sub-threads running. Either way, this session only runs for a max of 5 mins.
		pcall(task.cancel, thread.timeOutThread)
		pcall(task.cancel, thread.running)
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

local function handleInputs()
	local res = Https:RequestAsync({
		Url = IP .. "/getInputs",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
		},
		Body = encoder({ ServerId = ServerId }),
	})
	if res.StatusCode ~= 200 then
		return
	end
	local decodedData: { { input: string, id: number } } = Https:JSONDecode(res.Body)
	for _, input in decodedData do
		if not IDinputs[input.id] then
			IDinputs[input.id] = {}
		end
		table.insert(IDinputs[input.id], input.input)
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
	task.spawn(handleInputs)

	local data = Https:JSONDecode(res.Body)

	for i, id in data do
		task.spawn(handleRequest, id)
		task.wait(0.1)
	end
end

ScriptContext.Error:Connect(function(err, stackTrace)
	local msg = err
	local process = stackTrace:match("RluauRunnerV3|PROCESS|([%w%-]+)|")
	if process then
		sendMessageTo(process, `Error: {msg}`)
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
	Https:PostAsync(IP .. "/start", encoder({ ServerId = ServerId }))
	task.wait(0.5)

	while not Closed do
		local sus, err = pcall(poll)
		if not sus then
			warn("Failed to poll:", err)
		end
		task.wait(POLL_RATE / 1000)
	end
	task.wait(1)
end

game:BindToClose(function(reason: Enum.CloseReason)
	task.wait(1)
	while next(Processes) do
		task.wait()
	end
end)

return {
	start = start,
}
