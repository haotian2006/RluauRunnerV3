--!native
	-- Write 16-bit little endian
	local function u16le(n)
		return string.char(bit32.band(n,0xFF), bit32.band(bit32.rshift(n,8),0xFF))
	end

	-- BitWriter for LZW (LSB-first) - simple and reliable
	local function BitWriter()
		return {
			buffer = 0,
			bufferBits = 0,
			output = {},

			writeBits = function(self, value, bitCount)
				-- Add bits to buffer
				self.buffer = self.buffer + value * (2 ^ self.bufferBits)
				self.bufferBits = self.bufferBits + bitCount

				-- Output complete bytes
				while self.bufferBits >= 8 do
					local byte = self.buffer % 256
					table.insert(self.output, string.char(byte))
					self.buffer = math.floor(self.buffer / 256)
					self.bufferBits = self.bufferBits - 8
				end
			end,

			flush = function(self)
				if self.bufferBits > 0 then
					table.insert(self.output, string.char(self.buffer % 256))
				end
			end,

			getData = function(self)
				return table.concat(self.output)
			end
		}
	end

	-- LZW Compression for GIF - following GIF89a spec exactly
	local function lzwCompress(indices, minCodeSize)
		local CLEAR = 2 ^ minCodeSize
		local EOI = CLEAR + 1

		-- Initialize dictionary
		local dict = {}
		local dictSize = EOI + 1
		local codeSize = minCodeSize + 1

		local writer = BitWriter()

		-- Write CLEAR code to start
		writer:writeBits(CLEAR, codeSize)

		-- Start with empty string (per GIF spec)
		local w = ""

		for i = 1, #indices do
			local k = string.char(indices[i])
			local wk = w .. k

			-- Check if wk exists (either in dict or as root code)
			local wkCode = dict[wk]
			if not wkCode and #wk == 1 then
				-- Single character is a root code (0-255)
				wkCode = string.byte(wk)
			end

			if wkCode then
				-- String exists, continue building
				w = wk
			else
				-- String not found, output code for w and add wk to dictionary
				local code = dict[w]
				if not code and #w > 0 then
					-- Single character root code
					code = string.byte(w)
				end

				if code then
					writer:writeBits(code, codeSize)
				end

				-- Add wk to dictionary if there's room
				if dictSize < 4096 then
					dict[wk] = dictSize
					dictSize = dictSize + 1

					-- Increase code size AFTER adding entry (when next code won't fit)
					if dictSize > (2 ^ codeSize) and codeSize < 12 then
						codeSize = codeSize + 1
					end            
				end

				-- Reset dictionary when full
				if dictSize >= 4096 then
					writer:writeBits(CLEAR, codeSize)
					dict = {}
					dictSize = EOI + 1
					codeSize = minCodeSize + 1
				end

				w = k
			end
		end

		-- Output code for any remaining string
		if #w > 0 then
			local code = dict[w]
			if not code then
				code = string.byte(w)
			end
			writer:writeBits(code, codeSize)
		end

		-- Write EOI (End Of Information)
		writer:writeBits(EOI, codeSize)

		-- Flush remaining bits
		writer:flush()

		-- Pack into GIF sub-blocks (max 255 bytes per block)
		local data = writer:getData()
		local blocks = {}
		local pos = 1
		while pos <= #data do
			local len = math.min(255, #data - pos + 1)
			table.insert(blocks, string.char(len) .. string.sub(data, pos, pos + len - 1))
			pos = pos + len
		end
		table.insert(blocks, string.char(0)) -- Block terminator

		return table.concat(blocks)
	end

	-- Quantize 24-bit RGB to 256-color palette (simple 3-3-2)
	local function quantize(r,g,b)
		local ri = math.floor(r/256*8)
		local gi = math.floor(g/256*8)
		local bi = math.floor(b/256*4)
		return math.min(ri,7)*32 + math.min(gi,7)*4 + math.min(bi,3)
	end

	-- Build 256-color global palette (3-3-2)
	local function buildGlobalPalette()
		local t = {}
		for i=0,255 do
			local r = bit32.band(bit32.rshift(i,5),7)
			local g = bit32.band(bit32.rshift(i,2),7)
			local b = bit32.band(i,3)
			t[#t+1] = string.char(math.floor(r/7*255+0.5),
				math.floor(g/7*255+0.5),
				math.floor(b/3*255+0.5))
		end
		return table.concat(t)
	end

return function(frames,durations,options,println)
		local line = println('GIF: Starting encoding...')
		options = options or {}
		local loopCount = options.loop or 0
		local yieldTime = options.yield or 1/60
		assert(#frames > 0)
		assert(#frames == #durations)
		local width = frames[1].Size.X
		local height = frames[1].Size.Y

		local out = {}
		out[#out+1] = "GIF89a"
		out[#out+1] = u16le(width)..u16le(height)..string.char(0xF7,0x00,0x00)

		println('GIF: Building palette...', line)
		task.wait()
		local palette = buildGlobalPalette()
		out[#out+1] = palette

		-- Netscape Loop
		out[#out+1] = "\x21\xFF\x0BNETSCAPE2.0\x03\x01"..u16le(loopCount).."\x00"

		println(string.format('GIF: Encoding %d frames...', #frames), line)
		task.wait()
		local s = os.clock()
		for i=1,#frames do
			local img = frames[i]
			local delay = math.floor(durations[i]*100+0.5)

			println(string.format('GIF: Frame %d/%d - Quantizing pixels...', i, #frames), line)
			task.wait()

	
			out[#out+1] = "\x21\xF9\x04"..string.char(0x00)..u16le(delay)..string.char(0x00,0x00)
	
			out[#out+1] = "\x2C"..u16le(0)..u16le(0)..u16le(width)..u16le(height)..string.char(0x00)

			
			local indices = {}
			local buf = img.imageBuffer
			
			for y=0,height-1 do
				for x=0,width-1 do
					local p = ((y*width)+x)*4
					local r = buffer.readu8(buf,p)
					local g = buffer.readu8(buf,p+1)
					local b = buffer.readu8(buf,p+2)
					indices[#indices+1] = quantize(r,g,b)
				end
				if os.clock()-s > yieldTime then
					task.wait()
					s = os.clock()
					println(string.format('GIF: Frame %d/%d - Quantizing pixels... (%d%%)', i, #frames, (y/height*100)), line)	
				end	
			end

			println(string.format('GIF: Frame %d/%d - LZW compressing...', i, #frames), line)

			
			out[#out+1] = string.char(8)
			out[#out+1] = lzwCompress(indices,8)
		end

		println('GIF: Finalizing...', line)
		task.wait()

		out[#out+1] = string.char(0x3B) 

		println('GIF: Encoding complete!', line)
		task.wait()

		return table.concat(out)
	end
