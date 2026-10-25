--!native
-- CRC32 lookup table
local crc32_table = {}
for i = 0, 255 do
	local c = i
	for j = 1, 8 do
		if c % 2 == 1 then
			c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
		else
			c = bit32.rshift(c, 1)
		end
	end
	crc32_table[i] = c
end

-- Calculate CRC32
local function crc32(data)
	local c = 0xFFFFFFFF
	for i = 1, #data do
		local byte = string.byte(data, i)
		c = bit32.bxor(bit32.rshift(c, 8), crc32_table[bit32.band(bit32.bxor(c, byte), 0xFF)])
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

-- Pack 32-bit big-endian integer
local function pack32be(value)
	return string.char(
		bit32.band(bit32.rshift(value, 24), 0xFF),
		bit32.band(bit32.rshift(value, 16), 0xFF),
		bit32.band(bit32.rshift(value, 8), 0xFF),
		bit32.band(value, 0xFF)
	)
end

-- Create PNG chunk
local function createChunk(chunkType, data)
	local length = pack32be(#data)
	local typeAndData = chunkType .. data
	local crc = pack32be(crc32(typeAndData))
	return length .. typeAndData .. crc
end

-- Adler-32 checksum
local function adler32(data)
	local s1 = 1
	local s2 = 0

	for i = 1, #data do
		s1 = (s1 + string.byte(data, i)) % 65521
		s2 = (s2 + s1) % 65521
	end

	return s2 * 65536 + s1
end

-- Simple DEFLATE compression (uncompressed blocks)
local function deflate(data)
	local result = string.char(0x78, 0x01) -- zlib header (deflate, default compression)
	local pos = 1
	local dataLen = #data

	while pos <= dataLen do
		local blockSize = math.min(65535, dataLen - pos + 1)
		local isLastBlock = (pos + blockSize - 1 >= dataLen) and 1 or 0

		-- Block header: BFINAL + BTYPE (00 = uncompressed)
		result = result .. string.char(isLastBlock)

		-- LEN and NLEN (little-endian)
		result = result
			.. string.char(
				bit32.band(blockSize, 0xFF),
				bit32.band(bit32.rshift(blockSize, 8), 0xFF),
				bit32.band(bit32.bxor(blockSize, 0xFFFF), 0xFF),
				bit32.band(bit32.rshift(bit32.bxor(blockSize, 0xFFFF), 8), 0xFF)
			)

		-- Block data
		result = result .. string.sub(data, pos, pos + blockSize - 1)
		pos = pos + blockSize
	end

	-- Adler-32 checksum
	local checksum = adler32(data)
	result = result .. pack32be(checksum)

	return result
end


return  function (image,println,timmeout)

	local line = println('PNG: Starting encoding...')
	local width = image.Size.X
	local height = image.Size.Y
	local imgBuffer = image.imageBuffer

	-- PNG signature
	local png = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

	-- IHDR chunk
	local ihdr = pack32be(width) .. pack32be(height)
	ihdr = ihdr
		.. string.char(
			8, -- bit depth
			6, -- color type (RGBA)
			0, -- compression method
			0, -- filter method
			0 -- interlace method
		)
	png = png .. createChunk("IHDR", ihdr)

	println('PNG: Reading pixels...', line)
	task.wait()

	-- IDAT chunk (image data)
	local imageData = {}
	local s = os.clock()
	for y = 0, height - 1 do
		-- Filter type 0 (none) for each scanline
		table.insert(imageData, string.char(0))

		for x = 0, width - 1 do
			local idx = ((y * width) + x) * 4
			local r = buffer.readu8(imgBuffer, idx)
			local g = buffer.readu8(imgBuffer, idx + 1)
			local b = buffer.readu8(imgBuffer, idx + 2)
			local a = buffer.readu8(imgBuffer, idx + 3)

			table.insert(imageData, string.char(r, g, b, a))
		end


		if os.clock() -s > 1/60 then
			local progress = math.floor((y / (height - 1)) * 100)
			println(string.format('PNG: Reading pixels... %d%%', progress), line)
			task.wait()
			s = os.clock()
		end
	end

	println('PNG: Compressing...', line)
	task.wait()

	local rawData = table.concat(imageData)
	local compressed = deflate(rawData)
	png = png .. createChunk("IDAT", compressed)

	-- IEND chunk
	png = png .. createChunk("IEND", "")

	println('PNG: Encoding complete!', line)
	task.wait()

	return png
end