--[[
	Plots a mathematical function and outputs it as an image file.
	
	@param func function - A function that:
		- If isParametric: takes t and returns either:
			- A table of {x,y} pairs: {{x1,y1}, {x2,y2}, ...}
			- Multiple x,y values: x1, y1, x2, y2, ...
		- If isXFunction: takes y and returns one or more x values
		- Otherwise: takes x and returns one or more y values
	@param options table - Configuration table with:
		- offset: Vector2 - The origin point offset (default: center of image)
		- size: Vector2 - The axis ranges in units (x,y) - image will be auto-sized to fit within maxPixelSize (default: Vector2.new(10, 8))
		- scale: number - Pixels per unit (auto-calculated to fit within maxPixelSize, but can be overridden)
		- maxPixelSize: number - Maximum pixel size for either axis (default: 1024)
		- isXFunction: boolean - If true, function returns x from y input (default: false)
		- isParametric: boolean - If true, function takes t and returns x, y pairs (default: false)
		- tRange: {number, number} - Range for parametric t parameter (default: {0, 2*pi})
		- color: {Color3} | Color3 - List of colors for each curve, or single color (default: list of red, green, blue, etc.)
		- backgroundColor: Color3 - Background color (default: black)
		- showAxes: boolean - Whether to draw axes (default: true)
		- axesColor: Color3 - Color of the axes (default: gray)
		- showGrid: boolean - Whether to draw grid lines (default: false)
		- gridColor: Color3 - Color of the grid (default: dark gray)
		- gridSpacing: number - Units between grid lines (default: 1)
		- showLabels: boolean - Whether to show axis labels (default: true)
		- labelColor: Color3 - Color of the labels (default: white)
		- labelSpacing: number - Units between labels (default: 1)
		- labelSize: number - Text scale for labels (default: 1)
		- thickness: number - Line thickness in pixels (default: 1)
		- filename: string - Output filename (default: "graph.png")
]]
local function plotFunction(func: (number) -> number, options: {
	offset: Vector2?,
	size: Vector2?,
	scale: number?,
	maxPixelSize: number?,
	isXFunction: boolean?,
	isParametric: boolean?,
	tRange: {number}?,
	color: ({Color3} | Color3)?,
	backgroundColor: Color3?,
	showAxes: boolean?,
	axesColor: Color3?,
	showGrid: boolean?,
	gridColor: Color3?,
	gridSpacing: number?,
	showLabels: boolean?,
	labelColor: Color3?,
	labelSpacing: number?,
	labelSize: number?,
	thickness: number?,
	filename: string?,
	},Image,io)
	-- Default options
	options = options or {}
	local axisSize = options.size or Vector2.new(10, 8) -- Axis ranges in units
	local scale = options.scale or 50 -- Default scale, will be adjusted to fit within maxPixelSize
	local maxPixelSize = options.maxPixelSize or 1024 -- Maximum pixel size for either axis
	axisSize*=2
	-- Calculate pixel dimensions based on axis ranges
	local pixelWidth = axisSize.X * scale
	local pixelHeight = axisSize.Y * scale

	-- Ensure pixel dimensions don't exceed maxPixelSize
	if pixelWidth > maxPixelSize then
		scale = maxPixelSize / axisSize.X
		pixelWidth = maxPixelSize
	end
	if pixelHeight > maxPixelSize then
		scale = math.min(scale, maxPixelSize / axisSize.Y)
		pixelHeight = maxPixelSize
	end

	local size = Vector2.new(pixelWidth, pixelHeight) -- Final pixel dimensions
	local offset = options.offset or Vector2.new(size.X / 2, size.Y / 2)
	local isXFunction = options.isXFunction or false
	local isParametric = options.isParametric or false
	local tRange = options.tRange or {0, 2 * math.pi}
	local colors = options.color or {
		Color3.new(1, 0, 0),     -- Red
		Color3.new(0, 1, 0),     -- Green
		Color3.new(0, 0, 1),     -- Blue
		Color3.new(1, 1, 0),     -- Yellow
		Color3.new(1, 0, 1),     -- Magenta
		Color3.new(0, 1, 1),     -- Cyan
		Color3.new(1, 0.5, 0),   -- Orange
		Color3.new(0.5, 0, 1),   -- Purple
	}
	-- Convert single color to table if needed
	if type(colors.r) == "number" then
		colors = {colors}
	end
	local backgroundColor = options.backgroundColor or Color3.new(1, 1, 1)
	local showAxes = options.showAxes ~= false
	local axesColor = options.axesColor or Color3.new(0.3, 0.3, 0.3)
	local showGrid = options.showGrid or false
	local gridColor = options.gridColor or Color3.new(0.8, 0.8, 0.8)
	local gridSpacing = options.gridSpacing or 1
	local showLabels = options.showLabels ~= false
	local labelColor = options.labelColor or Color3.new(0, 0, 0)
	-- Adaptive label spacing based on axis size
	local baseLabelSpacing = options.labelSpacing or 1
	local labelSpacing = baseLabelSpacing
	-- Adjust spacing for larger axis ranges to avoid overcrowding
	if axisSize.X > 20 then
		labelSpacing = math.ceil(axisSize.X / 10)
	elseif axisSize.X > 10 then
		labelSpacing = math.ceil(axisSize.X / 8)
	end
	local labelSize = options.labelSize or 1
	local thickness = options.thickness or 1
	local filename = options.filename or "graph.png"

	-- Create image
	local image = Image.new(size)
	image:Fill(backgroundColor, 0)

	-- Draw grid if enabled
	if showGrid then
		local startX = math.floor(-offset.X / scale / gridSpacing) * gridSpacing
		local endX = math.ceil((size.X - offset.X) / scale / gridSpacing) * gridSpacing
		local startY = math.floor(-offset.Y / scale / gridSpacing) * gridSpacing
		local endY = math.ceil((size.Y - offset.Y) / scale / gridSpacing) * gridSpacing

		-- Vertical grid lines
		for x = startX, endX, gridSpacing do
			local screenX = offset.X + x * scale
			if screenX >= 0 and screenX <= size.X then
				image:DrawLine(
					Vector2.new(screenX, 0),
					Vector2.new(screenX, size.Y),
					gridColor,
					0
				)
			end
		end

		-- Horizontal grid lines
		for y = startY, endY, gridSpacing do
			local screenY = offset.Y - y * scale
			if screenY >= 0 and screenY <= size.Y then
				image:DrawLine(
					Vector2.new(0, screenY),
					Vector2.new(size.X, screenY),
					gridColor,
					0
				)
			end
		end
	end

	local isXY = type(func(0,0)) == "boolean" -- this is a function that takes x y and returns a/list of boolean

	-- Plot the function
	local step = 0.01 / scale -- Adaptive step size based on scale
	local plottedCurves = {} -- Track which curves were actually plotted
	local startTime = os.clock()

	if isXY then
		-- Boolean XY mode: f(x, y) -> boolean(s)
		local startX = -offset.X / scale
		local endX = (size.X - offset.X) / scale
		local startY = -(size.Y - offset.Y) / scale
		local endY = offset.Y / scale

		local pixelStep = 1 / scale -- Step size in world units for each pixel

		for x = startX, endX, pixelStep do
			-- Yield periodically to prevent timeout
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			for y = startY, endY, pixelStep do
				local results = {pcall(func, x, y)}
				local success = table.remove(results, 1)

				if success and #results > 0 then
					-- Process each boolean result as a separate region
					for i, value in ipairs(results) do
						if type(value) == "boolean" and value then
							plottedCurves[i] = true -- Mark this region as plotted

							-- Convert to screen coordinates
							local screenX = offset.X + x * scale
							local screenY = offset.Y - y * scale -- Flip Y axis

							-- Only draw if within bounds
							if screenX >= 0 and screenX < size.X and screenY >= 0 and screenY < size.Y then
								local regionColor = colors[((i - 1) % #colors) + 1]
								image:SetPixel(math.floor(screenX), math.floor(screenY), regionColor, 0)
							end
						end
					end
				elseif not success then
					error("Error in function: " .. tostring(results[1]))
				end
			end
		end

	elseif isParametric then
		-- Parametric mode: t -> (x, y)
		local tStart = tRange[1]
		local tEnd = tRange[2]
		local tStep = (tEnd - tStart) / (size.X * 2) -- More samples for smoother curves

		local prevScreenPositions = {} -- Track previous positions for each curve

		for t = tStart, tEnd, tStep do
			-- Yield periodically to prevent timeout
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			local results = {pcall(func, t)}
			local success = table.remove(results, 1)

			if success and #results >= 1 then
				-- Check if results are in table format or flat format
				local curveData = {}
				if type(results[1]) == "table" then
					-- Table format: {{x1,y1}, {x2,y2}, ...}
					curveData = results
				else
					-- Flat format: x1, y1, x2, y2, ...
					local pairCount = math.floor(#results / 2)
					for i = 1, pairCount do
						curveData[i] = {results[(i - 1) * 2 + 1], results[(i - 1) * 2 + 2]}
					end
				end

				-- Process each curve
				for i, point in ipairs(curveData) do
					local x, y = point[1], point[2]
					if type(x) == "number" and type(y) == "number" and x == x and y == y then
						plottedCurves[i] = true -- Mark this curve as plotted
						-- Convert to screen coordinates
						local screenX = offset.X + x * scale
						local screenY = offset.Y - y * scale -- Flip Y axis

						-- Only draw if within bounds
						if screenX >= -thickness and screenX <= size.X + thickness and screenY >= -thickness and screenY <= size.Y + thickness then
							local screenPos = Vector2.new(screenX, screenY)

							-- Draw line from previous point if it exists
							if prevScreenPositions[i] then
								local curveColor = colors[((i - 1) % #colors) + 1]
								-- Draw with thickness if specified
								if thickness > 1 then
									for k = 0, thickness - 1 do
										image:DrawLine(
											Vector2.new(prevScreenPositions[i].X + k - thickness/2, prevScreenPositions[i].Y + k - thickness/2),
											Vector2.new(screenPos.X + k - thickness/2, screenPos.Y + k - thickness/2),
											curveColor,
											0
										)
									end
								else
									image:DrawLine(prevScreenPositions[i], screenPos, curveColor, 0)
								end
							end

							prevScreenPositions[i] = screenPos
						else
							prevScreenPositions[i] = nil
						end
					else
						prevScreenPositions[i] = nil
					end
				end
			elseif not success then
				error("Error in function: " .. tostring(results[1]))
			end
		end

	elseif not isXFunction then
		-- y = f(x), iterate over x values
		local startX = -offset.X / scale
		local endX = (size.X - offset.X) / scale

		local prevScreenPositions = {} -- Track previous positions for each curve

		for x = startX, endX, step do
			-- Yield periodically to prevent timeout
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			local results = {pcall(func, x)}
			local success = table.remove(results, 1)

			if success and #results > 0 then
				-- Plot each returned value as a separate curve
				for i, y in ipairs(results) do
					if type(y) == "number" and y == y then -- Check for NaN
						plottedCurves[i] = true -- Mark this curve as plotted
						-- Convert to screen coordinates
						local screenX = offset.X + x * scale
						local screenY = offset.Y - y * scale -- Flip Y axis

						-- Only draw if within bounds
						if screenX >= 0 and screenX <= size.X and screenY >= -thickness and screenY <= size.Y + thickness then
							local screenPos = Vector2.new(screenX, screenY)

							-- Draw line from previous point if it exists
							if prevScreenPositions[i] then
								local curveColor = colors[((i - 1) % #colors) + 1]
								-- Draw with thickness if specified
								if thickness > 1 then
									for t = 0, thickness - 1 do
										image:DrawLine(
											Vector2.new(prevScreenPositions[i].X, prevScreenPositions[i].Y + t - thickness/2),
											Vector2.new(screenPos.X, screenPos.Y + t - thickness/2),
											curveColor,
											0
										)
									end
								else
									image:DrawLine(prevScreenPositions[i], screenPos, curveColor, 0)
								end
							end

							prevScreenPositions[i] = screenPos
						else
							prevScreenPositions[i] = nil
						end
					else
						prevScreenPositions[i] = nil
					end
				end
			elseif not success then
				error("Error in function: " .. tostring(results[1]))

			end
		end

	else
		-- x = f(y), iterate over y values
		local startY = -(size.Y - offset.Y) / scale
		local endY = offset.Y / scale

		local prevScreenPositions = {} -- Track previous positions for each curve

		for y = startY, endY, step do
			-- Yield periodically to prevent timeout
			if os.clock() - startTime > 1/160 then
				task.wait()
				startTime = os.clock()
			end

			local results = {pcall(func, y)}
			local success = table.remove(results, 1)

			if success and #results > 0 then
				-- Plot each returned value as a separate curve
				for i, x in ipairs(results) do
					if type(x) == "number" and x == x then
						plottedCurves[i] = true -- Mark this curve as plotted
						local screenX = offset.X + x * scale
						local screenY = offset.Y - y * scale

						if screenY >= 0 and screenY <= size.Y and screenX >= -thickness and screenX <= size.X + thickness then
							local screenPos = Vector2.new(screenX, screenY)

							if prevScreenPositions[i] then
								local curveColor = colors[((i - 1) % #colors) + 1]
								if thickness > 1 then
									for t = 0, thickness - 1 do
										image:DrawLine(
											Vector2.new(prevScreenPositions[i].X + t - thickness/2, prevScreenPositions[i].Y),
											Vector2.new(screenPos.X + t - thickness/2, screenPos.Y),
											curveColor,
											0
										)
									end
								else
									image:DrawLine(prevScreenPositions[i], screenPos, curveColor, 0)
								end
							end

							prevScreenPositions[i] = screenPos
						else
							prevScreenPositions[i] = nil
						end
					else
						prevScreenPositions[i] = nil
					end
				end
			elseif not success then
				error("Error in function: " .. tostring(results[1]))
			end
		end
	end

	-- Draw legend if multiple curves were plotted
	local curveCount = 0
	for _ in pairs(plottedCurves) do
		curveCount = curveCount + 1
	end

	if curveCount > 1 then
		local legendX = 10
		local legendY = 10
		local lineHeight = 16
		local lineLength = 20
		local textOffset = 25

		local curveIndices = {}
		for i in pairs(plottedCurves) do
			table.insert(curveIndices, i)
		end
		table.sort(curveIndices)

		for _, i in ipairs(curveIndices) do
			local curveColor = colors[((i - 1) % #colors) + 1]
			local yPos = legendY + (_ - 1) * lineHeight

			-- Draw colored line
			if thickness > 1 then
				for t = 0, thickness - 1 do
					image:DrawLine(
						Vector2.new(legendX + textOffset, yPos + 4 + t - thickness/2),
						Vector2.new(legendX + textOffset + lineLength, yPos + 4 + t - thickness/2),
						curveColor,
						0
					)
				end
			else
				image:DrawLine(
					Vector2.new(legendX + textOffset, yPos + 4),
					Vector2.new(legendX + textOffset + lineLength, yPos + 4),
					curveColor,
					0
				)
			end

			-- Draw label
			local label = "F(" .. i .. "):"
			image:DrawText(
				label,
				Vector2.new(legendX, yPos),
				labelColor,
				0,
				1
			)
		end
	end

	-- Draw axes if enabled (drawn after plotting so they appear on top)
	if showAxes then
		-- X-axis
		if offset.Y >= 0 and offset.Y <= size.Y then
			image:DrawLine(
				Vector2.new(0, offset.Y),
				Vector2.new(size.X, offset.Y),
				axesColor,
				0
			)
		end

		-- Y-axis
		if offset.X >= 0 and offset.X <= size.X then
			image:DrawLine(
				Vector2.new(offset.X, 0),
				Vector2.new(offset.X, size.Y),
				axesColor,
				0
			)
		end
	end

	-- Draw axis labels if enabled (drawn after plotting so they appear on top)
	if showLabels and showAxes then
		local startX = math.floor(-offset.X / scale / labelSpacing) * labelSpacing
		local endX = math.ceil((size.X - offset.X) / scale / labelSpacing) * labelSpacing
		local startY = math.floor(-(size.Y - offset.Y) / scale / labelSpacing) * labelSpacing
		local endY = math.ceil(offset.Y / scale / labelSpacing) * labelSpacing

		-- X-axis labels
		if offset.Y >= 0 and offset.Y <= size.Y then
			for x = startX, endX, labelSpacing do
				if x ~= 0 then -- Skip origin
					local screenX = offset.X + x * scale
					if screenX >= 10 and screenX <= size.X - 10 then
						-- Draw tick mark
						image:DrawLine(
							Vector2.new(screenX, offset.Y - 3),
							Vector2.new(screenX, offset.Y + 3),
							axesColor,
							0
						)

						-- Format label (remove trailing zeros)
						local label = tostring(x)
						if math.floor(x) == x then
							label = tostring(math.floor(x))
						end

						-- Draw label below axis
						local labelOffset = 8
						if offset.Y > size.Y - 20 then
							labelOffset = -12 -- Draw above if axis is at bottom
						end

						image:DrawText(
							label,
							Vector2.new(screenX - (#label * 3 * labelSize), offset.Y + labelOffset),
							labelColor,
							0,
							labelSize
						)
					end
				end
			end
		end

		-- Y-axis labels
		if offset.X >= 0 and offset.X <= size.X then
			for y = startY, endY, labelSpacing do
				if y ~= 0 then -- Skip origin
					local screenY = offset.Y - y * scale
					if screenY >= 10 and screenY <= size.Y - 10 then
						-- Draw tick mark
						image:DrawLine(
							Vector2.new(offset.X - 3, screenY),
							Vector2.new(offset.X + 3, screenY),
							axesColor,
							0
						)

						-- Format label
						local label = tostring(y)
						if math.floor(y) == y then
							label = tostring(math.floor(y))
						end

						-- Draw label to the left of axis
						local labelOffset = -10 - (#label * 6 * labelSize)
						if offset.X < 40 then
							labelOffset = 10 -- Draw to the right if axis is on left edge
						end

						image:DrawText(
							label,
							Vector2.new(offset.X + labelOffset, screenY - 4),
							labelColor,
							0,
							labelSize
						)
					end
				end
			end
		end

		-- Draw origin label
		if offset.X >= 20 and offset.X <= size.X - 20 and offset.Y >= 20 and offset.Y <= size.Y - 20 then
			image:DrawText(
				"0",
				Vector2.new(offset.X - 12, offset.Y + 8),
				labelColor,
				0,
				labelSize
			)
		end
	end

	-- Convert to PNG and write to file
	local pngData = Image.toPng(image, false)
	io.writefile(pngData, filename)
	return image
end



return plotFunction