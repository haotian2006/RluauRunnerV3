-- Probe: can a runtime script reset service state (for startup cleanup)?
local out = {}
local function try(k, f)
	local ok, r = pcall(f)
	table.insert(out, k .. ": " .. (ok and tostring(r) or ("ERR " .. tostring(r))))
end
local realGame = game.Parent == nil and game or game
local ws = realGame:GetService("Workspace")
local p = Instance.new("Part")
p.Transparency = 0.5
try("part.ResetPropertyToDefault", function()
	p:ResetPropertyToDefault("Transparency")
	return p.Transparency
end)
try("part.IsPropertyModified", function()
	p.Name = "x"
	return p:IsPropertyModified("Name")
end)
local L = realGame:GetService("Lighting")
try("lighting.Name", function()
	return L.Name
end)
try("lighting.IsPropertyModified ClockTime", function()
	return L:IsPropertyModified("ClockTime")
end)
try("lighting.rename+reset", function()
	local old = L.Name
	L.Name = "tmp"
	L:ResetPropertyToDefault("Name")
	local r = L.Name
	L.Name = old
	return r
end)
try("game.Name", function()
	return realGame.Name
end)
try("game.IsPropertyModified Name", function()
	return realGame:IsPropertyModified("Name")
end)
try("terrain.Clear", function()
	return typeof(ws.Terrain.Clear)
end)
local renamed = {}
for _, s in realGame:GetChildren() do
	if s.Name ~= s.ClassName then
		table.insert(renamed, s.ClassName .. "=" .. s.Name)
	end
end
table.insert(out, "services name ~= class: " .. table.concat(renamed, ", "))
local modified = {}
for _, s in realGame:GetChildren() do
	local n = 0
	local ok, props = pcall(function()
		return realGame:GetService("ReflectionService"):GetPropertiesOfClass(s.ClassName)
	end)
	if ok and props then
		for _, prop in props do
			if prop.Permits and prop.Permits.Write ~= nil then
				local okm, m = pcall(s.IsPropertyModified, s, prop.Name)
				if okm and m then
					n += 1
				end
			end
		end
	end
	if n > 0 then
		table.insert(modified, s.ClassName .. ":" .. n)
	end
	if next(s:GetAttributes()) or #s:GetTags() > 0 then
		table.insert(modified, s.ClassName .. ":attrs/tags")
	end
end
table.insert(out, "services with modified props: " .. table.concat(modified, ", "))
print(table.concat(out, "\n"))
