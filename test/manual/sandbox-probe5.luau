--!nosandbox
-- Probe: which service props differ from engine defaults, and what their defaults are (restored right after).
local RS = game:GetService("ReflectionService")
local out = {}
for _, s in game:GetChildren() do
	local ok, props = pcall(RS.GetPropertiesOfClass, RS, s.ClassName)
	if ok and props then
		for _, prop in props do
			if prop.Permits and prop.Permits.Write ~= nil and prop.Name ~= "Parent" then
				local okm, modified = pcall(s.IsPropertyModified, s, prop.Name)
				if okm and modified then
					local okv, cur = pcall(function()
						return s[prop.Name]
					end)
					local def = "?"
					if okv and pcall(s.ResetPropertyToDefault, s, prop.Name) then
						def = tostring(s[prop.Name])
						pcall(function()
							s[prop.Name] = cur
						end)
					end
					table.insert(out, `{s.ClassName}.{prop.Name} = {tostring(cur)} (default {def})`)
				end
			end
		end
	end
end
local where = {}
for _, d in game:GetDescendants() do
	if d.Name == "LuauBot" then
		table.insert(where, d:GetFullName())
	end
end
table.insert(out, "LuauBot in game: " .. (#where > 0 and table.concat(where, ",") or "no"))
print(table.concat(out, "\n"))
