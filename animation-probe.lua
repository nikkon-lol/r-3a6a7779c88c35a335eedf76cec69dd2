-- Passive animation observer. No build requests, tool activation or animation playback.
if _G.AUTOBUILD_ANIMATION_PROBE_STOP then pcall(_G.AUTOBUILD_ANIMATION_PROBE_STOP) end
local Players=game:GetService("Players")
local UserInputService=game:GetService("UserInputService")
local CoreGui=game:GetService("CoreGui")
local player=Players.LocalPlayer
local started=os.clock()
local stopped=false
local connections={}
local lines={"AUTOBUILD ANIMATION PROBE 2","Read-only observer; use normal tools manually. Summary continues after detailed output limit."}
local seenTools=setmetatable({},{__mode="k"})
local seenAnimators=setmetatable({},{__mode="k"})
local seenTracks=setmetatable({},{__mode="k"})
local clicks=0
local capped=false
local summaries={}
local lastClickAt,lastClickTool=-math.huge,nil
local status
local function connect(signal,fn)
	local c=signal:Connect(fn) connections[#connections+1]=c return c
end
local function path(instance)
	local ok,value=pcall(function() return instance:GetFullName() end)
	return ok and value or "?"
end
local function log(text)
	if stopped then return end
	if #lines>=900 then
		if not capped then capped=true print("ANIM PROBE: detailed log limit reached; summary continues") if status then status.Text="Лимит подробностей; сводка продолжает собираться" end end
		return
	end
	local line=string.format("+%.3fs %s",os.clock()-started,tostring(text))
	lines[#lines+1]=line print("ANIM PROBE "..line)
	if status then status.Text=string.format("Активаций: %d · записей: %d",clicks,#lines) end
end
local function currentTool()
	local character=player.Character
	return character and character:FindFirstChildOfClass("Tool")
end
local function property(o,key,fallback)
	local ok,value=pcall(function() return o[key] end)
	return ok and value~=nil and value or fallback
end
local function describe(track)
	local animation=property(track,"Animation",nil)
	return string.format("name=%s id=%s priority=%s loop=%s playing=%s time=%.3f length=%.3f speed=%.3f weight=%.3f target=%.3f origin=%s",
		tostring(property(track,"Name","?")),tostring(animation and property(animation,"AnimationId","?") or "?"),tostring(property(track,"Priority","?")),tostring(property(track,"Looped",false)),tostring(property(track,"IsPlaying",false)),property(track,"TimePosition",0),property(track,"Length",0),property(track,"Speed",0),property(track,"WeightCurrent",0),property(track,"WeightTarget",0),animation and path(animation) or "?")
end
local function noteTrack(tool,track)
	local priority=tostring(property(track,"Priority","?"))
	local name=tostring(property(track,"Name","?"))
	if not priority:find("Action",1,true) and name~="ToolNoneAnim" then return end
	local animation=property(track,"Animation",nil)
	local id=animation and property(animation,"AnimationId",nil)
	if not id then return end
	local key=tool and tool.Name or "none"
	local row=summaries[key] or {clicks=0,assets={}} summaries[key]=row
	row.assets[id]={priority=priority,loop=property(track,"Looped",false),name=name}
end
local function animatorNow()
	local character=player.Character
	local humanoid=character and character:FindFirstChildOfClass("Humanoid")
	return humanoid and humanoid:FindFirstChildOfClass("Animator")
end
local function snapshot(reason)
	if stopped then return end
	local animator=animatorNow()
	if not animator then log("SNAPSHOT "..reason.." | no Animator") return end
	local ok,tracks=pcall(function() return animator:GetPlayingAnimationTracks() end)
	if not ok then log("SNAPSHOT "..reason.." | tracks unavailable") return end
	local tool=currentTool()
	log("SNAPSHOT "..reason.." | equipped="..(tool and tool.Name or "none").." | active="..#tracks)
	for _,track in ipairs(tracks) do noteTrack(tool,track) log("  TRACK "..describe(track)) end
end
local function inventoryAnimations(root)
	local count=0
	for _,o in ipairs(root:GetDescendants()) do
		if o:IsA("Animation") then
			count+=1 log("ASSET "..path(o).." | id="..tostring(o.AnimationId))
		elseif o:IsA("StringValue") and (o.Value:find("rbxassetid://",1,true) or o.Value:find("roblox.com/asset",1,true)) then
			log("ASSET VALUE "..path(o).." | "..o.Value)
		end
	end
	return count
end
local function captureClick(tool,reason)
	if stopped then return end
	if tool==lastClickTool and os.clock()-lastClickAt<.04 then log(reason.." | same mouse action | "..tool.Name) return end
	lastClickAt=os.clock() lastClickTool=tool
	clicks+=1 local number=clicks
	local row=summaries[tool.Name] or {clicks=0,assets={}} summaries[tool.Name]=row row.clicks+=1
	log(reason.." #"..number.." "..tool.Name) snapshot("click #"..number.." immediate")
	for _,delay in ipairs({.05,.2,.6}) do task.delay(delay,function() snapshot("click #"..number.." +"..delay) end) end
end
local function watchTool(tool)
	if not tool:IsA("Tool") or seenTools[tool] then return end
	seenTools[tool]=true
	local handle=tool:FindFirstChild("Handle")
	log("TOOL "..tool.Name.." | requiresHandle="..tostring(tool.RequiresHandle).." | handle="..(handle and handle.ClassName or "none").." | grip="..tostring(tool.Grip).." | animations="..inventoryAnimations(tool))
	connect(tool.Equipped,function()
		log("EQUIPPED "..tool.Name) snapshot("equip "..tool.Name)
		task.delay(.2,function() snapshot("equip +0.2 "..tool.Name) end)
	end)
	connect(tool.Unequipped,function() log("UNEQUIPPED "..tool.Name) end)
	connect(tool.Activated,function()
		captureClick(tool,"ACTIVATED")
	end)
end
local function watchAnimator(animator)
	if not animator:IsA("Animator") or seenAnimators[animator] then return end
	seenAnimators[animator]=true
	log("ANIMATOR "..path(animator))
	connect(animator.AnimationPlayed,function(track)
		local tool=currentTool()
		noteTrack(tool,track)
		log("PLAY | tool="..(tool and tool.Name or "none").." | "..describe(track))
		if seenTracks[track] then return end seenTracks[track]=true
		connect(track.Stopped,function() log("STOP | "..describe(track)) end)
	end)
end
local function watchContainer(container)
	for _,o in ipairs(container:GetChildren()) do if o:IsA("Tool") then watchTool(o) end end
	connect(container.ChildAdded,function(o) if o:IsA("Tool") then watchTool(o) end end)
end
local function watchCharacter(character)
	log("CHARACTER "..character.Name)
	watchContainer(character)
	local hum=character:FindFirstChildOfClass("Humanoid")
	if hum then log("RIG "..tostring(hum.RigType)) end
	local animate=character:FindFirstChild("Animate")
	if animate then inventoryAnimations(animate) else log("No Animate at start") end
	for _,o in ipairs(character:GetDescendants()) do if o:IsA("Animator") then watchAnimator(o) end end
	connect(character.DescendantAdded,function(o)
		if o:IsA("Animator") then watchAnimator(o)
		elseif o:IsA("Animation") then log("ASSET ADDED "..path(o).." | "..o.AnimationId) end
	end)
	snapshot("character initial")
end
local function report()
	local summary={"SUMMARY (kept even when detailed log reached its limit)"}
	local names={} for name in pairs(summaries) do names[#names+1]=name end table.sort(names)
	for _,name in ipairs(names) do
		local row=summaries[name] summary[#summary+1]="TOOL "..name.." activations="..row.clicks
		local ids={} for id in pairs(row.assets) do ids[#ids+1]=id end table.sort(ids)
		for _,id in ipairs(ids) do local a=row.assets[id] summary[#summary+1]="  "..id.." | "..a.name.." | "..a.priority.." | loop="..tostring(a.loop) end
	end
	return table.concat(lines,"\n").."\n"..table.concat(summary,"\n")..string.format("\nElapsed=%.3fs; activations=%d; observerStopped=%s; detailedLogCapped=%s\n",os.clock()-started,clicks,tostring(stopped),tostring(capped))
end
local function copyReport()
	local text=report()
	local writer=setclipboard or (syn and syn.set_clipboard) or (Clipboard and Clipboard.set)
	local copied=writer and pcall(writer,text)
	if writefile then pcall(writefile,"Autobuild-animation-report.txt",text) end
	if status then status.Text=copied and "Отчёт скопирован — пришли его в чат" or "Буфер недоступен; отчёт в файле/F9" end
	return text
end
local gui=Instance.new("ScreenGui") gui.Name="AUTOBUILD_ANIMATION_PROBE_UI" gui.ResetOnSpawn=false gui.DisplayOrder=1001
local ok=pcall(function() gui.Parent=CoreGui end)
if not ok then gui.Parent=player:WaitForChild("PlayerGui") end
local panel=Instance.new("Frame") panel.Parent=gui panel.Size=UDim2.fromOffset(360,158) panel.Position=UDim2.new(0,16,1,-176) panel.BackgroundColor3=Color3.fromRGB(21,19,34) panel.BorderSizePixel=0
local corner=Instance.new("UICorner") corner.CornerRadius=UDim.new(0,10) corner.Parent=panel
local function label(text,y,height,size)
	local o=Instance.new("TextLabel") o.Parent=panel o.Position=UDim2.fromOffset(14,y) o.Size=UDim2.new(1,-28,0,height) o.BackgroundTransparency=1 o.Text=text o.TextColor3=Color3.fromRGB(230,223,251) o.Font=Enum.Font.Gotham o.TextSize=size or 12 o.TextWrapped=true o.TextXAlignment=Enum.TextXAlignment.Left return o
end
label("Animation Probe · наблюдение",12,24,15)
label("Возьми обычные предметы: по 2–3 клика каждым.\nЗатем нажми «Завершить и скопировать».",41,37)
status=label("Наблюдение запущено",83,20,11)
local function button(text,x,width,callback)
	local b=Instance.new("TextButton") b.Parent=panel b.Position=UDim2.fromOffset(x,116) b.Size=UDim2.fromOffset(width,30) b.Text=text b.Font=Enum.Font.Gotham b.TextSize=11 b.TextColor3=Color3.fromRGB(244,238,255) b.BackgroundColor3=Color3.fromRGB(91,65,149) b.BorderSizePixel=0
	local c=Instance.new("UICorner") c.CornerRadius=UDim.new(0,6) c.Parent=b connect(b.MouseButton1Click,callback)
end
local function stop()
	if not stopped then
		log("FINISH") stopped=true
		for _,c in ipairs(connections) do c:Disconnect() end
		_G.AUTOBUILD_ANIMATION_PROBE_STOP=nil
		local text=copyReport() gui:Destroy() return text
	end
	return report()
end
button("Скопировать",14,104,copyReport)
button("Завершить и скопировать",126,220,stop)
_G.AUTOBUILD_ANIMATION_PROBE_STOP=stop
local backpack=player:FindFirstChildOfClass("Backpack") if backpack then watchContainer(backpack) end
connect(player.ChildAdded,function(o) if o:IsA("Backpack") then watchContainer(o) end end)
connect(player.CharacterAdded,watchCharacter)
connect(UserInputService.InputBegan,function(input,processed)
	if not processed and input.UserInputType==Enum.UserInputType.MouseButton1 then local tool=currentTool() if tool then captureClick(tool,"MOUSE") end end
end)
if player.Character then watchCharacter(player.Character) end
log("READY | hold Build still, place blocks, move, then stop and copy")
