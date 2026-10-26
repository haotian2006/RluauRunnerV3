--!native
--!optimize 2
-- Texels are brightness factors (x 1/GAIN) multiplied into the part colour, so a texture can also lighten.

local SIZE = 128
local GAIN = 255 / 200

local M = {}
M.GAIN = GAIN

local function hash(x, y, seed)
	local h = bit32.bxor(x * 374761393, y * 668265263, seed * 2246822519)
	h = bit32.bxor(h, bit32.rshift(h, 13)) * 1274126177
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return bit32.band(h, 0xFFFF) / 0xFFFF
end

local function smooth(t)
	return t * t * (3 - 2 * t)
end

-- Value noise that tiles every `period` cells.
local function noise(x, y, period, seed)
	local ix, iy = math.floor(x), math.floor(y)
	local fx, fy = smooth(x - ix), smooth(y - iy)
	local x0, y0 = ix % period, iy % period
	local x1, y1 = (ix + 1) % period, (iy + 1) % period
	local a, b = hash(x0, y0, seed), hash(x1, y0, seed)
	local c, d = hash(x0, y1, seed), hash(x1, y1, seed)
	local top = a + (b - a) * fx
	return top + ((c + (d - c) * fx) - top) * fy
end

-- Fractal noise over [0, 1) x [0, 1) tiling at the texture edge; base cells across.
local function fbm(u, v, base, octaves, seed)
	local sum, amp, total = 0, 1, 0
	local cells = base
	for o = 1, octaves do
		sum += noise(u * cells, v * cells, cells, seed + o) * amp
		total += amp
		amp *= 0.5
		cells *= 2
	end
	return sum / total
end

-- Distance to the nearest and second-nearest of cells x cells jittered points (tiling).
local function voronoi(u, v, cells, seed)
	local x, y = u * cells, v * cells
	local ix, iy = math.floor(x), math.floor(y)
	local d1, d2 = math.huge, math.huge
	for oy = -1, 1 do
		for ox = -1, 1 do
			local cx, cy = ix + ox, iy + oy
			local px = cx + hash(cx % cells, cy % cells, seed)
			local py = cy + hash(cx % cells, cy % cells, seed + 7)
			local d = (px - x) ^ 2 + (py - y) ^ 2
			if d < d1 then
				d1, d2 = d, d1
			elseif d < d2 then
				d2 = d
			end
		end
	end
	return math.sqrt(d1), math.sqrt(d2)
end

local function wood(u, v, rings, seed)
	local t = (v + fbm(u, v, 4, 3, seed) * 0.35) * rings
	local band = math.abs(math.sin(t * math.pi))
	return 0.88 + band ^ 6 * -0.22 + (fbm(u * 0.25, v, 16, 2, seed + 9) - 0.5) * 0.12
end

-- Brightness factor at (u, v) in [0, 1) for each pattern, around 1.
local PATTERNS = {
	plastic = function(u, v)
		return 1 + (fbm(u, v, 16, 2, 11) - 0.5) * 0.05
	end,
	concrete = function(u, v)
		return 0.92 + (fbm(u, v, 4, 5, 21) - 0.5) * 0.35 + (hash(math.floor(u * SIZE), math.floor(v * SIZE), 22) - 0.5) * 0.08
	end,
	grass = function(u, v)
		local blades = hash(math.floor(u * SIZE), math.floor(v * SIZE), 31)
		return 0.9 + (fbm(u, v, 4, 4, 32) - 0.5) * 0.3 + (blades - 0.5) * 0.25
	end,
	sand = function(u, v)
		return 0.95 + (hash(math.floor(u * SIZE), math.floor(v * SIZE), 41) - 0.5) * 0.18 + (fbm(u, v, 4, 3, 42) - 0.5) * 0.15
	end,
	wood = function(u, v)
		return wood(u, v, 6, 51)
	end,
	planks = function(u, v)
		local row = math.floor(v * 4)
		local shift = hash(row, 0, 61) * 0.5
		local x = (u + shift) % 1
		local seam = if (v * 4) % 1 < 0.04 or (x * 2) % 1 < 0.02 then 0.6 else 1
		return wood(x, v * 4 % 1, 3, 62 + row) * seam
	end,
	brick = function(u, v)
		local rows = 8
		local y = v * rows
		local row = math.floor(y)
		local x = u * 4 + (if row % 2 == 1 then 0.5 else 0)
		local mortar = (y % 1) < 0.12 or (x % 1) < 0.06
		if mortar then
			return 1.25 + (fbm(u, v, 16, 2, 71) - 0.5) * 0.1
		end
		return 0.9 + (hash(math.floor(x) % 4, row, 72) - 0.5) * 0.18 + (fbm(u, v, 8, 3, 73) - 0.5) * 0.2
	end,
	cobble = function(u, v)
		local d1, d2 = voronoi(u, v, 6, 81)
		local edge = d2 - d1
		if edge < 0.08 then
			return 0.55
		end
		return 0.88 + (fbm(u, v, 8, 3, 82) - 0.5) * 0.3 + math.min(edge, 0.5) * 0.3
	end,
	pebble = function(u, v)
		local d1, d2 = voronoi(u, v, 10, 91)
		return if d2 - d1 < 0.1 then 0.7 else 0.95 + (1 - d1) * 0.15
	end,
	slate = function(u, v)
		local patches = math.max(fbm(u, v, 3, 3, 104) - 0.55, 0) * 0.45
		return 0.92 + (fbm(u, v, 4, 4, 102) - 0.5) * 0.22 + (fbm(u, v, 16, 3, 103) - 0.5) * 0.1 + patches
	end,
	rock = function(u, v)
		local ridge = 1 - math.abs(fbm(u, v, 4, 5, 111) * 2 - 1)
		return 0.88 + (fbm(u, v, 4, 5, 112) - 0.5) * 0.4 - ridge ^ 10 * 0.35
	end,
	marble = function(u, v)
		local t = math.sin((u + v + fbm(u, v, 4, 5, 121) * 1.6) * math.pi * 4)
		return 1.02 - (1 - math.abs(t)) ^ 12 * 0.3
	end,
	granite = function(u, v)
		local s = hash(math.floor(u * SIZE / 2), math.floor(v * SIZE / 2), 131)
		local speck = if s > 0.92 then 0.65 elseif s < 0.06 then 1.2 else 1
		return speck * (0.95 + (fbm(u, v, 8, 3, 132) - 0.5) * 0.15)
	end,
	metal = function(u, v)
		return 0.95 + (noise(u * 4, v * SIZE, 4, 141) - 0.5) * 0.15 + (fbm(u, v, 4, 3, 142) - 0.5) * 0.1
	end,
	diamond = function(u, v)
		local x, y = (u * 8) % 1 - 0.5, (v * 8) % 1 - 0.5
		local a = math.abs(x + y * 2) + math.abs(x - y * 2)
		local raised = a < 0.35
		return (if raised then 1.15 else 0.92) + (fbm(u, v, 8, 2, 151) - 0.5) * 0.08
	end,
	corroded = function(u, v)
		local rust = fbm(u, v, 4, 5, 161)
		return 0.95 + (rust - 0.5) * 0.5 - (if rust > 0.65 then 0.15 else 0)
	end,
	fabric = function(u, v)
		local x, y = (u * 32) % 1, (v * 32) % 1
		local over = (math.floor(u * 32) + math.floor(v * 32)) % 2 == 0
		local thread = if over then math.sin(x * math.pi) else math.sin(y * math.pi)
		return 0.85 + thread * 0.2
	end,
	ice = function(u, v)
		local ridge = 1 - math.abs(fbm(u, v, 3, 4, 171) * 2 - 1)
		return 1.05 - ridge ^ 12 * 0.15
	end,
	foil = function(u, v)
		local ridge = 1 - math.abs(fbm(u, v, 6, 4, 181) * 2 - 1)
		return 0.9 + ridge ^ 3 * 0.25
	end,
	ground = function(u, v)
		return 0.9 + (fbm(u, v, 4, 5, 191) - 0.5) * 0.4
	end,
	asphalt = function(u, v)
		return 0.95 + (hash(math.floor(u * SIZE), math.floor(v * SIZE), 201) - 0.5) * 0.3 + (fbm(u, v, 4, 3, 202) - 0.5) * 0.1
	end,
	pavement = function(u, v)
		local seam = (u * 2) % 1 < 0.03 or (v * 2) % 1 < 0.03
		return if seam then 0.65 else 0.95 + (fbm(u, v, 8, 3, 211) - 0.5) * 0.2
	end,
	snow = function(u, v)
		return 1.03 + (fbm(u, v, 6, 4, 221) - 0.5) * 0.1
	end,
	layers = function(u, v)
		return 0.92 + math.sin((v + fbm(u, v, 3, 3, 231) * 0.2) * math.pi * 10) * 0.08 + (fbm(u, v, 8, 3, 232) - 0.5) * 0.15
	end,
}

-- Pattern and tile size in studs by material.
local BY_MATERIAL = {
	[Enum.Material.Plastic] = { "plastic", 8 },
	[Enum.Material.Concrete] = { "concrete", 8 },
	[Enum.Material.Grass] = { "grass", 6 },
	[Enum.Material.LeafyGrass] = { "grass", 5 },
	[Enum.Material.Sand] = { "sand", 6 },
	[Enum.Material.Wood] = { "wood", 4 },
	[Enum.Material.WoodPlanks] = { "planks", 8 },
	[Enum.Material.Brick] = { "brick", 8 },
	[Enum.Material.Cobblestone] = { "cobble", 8 },
	[Enum.Material.Pebble] = { "pebble", 6 },
	[Enum.Material.Slate] = { "slate", 8 },
	[Enum.Material.Rock] = { "rock", 8 },
	[Enum.Material.Basalt] = { "rock", 8 },
	[Enum.Material.Marble] = { "marble", 10 },
	[Enum.Material.Granite] = { "granite", 6 },
	[Enum.Material.Metal] = { "metal", 4 },
	[Enum.Material.DiamondPlate] = { "diamond", 4 },
	[Enum.Material.CorrodedMetal] = { "corroded", 6 },
	[Enum.Material.Fabric] = { "fabric", 2 },
	[Enum.Material.Ice] = { "ice", 8 },
	[Enum.Material.Glacier] = { "ice", 10 },
	[Enum.Material.Foil] = { "foil", 4 },
	[Enum.Material.Ground] = { "ground", 8 },
	[Enum.Material.Mud] = { "ground", 6 },
	[Enum.Material.Asphalt] = { "asphalt", 6 },
	[Enum.Material.Pavement] = { "pavement", 8 },
	[Enum.Material.Snow] = { "snow", 8 },
	[Enum.Material.Salt] = { "sand", 4 },
	[Enum.Material.Limestone] = { "layers", 8 },
	[Enum.Material.Sandstone] = { "layers", 8 },
	[Enum.Material.CrackedLava] = { "slate", 8 },
}

local cache = {}

-- { pixels, size, studs } for a material, or nil for untextured ones (SmoothPlastic, Neon, Glass).
function M.texture(material: Enum.Material)
	local spec = BY_MATERIAL[material]
	if not spec then
		return nil
	end
	local hit = cache[spec[1]]
	if not hit then
		local pattern = PATTERNS[spec[1]]
		local values = table.create(SIZE * SIZE)
		local sum = 0
		for y = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				local value = pattern((x + 0.5) / SIZE, (y + 0.5) / SIZE)
				values[y * SIZE + x + 1] = value
				sum += value
			end
		end
		-- mean ~1 keeps the part's colour on average
		local norm = 0.98 / (sum / (SIZE * SIZE))
		local pixels = buffer.create(SIZE * SIZE * 4)
		for i, value in values do
			local byte = math.clamp(math.floor(value * norm * 200 + 0.5), 0, 255)
			buffer.writeu32(pixels, (i - 1) * 4, bit32.bor(byte, bit32.lshift(byte, 8), bit32.lshift(byte, 16), 0xFF000000))
		end
		hit = pixels
		cache[spec[1]] = hit
	end
	return { hit, SIZE, spec[2] }
end

return M
