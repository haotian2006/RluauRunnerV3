--[=[
	Builds luauBot.b64 from roblox/ (laid out by bundle.project.json), or unpacks one back into
	files. Run from the repository root.

	  lune run scripts/bundle [build [out]]         build luauBot.b64 (or out)
	  lune run scripts/bundle unpack <b64> <dir>    write each ModuleScript to <dir>
	  lune run scripts/bundle list <b64>            print each ModuleScript's path and size

	LuauBot's servers load it: an rbxm of the ModuleScript tree, zstd compressed and base64
	encoded, which EncodingService decodes and decompresses for DeserializeInstancesAsync.

	"$private" paths are read from the private luau-bot-headless checkout (LUAU_BOT_PRIVATE_DIR,
	or ../luau-bot-headless or ../studio-mods), as src/privateFiles.js finds it; without it the
	build fails rather than ship a bot with no sandbox.
]=]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local ROOT = process.cwd
local PRIVATE = nil
for _, dir in { process.env.LUAU_BOT_PRIVATE_DIR, `{ROOT}/../luau-bot-headless`, `{ROOT}/../studio-mods` } do
	if dir and dir ~= "" and fs.isDir(`{dir}/sandbox`) then
		PRIVATE = dir
		break
	end
end
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(data: string): string
	local input = buffer.fromstring(data)
	local length = buffer.len(input)
	local output = buffer.create(math.ceil(length / 3) * 4)
	local alphabet = buffer.fromstring(ALPHABET)
	local out = 0
	for i = 0, length - 1, 3 do
		local a = buffer.readu8(input, i)
		local b = if i + 1 < length then buffer.readu8(input, i + 1) else 0
		local c = if i + 2 < length then buffer.readu8(input, i + 2) else 0
		local n = bit32.bor(bit32.lshift(a, 16), bit32.lshift(b, 8), c)
		buffer.writeu8(output, out, buffer.readu8(alphabet, bit32.extract(n, 18, 6)))
		buffer.writeu8(output, out + 1, buffer.readu8(alphabet, bit32.extract(n, 12, 6)))
		buffer.writeu8(output, out + 2, if i + 1 < length then buffer.readu8(alphabet, bit32.extract(n, 6, 6)) else 61)
		buffer.writeu8(output, out + 3, if i + 2 < length then buffer.readu8(alphabet, bit32.extract(n, 0, 6)) else 61)
		out += 4
	end
	return buffer.tostring(output)
end

local function base64Decode(text: string): string
	text = text:gsub("[^%w%+/]", "")
	local values = {}
	for i = 1, #ALPHABET do
		values[ALPHABET:byte(i)] = i - 1
	end
	local input = buffer.fromstring(text)
	local length = buffer.len(input)
	local output = buffer.create(length * 3 // 4)
	local out = 0
	for i = 0, length - 1, 4 do
		local count = math.min(4, length - i)
		local n = 0
		for j = 0, 3 do
			n = bit32.lshift(n, 6) + (if j < count then values[buffer.readu8(input, i + j)] else 0)
		end
		for j = 0, count - 2 do
			buffer.writeu8(output, out, bit32.extract(n, 16 - j * 8, 8))
			out += 1
		end
	end
	return buffer.readstring(output, 0, out)
end

-- Lune's zstd frames omit the content size, which DecompressBuffer rejects. Descriptor 0x80
-- adds a 4-byte size after the window byte (RFC 8878 3.1.1.1); blocks unchanged.
local function withContentSize(frame: string, size: number): string
	assert(frame:byte(5) == 0, "unexpected zstd frame header")
	return frame:sub(1, 4) .. string.char(0x80) .. frame:sub(6, 6) .. string.pack("<I4", size) .. frame:sub(7)
end

local function readBundle(path: string)
	local model = serde.decompress("zstd", base64Decode(fs.readFile(path)))
	return roblox.deserializeModel(model)
end

-- Every ModuleScript under the roots, as "LuauBot/LoadEnv/Sandbox" paths, parents first.
local function walk(roots, visit)
	local function go(instance, path)
		visit(instance, path)
		for _, child in instance:GetChildren() do
			go(child, path .. "/" .. child.Name)
		end
	end
	for _, root in roots do
		go(root, root.Name)
	end
end

-- One project node: "$path" is a .luau file or a folder with init.luau (whose other .luau files
-- and subfolders become children), "$private" a file in the private checkout; every other key
-- is a child node.
local function build(name: string, node, parentPath: string)
	local module = roblox.Instance.new("ModuleScript")
	module.Name = name
	local path = node["$path"]
	local full = if path then `{ROOT}/{path}` else nil
	if node["$private"] then
		assert(PRIVATE, `{node["$private"]} is in the private luau-bot-headless repository; check it out beside this one or set LUAU_BOT_PRIVATE_DIR`)
		full = `{PRIVATE}/{node["$private"]}`
		assert(fs.isFile(full), `missing private file {full}`)
	end
	local folder
	if full then
		if fs.isDir(full) then
			folder = full
			full ..= "/init.luau"
		end
		module.Source = (fs.readFile(full):gsub("\r\n", "\n"))
	end
	if folder then
		for _, entry in fs.readDir(folder) do
			local child = `{folder}/{entry}`
			if entry ~= "init.luau" and (fs.isDir(child) or entry:match("%.luau$")) then
				local childName = entry:gsub("%.luau$", "")
				local relative = `{path}/{entry}`
				build(childName, { ["$path"] = relative }, parentPath).Parent = module
			end
		end
	end
	for key, child in node do
		if key:sub(1, 1) ~= "$" then
			build(key, child, `{parentPath}/{name}`).Parent = module
		end
	end
	return module
end

local command = process.args[1]
if command == "unpack" or command == "list" then
	local roots = readBundle(assert(process.args[2], "usage: unpack <b64> <dir> | list <b64>"))
	local target = process.args[3]
	walk(roots, function(instance, path)
		local source = if instance:IsA("LuaSourceContainer") then instance.Source else nil
		print(string.format("%-60s %-14s %s", path, instance.ClassName, if source then #source else "-"))
		if command == "unpack" and target and source then
			local file = `{target}/{path}.luau`
			fs.writeDir(file:match("^(.*)/[^/]+$"))
			fs.writeFile(file, source)
		end
	end)
elseif command == nil or command == "build" then
	local project = serde.decode("json", fs.readFile(`{ROOT}/bundle.project.json`))
	local root = build(project.name, project.tree, "")
	local model = roblox.serializeModel({ root })
	local encoded = base64Encode(withContentSize(serde.compress("zstd", model), #model))
	local out = process.args[2] or `{ROOT}/luauBot.b64`
	fs.writeFile(out, encoded)
	local count = #root:GetDescendants() + 1
	print(`wrote {out}: {count} ModuleScripts, {#model} bytes of rbxm, {#encoded} chars`)
else
	error(`unknown command {command}; expected build, unpack or list`)
end
