-- this is basicly just vencord's uwufiyer that was removed 
-- hi 
local endings = {
	"rawr x3",
	"OwO",
	"UwU",
	"o.O",
	"-.-",
	">w<",
	"(⑅˘꒳˘)",
	"(ꈍᴗꈍ)",
	"(˘ω˘)",
	"(U ᵕ U❁)",
	"σωσ",
	"òωó",
	"(///ˬ///✿)",
	"(U ﹏ U)",
	"( ͡o ω ͡o )",
	"ʘwʘ",
	":3",
	":3", 
	"XD",
	"nyaa~~",
	"mya",
	">_<",
	"😳",
	"🥺",
	"😳😳😳",
	"rawr",
	"^^",
	"^^;;",
	"(ˆ ﻌ ˆ)♡",
	"^•ﻌ•^",
	"/(^•ω•^)",
	"(✿oωo)"
}

local replacements = {
	{"small", "smol"},
	{"cute", "kawaii~"},
	{"fluff", "floof"},
	{"love", "luv"},
	{"stupid", "baka"},
	{"what", "nani"},
	{"meow", "nya~"},
	{"hello", "hewwo"},
}

local function selectRandomElement(arr)
	local randomIndex = math.random(#arr)
	return arr[randomIndex]
end

local function uwuify(message)
	message = message:lower()
	for _, pair in replacements do
		message = message:gsub(pair[1], pair[2])
	end
	message = message
		:gsub("([ \t\n])n", "%1ny") 
		:gsub("[lr]", "w") 
		:gsub("([ \t\n])([a-z])", function(p1, p2) return math.random() < .5 and (p1..p2.."-"..p2) or (p1..p2) end) 
		:gsub("([^.,!][.,!])([ \t\n])", function(p1, p2) return p1.." "..selectRandomElement(endings)..p2 end) 
	return message
end

return uwuify