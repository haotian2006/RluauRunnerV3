--!native
local module = {}

local clock = os.clock
local fps = 0
local Profiler
local runningBenchs = 0
local function clamp(value, min, max)
	if value < min then
		value = min
	elseif value > max then
		value = max
	end
	return value
end

local function round(number)
	return number >= 0 and math.floor(number + 0.5) or math.ceil(number - 0.5)
end


do
	local function sortTimes(trace)
		if trace.TimeValues then
			table.sort(trace.TimeValues)
		end

		if trace.ChildTraces then
			for _, childTrace in pairs(trace.ChildTraces) do
				sortTimes(childTrace)
			end
		end
	end

	function module.new()
		local Profiler = {
			_CurrentTrace = {
				ChildTraces = {},
			},
			_ParentTraces = {},
			_Depth = 0,
		}

		function Profiler._Finalize()
			sortTimes(Profiler._CurrentTrace)
		end

		function Profiler.Begin(Label)
			if type(Label) ~= "string" then
				error("Attempted to call Profile.Begin() without passing a valid Label name",2)
			end

			local Start = clock()

			Profiler._ParentTraces[Profiler._Depth] = Profiler._CurrentTrace
			Profiler._Depth = Profiler._Depth + 1

			local Trace = Profiler._CurrentTrace.ChildTraces[Label] or {
				ChildTraces = {},
				TimeValues = {},
				NumTimeValues = 0,
				Label = Label,
			}
			Trace.StartClock = Start
			Profiler._CurrentTrace.ChildTraces[Label] = Trace

			Profiler._CurrentTrace = Trace
		end

		function Profiler.End(EndTime)
			EndTime = EndTime or clock()

			local Trace = Profiler._CurrentTrace
			if Trace then
				if not Trace.TimeValues then
					error("Added an extra Profiler.End() that has no matching Profiler.Begin()",2)
				end
				Profiler._Depth = Profiler._Depth - 1
				Trace.NumTimeValues = Trace.NumTimeValues + 1

				Trace.TimeValues[Trace.NumTimeValues] = (EndTime - Trace.StartClock)
				Profiler._CurrentTrace = Profiler._ParentTraces[Profiler._Depth]
			end
		end

		-- Aliases for user preference
		Profiler.begin = Profiler.Begin
		Profiler["end"] = Profiler.End
		Profiler.Start = Profiler.Begin
		Profiler.Stop = Profiler.End
		Profiler.Open = Profiler.Begin
		Profiler.Close = Profiler.End
		Profiler.Enter = Profiler.Begin
		Profiler.Exit = Profiler.End


		return Profiler
	end
	Profiler = module
end

local function resultHandler(co, ok, ...)
	if not ok then
		local message = (...)
		error(debug.traceback(co, message), 4)
	end

	if coroutine.status(co) ~= "dead" then
		return true
	else
		return false
	end
end

local function YieldCheck(callback, ...)
	local co = coroutine.create(callback)

	return resultHandler(co, coroutine.resume(co, ...))
end

local function timeFunction(key, func, profiler, ...)
	profiler.Begin(key)
	local Start = clock()
	func(...)
	local End = clock()
	profiler.End(End)

	return End - Start
end

function module.Run( benchTable,printValue,iterations,waitIter,tracker)
	local results = {
		Timestamp = nil,
		OriginalKeys = {},
		Summary = {},
		SortedKeys = {},
		Datapoints = {},
		Profiler = nil,
		Success = true,
		Message = nil,
		FPS = {fps},
		Itereations = iterations,
		OtherRunning = runningBenchs
	}
	iterations = iterations or 1000
	waitIter = waitIter or 20
	tracker.totalIterations = iterations
	tracker.iterations = 0
	local FPSs = results.FPS
	tracker = tracker or {}
	local profiler = Profiler.new()
	results.Profiler = profiler._CurrentTrace

	task.wait(.4)
	runningBenchs += 1
	local success, err = pcall(function()
		local bench = benchTable
	

		if type(bench) ~= "table" then
			error("Bench file must return a table", 2)
			return
		end
		
		if not (bench.Functions) and not bench.ParameterGenerator and next(bench) then
			local funcs = {}
			for i,v in bench do
				if type(v) == 'function' then
					funcs[i] = v
				end
			end
			bench.Functions = funcs
	
		end
		
		if type(bench.Functions) ~= "table" then
			error("Bench.Functions must be a table of functions to test", 2)
			return
		end

		if type(bench.ParameterGenerator) ~= "function" then
			bench.ParameterGenerator = function() return end
		end

		local tempProfiler = Profiler.new()
		for key, func in pairs(bench.Functions) do
			if type(func) ~= "function" then 
				continue 
			end

			tempProfiler._CurrentTrace = {ChildTraces = {}}

			local startCheck = clock()
			local doesYield = YieldCheck(func, tempProfiler, bench.ParameterGenerator())
			local endCheck = clock()
			local elapsedCheck = endCheck - startCheck

			if doesYield then
				error(string.format("Function '%s' yields- it is not possible to benchmark yielding functions, as the scheduler resumption will dictate the results.", key), 2)
			elseif elapsedCheck > 0.04 then
				error(string.format("Function '%s' takes too long to run and would cause the program to hang.", key), 2)
			end

			table.insert(results.SortedKeys, key)

			results.Datapoints[key] = {}
			results.OriginalKeys[key] = key


		end
		table.sort(results.SortedKeys)
	
		for iteration = 1, iterations do
			for key, func in pairs(bench.Functions) do
				if type(func) ~= "function" then 
					continue 
				end

				local timing = timeFunction(key, func, profiler,profiler, bench.ParameterGenerator())
				table.insert(results.Datapoints[key], timing)

				if profiler._Depth ~= 0 then
					error("Missing a Profiler.End() to close a Profiler.Begin()", 2)
				end


			end
			tracker.iterations += 1
			if iteration % waitIter == 0 then
				task.wait()
				table.insert(FPSs,fps)
				tracker.fps = fps
				results.OtherRunning = math.max(runningBenchs,results.OtherRunning)
			end
		end

		profiler._Finalize()
		for key, points in pairs(results.Datapoints) do
			table.sort(points)

			local total = 0
			for i, v in ipairs(points) do
				total = total + v
			end
			local min, max = points[1], points[#points]
			local avg = (min + max) / 2

			results.Summary[key] = {
				Total = total,
				Min = min,
				Max = max,
				Average = avg,
				Tenth = points[clamp(round(#points*0.1), 0, #points)],
				Fiftieth = points[clamp(round(#points*0.5), 0, #points)],
				Ninetieth = points[clamp(round(#points*0.9), 0, #points)],

			}
		end
	end)

	if not success then
		results.Success = false
		results.Message = err
	end
	local avgFps = 0
	for i,v in FPSs do
		avgFps += v
	end
	avgFps /= #FPSs
	results.AvgFps = avgFps
	results.Timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local p 
	printValue = printValue or 1
	if printValue == 1 then
		p = module.PrintSummary(results)
	elseif printValue == 2 or printValue then
		p = module.PrintSummary2(results)
	end
	runningBenchs -= 1
	return results,p
end

local output ={}
local print = function(x)
	table.insert(output,x)
end
local function flush()
	local o = table.concat(output,'\n')
	table.clear(output)
	return o
end
function module.PrintSummary(results)
	if results.Message then
		print("Error: " .. results.Message)
		return flush()
	end
	if not results or not results.Summary then
		print("No summary data available to print.")
		return flush()
	end

	print("Benchmarking Summary (in ms):")
	print(`Avg FPS {results.AvgFps}`)
	print(`Num of Benchs: {results.OtherRunning} | Iterations: {results.Itereations or 1000}`)

	local max_key_len = #"Function"
	for key in results.Summary do
		if #key > max_key_len then
			max_key_len = #key
		end
	end

	max_key_len = max_key_len + 2

	local fmt_header = string.format("%%-%ds %%11s %%11s %%11s", max_key_len)
	local fmt_row = string.format("%%-%ds %%11.5f %%11.5f %%11.5f", max_key_len)

	print(string.format(fmt_header, "Function", "50th %", "Average", "Total"))
	for key, data in pairs(results.Summary) do
		print(string.format(fmt_row,
			key,
			data.Fiftieth * 1000,
			data.Average * 1000,
			data.Total * 1000
			))
	end

	return flush()
end

function module.PrintSummary2(results)
	if results.Message then
		print("Error: " .. results.Message)
		return flush()
	end
	local summary = results.Summary
	print(`Avg FPS: {results.AvgFps}`)
	print(`Num of Benchs: {results.OtherRunning} | Iterations: {results.Itereations or 1000}`)
	print("Average:")
	for key, values in pairs(summary) do
		print(string.format("%-5s %7.7f", key, values.Average*1000))
	end
	print()
	print("50th %:")
	for key, values in pairs(summary) do
		print(string.format("%-5s %7.7f", key, values.Fiftieth*1000))
	end
	print()

	print("Total:")
	for key, values in pairs(summary) do
		print(string.format("%-5s %7.7f", key, values.Total*1000))
	end
	return flush()
end

function module.generateBenchmarkVisualization(results: any,Image): any
	local summary = results.Summary or {}
	local sortedKeys = results.SortedKeys or {}
	local native = results.Native
	local optimize = results.Optimize
	local avgFps = results.AvgFps
	local iters = results.Itereations or 0

	local colors = {
		Color3.fromRGB(66, 135, 245),   
		Color3.fromRGB(255, 92, 92),  
		Color3.fromRGB(82, 196, 26),  
		Color3.fromRGB(142, 68, 173),  
		Color3.fromRGB(250, 173, 20),
		Color3.fromRGB(250, 140, 22),   
		Color3.fromRGB(19, 194, 194),   
		Color3.fromRGB(235, 47, 150),   
	}


	local numFunctions = #sortedKeys
	local margin = 20
	local padding = 12
	local infoBoxHeight = 20
	local rowHeight = 100
	local summaryWidth = 200
	local barChartWidth = 300
	local totalWidth = summaryWidth + barChartWidth + margin * 2

	local height = infoBoxHeight + margin * 2 + numFunctions * rowHeight + margin * (numFunctions - 1)+50

	local img = Image.new(Vector2.new(totalWidth, height))
	img:Fill(Color3.fromRGB(250, 251, 252), 0)

	local infoBoxX = margin
	local infoBoxY = 10

	local yOffset = infoBoxY + padding

	local xInfoOffset = infoBoxX + padding
	if native ~= nil then
		img:DrawText(
			"Native: " .. tostring(native),
			Vector2.new(xInfoOffset, yOffset),
			Color3.fromRGB(60, 60, 60),
			0,
			2
		)
		xInfoOffset = xInfoOffset + 120
	end

	if optimize ~= nil then
		img:DrawText(
			"Optimization: " .. tostring(optimize),
			Vector2.new(xInfoOffset, yOffset),
			Color3.fromRGB(60, 60, 60),
			0,
			2
		)
		xInfoOffset = xInfoOffset + 140
	end

	if avgFps ~= nil then
		img:DrawText(
			string.format("Avg FPS: %d", math.floor(avgFps + 0.5)),
			Vector2.new(xInfoOffset, yOffset),
			Color3.fromRGB(60, 60, 60),
			0,
			2
		)
		xInfoOffset = xInfoOffset + 50
	end


	img:DrawText(
		"Iters: " .. tostring(iters),
		Vector2.new(infoBoxX + totalWidth - margin * 2 - padding - 120, yOffset),
		Color3.fromRGB(60, 60, 60),
		0,
		2
	)

	local maxFiftieth = 0
	for _, stats in pairs(summary) do
		if stats.Fiftieth then
			maxFiftieth = math.max(maxFiftieth, stats.Fiftieth)
		end
	end


	local currentY = infoBoxY + infoBoxHeight + margin

	for i, key in ipairs(sortedKeys) do
		local funcName = tostring(key)
		local stats = summary[funcName]

		if stats then
			local color = colors[((i - 1) % #colors) + 1]
			local rowX = margin
			local rowY = currentY

			img:DrawRectangle(
				Vector2.new(rowX, rowY),
				Vector2.new(totalWidth - margin * 2, rowHeight),
				Color3.fromRGB(255, 255, 255),
				0
			)

			for j = 0, 2 do
				img:DrawRectangle(
					Vector2.new(rowX + j, rowY + j),
					Vector2.new(totalWidth - margin * 2 - j * 2, rowHeight - j * 2),
					Color3.fromRGB(220, 223, 230),
					0
				)
			end

			img:DrawRectangle(
				Vector2.new(rowX + padding, rowY + padding),
				Vector2.new(10, 10),
				color,
				0
			)

			img:DrawText(
				funcName,
				Vector2.new(rowX + padding + 16, rowY + padding),
				Color3.fromRGB(30, 30, 30),
				0,
				2
			)

			local statsY = rowY + padding + 16
			local statsX = rowX + padding + 16

			local statLabels = {
				{"Min", stats.Min},
				{"50th", stats.Fiftieth},
				{"Avg", stats.Average},
				{"90th", stats.Ninetieth},
				{"Max", stats.Max},
			}

			for idx, stat in ipairs(statLabels) do
				local label, value = stat[1], stat[2]
				if value then
					local timeMs = value * 1000
					local formattedTime
					if timeMs < 0.01 then
						formattedTime = string.format("%.4f", timeMs)
					elseif timeMs < 0.1 then
						formattedTime = string.format("%.3f", timeMs)
					else
						formattedTime = string.format("%.2f", timeMs)
					end

					img:DrawText(
						string.format("%s:%sms", label, formattedTime),
						Vector2.new(statsX, statsY),
						Color3.fromRGB(80, 80, 80),
						0,
						1
					)
					statsY = statsY + 13
				end
			end

			if stats.Fiftieth then
				local barStartX = rowX + summaryWidth
				local barY = rowY + 15
				local barMaxWidth = barChartWidth - 80
				local barLength = (stats.Fiftieth / maxFiftieth) * barMaxWidth
				local barHeightPx = 30

				img:DrawRectangle(
					Vector2.new(barStartX, barY+20),
					Vector2.new(barLength, barHeightPx),
					color,
					0
				)

				local timeMs = stats.Fiftieth * 1000
				local valueLabel
				if timeMs < 0.01 then
					valueLabel = string.format("%.4fms", timeMs)
				elseif timeMs < 1 then
					valueLabel = string.format("%.2fms", timeMs)
				else
					valueLabel = string.format("%dms", math.floor(timeMs + 0.5))
				end

				img:DrawText(
					valueLabel,
					Vector2.new(barStartX + barLength + 6, barY + 10+20),
					Color3.fromRGB(60, 60, 60),
					0,
					1
				)
			end

			currentY = currentY + rowHeight + margin
		end
	end

	return img
end


local FrameUpdateTable = {}
local LastIteration, Start = 0, os.clock()
local function getFPS()
	LastIteration = os.clock()
	for Index = #FrameUpdateTable, 1, -1 do
		FrameUpdateTable[Index + 1] = FrameUpdateTable[Index] >= LastIteration - 1 and FrameUpdateTable[Index] or nil
	end

	FrameUpdateTable[1] = LastIteration
	return math.floor(LastIteration - Start >= 1 and #FrameUpdateTable or #FrameUpdateTable / (LastIteration - Start))

end

task.spawn(function()
	while true do
		task.wait()
		fps = getFPS()
	end
end)

return module