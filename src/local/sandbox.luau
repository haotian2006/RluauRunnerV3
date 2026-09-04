--!nocheck

local datetime = require("@lune/datetime")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local regex = require("@lune/regex")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

type Job = {
	source: string,
	optimizationLevel: number?,
	codegenEnabled: boolean?,
	maxLines: number?,
	maxLineBytes: number?,
	isWeb: boolean?,
	processId: string?,
}

local jobPath = process.args[1]
if not jobPath then
	stdio.write('{"t":"fatal","v":"no job file given"}\n')
	process.exit(2)
end

local job: Job = serde.decode("json", fs.readFile(jobPath))

local MAX_LINES = job.maxLines or 2000
local MAX_LINE_BYTES = job.maxLineBytes or 4000
local MAX_FILE_BYTES = 10 * 1024 * 1024
local MAX_WRITE_FILES = 8

local lineCount = 0
local truncated = false

local outputLog: { string } = {}
local pendingWrite = ""

local function scrub(value: string): string
	return (string.gsub(value, "[\128-\255]", "?"))
end

local function writeEvent(event)
	local ok, encoded = pcall(serde.encode, "json", event)
	if not ok then
		encoded = serde.encode("json", { t = event.t, v = scrub(tostring(event.v)) })
	end
	stdio.write(encoded .. "\n")
end

local function write(kind: string, value: string)
	writeEvent({ t = kind, v = value })
end

local function encodeHex(value: string): string
	local encoded = table.create(#value)
	for index = 1, #value do
		encoded[index] = string.format("%02x", string.byte(value, index))
	end
	return table.concat(encoded)
end

local function decodeHex(value: string): string
	local decoded = buffer.create(math.floor(#value / 2))
	local offset = 0
	for index = 1, #value - 1, 2 do
		buffer.writeu8(decoded, offset, tonumber(string.sub(value, index, index + 1), 16) or 0)
		offset += 1
	end
	return buffer.tostring(decoded)
end

local function cutAtCharBoundary(text: string, limit: number): string
	local cut = limit
	while cut > 0 do
		local nextByte = string.byte(text, cut + 1)
		if not nextByte or nextByte < 0x80 or nextByte >= 0xC0 then
			break
		end
		cut -= 1
	end
	return string.sub(text, 1, cut)
end

local function emitLine(kind: string, text: string)
	if truncated then
		return
	end
	if lineCount >= MAX_LINES then
		truncated = true
		write("truncated", string.format("output stopped after %d lines", MAX_LINES))
		return
	end
	lineCount += 1
	if #text > MAX_LINE_BYTES then
		text = cutAtCharBoundary(text, MAX_LINE_BYTES) .. "... (line truncated)"
	end
	table.insert(outputLog, text .. "\n")
	write(kind, text)
end

-- io.write can leave a partial line buffered. Anything else reaching the host
-- has to push that out first, or output arrives in a different order than the
-- script produced it.
local function flushPendingWrite()
	if pendingWrite == "" then
		return
	end
	local trailing = pendingWrite
	pendingWrite = ""
	emitLine("out", trailing)
end

local function emit(kind: string, text: string)
	flushPendingWrite()
	emitLine(kind, text)
end

local MAX_TABLE_DEPTH = 20

local function tableToString(value: { [any]: any }, indent: number?, lookup: { [any]: boolean }?): string
	local rendered = tostring(value)
	if not string.find(rendered, "table:") then
		return rendered
	end

	indent = indent or 0
	if indent >= MAX_TABLE_DEPTH then
		return "{...},\n"
	end
	lookup = lookup or {}
	local indentString = string.rep("  ", indent)
	local result = "{\n"
	lookup[value] = true

	for key, nested in pairs(value) do
		local formattedKey = if type(key) == "string" then `"{key}"` else tostring(key)
		result ..= indentString .. "  [" .. formattedKey .. "] = "
		if type(nested) == "table" then
			if lookup[nested] then
				result ..= "<Circular Reference>,\n"
			else
				result ..= tableToString(nested, indent + 1, lookup)
			end
		else
			result ..= tostring(nested) .. ",\n"
		end
	end

	return result .. indentString .. "}\n"
end

local function join(formatTables: boolean, ...): string
	local parts = table.create(select("#", ...))
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		parts[index] = if formatTables and type(value) == "table" then tableToString(value) else tostring(value)
	end
	return table.concat(parts, "\t")
end

local function copyFrozen(source: any): any
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = value
	end
	return table.freeze(copy)
end

local trackedThreads: { [thread]: boolean } = {}
local sandboxTask = {}
for key, value in pairs(task) do
	sandboxTask[key] = value
end

local function trackThread(threadValue: thread): thread
	trackedThreads[threadValue] = true
	return threadValue
end

sandboxTask.spawn = function(...)
	return trackThread(task.spawn(...))
end
sandboxTask.defer = function(...)
	return trackThread(task.defer(...))
end
sandboxTask.delay = function(...)
	return trackThread(task.delay(...))
end
sandboxTask.cancel = function(threadValue: thread)
	trackedThreads[threadValue] = nil
	return task.cancel(threadValue)
end
sandboxTask = table.freeze(sandboxTask)

local function hasTrackedThreads(): boolean
	local active = false
	for threadValue in pairs(trackedThreads) do
		if coroutine.status(threadValue) == "dead" then
			trackedThreads[threadValue] = nil
		else
			active = true
		end
	end
	return active
end

local environment: { [string]: any } = {
	assert = assert,
	error = error,
	getmetatable = getmetatable,
	ipairs = ipairs,
	next = next,
	pairs = pairs,
	pcall = pcall,
	rawequal = rawequal,
	rawget = rawget,
	rawlen = rawlen,
	rawset = rawset,
	select = select,
	setmetatable = setmetatable,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	unpack = unpack,
	xpcall = xpcall,

	string = copyFrozen(string),
	table = copyFrozen(table),
	math = copyFrozen(math),
	coroutine = copyFrozen(coroutine),
	utf8 = copyFrozen(utf8),
	bit32 = copyFrozen(bit32),
	debug = copyFrozen(debug),

	-- setfenv can't reach outside the function/thread it's given (verified:
	-- setfenv(2, ...) errors "cannot change environment of given object"),
	-- so it can't climb back out to this trusted script's own environment.
	setfenv = setfenv,
	newproxy = newproxy,
	collectgarbage = collectgarbage,

	task = sandboxTask,

	os = table.freeze({
		clock = os.clock,
		date = os.date,
		difftime = os.difftime,
		time = os.time,
	}),

	_G = {},

	print = function(...)
		emit("out", join(true, ...))
	end,
	warn = function(...)
		emit("warn", join(false, ...))
	end,
}

local virtualFiles = {}
local virtualFileOrder = {}
local inputQueue = {}
local buttonDispatchers = {}
local protocolClosed = false
local protocolReading = false

local function decodeProtocolInput(input)
	if input.kind == "buffer" then
		return decodeHex(input.hex or "")
	end
	return tostring(input.value or "")
end

local function pumpProtocol()
	while protocolReading and not protocolClosed do
		task.wait()
	end
	if protocolClosed then
		return
	end
	protocolReading = true
	local readOk, line = pcall(stdio.readLine)
	protocolReading = false
	if not readOk or line == nil then
		protocolClosed = true
		return
	end
	if line == "" then
		return
	end
	local ok, message = pcall(serde.decode, "json", line)
	if ok and message.kind == "button" then
		local dispatch = buttonDispatchers[message.buttonId]
		if dispatch ~= nil then
			dispatch(tostring(message.userId or ""), tostring(message.username or ""))
		end
	elseif ok then
		if #inputQueue >= 32 then
			table.remove(inputQueue, 1)
		end
		table.insert(inputQueue, decodeProtocolInput(message))
	end
end

local function readDiscordInput()
	while #inputQueue == 0 do
		if protocolClosed then
			return nil
		end
		pumpProtocol()
		task.wait()
	end
	return table.remove(inputQueue, 1)
end

environment.io = table.freeze({
	read = readDiscordInput,

	write = function(...)
		local parts = table.create(select("#", ...))
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		pendingWrite ..= table.concat(parts)
		while true do
			local breakAt = string.find(pendingWrite, "\n", 1, true)
			if breakAt == nil then
				break
			end
			local line = string.sub(pendingWrite, 1, breakAt - 1)
			pendingWrite = string.sub(pendingWrite, breakAt + 1)
			emitLine("out", line)
		end
	end,
	getoutput = function()
		return table.concat(outputLog) .. pendingWrite
	end,
	clearoutput = function()
		table.clear(outputLog)
		pendingWrite = ""
		writeEvent({ t = "clear" })
	end,
	followupnext = function()
		writeEvent({ t = "followup" })
	end,
	writefile = function(data, fileType)
		fileType = fileType or "output.txt"
		if type(data) == "buffer" then
			data = buffer.tostring(data)
		elseif type(data) ~= "string" then
			error("Data must be a string or buffer for writefile", 2)
		end
		if #data > MAX_FILE_BYTES then
			error("File exceeds the 10 MB writefile limit", 2)
		end
		if virtualFiles[fileType] == nil then
			if #virtualFileOrder >= MAX_WRITE_FILES then
				local oldest = table.remove(virtualFileOrder, 1)
				virtualFiles[oldest] = nil
			end
			table.insert(virtualFileOrder, fileType)
		end
		virtualFiles[fileType] = data
		writeEvent({ t = "file", name = fileType, hex = encodeHex(data) })
	end,
	readfile = function(fileType)
		if fileType ~= nil then
			return virtualFiles[fileType] or "", fileType
		end
		local first = virtualFileOrder[1]
		if first ~= nil then
			return virtualFiles[first], first
		end
		return "", "txt"
	end,
})

for name, value in { typeof = typeof, buffer = buffer, vector = vector } do
	if value ~= nil then
		environment[name] = if type(value) == "table" then copyFrozen(value) else value
	end
end

environment._VERSION = _VERSION

environment.serde = copyFrozen(serde)
environment.regex = copyFrozen(regex)
environment.datetime = copyFrozen(datetime)

local ROBLOX_DATATYPES = {
	"Axes",
	"BrickColor",
	"CFrame",
	"Color3",
	"ColorSequence",
	"ColorSequenceKeypoint",
	"Enum",
	"Faces",
	"Font",
	"Instance",
	"NumberRange",
	"NumberSequence",
	"NumberSequenceKeypoint",
	"PhysicalProperties",
	"Ray",
	"Rect",
	"Region3",
	"Region3int16",
	"UDim",
	"UDim2",
	"Vector2",
	"Vector2int16",
	"Vector3",
	"Vector3int16",
}

for _, name in ROBLOX_DATATYPES do
	environment[name] = (roblox :: any)[name]
end

local dataModel = roblox.Instance.new("DataModel")
environment.game = dataModel
environment.workspace = dataModel:GetService("Workspace")

-- Explicit allowlist: do not expose getAuthCookie, host Studio paths, or any
-- capabilities added to @lune/roblox by a future Lune update by default.
local sandboxRoblox = {}
for _, name in ROBLOX_DATATYPES do
	sandboxRoblox[name] = (roblox :: any)[name]
end
for _, name in
	{
		"deserializePlace",
		"deserializeModel",
		"serializePlace",
		"serializeModel",
		"getReflectionDatabase",
		"implementProperty",
		"implementMethod",
	}
do
	sandboxRoblox[name] = (roblox :: any)[name]
end
sandboxRoblox = table.freeze(sandboxRoblox)

local sandboxStdio = table.freeze({
	write = function(value)
		emit("out", tostring(value))
	end,
	ewrite = function(value)
		emit("warn", tostring(value))
	end,
	format = function(...)
		return join(true, ...)
	end,
	readLine = readDiscordInput,
	-- One Discord input or attachment is the complete available input payload.
	readToEnd = readDiscordInput,
	color = stdio.color,
	style = stdio.style,
})

local buttonCount = 0
local processId = job.processId or "lune"

local function createButtonSignal(buttonId)
	local waitQueue = {}
	local connections = {}

	local function waitFor(queue)
		while #queue == 0 do
			if protocolClosed then
				return nil
			end
			pumpProtocol()
			task.wait()
		end
		local click = table.remove(queue, 1)
		return click.userId, click.username
	end

	local function connect(callback, once)
		if type(callback) ~= "function" then
			error("DiscordButton.Clicked:Connect expects a function", 3)
		end
		local queue = {}
		local connection = { Connected = true }
		local threadValue
		function connection:Disconnect()
			if not self.Connected then
				return
			end
			self.Connected = false
			connections[self] = nil
			if threadValue ~= coroutine.running() then
				pcall(sandboxTask.cancel, threadValue)
			end
		end
		connections[connection] = queue
		threadValue = sandboxTask.spawn(function()
			while connection.Connected do
				local userId, username = waitFor(queue)
				if userId == nil and protocolClosed then
					connection:Disconnect()
					return
				end
				if once then
					connection.Connected = false
					connections[connection] = nil
				end
				local ok, callbackError = pcall(callback, userId, username)
				if not ok then
					emit("error", tostring(callbackError))
				end
				if once then
					return
				end
			end
		end)
		return connection
	end

	local signal = {}
	function signal:Wait()
		return waitFor(waitQueue)
	end
	function signal:Connect(callback)
		return connect(callback, false)
	end
	function signal:Once(callback)
		return connect(callback, true)
	end

	local function fire(userId, username)
		local click = { userId = userId, username = username }
		if #waitQueue >= 32 then
			table.remove(waitQueue, 1)
		end
		table.insert(waitQueue, click)
		for _, queue in connections do
			if #queue >= 32 then
				table.remove(queue, 1)
			end
			table.insert(queue, click)
		end
	end

	local function destroy()
		buttonDispatchers[buttonId] = nil
		for connection in connections do
			connection:Disconnect()
		end
	end

	buttonDispatchers[buttonId] = fire
	return table.freeze(signal), destroy
end

local function option(options, upper, lower)
	local value = options[upper]
	if value == nil then
		value = options[lower]
	end
	return value
end

local function buttonChanges(options, creating)
	local changes = {}
	local label = option(options, "Label", "label")
	if creating or label ~= nil then
		if type(label) ~= "string" or #label < 1 or #label > 80 then
			error("Discord button label must contain 1-80 characters", 3)
		end
		changes.label = label
	end
	local style = option(options, "Style", "style")
	if creating and style == nil then
		style = "Primary"
	end
	if style ~= nil then
		local styles = {
			primary = "Primary",
			secondary = "Secondary",
			success = "Success",
			danger = "Danger",
		}
		local normalized = if type(style) == "string" then styles[string.lower(style)] else nil
		if normalized == nil then
			error("Discord button style must be Primary, Secondary, Success, or Danger", 3)
		end
		changes.style = normalized
	end
	for _, name in { "Disabled", "OwnerOnly" } do
		local lower = string.lower(string.sub(name, 1, 1)) .. string.sub(name, 2)
		local value = option(options, name, lower)
		if value ~= nil then
			if type(value) ~= "boolean" then
				error(`Discord button {name} must be a boolean`, 3)
			end
			changes[lower] = value
		end
	end
	return changes
end

local discord = { isWeb = job.isWeb == true }

discord.button = function(options)
	if discord.isWeb then
		error("discord.button is only available for runs started from Discord", 2)
	end
	if type(options) == "string" then
		options = { Label = options }
	elseif type(options) ~= "table" then
		error("discord.button expects a label or options table", 2)
	end
	if buttonCount >= 25 then
		error("A response can contain at most 25 buttons", 2)
	end
	buttonCount += 1
	local buttonId = `{processId}-{buttonCount}`
	local changes = buttonChanges(options, true)
	local clicked, destroySignal = createButtonSignal(buttonId)
	writeEvent({
		t = "button",
		action = "create",
		buttonId = buttonId,
		processId = processId,
		label = changes.label,
		style = changes.style,
		disabled = changes.disabled,
		ownerOnly = changes.ownerOnly,
	})

	local destroyed = false
	local handle = { Clicked = clicked, Event = clicked }
	function handle:Update(update)
		if destroyed then
			error("Cannot update a destroyed Discord button", 2)
		end
		if type(update) ~= "table" then
			error("DiscordButton:Update expects an options table", 2)
		end
		local updateChanges = buttonChanges(update, false)
		updateChanges.t = "button"
		updateChanges.action = "update"
		updateChanges.buttonId = buttonId
		updateChanges.processId = processId
		writeEvent(updateChanges)
		return self
	end
	function handle:Destroy()
		if destroyed then
			return
		end
		destroyed = true
		destroySignal()
		writeEvent({
			t = "button",
			action = "delete",
			buttonId = buttonId,
			processId = processId,
		})
	end
	return table.freeze(handle)
end

discord.followUpNext = function()
	writeEvent({ t = "followup" })
end

environment.discord = table.freeze(discord)

local requireModules = {
	["@lune/datetime"] = environment.datetime,
	["@lune/regex"] = environment.regex,
	["@lune/roblox"] = sandboxRoblox,
	["@lune/serde"] = environment.serde,
	["@lune/stdio"] = sandboxStdio,
	["@lune/task"] = sandboxTask,
}

local compileSandboxed

environment.require = function(name)
	if type(name) ~= "string" then
		error("require expects a module name string", 2)
	end
	local module = requireModules[name]
	if module == nil then
		if name == "@lune/fs" then
			error("module '@lune/fs' is not enabled in this sandbox; use the io global instead", 2)
		end
		error(`module '{name}' is not enabled in this sandbox`, 2)
	end
	return module
end

environment.getfenv = function(_target)
	return environment
end

environment.loadstring = function(source, chunkName)
	if type(source) ~= "string" then
		error("loadstring expects source code as a string", 2)
	end
	if chunkName ~= nil and type(chunkName) ~= "string" then
		error("loadstring expects the chunk name to be a string", 2)
	end
	return compileSandboxed(source, chunkName)
end

local importNames = {}
for name in environment do
	assert(string.match(name, "^[%a_][%w_]*$"), `unsafe environment key: {name}`)
	table.insert(importNames, name)
end
table.sort(importNames)

local importAssignments = {}
for _, name in importNames do
	table.insert(importAssignments, `imports.{name}`)
end

local prelude = `return function(imports) local {table.concat(importNames, ", ")} = {table.concat(
	importAssignments,
	", "
)}; return function() `

compileSandboxed = function(source, chunkName, codegenEnabled)
	local ok, compiledOrError = pcall(luau.compile, prelude .. source .. "\nend\nend", {
		optimizationLevel = job.optimizationLevel or 1,
		debugLevel = 1,
	})
	if not ok then
		return nil, tostring(compiledOrError)
	end

	local loaded, topLevelOrError = pcall(luau.load, compiledOrError, {
		debugName = chunkName or "loadstring",
		codegenEnabled = codegenEnabled or false,
	})
	if not loaded then
		return nil, tostring(topLevelOrError)
	end

	local wrapped, wrapperOrError = pcall(topLevelOrError)
	if not wrapped then
		return nil, tostring(wrapperOrError)
	end
	return wrapperOrError(environment)
end

table.freeze(environment)

local chunk, compileError = compileSandboxed(job.source, "script", job.codegenEnabled)
if chunk == nil then
	emit("error", compileError)
	process.exit(1)
end

local mainFinished = false
local heartbeatThread = task.delay(0, function()
	while true do
		if mainFinished and not hasTrackedThreads() then
			return
		end
		task.wait(0.25)
		write("heartbeat", "")
	end
end)

local ok, err = pcall(chunk)
-- io.write text with no trailing line break would otherwise never be sent.
flushPendingWrite()
mainFinished = true
if not hasTrackedThreads() then
	pcall(task.cancel, heartbeatThread)
end
if not ok then
	emit("error", if type(err) == "table" then tableToString(err) else tostring(err))
end
