--!native

local function unpack32be(data, pos)
	return bit32.bor(
		bit32.lshift(string.byte(data, pos),     24),
		bit32.lshift(string.byte(data, pos + 1), 16),
		bit32.lshift(string.byte(data, pos + 2),  8),
		string.byte(data, pos + 3)
	)
end

local function newBitReader(data, startPos)
	local pos      = startPos or 1
	local bits     = 0
	local bitCount = 0

	local function readBit()
		if bitCount == 0 then
			bits     = string.byte(data, pos) or 0
			pos      = pos + 1
			bitCount = 8
		end
		local b = bits % 2
		bits     = math.floor(bits / 2)
		bitCount = bitCount - 1
		return b
	end

	local function readBits(n)
		local value = 0
		for i = 0, n - 1 do
			value = value + readBit() * bit32.lshift(1, i)
		end
		return value
	end

	local function readU16LE()
		bitCount = 0
		local lo = string.byte(data, pos) or 0
		local hi = string.byte(data, pos + 1) or 0
		pos = pos + 2
		return lo + hi * 256
	end

	local function readRawBytes(n)
		bitCount = 0
		local result = string.sub(data, pos, pos + n - 1)
		pos = pos + n
		return result
	end

	return { readBit = readBit, readBits = readBits, readU16LE = readU16LE, readRawBytes = readRawBytes }
end

-- lengths[i] = bit-length for symbol (i-1).
local function buildHuffman(lengths, numSymbols)
	local maxLen = 0
	for i = 1, numSymbols do
		local l = lengths[i] or 0
		if l > maxLen then maxLen = l end
	end
	if maxLen == 0 then return function() return 0 end end

	local blCount = {}
	for i = 0, maxLen do blCount[i] = 0 end
	for i = 1, numSymbols do
		local l = lengths[i] or 0
		if l > 0 then blCount[l] = blCount[l] + 1 end
	end

	local nextCode = {}
	local code = 0
	blCount[0] = 0
	for bits = 1, maxLen do
		code = (code + blCount[bits - 1]) * 2
		nextCode[bits] = code
	end

	-- Canonical codes stay unreversed: the decode loop builds MSB-first (acc = acc*2 + bit).
	local syms = {}
	for i = 1, numSymbols do
		local len = lengths[i] or 0
		if len > 0 then
			local c = nextCode[len]; nextCode[len] = c + 1
			syms[c + bit32.lshift(1, len)] = i - 1
		end
	end

	return function(reader)
		local acc = 1
		for _ = 1, maxLen do
			acc = acc * 2 + reader.readBit()
			local s = syms[acc]
			if s ~= nil then return s end
		end
		error("PNG: invalid Huffman code")
	end
end

local _fixedLitLens = {}
for i = 0, 143 do _fixedLitLens[i+1] = 8 end
for i = 144, 255 do _fixedLitLens[i+1] = 9 end
for i = 256, 279 do _fixedLitLens[i+1] = 7 end
for i = 280, 287 do _fixedLitLens[i+1] = 8 end
local _fixedDistLens = {}
for i = 0, 31 do _fixedDistLens[i+1] = 5 end

local decodeFixedLit  = buildHuffman(_fixedLitLens,  288)
local decodeFixedDist = buildHuffman(_fixedDistLens,  32)

local LEN_BASE  = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local LEN_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local DST_BASE  = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local DST_EXTRA = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

local function inflate(data, limit)
	local cmf = string.byte(data, 1)
	assert(bit32.band(cmf, 0x0F) == 8, "PNG: unsupported zlib compression method")
	assert(bit32.band(string.byte(data, 2), 0x20) == 0, "PNG: preset dictionary not supported")

	local reader = newBitReader(data, 3)
	local out    = {}
	local outLen = 0

	local function push(b)
		outLen = outLen + 1
		if outLen > limit then error("PNG: image data is larger than its header says", 0) end
		out[outLen] = b
	end

	local function copyBack(dist, length)
		local start = outLen - dist + 1
		for i = 0, length - 1 do push(out[start + i]) end
	end

	local function decodeBlock(decLit, decDist)
		while true do
			local sym = decLit(reader)
			if sym < 256 then
				push(sym)
			elseif sym == 256 then
				break
			else
				local li     = sym - 257 + 1
				local length = LEN_BASE[li] + reader.readBits(LEN_EXTRA[li])
				local dsym   = decDist(reader)
				local dist   = DST_BASE[dsym + 1] + reader.readBits(DST_EXTRA[dsym + 1])
				copyBack(dist, length)
			end
		end
	end

	repeat
		local bfinal = reader.readBit()
		local btype  = reader.readBits(2)

		if btype == 0 then
			local len = reader.readU16LE()
			reader.readU16LE()
			local raw = reader.readRawBytes(len)
			for i = 1, #raw do push(string.byte(raw, i)) end

		elseif btype == 1 then
			decodeBlock(decodeFixedLit, decodeFixedDist)

		elseif btype == 2 then
			local hlit  = reader.readBits(5) + 257
			local hdist = reader.readBits(5) + 1
			local hclen = reader.readBits(4) + 4

			local CL_ORDER = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
			local clLens   = {}
			for i = 1, 19 do clLens[i] = 0 end
			for i = 1, hclen do clLens[CL_ORDER[i] + 1] = reader.readBits(3) end
			local decCL = buildHuffman(clLens, 19)

			local allLens = {}
			local k = 0
			while k < hlit + hdist do
				local sym = decCL(reader)
				if sym <= 15 then
					k = k + 1; allLens[k] = sym
				elseif sym == 16 then
					local rep = reader.readBits(2) + 3; local prev = allLens[k] or 0
					for _ = 1, rep do k = k + 1; allLens[k] = prev end
				elseif sym == 17 then
					local rep = reader.readBits(3) + 3
					for _ = 1, rep do k = k + 1; allLens[k] = 0 end
				elseif sym == 18 then
					local rep = reader.readBits(7) + 11
					for _ = 1, rep do k = k + 1; allLens[k] = 0 end
				end
			end

			local litLens  = {}; for i = 1, hlit  do litLens[i]  = allLens[i]          or 0 end
			local distLens = {}; for i = 1, hdist do distLens[i] = allLens[hlit + i] or 0 end
			decodeBlock(buildHuffman(litLens, hlit), buildHuffman(distLens, hdist))
		else
			error("PNG: invalid DEFLATE block type")
		end
	until bfinal == 1

	return out, outLen
end

local function paeth(a, b, c)
	local p  = a + b - c
	local pa = math.abs(p - a)
	local pb = math.abs(p - b)
	local pc = math.abs(p - c)
	if pa <= pb and pa <= pc then return a
	elseif pb <= pc          then return b
	else                          return c end
end

-- imageBuffer layout matches the encoder: packed RGBA, row-major, y=0 at top.
local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }
local DEPTHS = {
	[0] = { [1] = true, [2] = true, [4] = true, [8] = true, [16] = true },
	[2] = { [8] = true, [16] = true },
	[3] = { [1] = true, [2] = true, [4] = true, [8] = true },
	[4] = { [8] = true, [16] = true },
	[6] = { [8] = true, [16] = true },
}

local function u16(data, pos)
	return (string.byte(data, pos) or 0) * 256 + (string.byte(data, pos + 1) or 0)
end

return function(pngData, println, timeout)
	local line = println and println("PNG: Starting decoding...") or nil

	assert(
		string.sub(pngData, 1, 8) == string.char(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A),
		"PNG: invalid file signature"
	)

	local pos = 9
	local width, height, colorType, bitDepth
	local idatParts = {}
	local palette, trns

	while pos <= #pngData do
		local length    = unpack32be(pngData, pos)
		local chunkType = string.sub(pngData, pos + 4, pos + 7)
		local data      = string.sub(pngData, pos + 8, pos + 8 + length - 1)
		pos = pos + 12 + length

		if chunkType == "IHDR" then
			width     = unpack32be(data, 1)
			height    = unpack32be(data, 5)
			bitDepth  = string.byte(data, 9)
			colorType = string.byte(data, 10)
			assert(DEPTHS[colorType], `PNG: unknown color type {colorType}`)
			assert(DEPTHS[colorType][bitDepth], `PNG: invalid bit depth {bitDepth} for color type {colorType}`)
			assert(string.byte(data, 13) == 0, "PNG: interlaced images are not supported")
		elseif chunkType == "PLTE" then
			palette = data
		elseif chunkType == "tRNS" then
			trns = data
		elseif chunkType == "IDAT" then
			table.insert(idatParts, data)
		elseif chunkType == "IEND" then
			break
		end
	end

	assert(width and height, "PNG: IHDR chunk not found")
	assert(colorType ~= 3 or palette, "PNG: palette image without a PLTE chunk")

	if println then println("PNG: Decompressing...", line) end
	task.wait()

	-- At most 8 bytes per pixel (16-bit RGBA) plus a filter byte per row.
	local rawBytes = inflate(table.concat(idatParts), height * (width * 8 + 1))

	if println then println("PNG: Applying filters...", line) end
	task.wait()

	local channels  = CHANNELS[colorType]
	local bitsPerPx = channels * bitDepth
	local bpp       = math.max(1, bitsPerPx // 8)
	local stride    = (width * bitsPerPx + 7) // 8
	local imgBuffer = buffer.create(width * height * 4)
	local maxVal    = bit32.lshift(1, bitDepth) - 1

	-- tRNS for gray/RGB names one colour (as raw samples) that is fully transparent
	local keyGray, keyR, keyG, keyB
	if trns and colorType == 0 and #trns >= 2 then
		keyGray = u16(trns, 1)
	elseif trns and colorType == 2 and #trns >= 6 then
		keyR, keyG, keyB = u16(trns, 1), u16(trns, 3), u16(trns, 5)
	end

	local prev   = {}; for i = 1, stride do prev[i] = 0 end
	local rawPos = 1
	local s      = os.clock()

	for y = 0, height - 1 do
		local filterType = rawBytes[rawPos]; rawPos = rawPos + 1
		local cur = {}

		for x = 1, stride do
			local raw  = rawBytes[rawPos]; rawPos = rawPos + 1
			local a    = (x > bpp) and cur[x - bpp]       or 0
			local b    = prev[x]                           or 0
			local c    = (x > bpp) and (prev[x - bpp] or 0) or 0
			local recon

			if     filterType == 0 then recon = raw
			elseif filterType == 1 then recon = (raw + a)                          % 256
			elseif filterType == 2 then recon = (raw + b)                          % 256
			elseif filterType == 3 then recon = (raw + math.floor((a + b) / 2))   % 256
			elseif filterType == 4 then recon = (raw + paeth(a, b, c))            % 256
			else                        recon = raw
			end

			cur[x] = recon
		end

		if bitDepth == 8 and colorType == 6 then
			for x = 0, width - 1 do
				local bi, ci = (y * width + x) * 4, x * 4 + 1
				buffer.writeu8(imgBuffer, bi,     cur[ci])
				buffer.writeu8(imgBuffer, bi + 1, cur[ci + 1])
				buffer.writeu8(imgBuffer, bi + 2, cur[ci + 2])
				buffer.writeu8(imgBuffer, bi + 3, cur[ci + 3])
			end
		elseif bitDepth == 8 and colorType == 2 and not keyR then
			for x = 0, width - 1 do
				local bi, ci = (y * width + x) * 4, x * 3 + 1
				buffer.writeu8(imgBuffer, bi,     cur[ci])
				buffer.writeu8(imgBuffer, bi + 1, cur[ci + 1])
				buffer.writeu8(imgBuffer, bi + 2, cur[ci + 2])
				buffer.writeu8(imgBuffer, bi + 3, 255)
			end
		else
			local function sample(i)
				if bitDepth == 8 then
					return cur[i + 1]
				elseif bitDepth == 16 then
					return cur[i * 2 + 1] * 256 + cur[i * 2 + 2]
				end
				local bit = i * bitDepth
				return bit32.band(bit32.rshift(cur[bit // 8 + 1], 8 - bitDepth - bit % 8), maxVal)
			end
			local function to8(v)
				if bitDepth == 16 then return v // 256 end
				if bitDepth == 8 then return v end
				return v * 255 // maxVal
			end

			for x = 0, width - 1 do
				local r, g, b, a
				if colorType == 3 then
					local idx = sample(x)
					r = string.byte(palette, idx * 3 + 1) or 0
					g = string.byte(palette, idx * 3 + 2) or 0
					b = string.byte(palette, idx * 3 + 3) or 0
					a = trns and string.byte(trns, idx + 1) or 255
				elseif colorType == 0 then
					local v = sample(x)
					r = to8(v); g = r; b = r
					a = if v == keyGray then 0 else 255
				elseif colorType == 4 then
					r = to8(sample(x * 2)); g = r; b = r
					a = to8(sample(x * 2 + 1))
				elseif colorType == 2 then
					local sr, sg, sb = sample(x * 3), sample(x * 3 + 1), sample(x * 3 + 2)
					r, g, b = to8(sr), to8(sg), to8(sb)
					a = if sr == keyR and sg == keyG and sb == keyB then 0 else 255
				else
					r, g, b, a = to8(sample(x * 4)), to8(sample(x * 4 + 1)), to8(sample(x * 4 + 2)), to8(sample(x * 4 + 3))
				end
				local bi = (y * width + x) * 4
				buffer.writeu8(imgBuffer, bi,     r)
				buffer.writeu8(imgBuffer, bi + 1, g)
				buffer.writeu8(imgBuffer, bi + 2, b)
				buffer.writeu8(imgBuffer, bi + 3, a)
			end
		end

		prev = cur

		if os.clock() - s > 1 / 60 then
			if println then
				local progress = math.floor((y / (height - 1)) * 100)
				println(string.format("PNG: Applying filters... %d%%", progress), line)
			end
			task.wait()
			s = os.clock()
		end
	end

	if println then println("PNG: Decoding complete!", line) end
	task.wait()

	return imgBuffer, Vector2.new(width, height)
end
