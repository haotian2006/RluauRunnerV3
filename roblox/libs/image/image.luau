--!native

local nativeImage = require(script.Parent.native)

local ImageCombineType = {
	BlendSourceOver = 1,
	Overwrite = 2,
	Add = 3,
	Multiply = 4,
	AlphaBlend = 5,
}

local ResamplerMode = {
	Default = 0, -- Bilinear filtering
	Pixelated = 1, -- Nearest neighbor
}

-- Convert enum to integer (handles both enum objects and direct integers)
local function enumToInt(value)
	if type(value) == "number" then
		return value
	elseif type(value) == "table" and value.Value then
		return value.Value
	elseif type(value) == "userdata" then
		return value.Value
	end
	return 2 -- Default to Overwrite
end

local function createImageBuffer(width, height)
	local size = width * height * 4
	return buffer.create(size)
end

local function getPixelIndex(x, y, width)
	return ((y * width) + x) * 4
end

local function min(a, b)
	return a < b and a or b
end

local function max(a, b)
	return a > b and a or b
end

local function isInBounds(x, y, width, height)
	return x >= 0 and x < width and y >= 0 and y < height
end

-- Bitpack RGBA into a single u32 (R | G << 8 | B << 16 | A << 24)
local function packRGBA(color, transparency)
	local r = math.floor(color.R * 255)
	local g = math.floor(color.G * 255)
	local b = math.floor(color.B * 255)
	local a = math.floor((1 - transparency) * 255)

	return r + (g * 256) + (b * 65536) + (a * 16777216)
end

-- Unpack u32 to RGBA components
local function unpackRGBA(packed)
	local r = packed % 256
	local g = math.floor(packed / 256) % 256
	local b = math.floor(packed / 65536) % 256
	local a = math.floor(packed / 16777216) % 256
	return r, g, b, a
end

-- Blend two colors based on combine type
local function blendPixels(srcPacked, dstPacked, combineType)
	local sr, sg, sb, sa = unpackRGBA(srcPacked)
	local dr, dg, db, da = unpackRGBA(dstPacked)

	if combineType == 2 then -- Overwrite
		return srcPacked
	elseif combineType == 3 then -- Add
		local r = min(255, sr + dr)
		local g = min(255, sg + dg)
		local b = min(255, sb + db)
		local a = min(255, sa + da)
		return r + (g * 256) + (b * 65536) + (a * 16777216)
	elseif combineType == 4 then -- Multiply
		local r = math.floor((sr / 255) * (dr / 255) * 255)
		local g = math.floor((sg / 255) * (dg / 255) * 255)
		local b = math.floor((sb / 255) * (db / 255) * 255)
		local a = math.floor((sa / 255) * (da / 255) * 255)
		return r + (g * 256) + (b * 65536) + (a * 16777216)
	elseif combineType == 5 then -- AlphaBlend
		local srcAlpha = sa / 255
		local r = math.floor(sr * srcAlpha + dr * (1 - srcAlpha))
		local g = math.floor(sg * srcAlpha + dg * (1 - srcAlpha))
		local b = math.floor(sb * srcAlpha + db * (1 - srcAlpha))
		return r + (g * 256) + (b * 65536) + (sa * 16777216)
	else -- BlendSourceOver (1) or default
		local srcAlpha = sa / 255
		local dstAlpha = da / 255
		local outAlpha = srcAlpha + dstAlpha * (1 - srcAlpha)

		if outAlpha == 0 then
			return 0
		end

		local r = math.floor((sr * srcAlpha + dr * dstAlpha * (1 - srcAlpha)) / outAlpha)
		local g = math.floor((sg * srcAlpha + dg * dstAlpha * (1 - srcAlpha)) / outAlpha)
		local b = math.floor((sb * srcAlpha + db * dstAlpha * (1 - srcAlpha)) / outAlpha)
		local a = math.floor(outAlpha * 255)
		return r + (g * 256) + (b * 65536) + (a * 16777216)
	end
end

-- Custom EditableImage class
Image = {}
Image.__index = Image

function Image.new(size: Vector2)
	if not (typeof(size) == "Vector2" or typeof(size) == "Vector3") then
		error("arg 1: size must be a Vector2 or Vector3, got " .. typeof(size), 2)
	end
	if not (size.X > 0 and size.Y > 0) then
		error("arg 1: size X and Y must be positive", 2)
	end

	local self = setmetatable({}, Image)

	-- Store size with clamping
	local width = max(1, min(math.floor(size.X), 1024))
	local height = max(1, min(math.floor(size.Y), 1024))
	self.Size = Vector2.new(width, height)

	-- Create internal buffer to hold image data
	self.imageBuffer = createImageBuffer(width, height)

	return self
end

-- Write a pixel to the buffer
function Image:SetPixel(x: number, y: number, color: Color3, transparency: number?, combineType: any?)
	transparency = transparency or 0
	if type(x) ~= "number" then
		error("arg 1: x must be a number, got " .. type(x), 2)
	end
	if type(y) ~= "number" then
		error("arg 2: y must be a number, got " .. type(y), 2)
	end
	if typeof(color) ~= "Color3" then
		error("arg 3: color must be a Color3, got " .. typeof(color), 2)
	end
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y

	if not isInBounds(x, y, width, height) then
		return
	end

	local idx = getPixelIndex(x, y, width)
	local packed = packRGBA(color, transparency)

	if combineType then
		local mode = enumToInt(combineType)
		if mode ~= 2 then
			local existing = buffer.readu32(imgBuffer, idx)
			packed = blendPixels(packed, existing, mode)
		end
	end

	buffer.writeu32(imgBuffer, idx, packed)
end

-- Read a pixel from the buffer
function Image:GetPixel(x: number, y: number)
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y

	if not isInBounds(x, y, width, height) then
		return
	end

	local idx = getPixelIndex(x, y, width)

	local r = buffer.readu8(imgBuffer, idx) / 255
	local g = buffer.readu8(imgBuffer, idx + 1) / 255
	local b = buffer.readu8(imgBuffer, idx + 2) / 255
	local a = buffer.readu8(imgBuffer, idx + 3) / 255

	return Color3.new(r, g, b), 1 - a
end

-- Fill the entire image with a color
function Image:Fill(color: Color3, transparency: number?)
	transparency = transparency or 0
	if typeof(color) ~= "Color3" then
		error("arg 1: color must be a Color3, got " .. typeof(color), 2)
	end
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	local packed = packRGBA(color, transparency)

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			buffer.writeu32(imgBuffer, idx, packed)
		end
	end
end

-- Draw a rectangle
function Image:DrawRectangle(position: Vector2, size: Vector2, color: Color3, transparency: number?, combineType: any?)
	transparency = transparency or 0
	if not (typeof(position) == "Vector2" or typeof(position) == "Vector3") then
		error("arg 1: position must be a Vector2 or Vector3, got " .. typeof(position), 2)
	end
	if not (typeof(size) == "Vector2" or typeof(size) == "Vector3") then
		error("arg 2: size must be a Vector2 or Vector3, got " .. typeof(size), 2)
	end
	if not (size.X > 0 and size.Y > 0) then
		error("arg 2: size X and Y must be positive", 2)
	end
	if typeof(color) ~= "Color3" then
		error("arg 3: color must be a Color3, got " .. typeof(color), 2)
	end

	local imgBuffer = self.imageBuffer
	local width = self.Size.X
	local packed = packRGBA(color, transparency)

	local startX = math.floor(position.X)
	local startY = math.floor(position.Y)
	local endX = math.floor(position.X + size.X)
	local endY = math.floor(position.Y + size.Y)

	startX = max(0, min(startX, self.Size.X - 1))
	startY = max(0, min(startY, self.Size.Y - 1))
	endX = max(0, min(endX, self.Size.X))
	endY = max(0, min(endY, self.Size.Y))

	local mode = combineType and enumToInt(combineType) or 2
	local needsBlend = mode ~= 2

	for y = startY, endY - 1 do
		for x = startX, endX - 1 do
			local idx = getPixelIndex(x, y, width)
			if needsBlend then
				local existing = buffer.readu32(imgBuffer, idx)
				buffer.writeu32(imgBuffer, idx, blendPixels(packed, existing, mode))
			else
				buffer.writeu32(imgBuffer, idx, packed)
			end
		end
	end
end

-- Draw an anti-aliased line
function Image:DrawLine(p1: Vector2, p2: Vector2, color: Color3, transparency: number?, combineType: any?)
	transparency = transparency or 0
	if not (typeof(p1) == "Vector2" or typeof(p1) == "Vector3") then
		error("arg 1: p1 must be a Vector2 or Vector3, got " .. typeof(p1), 2)
	end
	if not (typeof(p2) == "Vector2" or typeof(p2) == "Vector3") then
		error("arg 2: p2 must be a Vector2 or Vector3, got " .. typeof(p2), 2)
	end
	if typeof(color) ~= "Color3" then
		error("arg 3: color must be a Color3, got " .. typeof(color), 2)
	end

	combineType = enumToInt(combineType or ImageCombineType.AlphaBlend)

	local x0, y0 = p1.X, p1.Y
	local x1, y1 = p2.X, p2.Y

	-- Xiaolin Wu's line algorithm for anti-aliasing
	local function ipart(x)
		return math.floor(x)
	end

	local function fpart(x)
		return x - math.floor(x)
	end

	local function rfpart(x)
		return 1 - fpart(x)
	end

	local steep = math.abs(y1 - y0) > math.abs(x1 - x0)

	if steep then
		x0, y0 = y0, x0
		x1, y1 = y1, x1
	end

	if x0 > x1 then
		x0, x1 = x1, x0
		y0, y1 = y1, y0
	end

	local dx = x1 - x0
	local dy = y1 - y0
	local gradient = dx == 0 and 1 or dy / dx

	-- Handle first endpoint
	local xend = math.floor(x0 + 0.5)
	local yend = y0 + gradient * (xend - x0)
	local xgap = rfpart(x0 + 0.5)
	local xpxl1 = xend
	local ypxl1 = ipart(yend)

	if steep then
		self:SetPixel(ypxl1, xpxl1, color, transparency + (1 - transparency) * fpart(yend) * xgap, combineType)
		self:SetPixel(ypxl1 + 1, xpxl1, color, transparency + (1 - transparency) * rfpart(yend) * xgap, combineType)
	else
		self:SetPixel(xpxl1, ypxl1, color, transparency + (1 - transparency) * fpart(yend) * xgap, combineType)
		self:SetPixel(xpxl1, ypxl1 + 1, color, transparency + (1 - transparency) * rfpart(yend) * xgap, combineType)
	end

	local intery = yend + gradient

	-- Handle second endpoint
	xend = math.floor(x1 + 0.5)
	yend = y1 + gradient * (xend - x1)
	xgap = fpart(x1 + 0.5)
	local xpxl2 = xend
	local ypxl2 = ipart(yend)

	if steep then
		self:SetPixel(ypxl2, xpxl2, color, transparency + (1 - transparency) * fpart(yend) * xgap, combineType)
		self:SetPixel(ypxl2 + 1, xpxl2, color, transparency + (1 - transparency) * rfpart(yend) * xgap, combineType)
	else
		self:SetPixel(xpxl2, ypxl2, color, transparency + (1 - transparency) * fpart(yend) * xgap, combineType)
		self:SetPixel(xpxl2, ypxl2 + 1, color, transparency + (1 - transparency) * rfpart(yend) * xgap, combineType)
	end

	-- Main loop
	for x = xpxl1 + 1, xpxl2 - 1 do
		if steep then
			self:SetPixel(ipart(intery), x, color, transparency + (1 - transparency) * rfpart(intery), combineType)
			self:SetPixel(ipart(intery) + 1, x, color, transparency + (1 - transparency) * fpart(intery), combineType)
		else
			self:SetPixel(x, ipart(intery), color, transparency + (1 - transparency) * rfpart(intery), combineType)
			self:SetPixel(x, ipart(intery) + 1, color, transparency + (1 - transparency) * fpart(intery), combineType)
		end
		intery = intery + gradient
	end
end

-- Draw a circle
function Image:DrawCircle(center: Vector2, radius: number, color: Color3, transparency: number?, combineType: any?)
	transparency = transparency or 0
	if not (typeof(center) == "Vector2" or typeof(center) == "Vector3") then
		error("arg 1: center must be a Vector2 or Vector3, got " .. typeof(center), 2)
	end
	if not (type(radius) == "number" and radius > 0) then
		error("arg 2: radius must be a positive number, got " .. type(radius) .. " with value " .. tostring(radius), 2)
	end
	if typeof(color) ~= "Color3" then
		error("arg 3: color must be a Color3, got " .. typeof(color), 2)
	end

	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	local packed = packRGBA(color, transparency)

	local cx = math.floor(center.X)
	local cy = math.floor(center.Y)
	local r = radius
	local rSquared = r * r

	-- Bounding box for circle
	local minX = max(0, math.floor(cx - r))
	local maxX = min(width - 1, math.floor(cx + r))
	local minY = max(0, math.floor(cy - r))
	local maxY = min(height - 1, math.floor(cy + r))

	local mode = combineType and enumToInt(combineType) or 2
	local needsBlend = mode ~= 2

	for y = minY, maxY do
		for x = minX, maxX do
			local dx = x - cx
			local dy = y - cy
			local distSquared = dx * dx + dy * dy

			if distSquared <= rSquared then
				local idx = getPixelIndex(x, y, width)
				if needsBlend then
					local existing = buffer.readu32(imgBuffer, idx)
					buffer.writeu32(imgBuffer, idx, blendPixels(packed, existing, mode))
				else
					buffer.writeu32(imgBuffer, idx, packed)
				end
			end
		end
	end
end

-- Get raw buffer access
function Image:GetBuffer()
	return self.imageBuffer
end

-- Clone the buffer
function Image:Clone()
	local clone = Image.new(self.Size)
	local imgBuffer = self.imageBuffer
	local cloneBuffer = clone.imageBuffer
	local size = self.Size.X * self.Size.Y * 4

	buffer.copy(cloneBuffer, 0, imgBuffer, 0, size)

	return clone
end

-- Read a rectangular region of pixels into a buffer
function Image:ReadPixelsBuffer(position: Vector2, size: Vector2)
	if not (typeof(position) == "Vector2" or typeof(position) == "Vector3") then
		error("arg 1: position must be a Vector2 or Vector3, got " .. typeof(position), 2)
	end
	if not (typeof(size) == "Vector2" or typeof(size) == "Vector3") then
		error("arg 2: size must be a Vector2 or Vector3, got " .. typeof(size), 2)
	end
	if not (size.X > 0 and size.Y > 0) then
		error("arg 2: size X and Y must be positive", 2)
	end

	local startX = math.floor(position.X)
	local startY = math.floor(position.Y)
	local regionWidth = math.floor(size.X)
	local regionHeight = math.floor(size.Y)

	-- Clamp to image bounds
	startX = max(0, min(startX, self.Size.X - 1))
	startY = max(0, min(startY, self.Size.Y - 1))
	regionWidth = max(0, min(regionWidth, self.Size.X - startX))
	regionHeight = max(0, min(regionHeight, self.Size.Y - startY))

	-- Create output buffer
	local outputBuffer = buffer.create(regionWidth * regionHeight * 4)
	local imgBuffer = self.imageBuffer
	local imgWidth = self.Size.X

	-- Copy pixels row by row
	for y = 0, regionHeight - 1 do
		for x = 0, regionWidth - 1 do
			local srcIdx = getPixelIndex(startX + x, startY + y, imgWidth)
			local dstIdx = getPixelIndex(x, y, regionWidth)

			-- Copy RGBA bytes
			buffer.writeu8(outputBuffer, dstIdx, buffer.readu8(imgBuffer, srcIdx))
			buffer.writeu8(outputBuffer, dstIdx + 1, buffer.readu8(imgBuffer, srcIdx + 1))
			buffer.writeu8(outputBuffer, dstIdx + 2, buffer.readu8(imgBuffer, srcIdx + 2))
			buffer.writeu8(outputBuffer, dstIdx + 3, buffer.readu8(imgBuffer, srcIdx + 3))
		end
	end

	return outputBuffer
end

-- Write a rectangular region of pixels from a buffer
function Image:WritePixelsBuffer(position: Vector2, size: Vector2, pixelBuffer: buffer)
	if not (typeof(position) == "Vector2" or typeof(position) == "Vector3") then
		error("arg 1: position must be a Vector2 or Vector3, got " .. typeof(position), 2)
	end
	if not (typeof(size) == "Vector2" or typeof(size) == "Vector3") then
		error("arg 2: size must be a Vector2 or Vector3, got " .. typeof(size), 2)
	end
	if not (size.X > 0 and size.Y > 0) then
		error("arg 2: size X and Y must be positive", 2)
	end
	if type(pixelBuffer) ~= "buffer" then
		error("arg 3: pixelBuffer must be a buffer, got " .. type(pixelBuffer), 2)
	end

	local startX = math.floor(position.X)
	local startY = math.floor(position.Y)
	local regionWidth = math.floor(size.X)
	local regionHeight = math.floor(size.Y)

	-- Clamp to image bounds
	startX = max(0, min(startX, self.Size.X - 1))
	startY = max(0, min(startY, self.Size.Y - 1))
	regionWidth = max(0, min(regionWidth, self.Size.X - startX))
	regionHeight = max(0, min(regionHeight, self.Size.Y - startY))

	local imgBuffer = self.imageBuffer
	local imgWidth = self.Size.X

	-- Copy pixels row by row from input buffer
	for y = 0, regionHeight - 1 do
		for x = 0, regionWidth - 1 do
			local srcIdx = getPixelIndex(x, y, regionWidth)
			local dstIdx = getPixelIndex(startX + x, startY + y, imgWidth)

			-- Copy RGBA bytes
			buffer.writeu8(imgBuffer, dstIdx, buffer.readu8(pixelBuffer, srcIdx))
			buffer.writeu8(imgBuffer, dstIdx + 1, buffer.readu8(pixelBuffer, srcIdx + 1))
			buffer.writeu8(imgBuffer, dstIdx + 2, buffer.readu8(pixelBuffer, srcIdx + 2))
			buffer.writeu8(imgBuffer, dstIdx + 3, buffer.readu8(pixelBuffer, srcIdx + 3))
		end
	end
end

-- Simple 5x3 bitmap font (uppercase letters, numbers, and basic symbols)
local FONT_CHARS = {
	["A"] = { 0x7, 0x5, 0x7, 0x5, 0x5 },
	["B"] = { 0x6, 0x5, 0x6, 0x5, 0x6 },
	["C"] = { 0x7, 0x4, 0x4, 0x4, 0x7 },
	["D"] = { 0x6, 0x5, 0x5, 0x5, 0x6 },
	["E"] = { 0x7, 0x4, 0x6, 0x4, 0x7 },
	["F"] = { 0x7, 0x4, 0x6, 0x4, 0x4 },
	["G"] = { 0x7, 0x4, 0x5, 0x5, 0x7 },
	["H"] = { 0x5, 0x5, 0x7, 0x5, 0x5 },
	["I"] = { 0x7, 0x2, 0x2, 0x2, 0x7 },
	["J"] = { 0x7, 0x1, 0x1, 0x5, 0x7 },
	["K"] = { 0x5, 0x5, 0x6, 0x5, 0x5 },
	["L"] = { 0x4, 0x4, 0x4, 0x4, 0x7 },
	["M"] = { 0x5, 0x7, 0x7, 0x5, 0x5 },
	["N"] = { 0x5, 0x7, 0x7, 0x7, 0x5 },
	["O"] = { 0x7, 0x5, 0x5, 0x5, 0x7 },
	["P"] = { 0x7, 0x5, 0x7, 0x4, 0x4 },
	["Q"] = { 0x7, 0x5, 0x5, 0x7, 0x1 },
	["R"] = { 0x7, 0x5, 0x6, 0x5, 0x5 },
	["S"] = { 0x7, 0x4, 0x7, 0x1, 0x7 },
	["T"] = { 0x7, 0x2, 0x2, 0x2, 0x2 },
	["U"] = { 0x5, 0x5, 0x5, 0x5, 0x7 },
	["V"] = { 0x5, 0x5, 0x5, 0x5, 0x2 },
	["W"] = { 0x5, 0x5, 0x7, 0x7, 0x5 },
	["X"] = { 0x5, 0x5, 0x2, 0x5, 0x5 },
	["Y"] = { 0x5, 0x5, 0x2, 0x2, 0x2 },
	["Z"] = { 0x7, 0x1, 0x2, 0x4, 0x7 },
	["0"] = { 0x7, 0x5, 0x5, 0x5, 0x7 },
	["1"] = { 0x2, 0x6, 0x2, 0x2, 0x7 },
	["2"] = { 0x7, 0x1, 0x7, 0x4, 0x7 },
	["3"] = { 0x7, 0x1, 0x7, 0x1, 0x7 },
	["4"] = { 0x5, 0x5, 0x7, 0x1, 0x1 },
	["5"] = { 0x7, 0x4, 0x7, 0x1, 0x7 },
	["6"] = { 0x7, 0x4, 0x7, 0x5, 0x7 },
	["7"] = { 0x7, 0x1, 0x1, 0x1, 0x1 },
	["8"] = { 0x7, 0x5, 0x7, 0x5, 0x7 },
	["9"] = { 0x7, 0x5, 0x7, 0x1, 0x7 },
	[" "] = { 0x0, 0x0, 0x0, 0x0, 0x0 },
	["."] = { 0x0, 0x0, 0x0, 0x0, 0x2 },
	[","] = { 0x0, 0x0, 0x0, 0x2, 0x4 },
	["!"] = { 0x2, 0x2, 0x2, 0x0, 0x2 },
	["?"] = { 0x7, 0x1, 0x2, 0x0, 0x2 },
	[":"] = { 0x0, 0x2, 0x0, 0x2, 0x0 },
	["-"] = { 0x0, 0x0, 0x7, 0x0, 0x0 },
	["+"] = { 0x0, 0x2, 0x7, 0x2, 0x0 },
	["="] = { 0x0, 0x7, 0x0, 0x7, 0x0 },
	["*"] = { 0x0, 0x5, 0x2, 0x5, 0x0 },
	["/"] = { 0x1, 0x1, 0x2, 0x4, 0x4 },
	["("] = { 0x2, 0x4, 0x4, 0x4, 0x2 },
	[")"] = { 0x2, 0x1, 0x1, 0x1, 0x2 },
	["<"] = { 0x1, 0x2, 0x4, 0x2, 0x1 },
	[">"] = { 0x4, 0x2, 0x1, 0x2, 0x4 },
}

-- Draw text on the image
local text2d
local ALIGN = { Left = true, Center = true, Right = true }

-- options: { Size, Font (Enum.Font), Bold, Align, MaxWidth, LineHeight, StrokeColor,
-- StrokeThickness, StrokeTransparency }. A number keeps the old scale meaning: capitals
-- about 5 * scale px tall with position at their top-left. Returns the text's size.
function Image:DrawText(text: string, position: Vector2, color: Color3, transparency: number?, options: any?)
	if type(text) ~= "string" then
		error("arg 1: text must be a string, got " .. type(text), 2)
	end
	if not (typeof(position) == "Vector2" or typeof(position) == "Vector3") then
		error("arg 2: position must be a Vector2 or Vector3, got " .. typeof(position), 2)
	end
	if typeof(color) ~= "Color3" then
		error("arg 3: color must be a Color3, got " .. typeof(color), 2)
	end
	if transparency ~= nil and type(transparency) ~= "number" then
		error("arg 4: transparency must be a number, got " .. typeof(transparency), 2)
	end
	local o = {}
	if type(options) == "table" then
		local size = options.Size or 14
		if type(size) ~= "number" or size <= 0 then
			error("arg 5: Size must be a positive number", 2)
		end
		o.size = size
		local font = options.Font
		if font ~= nil and not (typeof(font) == "EnumItem" and font.EnumType == Enum.Font) then
			error("arg 5: Font must be an Enum.Font", 2)
		end
		o.font = font or (if options.Bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans)
		local align = options.Align
		if typeof(align) == "EnumItem" then
			align = align.Name
		end
		if align ~= nil and not ALIGN[align] then
			error("arg 5: Align must be Left, Center or Right", 2)
		end
		o.align = align
		local maxWidth = options.MaxWidth
		if maxWidth ~= nil and (type(maxWidth) ~= "number" or maxWidth <= 0) then
			error("arg 5: MaxWidth must be a positive number", 2)
		end
		o.maxWidth = maxWidth
		if options.LineHeight ~= nil and type(options.LineHeight) ~= "number" then
			error("arg 5: LineHeight must be a number", 2)
		end
		o.lineHeight = options.LineHeight
		if options.StrokeColor ~= nil then
			if typeof(options.StrokeColor) ~= "Color3" then
				error("arg 5: StrokeColor must be a Color3", 2)
			end
			o.stroke = options.StrokeColor
			o.strokeThickness = tonumber(options.StrokeThickness) or 1
			o.strokeTransparency = tonumber(options.StrokeTransparency) or 0
		end
	elseif options == nil or type(options) == "number" then
		local scale = options or 1
		if scale <= 0 then
			error("arg 5: scale must be a positive number, got " .. tostring(scale), 2)
		end
		o.size = math.max(4, 9.5 * scale)
		o.capTop = true
	else
		error("arg 5: expected a scale number or an options table, got " .. typeof(options), 2)
	end
	text2d = text2d or require(script.Parent.render2d)
	local alpha = 1 - math.clamp(transparency or 0, 0, 1)
	return text2d.drawText(self.imageBuffer, self.Size.X, self.Size.Y, text, position.X, position.Y, color, alpha, o)
end

-- Draw another image onto this image with transformations
function Image:DrawImageTransformed(
	position: Vector2,
	scale: Vector2,
	rotation: number,
	sourceImage: any,
	options: any?
)
	if not (typeof(position) == "Vector2" or typeof(position) == "Vector3") then
		error("arg 1: position must be a Vector2 or Vector3, got " .. typeof(position), 2)
	end
	if not (typeof(scale) == "Vector2" or typeof(scale) == "Vector3") then
		error("arg 2: scale must be a Vector2 or Vector3, got " .. typeof(scale), 2)
	end
	if type(rotation) ~= "number" then
		error("arg 3: rotation must be a number, got " .. type(rotation), 2)
	end
	if not (type(sourceImage) == "table" and sourceImage.imageBuffer) then
		error("arg 4: sourceImage must be an Image instance, got " .. type(sourceImage), 2)
	end
	if options and type(options) ~= "table" then
		error("arg 5: options must be a table, got " .. type(options), 2)
	end

	options = options or {}
	local combineType = options.CombineType or options.combineType or 5 -- Default to AlphaBlend
	local resamplerMode = enumToInt(options.ResamplerMode or options.resamplerMode or ResamplerMode.Default)
	local pivotPoint = options.PivotPoint
		or options.pivotPoint
		or Vector2.new(sourceImage.Size.X / 2, sourceImage.Size.Y / 2)

	-- Get source image dimensions
	local srcWidth = sourceImage.Size.X
	local srcHeight = sourceImage.Size.Y
	local srcBuffer = sourceImage.imageBuffer

	-- Convert rotation from degrees to radians
	local rotationRad = math.rad(rotation)
	local cosTheta = math.cos(rotationRad)
	local sinTheta = math.sin(rotationRad)

	-- Use pivot point from options
	local centerX = pivotPoint.X
	local centerY = pivotPoint.Y

	-- Calculate transformed bounds to determine which pixels to iterate
	local corners = {
		{ 0, 0 },
		{ srcWidth, 0 },
		{ 0, srcHeight },
		{ srcWidth, srcHeight },
	}

	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge

	for _, corner in ipairs(corners) do
		local x, y = corner[1], corner[2]
		-- Translate to pivot point
		x = x - centerX
		y = y - centerY
		-- Apply scale
		x = x * scale.X
		y = y * scale.Y
		-- Apply rotation
		local rotX = x * cosTheta - y * sinTheta
		local rotY = x * sinTheta + y * cosTheta
		-- Translate to position
		rotX = rotX + position.X
		rotY = rotY + position.Y

		minX = min(minX, rotX)
		maxX = max(maxX, rotX)
		minY = min(minY, rotY)
		maxY = max(maxY, rotY)
	end

	-- Clamp to destination bounds
	minX = max(0, math.floor(minX))
	minY = max(0, math.floor(minY))
	maxX = min(self.Size.X - 1, math.ceil(maxX))
	maxY = min(self.Size.Y - 1, math.ceil(maxY))

	-- Determine if we should use bilinear sampling
	local useBilinear = resamplerMode == ResamplerMode.Default

	-- Iterate over destination pixels
	for dy = minY, maxY do
		for dx = minX, maxX do
			-- Transform destination coordinates to source space
			-- Translate to rotation origin
			local px = dx - position.X
			local py = dy - position.Y

			-- Apply inverse rotation
			local rx = px * cosTheta + py * sinTheta
			local ry = -px * sinTheta + py * cosTheta

			-- Apply inverse scale
			rx = rx / scale.X
			ry = ry / scale.Y

			-- Translate back from pivot point
			rx = rx + centerX
			ry = ry + centerY

			if useBilinear then
				-- Bilinear interpolation
				local x0 = math.floor(rx)
				local y0 = math.floor(ry)
				local x1 = x0 + 1
				local y1 = y0 + 1

				local fx = rx - x0
				local fy = ry - y0

				-- Check bounds for all 4 sample points
				local inBounds00 = x0 >= 0 and x0 < srcWidth and y0 >= 0 and y0 < srcHeight
				local inBounds10 = x1 >= 0 and x1 < srcWidth and y0 >= 0 and y0 < srcHeight
				local inBounds01 = x0 >= 0 and x0 < srcWidth and y1 >= 0 and y1 < srcHeight
				local inBounds11 = x1 >= 0 and x1 < srcWidth and y1 >= 0 and y1 < srcHeight

				if inBounds00 or inBounds10 or inBounds01 or inBounds11 then
					-- Sample the 4 pixels
					local function samplePixel(sx, sy)
						if sx >= 0 and sx < srcWidth and sy >= 0 and sy < srcHeight then
							local srcIdx = getPixelIndex(sx, sy, srcWidth)
							return {
								buffer.readu8(srcBuffer, srcIdx),
								buffer.readu8(srcBuffer, srcIdx + 1),
								buffer.readu8(srcBuffer, srcIdx + 2),
								buffer.readu8(srcBuffer, srcIdx + 3),
							}
						end
						return { 0, 0, 0, 0 }
					end

					local p00 = samplePixel(x0, y0)
					local p10 = samplePixel(x1, y0)
					local p01 = samplePixel(x0, y1)
					local p11 = samplePixel(x1, y1)

					-- Bilinear interpolation
					local r = (
						p00[1] * (1 - fx) * (1 - fy)
							+ p10[1] * fx * (1 - fy)
							+ p01[1] * (1 - fx) * fy
							+ p11[1] * fx * fy
					)
					local g = (
						p00[2] * (1 - fx) * (1 - fy)
							+ p10[2] * fx * (1 - fy)
							+ p01[2] * (1 - fx) * fy
							+ p11[2] * fx * fy
					)
					local b = (
						p00[3] * (1 - fx) * (1 - fy)
							+ p10[3] * fx * (1 - fy)
							+ p01[3] * (1 - fx) * fy
							+ p11[3] * fx * fy
					)
					local a = (
						p00[4] * (1 - fx) * (1 - fy)
							+ p10[4] * fx * (1 - fy)
							+ p01[4] * (1 - fx) * fy
							+ p11[4] * fx * fy
					)

					local color = Color3.new(r / 255, g / 255, b / 255)
					local transparency = math.clamp(1 - a / 255, 0, 1)
					self:SetPixel(dx, dy, color, transparency, combineType)
				end
			else
				-- Nearest neighbor (pixelated)
				local sx = math.floor(rx + 0.5)
				local sy = math.floor(ry + 0.5)

				if sx >= 0 and sx < srcWidth and sy >= 0 and sy < srcHeight then
					-- Read source pixel
					local srcIdx = getPixelIndex(sx, sy, srcWidth)
					local r = buffer.readu8(srcBuffer, srcIdx)
					local g = buffer.readu8(srcBuffer, srcIdx + 1)
					local b = buffer.readu8(srcBuffer, srcIdx + 2)
					local a = buffer.readu8(srcBuffer, srcIdx + 3)

					local color = Color3.new(r / 255, g / 255, b / 255)
					local transparency = math.clamp(1 - a / 255, 0, 1)
					self:SetPixel(dx, dy, color, transparency, combineType)
				end
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- IMAGE EXTENSIONS
-- Paste these methods into your Image module, above the `return Image.new` line.
-- ─────────────────────────────────────────────────────────────────────────────

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  COLOR ADJUSTMENTS                                                      │
-- └─────────────────────────────────────────────────────────────────────────┘

-- Convert image to grayscale in-place (preserves alpha).
function Image:Grayscale()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			local r   = buffer.readu8(imgBuffer, idx)
			local g   = buffer.readu8(imgBuffer, idx + 1)
			local b   = buffer.readu8(imgBuffer, idx + 2)
			local lum = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
			buffer.writeu8(imgBuffer, idx,     lum)
			buffer.writeu8(imgBuffer, idx + 1, lum)
			buffer.writeu8(imgBuffer, idx + 2, lum)
		end
	end
end

-- Invert RGB channels in-place (preserves alpha).
function Image:Invert()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			buffer.writeu8(imgBuffer, idx,     255 - buffer.readu8(imgBuffer, idx))
			buffer.writeu8(imgBuffer, idx + 1, 255 - buffer.readu8(imgBuffer, idx + 1))
			buffer.writeu8(imgBuffer, idx + 2, 255 - buffer.readu8(imgBuffer, idx + 2))
		end
	end
end

-- Add `amount` (-255..255) to each RGB channel (preserves alpha).
function Image:AdjustBrightness(amount: number)
	if type(amount) ~= "number" then
		error("arg 1: amount must be a number, got " .. type(amount), 2)
	end
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			for ch = 0, 2 do
				local v = math.clamp(buffer.readu8(imgBuffer, idx + ch) + amount, 0, 255)
				buffer.writeu8(imgBuffer, idx + ch, math.floor(v))
			end
		end
	end
end

-- Multiply contrast around the midpoint 128.
-- factor > 1 increases contrast, 0 < factor < 1 decreases it.
function Image:AdjustContrast(factor: number)
	if type(factor) ~= "number" then
		error("arg 1: factor must be a number, got " .. type(factor), 2)
	end
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			for ch = 0, 2 do
				local v = math.clamp((buffer.readu8(imgBuffer, idx + ch) - 128) * factor + 128, 0, 255)
				buffer.writeu8(imgBuffer, idx + ch, math.floor(v))
			end
		end
	end
end

-- Adjust saturation. factor=0 → grayscale, factor=1 → unchanged, factor>1 → vivid.
function Image:AdjustSaturation(factor: number)
	if type(factor) ~= "number" then
		error("arg 1: factor must be a number, got " .. type(factor), 2)
	end
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			local r   = buffer.readu8(imgBuffer, idx)
			local g   = buffer.readu8(imgBuffer, idx + 1)
			local b   = buffer.readu8(imgBuffer, idx + 2)
			local lum = 0.299 * r + 0.587 * g + 0.114 * b
			buffer.writeu8(imgBuffer, idx,     math.floor(math.clamp(lum + (r - lum) * factor, 0, 255)))
			buffer.writeu8(imgBuffer, idx + 1, math.floor(math.clamp(lum + (g - lum) * factor, 0, 255)))
			buffer.writeu8(imgBuffer, idx + 2, math.floor(math.clamp(lum + (b - lum) * factor, 0, 255)))
		end
	end
end

-- Tint the image toward `color` by `strength` (0..1).
function Image:Tint(color: Color3, strength: number)
	if typeof(color) ~= "Color3" then
		error("arg 1: color must be a Color3, got " .. typeof(color), 2)
	end
	strength = math.clamp(strength or 0.5, 0, 1)
	local tr = color.R * 255
	local tg = color.G * 255
	local tb = color.B * 255
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			local r   = buffer.readu8(imgBuffer, idx)
			local g   = buffer.readu8(imgBuffer, idx + 1)
			local b   = buffer.readu8(imgBuffer, idx + 2)
			buffer.writeu8(imgBuffer, idx,     math.floor(r + (tr - r) * strength))
			buffer.writeu8(imgBuffer, idx + 1, math.floor(g + (tg - g) * strength))
			buffer.writeu8(imgBuffer, idx + 2, math.floor(b + (tb - b) * strength))
		end
	end
end

-- Posterize to black/white based on luminance cutoff (0..255).
function Image:Threshold(cutoff: number)
	cutoff = cutoff or 128
	if type(cutoff) ~= "number" then
		error("arg 1: cutoff must be a number, got " .. type(cutoff), 2)
	end
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			local r   = buffer.readu8(imgBuffer, idx)
			local g   = buffer.readu8(imgBuffer, idx + 1)
			local b   = buffer.readu8(imgBuffer, idx + 2)
			local lum = 0.299 * r + 0.587 * g + 0.114 * b
			local v   = lum >= cutoff and 255 or 0
			buffer.writeu8(imgBuffer, idx,     v)
			buffer.writeu8(imgBuffer, idx + 1, v)
			buffer.writeu8(imgBuffer, idx + 2, v)
		end
	end
end

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  CONVOLUTION HELPERS (internal)                                         │
-- └─────────────────────────────────────────────────────────────────────────┘

-- Apply a separable 1-D kernel horizontally then vertically (faster than 2-D).
-- `kernel` is a {-r..r} weight table (index 1 = weight for offset -(#kernel//2)).
local function applySeparable(imgBuffer, width, height, kernel)
	if nativeImage.separable(imgBuffer, width, height, kernel) then
		return
	end
	local radius = math.floor(#kernel / 2)
	local tmp    = buffer.create(width * height * 4)

	-- Horizontal pass
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local r, g, b, a = 0, 0, 0, 0
			for ki = 1, #kernel do
				local sx = math.clamp(x + ki - 1 - radius, 0, width - 1)
				local idx = getPixelIndex(sx, y, width)
				local w   = kernel[ki]
				r = r + buffer.readu8(imgBuffer, idx)     * w
				g = g + buffer.readu8(imgBuffer, idx + 1) * w
				b = b + buffer.readu8(imgBuffer, idx + 2) * w
				a = a + buffer.readu8(imgBuffer, idx + 3) * w
			end
			local dstIdx = getPixelIndex(x, y, width)
			buffer.writeu8(tmp, dstIdx,     math.clamp(math.floor(r), 0, 255))
			buffer.writeu8(tmp, dstIdx + 1, math.clamp(math.floor(g), 0, 255))
			buffer.writeu8(tmp, dstIdx + 2, math.clamp(math.floor(b), 0, 255))
			buffer.writeu8(tmp, dstIdx + 3, math.clamp(math.floor(a), 0, 255))
		end
	end

	-- Vertical pass (reads from tmp, writes back to imgBuffer)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local r, g, b, a = 0, 0, 0, 0
			for ki = 1, #kernel do
				local sy  = math.clamp(y + ki - 1 - radius, 0, height - 1)
				local idx = getPixelIndex(x, sy, width)
				local w   = kernel[ki]
				r = r + buffer.readu8(tmp, idx)     * w
				g = g + buffer.readu8(tmp, idx + 1) * w
				b = b + buffer.readu8(tmp, idx + 2) * w
				a = a + buffer.readu8(tmp, idx + 3) * w
			end
			local dstIdx = getPixelIndex(x, y, width)
			buffer.writeu8(imgBuffer, dstIdx,     math.clamp(math.floor(r), 0, 255))
			buffer.writeu8(imgBuffer, dstIdx + 1, math.clamp(math.floor(g), 0, 255))
			buffer.writeu8(imgBuffer, dstIdx + 2, math.clamp(math.floor(b), 0, 255))
			buffer.writeu8(imgBuffer, dstIdx + 3, math.clamp(math.floor(a), 0, 255))
		end
	end
end

-- Apply a non-separable 2-D kernel (row-major, centre = floor(size/2)+1).
-- `divisor` normalises the result; `bias` shifts it (useful for edge detect).
local function apply2DKernel(imgBuffer, width, height, kernel, kSize, divisor, bias)
	divisor = divisor or 1
	bias    = bias    or 0
	if nativeImage.kernel2D(imgBuffer, width, height, kernel, kSize, divisor, bias) then
		return
	end
	local half = math.floor(kSize / 2)
	local tmp  = buffer.create(width * height * 4)

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local r, g, b = 0, 0, 0
			for ky = 0, kSize - 1 do
				for kx = 0, kSize - 1 do
					local sx  = math.clamp(x + kx - half, 0, width  - 1)
					local sy  = math.clamp(y + ky - half, 0, height - 1)
					local idx = getPixelIndex(sx, sy, width)
					local w   = kernel[ky * kSize + kx + 1]
					r = r + buffer.readu8(imgBuffer, idx)     * w
					g = g + buffer.readu8(imgBuffer, idx + 1) * w
					b = b + buffer.readu8(imgBuffer, idx + 2) * w
				end
			end
			local dstIdx = getPixelIndex(x, y, width)
			buffer.writeu8(tmp, dstIdx,     math.clamp(math.floor(r / divisor + bias), 0, 255))
			buffer.writeu8(tmp, dstIdx + 1, math.clamp(math.floor(g / divisor + bias), 0, 255))
			buffer.writeu8(tmp, dstIdx + 2, math.clamp(math.floor(b / divisor + bias), 0, 255))
			buffer.writeu8(tmp, dstIdx + 3, buffer.readu8(imgBuffer, dstIdx + 3))
		end
	end

	buffer.copy(imgBuffer, 0, tmp, 0, width * height * 4)
end

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  FILTERS                                                                │
-- └─────────────────────────────────────────────────────────────────────────┘

-- Box blur with given radius (separable, O(n) per row/column regardless of radius).
function Image:Blur(radius: number)
	radius = math.max(1, math.floor(radius or 1))
	local size   = radius * 2 + 1
	local weight = 1 / size
	local kernel = {}
	for i = 1, size do kernel[i] = weight end
	applySeparable(self.imageBuffer, self.Size.X, self.Size.Y, kernel)
end

-- Gaussian blur. sigma controls spread; kernel size is auto-derived (6*sigma+1).
function Image:GaussianBlur(sigma: number)
	sigma     = sigma or 1
	local radius = math.max(1, math.floor(sigma * 3))
	local size   = radius * 2 + 1
	local kernel = {}
	local sum    = 0
	for i = 1, size do
		local x  = i - 1 - radius
		local v  = math.exp(-(x * x) / (2 * sigma * sigma))
		kernel[i] = v
		sum = sum + v
	end
	for i = 1, size do kernel[i] = kernel[i] / sum end
	applySeparable(self.imageBuffer, self.Size.X, self.Size.Y, kernel)
end

-- Standard 3×3 sharpen kernel.
function Image:Sharpen()
	apply2DKernel(self.imageBuffer, self.Size.X, self.Size.Y,
		{ 0,-1, 0,
			-1, 5,-1,
			0,-1, 0 }, 3, 1, 0)
end

-- Sobel edge detection. Returns magnitude image (black background, white edges).
function Image:EdgeDetect()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	local tmp = buffer.create(width * height * 4)

	local Gx = { -1,0,1, -2,0,2, -1,0,1 }
	local Gy = { -1,-2,-1, 0,0,0, 1,2,1 }

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local rx, ry = 0, 0
			local gx_c, gy_c = 0, 0
			local bx, by = 0, 0
			for ky = 0, 2 do
				for kx = 0, 2 do
					local sx  = math.clamp(x + kx - 1, 0, width  - 1)
					local sy  = math.clamp(y + ky - 1, 0, height - 1)
					local idx = getPixelIndex(sx, sy, width)
					local r   = buffer.readu8(imgBuffer, idx)
					local g   = buffer.readu8(imgBuffer, idx + 1)
					local b   = buffer.readu8(imgBuffer, idx + 2)
					local w   = ky * 3 + kx + 1
					rx   = rx   + r * Gx[w];  ry   = ry   + r * Gy[w]
					gx_c = gx_c + g * Gx[w];  gy_c = gy_c + g * Gy[w]
					bx   = bx   + b * Gx[w];  by   = by   + b * Gy[w]
				end
			end
			local dstIdx = getPixelIndex(x, y, width)
			local function mag(a, b2) return math.clamp(math.floor(math.sqrt(a*a + b2*b2)), 0, 255) end
			buffer.writeu8(tmp, dstIdx,     mag(rx, ry))
			buffer.writeu8(tmp, dstIdx + 1, mag(gx_c, gy_c))
			buffer.writeu8(tmp, dstIdx + 2, mag(bx, by))
			buffer.writeu8(tmp, dstIdx + 3, buffer.readu8(imgBuffer, dstIdx + 3))
		end
	end

	buffer.copy(imgBuffer, 0, tmp, 0, width * height * 4)
end

-- Classic emboss effect (adds 128 bias so mid-grey = "flat").
function Image:Emboss()
	apply2DKernel(self.imageBuffer, self.Size.X, self.Size.Y,
		{ -2,-1, 0,
			-1, 1, 1,
			0, 1, 2 }, 3, 1, 128)
end

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  PIXEL EFFECTS                                                          │
-- └─────────────────────────────────────────────────────────────────────────┘

-- Mosaic / pixelate: average each NxN block and fill it with that colour.
function Image:Pixelate(blockSize: number)
	blockSize = math.max(2, math.floor(blockSize or 8))
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y

	for by = 0, math.ceil(height / blockSize) - 1 do
		for bx = 0, math.ceil(width / blockSize) - 1 do
			local startX = bx * blockSize
			local startY = by * blockSize
			local endX   = math.min(startX + blockSize, width)
			local endY   = math.min(startY + blockSize, height)
			local count  = (endX - startX) * (endY - startY)
			local r, g, b, a = 0, 0, 0, 0

			for y = startY, endY - 1 do
				for x = startX, endX - 1 do
					local idx = getPixelIndex(x, y, width)
					r = r + buffer.readu8(imgBuffer, idx)
					g = g + buffer.readu8(imgBuffer, idx + 1)
					b = b + buffer.readu8(imgBuffer, idx + 2)
					a = a + buffer.readu8(imgBuffer, idx + 3)
				end
			end

			r = math.floor(r / count)
			g = math.floor(g / count)
			b = math.floor(b / count)
			a = math.floor(a / count)

			for y = startY, endY - 1 do
				for x = startX, endX - 1 do
					local idx = getPixelIndex(x, y, width)
					buffer.writeu8(imgBuffer, idx,     r)
					buffer.writeu8(imgBuffer, idx + 1, g)
					buffer.writeu8(imgBuffer, idx + 2, b)
					buffer.writeu8(imgBuffer, idx + 3, a)
				end
			end
		end
	end
end

-- Floyd-Steinberg dithering to the nearest of `levels` per channel.
-- levels=2 → 1-bit look; levels=4 → 2-bit look, etc.
function Image:Dither(levels: number)
	levels  = math.max(2, math.floor(levels or 2))
	local step  = 255 / (levels - 1)
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	-- Work on float arrays to accumulate error
	local fr, fg, fb = {}, {}, {}
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			local i   = y * width + x + 1
			fr[i] = buffer.readu8(imgBuffer, idx)
			fg[i] = buffer.readu8(imgBuffer, idx + 1)
			fb[i] = buffer.readu8(imgBuffer, idx + 2)
		end
	end

	local function quantise(v)
		return math.clamp(math.floor(v / step + 0.5) * step, 0, 255)
	end

	local function spread(arr, x, y, err, weight)
		if x >= 0 and x < width and y >= 0 and y < height then
			local i = y * width + x + 1
			arr[i]  = arr[i] + err * weight
		end
	end

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local i  = y * width + x + 1
			local or_ = quantise(fr[i]); local errR = fr[i] - or_; fr[i] = or_
			local og  = quantise(fg[i]); local errG = fg[i] - og;  fg[i] = og
			local ob  = quantise(fb[i]); local errB = fb[i] - ob;  fb[i] = ob

			spread(fr, x+1, y,   errR, 7/16); spread(fg, x+1, y,   errG, 7/16); spread(fb, x+1, y,   errB, 7/16)
			spread(fr, x-1, y+1, errR, 3/16); spread(fg, x-1, y+1, errG, 3/16); spread(fb, x-1, y+1, errB, 3/16)
			spread(fr, x,   y+1, errR, 5/16); spread(fg, x,   y+1, errG, 5/16); spread(fb, x,   y+1, errB, 5/16)
			spread(fr, x+1, y+1, errR, 1/16); spread(fg, x+1, y+1, errG, 1/16); spread(fb, x+1, y+1, errB, 1/16)

			local idx = getPixelIndex(x, y, width)
			buffer.writeu8(imgBuffer, idx,     math.clamp(math.floor(or_), 0, 255))
			buffer.writeu8(imgBuffer, idx + 1, math.clamp(math.floor(og),  0, 255))
			buffer.writeu8(imgBuffer, idx + 2, math.clamp(math.floor(ob),  0, 255))
		end
	end
end

-- Reduce colour depth to `levels` steps per channel (hard posterise, no dithering).
function Image:Posterize(levels: number)
	levels = math.max(2, math.floor(levels or 4))
	local step      = 255 / (levels - 1)
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			for ch = 0, 2 do
				local v = buffer.readu8(imgBuffer, idx + ch)
				local q = math.clamp(math.floor(v / step + 0.5) * step, 0, 255)
				buffer.writeu8(imgBuffer, idx + ch, math.floor(q))
			end
		end
	end
end

-- Chromatic aberration: shift the R channel right and B channel left by `offset` pixels.
function Image:ChromaticAberration(offset: number)
	offset = math.floor(offset or 3)
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	local tmp = buffer.create(width * height * 4)
	buffer.copy(tmp, 0, imgBuffer, 0, width * height * 4)

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local dstIdx = getPixelIndex(x, y, width)

			local rx     = math.clamp(x + offset, 0, width - 1)
			local bx     = math.clamp(x - offset, 0, width - 1)
			local rSrc   = getPixelIndex(rx, y, width)
			local bSrc   = getPixelIndex(bx, y, width)

			buffer.writeu8(imgBuffer, dstIdx,     buffer.readu8(tmp, rSrc))     -- R from right
			-- G stays where it is (already copied)
			buffer.writeu8(imgBuffer, dstIdx + 2, buffer.readu8(tmp, bSrc + 2)) -- B from left
		end
	end
end

-- Darken pixels toward the edges. strength (0..1) controls maximum darkening.
function Image:Vignette(strength: number)
	strength = math.clamp(strength or 0.8, 0, 1)
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	local cx = (width  - 1) / 2
	local cy = (height - 1) / 2
	local maxDist = math.sqrt(cx * cx + cy * cy)

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local dx   = x - cx
			local dy   = y - cy
			local dist = math.sqrt(dx * dx + dy * dy) / maxDist -- 0 (centre) to 1 (corner)
			local dark = 1 - dist * dist * strength              -- quadratic falloff
			local idx  = getPixelIndex(x, y, width)
			for ch = 0, 2 do
				local v = buffer.readu8(imgBuffer, idx + ch)
				buffer.writeu8(imgBuffer, idx + ch, math.floor(math.clamp(v * dark, 0, 255)))
			end
		end
	end
end

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  TRANSFORMS                                                             │
-- └─────────────────────────────────────────────────────────────────────────┘

-- Flip horizontally (mirror left/right) in-place.
function Image:FlipHorizontal()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, math.floor(width / 2) - 1 do
			local aIdx = getPixelIndex(x, y, width)
			local bIdx = getPixelIndex(width - 1 - x, y, width)
			local ar = buffer.readu8(imgBuffer, aIdx);     local ag = buffer.readu8(imgBuffer, aIdx + 1)
			local ab = buffer.readu8(imgBuffer, aIdx + 2); local aa = buffer.readu8(imgBuffer, aIdx + 3)
			buffer.writeu8(imgBuffer, aIdx,     buffer.readu8(imgBuffer, bIdx))
			buffer.writeu8(imgBuffer, aIdx + 1, buffer.readu8(imgBuffer, bIdx + 1))
			buffer.writeu8(imgBuffer, aIdx + 2, buffer.readu8(imgBuffer, bIdx + 2))
			buffer.writeu8(imgBuffer, aIdx + 3, buffer.readu8(imgBuffer, bIdx + 3))
			buffer.writeu8(imgBuffer, bIdx,     ar)
			buffer.writeu8(imgBuffer, bIdx + 1, ag)
			buffer.writeu8(imgBuffer, bIdx + 2, ab)
			buffer.writeu8(imgBuffer, bIdx + 3, aa)
		end
	end
end

-- Flip vertically (mirror top/bottom) in-place.
function Image:FlipVertical()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, math.floor(height / 2) - 1 do
		for x = 0, width - 1 do
			local aIdx = getPixelIndex(x, y, width)
			local bIdx = getPixelIndex(x, height - 1 - y, width)
			local ar = buffer.readu8(imgBuffer, aIdx);     local ag = buffer.readu8(imgBuffer, aIdx + 1)
			local ab = buffer.readu8(imgBuffer, aIdx + 2); local aa = buffer.readu8(imgBuffer, aIdx + 3)
			buffer.writeu8(imgBuffer, aIdx,     buffer.readu8(imgBuffer, bIdx))
			buffer.writeu8(imgBuffer, aIdx + 1, buffer.readu8(imgBuffer, bIdx + 1))
			buffer.writeu8(imgBuffer, aIdx + 2, buffer.readu8(imgBuffer, bIdx + 2))
			buffer.writeu8(imgBuffer, aIdx + 3, buffer.readu8(imgBuffer, bIdx + 3))
			buffer.writeu8(imgBuffer, bIdx,     ar)
			buffer.writeu8(imgBuffer, bIdx + 1, ag)
			buffer.writeu8(imgBuffer, bIdx + 2, ab)
			buffer.writeu8(imgBuffer, bIdx + 3, aa)
		end
	end
end

-- Rotate 90° clockwise `times` times (1, 2, or 3).
-- Returns a new Image (dimensions swap for odd multiples of 90°).
function Image:Rotate90(times: number)
	times = (times or 1) % 4
	if times == 0 then return self:Clone() end

	local src      = self
	local srcBuf   = src.imageBuffer

	for _ = 1, times do
		local sw   = src.Size.X
		local sh   = src.Size.Y
		local dst  = Image.new(Vector2.new(sh, sw)) -- dimensions swap
		local dstBuf = dst.imageBuffer

		for y = 0, sh - 1 do
			for x = 0, sw - 1 do
				-- Clockwise 90°: dst(sh-1-y, x) ← src(x, y)
				local srcIdx = getPixelIndex(x, y, sw)
				local dstIdx = getPixelIndex(sh - 1 - y, x, sh)
				buffer.writeu8(dstBuf, dstIdx,     buffer.readu8(srcBuf, srcIdx))
				buffer.writeu8(dstBuf, dstIdx + 1, buffer.readu8(srcBuf, srcIdx + 1))
				buffer.writeu8(dstBuf, dstIdx + 2, buffer.readu8(srcBuf, srcIdx + 2))
				buffer.writeu8(dstBuf, dstIdx + 3, buffer.readu8(srcBuf, srcIdx + 3))
			end
		end

		src    = dst
		srcBuf = dstBuf
	end

	return src
end

-- Crop a rectangular region and return a new Image.
function Image:Crop(position: Vector2, size: Vector2)
	if not (typeof(position) == "Vector2" or typeof(position) == "Vector3") then
		error("arg 1: position must be a Vector2 or Vector3, got " .. typeof(position), 2)
	end
	if not (typeof(size) == "Vector2" or typeof(size) == "Vector3") then
		error("arg 2: size must be a Vector2 or Vector3, got " .. typeof(size), 2)
	end
	local sx = math.clamp(math.floor(position.X), 0, self.Size.X - 1)
	local sy = math.clamp(math.floor(position.Y), 0, self.Size.Y - 1)
	local cw = math.clamp(math.floor(size.X), 1, self.Size.X - sx)
	local ch = math.clamp(math.floor(size.Y), 1, self.Size.Y - sy)

	local dst    = Image.new(Vector2.new(cw, ch))
	local dstBuf = dst.imageBuffer
	local srcBuf = self.imageBuffer
	local srcW   = self.Size.X

	for y = 0, ch - 1 do
		for x = 0, cw - 1 do
			local srcIdx = getPixelIndex(sx + x, sy + y, srcW)
			local dstIdx = getPixelIndex(x, y, cw)
			buffer.writeu8(dstBuf, dstIdx,     buffer.readu8(srcBuf, srcIdx))
			buffer.writeu8(dstBuf, dstIdx + 1, buffer.readu8(srcBuf, srcIdx + 1))
			buffer.writeu8(dstBuf, dstIdx + 2, buffer.readu8(srcBuf, srcIdx + 2))
			buffer.writeu8(dstBuf, dstIdx + 3, buffer.readu8(srcBuf, srcIdx + 3))
		end
	end

	return dst
end

-- Resize to `newSize` using bilinear interpolation. Returns a new Image.
function Image:Resize(newSize: Vector2)
	if not (typeof(newSize) == "Vector2" or typeof(newSize) == "Vector3") then
		error("arg 1: newSize must be a Vector2 or Vector3, got " .. typeof(newSize), 2)
	end
	local dw  = math.max(1, math.floor(newSize.X))
	local dh  = math.max(1, math.floor(newSize.Y))
	local sw  = self.Size.X
	local sh  = self.Size.Y
	local dst    = Image.new(Vector2.new(dw, dh))
	local dstBuf = dst.imageBuffer
	local srcBuf = self.imageBuffer

	local xScale = sw / dw
	local yScale = sh / dh

	for dy = 0, dh - 1 do
		for dx = 0, dw - 1 do
			local rx = (dx + 0.5) * xScale - 0.5
			local ry = (dy + 0.5) * yScale - 0.5
			local x0 = math.clamp(math.floor(rx), 0, sw - 1)
			local y0 = math.clamp(math.floor(ry), 0, sh - 1)
			local x1 = math.clamp(x0 + 1,         0, sw - 1)
			local y1 = math.clamp(y0 + 1,         0, sh - 1)
			local fx = rx - x0
			local fy = ry - y0

			local function s(x, y) return getPixelIndex(x, y, sw) end
			local p00 = s(x0,y0); local p10 = s(x1,y0)
			local p01 = s(x0,y1); local p11 = s(x1,y1)

			local dstIdx = getPixelIndex(dx, dy, dw)
			for ch = 0, 3 do
				local v = buffer.readu8(srcBuf, p00+ch) * (1-fx)*(1-fy)
					+ buffer.readu8(srcBuf, p10+ch) * fx    *(1-fy)
					+ buffer.readu8(srcBuf, p01+ch) * (1-fx)*fy
					+ buffer.readu8(srcBuf, p11+ch) * fx    *fy
				buffer.writeu8(dstBuf, dstIdx + ch, math.clamp(math.floor(v), 0, 255))
			end
		end
	end

	return dst
end

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │  UTILITY                                                                │
-- └─────────────────────────────────────────────────────────────────────────┘

-- Return three 256-entry arrays {r={}, g={}, b={}} counting pixel frequencies.
function Image:GetHistogram()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	local r, g, b = {}, {}, {}
	for i = 0, 255 do r[i]=0; g[i]=0; b[i]=0 end

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			local rv  = buffer.readu8(imgBuffer, idx)
			local gv  = buffer.readu8(imgBuffer, idx + 1)
			local bv  = buffer.readu8(imgBuffer, idx + 2)
			r[rv] = r[rv] + 1
			g[gv] = g[gv] + 1
			b[bv] = b[bv] + 1
		end
	end

	return { r = r, g = g, b = b }
end

-- Stretch each colour channel to use the full 0-255 range (auto levels).
function Image:AutoLevels()
	local hist = self:GetHistogram()
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y

	local function findMinMax(h)
		local lo, hi = 0, 255
		for i = 0, 255 do if h[i] > 0 then lo = i; break end end
		for i = 255, 0, -1 do if h[i] > 0 then hi = i; break end end
		return lo, hi
	end

	local rLo, rHi = findMinMax(hist.r)
	local gLo, gHi = findMinMax(hist.g)
	local bLo, bHi = findMinMax(hist.b)

	local function stretch(v, lo, hi)
		if hi == lo then return v end
		return math.clamp(math.floor((v - lo) / (hi - lo) * 255), 0, 255)
	end

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			buffer.writeu8(imgBuffer, idx,     stretch(buffer.readu8(imgBuffer, idx),     rLo, rHi))
			buffer.writeu8(imgBuffer, idx + 1, stretch(buffer.readu8(imgBuffer, idx + 1), gLo, gHi))
			buffer.writeu8(imgBuffer, idx + 2, stretch(buffer.readu8(imgBuffer, idx + 2), bLo, bHi))
		end
	end
end

-- Compare two images and return a new Image showing absolute channel differences.
-- Bright areas = large differences, black = identical.
function Image:Compare(otherImage)
	if not (type(otherImage) == "table" and otherImage.imageBuffer) then
		error("arg 1: otherImage must be an Image instance", 2)
	end
	local w = math.min(self.Size.X, otherImage.Size.X)
	local h = math.min(self.Size.Y, otherImage.Size.Y)
	local dst    = Image.new(Vector2.new(w, h))
	local dstBuf = dst.imageBuffer
	local aBuf   = self.imageBuffer
	local bBuf   = otherImage.imageBuffer
	local aw     = self.Size.X
	local bw     = otherImage.Size.X

	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local aIdx = getPixelIndex(x, y, aw)
			local bIdx = getPixelIndex(x, y, bw)
			local dIdx = getPixelIndex(x, y, w)
			for ch = 0, 2 do
				buffer.writeu8(dstBuf, dIdx + ch,
					math.abs(buffer.readu8(aBuf, aIdx + ch) - buffer.readu8(bBuf, bIdx + ch)))
			end
			buffer.writeu8(dstBuf, dIdx + 3, 255)
		end
	end

	return dst
end

-- Set pixels with alpha below `threshold` fully transparent (removes fringe).
function Image:AlphaErode(threshold: number)
	threshold = math.clamp(math.floor(threshold or 10), 0, 255)
	local imgBuffer = self.imageBuffer
	local width, height = self.Size.X, self.Size.Y
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local idx = getPixelIndex(x, y, width)
			if buffer.readu8(imgBuffer, idx + 3) < threshold then
				buffer.writeu8(imgBuffer, idx,     0)
				buffer.writeu8(imgBuffer, idx + 1, 0)
				buffer.writeu8(imgBuffer, idx + 2, 0)
				buffer.writeu8(imgBuffer, idx + 3, 0)
			end
		end
	end
end

return Image.new
