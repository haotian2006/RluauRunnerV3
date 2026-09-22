--!nosandbox
-- Probe: are the instances the engine creates at boot Archivable (i.e. would SavePlaceAsync persist them)?
local out = {}
for _, d in game:GetDescendants() do
	local c = d.ClassName
	local interesting = c == "ScreenshotHud" or c == "StatsItem" or c:find("Script") or c:find("Configuration") or c == "Camera"
	if interesting and not d:GetFullName():find("__ws_") then
		table.insert(out, d:GetFullName() .. "(" .. c .. ") archivable=" .. tostring(d.Archivable))
	end
end
print(table.concat(out, "\n"))
print("end")
