-- Per-job in-memory filesystem. No host paths, files, links, or credentials.
return function()
	local files, directories = {}, {[""] = true}
	local used, count = 0, 0
	local function normalize(path)
		assert(type(path) == "string" and #path <= 1024, "invalid virtual path")
		assert(not path:find("%z") and not path:find(":") and not path:match("^[/\\]"), "expected a relative virtual path")
		local parts = {}
		for part in path:gsub("\\", "/"):gmatch("[^/]+") do
			if part == ".." then
				assert(#parts > 0, "path escapes virtual root")
				table.remove(parts)
			elseif part ~= "." then table.insert(parts, part) end
		end
		return table.concat(parts, "/")
	end
	local function parent(path) return path:match("^(.*)/[^/]+$") or "" end
	local api = {}
	function api.isFile(path) return files[normalize(path)] ~= nil end
	function api.isDir(path) return directories[normalize(path)] == true end
	function api.readFile(path)
		local value = files[normalize(path)]
		assert(value ~= nil, "virtual file does not exist")
		return value
	end
	function api.writeDir(path)
		path = normalize(path)
		local current = ""
		for part in path:gmatch("[^/]+") do
			current = current == "" and part or current .. "/" .. part
			assert(not files[current], "path is a file")
			if not directories[current] then
				assert(count < 1024, "virtual filesystem entry limit exceeded")
				directories[current] = true; count += 1
			end
		end
	end
	function api.writeFile(path, value)
		path = normalize(path)
		if typeof(value) == "buffer" then value = buffer.tostring(value) end
		assert(type(value) == "string", "file contents must be a string or buffer")
		assert(not directories[path] and directories[parent(path)], "invalid virtual file parent")
		local old = files[path]
		local newSize = used - (old and #old or 0) + #value
		assert(newSize <= 16 * 1024 * 1024, "virtual filesystem exceeds 16 MiB")
		if not old then assert(count < 1024, "virtual filesystem entry limit exceeded"); count += 1 end
		files[path], used = value, newSize
	end
	function api.readDir(path)
		path = normalize(path)
		assert(directories[path], "virtual directory does not exist")
		local out = {}
		for entry in files do if parent(entry) == path then table.insert(out, entry:match("[^/]+$")) end end
		for entry in directories do if entry ~= "" and parent(entry) == path then table.insert(out, entry:match("[^/]+$")) end end
		table.sort(out); return out
	end
	function api.removeFile(path)
		path = normalize(path)
		local value = files[path]
		assert(value ~= nil, "virtual file does not exist")
		files[path] = nil; used -= #value; count -= 1
	end
	function api.removeDir(path)
		path = normalize(path)
		assert(path ~= "" and directories[path], "invalid virtual directory")
		local prefix = path .. "/"
		for entry, value in files do
			if entry:sub(1, #prefix) == prefix then files[entry] = nil; used -= #value; count -= 1 end
		end
		for entry in directories do
			if entry == path or entry:sub(1, #prefix) == prefix then directories[entry] = nil; count -= 1 end
		end
	end
	function api.copy(from, to, overwrite)
		from, to = normalize(from), normalize(to)
		assert(overwrite == true or not files[to], "destination exists")
		api.writeFile(to, api.readFile(from))
	end
	function api.move(from, to, overwrite)
		from, to = normalize(from), normalize(to)
		if from == to then return end
		api.copy(from, to, overwrite); api.removeFile(from)
	end
	function api.metadata(path)
		path = normalize(path)
		assert(files[path] ~= nil or directories[path], "virtual path does not exist")
		return {kind = directories[path] and "dir" or "file", exists = true, size = files[path] and #files[path] or 0}
	end
	return table.freeze(api)
end
