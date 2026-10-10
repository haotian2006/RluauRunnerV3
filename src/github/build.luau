--!strict
-- Builds one .rbxm from a repository's files using Rojo's sync rules.
-- stdin: length-prefixed (u32 big-endian) config JSON, then (path, data) pairs.
-- stdout: the model. Errors go to stderr with exit code 1.
-- Only the files on stdin are ever read; project $paths resolve inside that set.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Instance = roblox.Instance
local Enum = roblox.Enum
local db = roblox.getReflectionDatabase()

local function fail(msg: string): never
	stdio.ewrite(msg)
	process.exit(1)
	error(msg)
end

--// input

local input = stdio.readToEnd()
local pos = 1
local function chunk(): string
	if pos + 3 > #input then
		fail("truncated input")
	end
	local n = string.unpack(">I4", input, pos)
	local s = string.sub(input, pos + 4, pos + 3 + n)
	pos += 4 + n
	return s
end

local config = serde.decode("json", chunk())
local files: { [string]: string } = {}
local dirs: { [string]: { [string]: boolean } } = { [""] = {} }

local function addDir(path: string)
	if dirs[path] then
		return
	end
	dirs[path] = {}
	local parent, name = string.match(path, "^(.*)/([^/]+)$")
	if not parent then
		parent, name = "", path
	end
	addDir(parent)
	dirs[parent][name] = true
end

while pos <= #input do
	local path = chunk()
	files[path] = chunk()
	local parent, name = string.match(path, "^(.*)/([^/]+)$")
	if not parent then
		parent, name = "", path
	end
	addDir(parent)
	dirs[parent][name] = true
end

local function join(a: string, b: string): string
	return if a == "" then b else a .. "/" .. b
end

-- Resolves a project $path against the project's folder; refuses to leave the repo.
local function resolve(base: string, rel: string): string
	local parts = {}
	for seg in string.gmatch(base, "[^/]+") do
		table.insert(parts, seg)
	end
	for seg in string.gmatch((string.gsub(rel, "\\", "/")), "[^/]+") do
		if seg == ".." then
			if #parts == 0 then
				fail(`$path "{rel}" leaves the repository`)
			end
			table.remove(parts)
		elseif seg ~= "." then
			table.insert(parts, seg)
		end
	end
	return table.concat(parts, "/")
end

--// properties (Rojo's JSON value forms)

local function propType(className: string, prop: string): string?
	local class = db:GetClass(className)
	while class do
		local p = class.Properties[prop]
		if p then
			return p.Datatype
		end
		class = class.Superclass and db:GetClass(class.Superclass)
	end
	return nil
end

local function num(v: any, i: number): number
	return tonumber(v[i]) or 0
end

local function convert(datatype: string, v: any): any
	if string.sub(datatype, 1, 5) == "Enum." then
		local enum = Enum[string.sub(datatype, 6)]
		if type(v) == "string" then
			return enum[v]
		elseif type(v) == "number" then
			for _, item in enum:GetEnumItems() do
				if item.Value == v then
					return item
				end
			end
		end
		return nil
	elseif datatype == "Vector3" then
		return roblox.Vector3.new(num(v, 1), num(v, 2), num(v, 3))
	elseif datatype == "Vector2" then
		return roblox.Vector2.new(num(v, 1), num(v, 2))
	elseif datatype == "Color3" then
		return roblox.Color3.new(num(v, 1), num(v, 2), num(v, 3))
	elseif datatype == "Color3uint8" then
		return roblox.Color3.fromRGB(num(v, 1), num(v, 2), num(v, 3))
	elseif datatype == "UDim" then
		return roblox.UDim.new(num(v, 1), num(v, 2))
	elseif datatype == "UDim2" then
		return roblox.UDim2.new(num(v[1], 1), num(v[1], 2), num(v[2], 1), num(v[2], 2))
	elseif datatype == "NumberRange" then
		return roblox.NumberRange.new(num(v, 1), num(v, 2))
	elseif datatype == "Rect" then
		return roblox.Rect.new(num(v[1], 1), num(v[1], 2), num(v[2], 1), num(v[2], 2))
	elseif datatype == "BrickColor" then
		return roblox.BrickColor.new(v)
	elseif datatype == "CFrame" then
		local p, o = v.position or { 0, 0, 0 }, v.orientation or { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
		return roblox.CFrame.new(
			num(p, 1), num(p, 2), num(p, 3),
			num(o[1], 1), num(o[1], 2), num(o[1], 3),
			num(o[2], 1), num(o[2], 2), num(o[2], 3),
			num(o[3], 1), num(o[3], 2), num(o[3], 3)
		)
	elseif datatype == "Font" then
		return roblox.Font.new(v.family, Enum.FontWeight[v.weight or "Regular"], Enum.FontStyle[v.style or "Normal"])
	elseif datatype == "NumberSequence" then
		local kps = {}
		for _, k in v.keypoints or {} do
			table.insert(kps, roblox.NumberSequenceKeypoint.new(k.time, k.value, k.envelope or 0))
		end
		return roblox.NumberSequence.new(kps)
	elseif datatype == "ColorSequence" then
		local kps = {}
		for _, k in v.keypoints or {} do
			table.insert(kps, roblox.ColorSequenceKeypoint.new(k.time, roblox.Color3.new(num(k.color, 1), num(k.color, 2), num(k.color, 3))))
		end
		return roblox.ColorSequence.new(kps)
	elseif datatype == "Bool" or datatype == "String" or datatype == "Content" or datatype == "ContentId" then
		return v
	elseif datatype == "Float32" or datatype == "Float64" or datatype == "Int32" or datatype == "Int64" then
		return tonumber(v)
	end
	return nil
end

local EXPLICIT = {
	Bool = true, String = true, Float32 = true, Float64 = true, Int32 = true, Int64 = true,
	Vector3 = true, Vector2 = true, Color3 = true, Color3uint8 = true, UDim = true, UDim2 = true,
	NumberRange = true, Rect = true, BrickColor = true, CFrame = true, Font = true,
	NumberSequence = true, ColorSequence = true, Content = true,
}

-- An explicit value is { TypeName = value }; anything else is typed by the property.
local function explicitValue(v: any): (string?, any)
	if type(v) == "table" then
		local k, x = next(v)
		if type(k) == "string" and next(v, k) == nil and (EXPLICIT[k] or k == "Enum") then
			return k, x
		end
	end
	return nil, nil
end

local function attributeValue(v: any): any
	local t, x = explicitValue(v)
	if t then
		return convert(t, x)
	end
	if type(v) == "table" then
		return nil
	end
	return v
end

local function applyProperties(inst: any, props: any, attrs: any?)
	for name, raw in props or {} do
		if name == "Attributes" and type(raw) == "table" then
			for k, v in raw do
				local value = attributeValue(v)
				if value ~= nil then
					pcall(inst.SetAttribute, inst, k, value)
				end
			end
		elseif name == "Tags" and type(raw) == "table" then
			for _, tag in raw do
				pcall(inst.AddTag, inst, tag)
			end
		else
			local t, x = explicitValue(raw)
			local datatype = t or propType(inst.ClassName, name)
			local value = if datatype then convert(datatype, if t then x else raw) else nil
			if value ~= nil then
				pcall(function()
					inst[name] = value
				end)
			end
		end
	end
	for k, v in attrs or {} do
		local value = attributeValue(v)
		if value ~= nil then
			pcall(inst.SetAttribute, inst, k, value)
		end
	end
end

--// file rules

local KEYWORDS = {}
for _, k in string.split("and break continue do else elseif end false for function if in local nil not or repeat return then true until while", " ") do
	KEYWORDS[k] = true
end

local function luauLiteral(v: any, depth: number): string
	local t = type(v)
	if t == "string" then
		return string.format("%q", v)
	elseif t == "number" then
		if v ~= v then
			return "0/0"
		elseif v == math.huge then
			return "math.huge"
		elseif v == -math.huge then
			return "-math.huge"
		elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.17g", v)
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local pad = string.rep("\t", depth + 1)
		local out = {}
		local n = #v
		for i = 1, n do
			table.insert(out, pad .. luauLiteral(v[i], depth + 1))
		end
		local keys = {}
		for k in v do
			if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
				table.insert(keys, k)
			end
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, k in keys do
			local key = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") and not KEYWORDS[k]
				then k
				else "[" .. luauLiteral(k, depth + 1) .. "]"
			table.insert(out, pad .. key .. " = " .. luauLiteral(v[k], depth + 1))
		end
		if #out == 0 then
			return "{}"
		end
		return "{\n" .. table.concat(out, ",\n") .. ",\n" .. string.rep("\t", depth) .. "}"
	end
	return "nil"
end

local function parseCsv(text: string): { { string } }
	local rows, row, field, i, quoted = {}, {}, {}, 1, false
	local n = #text
	while i <= n do
		local c = string.sub(text, i, i)
		if quoted then
			if c == '"' then
				if string.sub(text, i + 1, i + 1) == '"' then
					table.insert(field, '"')
					i += 1
				else
					quoted = false
				end
			else
				table.insert(field, c)
			end
		elseif c == '"' then
			quoted = true
		elseif c == "," then
			table.insert(row, table.concat(field))
			field = {}
		elseif c == "\n" or c == "\r" then
			if c == "\r" and string.sub(text, i + 1, i + 1) == "\n" then
				i += 1
			end
			table.insert(row, table.concat(field))
			table.insert(rows, row)
			row, field = {}, {}
		else
			table.insert(field, c)
		end
		i += 1
	end
	if #field > 0 or #row > 0 then
		table.insert(row, table.concat(field))
		table.insert(rows, row)
	end
	return rows
end

-- Rojo's localization CSV: Key, Context, Example, Source and one column per locale.
local function localizationContents(text: string): string
	local rows = parseCsv(text)
	local header = rows[1] or {}
	local entries = {}
	for r = 2, #rows do
		local row = rows[r]
		local entry = { key = "", context = "", examples = "", source = "", values = {} }
		local any = false
		for c, col in header do
			local v = row[c] or ""
			if v ~= "" then
				any = true
			end
			if col == "Key" then
				entry.key = v
			elseif col == "Context" then
				entry.context = v
			elseif col == "Example" then
				entry.examples = v
			elseif col == "Source" then
				entry.source = v
			elseif v ~= "" then
				entry.values[col] = v
			end
		end
		if any then
			table.insert(entries, entry)
		end
	end
	return serde.encode("json", entries)
end

local RULES = {
	{ "%.server%.luau$", "Script" },
	{ "%.server%.lua$", "Script" },
	{ "%.client%.luau$", "LocalScript" },
	{ "%.client%.lua$", "LocalScript" },
	{ "%.model%.json$", "model" },
	{ "%.project%.json$", "project" },
	{ "%.meta%.json$", "meta" },
	{ "%.luau$", "ModuleScript" },
	{ "%.lua$", "ModuleScript" },
	{ "%.json$", "json" },
	{ "%.toml$", "toml" },
	{ "%.txt$", "txt" },
	{ "%.csv$", "csv" },
	{ "%.rbxmx$", "rbxm" },
	{ "%.rbxm$", "rbxm" },
}

local function classify(fileName: string): (string?, string)
	local lower = string.lower(fileName)
	for _, rule in RULES do
		local s = string.find(lower, rule[1])
		if s then
			return rule[2], string.sub(fileName, 1, s - 1)
		end
	end
	return nil, fileName
end

local buildDir, buildFile, buildProject

local function buildModelJson(node: any, name: string?): any
	local className = node.ClassName or node.className
	if type(className) ~= "string" then
		fail("model.json entries need a ClassName")
	end
	local inst = Instance.new(className)
	inst.Name = name or node.Name or node.name or className
	applyProperties(inst, node.Properties or node.properties, node.Attributes or node.attributes)
	for _, child in node.Children or node.children or {} do
		buildModelJson(child, nil).Parent = inst
	end
	return inst
end

function buildFile(path: string, fileName: string): any
	local kind, stem = classify(fileName)
	local data = files[path]
	if kind == nil or kind == "meta" then
		return nil
	end
	local inst
	if kind == "Script" or kind == "LocalScript" or kind == "ModuleScript" then
		inst = Instance.new(kind)
		inst.Source = data
	elseif kind == "json" or kind == "toml" then
		local ok, value = pcall(serde.decode, kind, data)
		if not ok then
			fail(`{path}: {value}`)
		end
		inst = Instance.new("ModuleScript")
		inst.Source = "return " .. luauLiteral(value, 0) .. "\n"
	elseif kind == "txt" then
		inst = Instance.new("StringValue")
		inst.Value = data
	elseif kind == "csv" then
		inst = Instance.new("LocalizationTable")
		inst.Contents = localizationContents(data)
	elseif kind == "rbxm" then
		local ok, roots = pcall(roblox.deserializeModel, data)
		if not ok then
			fail(`{path}: {roots}`)
		end
		if #roots ~= 1 then
			fail(`{path}: a model file must hold exactly one top-level instance, found {#roots}`)
		end
		inst = roots[1]
	elseif kind == "model" then
		local ok, node = pcall(serde.decode, "json", data)
		if not ok then
			fail(`{path}: {node}`)
		end
		inst = buildModelJson(node, stem)
	elseif kind == "project" then
		inst = buildProject(path)
		return inst
	end
	inst.Name = stem
	local dir = string.match(path, "^(.*)/[^/]+$") or ""
	local meta = files[join(dir, stem .. ".meta.json")]
	if meta and kind ~= "rbxm" and kind ~= "model" then
		local ok, m = pcall(serde.decode, "json", meta)
		if ok and type(m) == "table" then
			applyProperties(inst, m.properties, m.attributes)
		end
	end
	return inst
end

local INIT = {
	["init.luau"] = "ModuleScript",
	["init.lua"] = "ModuleScript",
	["init.server.luau"] = "Script",
	["init.server.lua"] = "Script",
	["init.client.luau"] = "LocalScript",
	["init.client.lua"] = "LocalScript",
}

function buildDir(path: string, name: string, asProject: boolean?): any
	local entries = dirs[path]
	if not entries then
		fail(`folder "{path}" not found`)
	end
	if not asProject and entries["default.project.json"] then
		return buildProject(join(path, "default.project.json"), name)
	end
	local initName
	for file in INIT do
		if entries[file] and files[join(path, file)] then
			if initName then
				fail(`{path} has more than one init script`)
			end
			initName = file
		end
	end
	local className = if initName then INIT[initName] else "Folder"
	local meta
	local metaSrc = files[join(path, "init.meta.json")]
	if metaSrc then
		local ok, m = pcall(serde.decode, "json", metaSrc)
		if ok and type(m) == "table" then
			meta = m
			if not initName and type(m.className) == "string" then
				className = m.className
			end
		end
	end
	local inst = Instance.new(className)
	inst.Name = name
	if initName then
		inst.Source = files[join(path, initName)]
	end
	if meta then
		applyProperties(inst, meta.properties, meta.attributes)
	end
	local names = {}
	for entry in entries do
		table.insert(names, entry)
	end
	table.sort(names)
	for _, entry in names do
		if INIT[entry] or entry == "init.meta.json" then
			continue
		end
		local child = join(path, entry)
		local built
		if dirs[child] then
			built = buildDir(child, entry)
		elseif files[child] then
			built = buildFile(child, entry)
		end
		if built then
			built.Parent = inst
		end
	end
	return inst
end

local function isService(className: string): boolean
	if className == "DataModel" then
		return true
	end
	local class = db:GetClass(className)
	if not class then
		return false
	end
	for _, tag in class.Tags or {} do
		if tag == "Service" then
			return true
		end
	end
	return false
end

local function buildNode(node: any, name: string, base: string): any
	if type(node) ~= "table" then
		fail(`project node "{name}" must be an object`)
	end
	local inst
	if type(node["$path"]) == "string" then
		local p = resolve(base, node["$path"])
		if dirs[p] then
			inst = buildDir(p, name)
		elseif files[p] then
			inst = buildFile(p, string.match(p, "([^/]+)$") :: string)
			if not inst then
				fail(`$path "{node["$path"]}" isn't a file Rojo can sync`)
			end
		else
			fail(`$path "{node["$path"]}" not found`)
		end
		inst.Name = name
	else
		local className = node["$className"] or "Folder"
		if isService(className) then
			className = "Folder"
		end
		local ok, created = pcall(Instance.new, className)
		if not ok then
			fail(`unknown $className "{className}"`)
		end
		inst = created
		inst.Name = name
	end
	applyProperties(inst, node["$properties"], node["$attributes"])
	for key, child in node do
		if type(key) == "string" and string.sub(key, 1, 1) ~= "$" then
			buildNode(child, key, base).Parent = inst
		end
	end
	return inst
end

function buildProject(path: string, name: string?): any
	local ok, project = pcall(serde.decode, "json", files[path] or "")
	if not ok or type(project) ~= "table" or type(project.tree) ~= "table" then
		fail(`{path} isn't a valid project file`)
	end
	local base = string.match(path, "^(.*)/[^/]+$") or ""
	return buildNode(project.tree, name or project.name or "Project", base)
end

--// entry

local root
if config.mode == "repo" then
	if files["default.project.json"] then
		root = buildProject("default.project.json")
	elseif dirs["src"] then
		root = buildDir("src", config.name)
	else
		fail("the repository has no default.project.json or src folder")
	end
elseif config.mode == "path" then
	local p = config.path
	local leaf = string.match(p, "([^/]+)$") or config.name
	if dirs[p] then
		root = buildDir(p, leaf)
	elseif files[p] then
		root = buildFile(p, leaf)
		if not root then
			fail(`"{p}" isn't a file Rojo can sync`)
		end
	else
		fail(`"{p}" not found in the repository`)
	end
elseif config.mode == "wally" then
	-- Wally's layout: _Index/<scope>_<name>@<version>/<name>, beside one link module per
	-- dependency, so a package's require(script.Parent.Dep) resolves as installed.
	local byKey = {}
	for _, pkg in config.packages do
		byKey[pkg.key] = pkg
	end
	local index = Instance.new("Folder")
	index.Name = "_Index"
	for _, pkg in config.packages do
		local folder = Instance.new("Folder")
		folder.Name = pkg.key
		if not dirs[pkg.key] then
			fail(`package {pkg.key} has no files Rojo can sync`)
		end
		local inst = buildDir(pkg.key, pkg.name)
		inst.Name = pkg.name
		inst.Parent = folder
		for alias, depKey in pkg.deps do
			local link = Instance.new("ModuleScript")
			link.Name = alias
			link.Source = `return require(script.Parent.Parent[{string.format("%q", depKey)}][{string.format("%q", byKey[depKey].name)}])\n`
			link.Parent = folder
		end
		folder.Parent = index
	end
	root = Instance.new("ModuleScript")
	root.Name = config.name
	root.Source = `return require(script._Index[{string.format("%q", config.root)}][{string.format("%q", byKey[config.root].name)}])\n`
	index.Parent = root
elseif config.mode == "model" then
	local ok, roots = pcall(roblox.deserializeModel, files.model or "")
	if not ok then
		fail(`not a valid model file: {roots}`)
	end
	if #roots == 1 then
		root = roots[1]
	else
		root = Instance.new("Folder")
		root.Name = config.name
		for _, r in roots do
			r.Parent = root
		end
	end
else
	fail("unknown mode")
end

stdio.write(roblox.serializeModel({ root }))
