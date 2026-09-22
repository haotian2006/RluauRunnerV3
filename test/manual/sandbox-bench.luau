-- Run twice through the bot: once normally, once with a leading --!nosandbox line, and compare.
local N = 100000
local function bench(f)
	local best = math.huge
	for _ = 1, 3 do
		local t = os.clock()
		f()
		best = math.min(best, os.clock() - t)
	end
	return best
end
local part = Instance.new("Part")
part.Parent = workspace
local rows = {
	{ "prop read (part.Position)", bench(function()
		local v
		for _ = 1, N do
			v = part.Position
		end
		return v
	end) },
	{ "prop write (part.Transparency)", bench(function()
		for i = 1, N do
			part.Transparency = i % 2
		end
	end) },
	{ "method (part:IsA)", bench(function()
		for _ = 1, N do
			part:IsA("BasePart")
		end
	end) },
	{ "workspace:FindFirstChild x10k", bench(function()
		for _ = 1, N / 10 do
			workspace:FindFirstChild("Part")
		end
	end) },
	{ "Instance.new+Destroy x10k", bench(function()
		for _ = 1, N / 10 do
			Instance.new("Folder"):Destroy()
		end
	end) },
	{ "typeof(number)", bench(function()
		local s = 0
		for i = 1, N do
			if typeof(i) == "number" then
				s += 1
			end
		end
		return s
	end) },
	{ "math.floor x1M", bench(function()
		local s = 0
		for i = 1, N * 10 do
			s += math.floor(i * 0.5)
		end
		return s
	end) },
	{ "Vector3.new x1M", bench(function()
		local v
		for i = 1, N * 10 do
			v = Vector3.new(i, 1, 1)
		end
		return v
	end) },
}
if thread then
	local lf = loadstring("local s = 0 for i = 1, 1000000 do s += math.floor(i * 0.5) end return s")
	table.insert(rows, { "loadstring math.floor x1M", bench(lf) })
end
part:Destroy()
local out = {}
for _, r in rows do
	table.insert(out, string.format("%-32s %.4fs", r[1], r[2]))
end
print(table.concat(out, "\n"))
