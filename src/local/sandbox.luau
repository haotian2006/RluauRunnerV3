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
}

local jobPath = process.args[1]
if not jobPath then
	stdio.write('{"t":"fatal","v":"no job file given"}\n')
	process.exit(2)
end

local job: Job = serde.decode("json", fs.readFile(jobPath))

local MAX_LINES = job.maxLines or 2000
local MAX_LINE_BYTES = job.maxLineBytes or 4000

local lineCount = 0
local truncated = false

local function scrub(value: string): string
	return (string.gsub(value, "[\128-\255]", "?"))
end

local function write(kind: string, value: string)
	local ok, encoded = pcall(serde.encode, "json", { t = kind, v = value })
	if not ok then
		encoded = serde.encode("json", { t = kind, v = scrub(value) })
	end
	stdio.write(encoded .. "\n")
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

local function emit(kind: string, text: string)
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
	write(kind, text)
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

local compiled = luau.compile(job.source, {
	optimizationLevel = job.optimizationLevel or 1,
	debugLevel = 1,
})

local chunk = luau.load(compiled, {
	debugName = "script",
	environment = environment,
	injectGlobals = false,
	codegenEnabled = job.codegenEnabled or false,
})

local mainFinished = false
local heartbeatThread = task.spawn(function()
	while true do
		if mainFinished and not hasTrackedThreads() then
			return
		end
		task.wait(0.25)
		write("heartbeat", "")
	end
end)

local ok, err = pcall(chunk)
mainFinished = true
if not hasTrackedThreads() then
	pcall(task.cancel, heartbeatThread)
end
if not ok then
	emit("error", if type(err) == "table" then tableToString(err) else tostring(err))
end
