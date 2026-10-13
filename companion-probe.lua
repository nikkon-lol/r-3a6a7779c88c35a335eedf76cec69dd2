-- Read-only observer. Run after ORBIT's R6 companion has been started.
if _G.ORBIT_COMPANION_PROBE_STOP then pcall(_G.ORBIT_COMPANION_PROBE_STOP) end
local api=_G.ORBIT_COMPANION_API
if type(api)~="table" or type(api.snapshot)~="function" then warn("Сначала запусти ORBIT companion-15 и создай двойника.") return end
local Players=game:GetService("Players") local RunService=game:GetService("RunService")
local player=Players.LocalPlayer
local started=os.clock() local elapsed=0 local samples=0 local worstFrame=0 local frames=0 local totalFrame=0 local worstError=0
local last=nil local connection=nil local stopping=false
local function vector(v) return v and string.format("%.3f,%.3f,%.3f",v.X,v.Y,v.Z) or "nil" end
local function stop()
	if stopping then return end stopping=true if connection then connection:Disconnect() end
	if _G.ORBIT_COMPANION_PROBE_STOP==stop then _G.ORBIT_COMPANION_PROBE_STOP=nil end
	local lines={"ORBIT R6 COMPANION PROBE 1","Read-only; no commands or property changes",string.format("Elapsed=%.2fs samples=%d meanFPS=%.1f worstFrame=%.4fs worstPositionError=%.3f",os.clock()-started,samples,frames>0 and frames/math.max(totalFrame,.0001) or 0,worstFrame,worstError)}
	if last then
		lines[#lines+1]="rig="..tostring(last.rig).." running="..tostring(last.running).." busy="..tostring(last.busy).." distance="..tostring(last.distance).." side="..tostring(last.side)
		lines[#lines+1]="status="..tostring(last.message)
		for _,part in ipairs(last.parts or {}) do
			lines[#lines+1]=part.name.." | own="..tostring(part.own).." present="..tostring(part.present).." anchored="..tostring(part.anchored).." collide="..tostring(part.collide).." color="..tostring(part.color)
			lines[#lines+1]="  size="..vector(part.size).." pos="..vector(part.pos).." goal="..vector(part.goal)
			lines[#lines+1]="  networkOwner="..tostring(part.networkOwner).." axisError="..tostring(part.axisError).." assemblyRoot="..tostring(part.assemblyRoot).." assemblyAnchored="..tostring(part.assemblyAnchored).." connectedParts="..tostring(part.connected)
			for property,request in pairs(part.pending or {}) do lines[#lines+1]="  pending "..property.." desired="..tostring(request.desired) end
		end
	end
	local char=player.Character local hum=char and char:FindFirstChildOfClass("Humanoid") local animator=hum and hum:FindFirstChildOfClass("Animator")
	if animator then pcall(function() for _,track in ipairs(animator:GetPlayingAnimationTracks()) do lines[#lines+1]="animation="..(track.Animation and track.Animation.AnimationId or "nil").." playing="..tostring(track.IsPlaying) end end) end
	local report=table.concat(lines,"\n") print(report)
	if setclipboard then pcall(setclipboard,report) end
	if writefile then pcall(writefile,"Orbit-companion-report.txt",report) end
end
_G.ORBIT_COMPANION_PROBE_STOP=stop
connection=RunService.Heartbeat:Connect(function(dt)
	frames+=1 totalFrame+=dt worstFrame=math.max(worstFrame,dt) elapsed+=dt
	if elapsed>=.25 then
		elapsed=0 local ok,value=pcall(api.snapshot)
		if ok then last=value samples+=1 worstError=math.max(worstError,value.error or 0) end
	end
	if os.clock()-started>=10 or _G.ORBIT_COMPANION_API~=api then stop() end
end)
print("ORBIT COMPANION PROBE: 10 секунд ходи, прыгай и меняй отступ двойника. Отчёт скопируется автоматически.")
