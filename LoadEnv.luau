return function(thread,env)
 
	env.table = if workspace:FindFirstChild("ExtendedTableLibrary")
		then require(workspace:FindFirstChild("ExtendedTableLibrary"))
		else table
	env.misc = if workspace:FindFirstChild("misc")
		then require((workspace:FindFirstChild("misc") :: any):Clone())
		else nil
	local benches = 0
	env.bench = if workspace:FindFirstChild("Bench")
		then function(data, printMode, iterations, waitPerIter)
			local module = require((workspace:FindFirstChild("Bench") :: any):Clone())
			benches += 1
            thread.blocked = true
			local running = true
			local tracker = {} :: any
			local line = env.println(`Benching: {0}/{0}`)
			task.spawn(function()
				while running do
					env.println(
						`Benching: {tracker.iterations}/{tracker.totalIterations} | FPS: {tracker.fps or 0}`,
						line
					)
					task.wait(0.1)
				end
			end)
			task.wait(1)
			local info, str = module.Run(data, printMode, iterations, waitPerIter, tracker)
			task.wait(0.1)
			env.println(`Done Benching`, line)
			running = false
			if str then
				table.insert(thread.output, `NATIVE: {env.native and "true" or "false"} | OPTIMIZE: {env.optimize}\n`)
				table.insert(thread.output, str .. "\n")
			end
			task.delay(2, function()
				benches -= 1
                if benches <= 0 then
                    thread.blocked = false
                end
			end)
			return info
		end
		else nil

	if env.misc then
		for i, v in env.misc do
			if type(v) == "function" then
				setfenv(v, env)
			end
		end
	end
end
