-- Terrain and Shovel diagnostics; observations only.
local T=(function()
-- Conservative read-only terrain measurements. Partial voxels are candidates,
-- not proof that smooth terrain intersects every point in their cell.
local T={resolution=4,maxRead=32768}
function T.box(position,size)
	return {lo=position-size/2,hi=position+size/2}
end
function T.region(box)
	local r=Region3.new(box.lo+Vector3.new(.001,.001,.001),box.hi-Vector3.new(.001,.001,.001)):ExpandToGrid(4)
	local size=r.Size/4
	return r,size.X*size.Y*size.Z
end
function T.read(terrain,box)
	local region,count=T.region(box)
	if count>T.maxRead then return nil,"region too large: "..count end
	local ok,materials,occupancies=pcall(function() return terrain:ReadVoxels(region,4) end)
	if not ok then return nil,tostring(materials) end
	return {region=region,lo=region.CFrame.Position-region.Size/2,size=materials.Size,materials=materials,occupancies=occupancies,count=count}
end
function T.conflicts(sample)
	local full,partial,water=0,0,0
	for x=1,sample.size.X do for y=1,sample.size.Y do for z=1,sample.size.Z do
		local occupancy=sample.occupancies[x][y][z]
		local material=sample.materials[x][y][z]
		if occupancy>.001 and material~=Enum.Material.Air then
			if material==Enum.Material.Water then water+=1
			elseif occupancy>=.999 then full+=1 else partial+=1 end
		end
	end end end
	return full,partial,water
end
function T.delta(before,after)
	if before.lo~=after.lo or before.size~=after.size then return nil,"different sample regions" end
	local result={changed=0,removed=0,added=0,materialOnly=0,totalBefore=0,totalAfter=0}
	for x=1,before.size.X do for y=1,before.size.Y do for z=1,before.size.Z do
		local a,b=before.occupancies[x][y][z],after.occupancies[x][y][z]
		result.totalBefore+=a result.totalAfter+=b
		if math.abs(a-b)>.001 or before.materials[x][y][z]~=after.materials[x][y][z] then
			result.changed+=1
			if b<a-.001 then result.removed+=1 elseif b>a+.001 then result.added+=1 else result.materialOnly+=1 end
			local lo=before.lo+Vector3.new((x-1)*4,(y-1)*4,(z-1)*4) local hi=lo+Vector3.new(4,4,4)
			if not result.lo then result.lo=lo result.hi=hi else
				result.lo=Vector3.new(math.min(result.lo.X,lo.X),math.min(result.lo.Y,lo.Y),math.min(result.lo.Z,lo.Z))
				result.hi=Vector3.new(math.max(result.hi.X,hi.X),math.max(result.hi.Y,hi.Y),math.max(result.hi.Z,hi.Z))
			end
			if x==1 or y==1 or z==1 or x==before.size.X or y==before.size.Y or z==before.size.Z then result.touchesEdge=true end
		end
	end end end
	return result
end
return T

end)()
if _G.AUTOBUILD_SHOVEL_PROBE_STOP then pcall(_G.AUTOBUILD_SHOVEL_PROBE_STOP) end
local Players=game:GetService("Players")
local UIS=game:GetService("UserInputService")
local player=Players.LocalPlayer
local terrain=workspace:FindFirstChildOfClass("Terrain")
local mouse=player:GetMouse()
local stopped,scanning=false,false
local connections={}
local started=os.clock()
local lines={"AUTOBUILD SHOVEL PROBE 1","Passive manual-action observer. No remote commands or terrain writes.","Partial occupied voxels are possible conflicts; no-change does not prove a height/depth limit."}
local clicks,overlaps,reads,changes=0,0,0,0
local lastClick=-math.huge
local active
local status,codeField,gui
local function log(s)
	if stopped then return end
	if #lines<1600 then lines[#lines+1]=string.format("+%.3fs %s",os.clock()-started,tostring(s)) print("SHOVEL PROBE "..lines[#lines]) end
end
local function connect(signal,fn) local c=signal:Connect(fn) connections[#connections+1]=c return c end
local function path(o) local ok,p=pcall(function() return o:GetFullName() end) return ok and p or "nil" end
local function vec(p) return p and string.format("%.3f,%.3f,%.3f",p.X,p.Y,p.Z) or "nil" end
local function ping()
	local ok,p=pcall(function() return player:GetNetworkPing()*2 end)
	return ok and p>0 and math.min(p,5) or .3
end
local function shovel()
	local containers={player.Character or false,player:FindFirstChildOfClass("Backpack") or false}
	for _,container in ipairs(containers) do
		if container then for _,t in ipairs(container:GetChildren()) do if t:IsA("Tool") and t.Name:lower()=="shovel" then return t end end end
	end
end
local function partSample(position)
	local params=OverlapParams.new() params.FilterType=Enum.RaycastFilterType.Exclude
	local exclusions={} if player.Character then exclusions[#exclusions+1]=player.Character end
	for _,name in ipairs({"BuildVisuals","ImaginaryScene"}) do local folder=workspace:FindFirstChild(name) if folder then exclusions[#exclusions+1]=folder end end
	params.FilterDescendantsInstances=exclusions params.MaxParts=257
	local ok,parts=pcall(function() return workspace:GetPartBoundsInBox(CFrame.new(position),Vector3.new(48,48,48),params) end)
	if not ok then return nil,tostring(parts) end
	local snapshot={}
	for _,p in ipairs(parts) do snapshot[p]={pos=p.Position,size=p.Size,cf=p.CFrame,color=p.Color,material=p.Material,collide=p.CanCollide,name=path(p)} end
	return snapshot,#parts>=257 and "truncated" or nil
end
local function partChanges(before,after)
	local result={added=0,removed=0,changed=0,examples={}}
	if not before or not after then return result end
	for p,a in pairs(before) do
		local b=after[p]
		local kind
		if not b then result.removed+=1 kind="removed"
		elseif a.cf~=b.cf or a.size~=b.size or a.material~=b.material or a.color~=b.color or a.collide~=b.collide then result.changed+=1 kind="modified" end
		if kind and #result.examples<6 then result.examples[#result.examples+1]=kind..":"..a.name.." "..vec(a.pos).."/"..vec(a.size).." -> "..(b and vec(b.pos).."/"..vec(b.size) or "absent") end
	end
	for p,b in pairs(after) do if not before[p] then result.added+=1 if #result.examples<6 then result.examples[#result.examples+1]="added:"..b.name.." "..vec(b.pos).."/"..vec(b.size) end end end
	return result
end
local function equipped()
	local t=player.Character and player.Character:FindFirstChildOfClass("Tool")
	return t and t.Name:lower()=="shovel" and t
end
local function uiMode()
	local pg=player:FindFirstChildOfClass("PlayerGui") local ui=pg and pg:FindFirstChild("Shovel")
	local button=ui and ui:FindFirstChild("Button",true)
	return button and (button:IsA("TextButton") or button:IsA("TextLabel") or button:IsA("TextBox")) and button.Text or "unknown"
end
local function read(box)
	if not terrain then return nil,"Terrain absent" end
	reads+=1 return T.read(terrain,box)
end
local function describePart(part)
	if not part then return "none" end
	if not part:IsA("BasePart") then return path(part).." class="..part.ClassName end
	return path(part).." size="..vec(part.Size).." pos="..vec(part.Position).." collide="..tostring(part.CanCollide).." material="..tostring(part.Material)
end
local function profile(point)
	if stopped then return end
	if not terrain then log("No Terrain instance") return end
	local params=RaycastParams.new() params.FilterType=Enum.RaycastFilterType.Include params.FilterDescendantsInstances={terrain}
	for _,shift in ipairs({Vector3.zero,Vector3.new(8,0,0),Vector3.new(-8,0,0),Vector3.new(0,0,8),Vector3.new(0,0,-8)}) do
		local p=point+shift
		local hit=workspace:Raycast(p+Vector3.new(0,256,0),Vector3.new(0,-768,0),params)
		log("COLUMN xz="..p.X..","..p.Z.." surface="..(hit and vec(hit.Position) or "no hit").." material="..tostring(hit and hit.Material))
	end
	local sample,err=read(T.box(point-Vector3.new(0,96,0),Vector3.new(4,256,4)))
	if sample then
		local runs={} local begin
		for y=1,sample.size.Y do
			local solid=false
			for x=1,sample.size.X do for z=1,sample.size.Z do if sample.occupancies[x][y][z]>.001 and sample.materials[x][y][z]~=Enum.Material.Air then solid=true end end end
			if solid and not begin then begin=sample.lo.Y+(y-1)*4 end
			if begin and (not solid or y==sample.size.Y) then runs[#runs+1]=string.format("Y[%.1f,%.1f]",begin,sample.lo.Y+(solid and y or y-1)*4) begin=nil end
		end
		log("COLUMN occupied bands="..table.concat(runs," ").." sampled Y="..sample.lo.Y..".."..(sample.lo.Y+sample.size.Y*4).." (not a dig permission map)")
	else log("COLUMN ERROR "..tostring(err)) end
	local floors=RaycastParams.new() floors.FilterType=Enum.RaycastFilterType.Exclude
	floors.FilterDescendantsInstances=player.Character and {terrain,player.Character} or {terrain}
	local rigid=workspace:Raycast(point+Vector3.new(0,64,0),Vector3.new(0,-1024,0),floors)
	log("RIGID BELOW candidate="..describePart(rigid and rigid.Instance).." hit="..vec(rigid and rigid.Position).." (unbreakable status unknown)")
end
local function capture(origin)
	if stopped or not equipped() or os.clock()-lastClick<.07 then return end
	lastClick=os.clock() clicks+=1
	local position=mouse.Hit.Position
	local record={id=clicks,time=os.clock(),box=T.box(position,Vector3.new(48,48,48)),mode=uiMode(),position=position}
	if active then active.ambiguous=true record.ambiguous=true overlaps+=1 end
	active=record
	if status then status.Text="Измеряю действие #"..record.id.." — дождись результата" end
	local root=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	log(string.format("CLICK #%d via=%s mode=%s target=%s surface=%s point=%s RTTx2=%.4fs root=%s distance=%.2f",record.id,origin,record.mode,describePart(mouse.Target),tostring(mouse.TargetSurface),vec(position),ping(),vec(root and root.Position),root and (root.Position-position).Magnitude or -1))
	local before,err=read(record.box)
	if not before then log("CLICK TERRAIN SAMPLE ERROR "..tostring(err)) end
	local parts,partsError=partSample(position)
	if partsError then log("CLICK PART SAMPLE "..partsError) end
	record.before=before
	task.spawn(function()
		local timeout=math.min(10,math.max(2.5,ping()*6+1))
		local ack,latest,lastChange,lastSignature,latestParts
		while not stopped and os.clock()-record.time<timeout do
			task.wait(.1)
			if stopped then return end
			local after=before and read(record.box)
			latest=after and T.delta(before,after)
			local nextParts=partSample(position) latestParts=partChanges(parts,nextParts)
			local partCount=latestParts.added+latestParts.removed+latestParts.changed
			if (latest and latest.changed>0) or partCount>0 then
				if not ack then ack=os.clock()-record.time changes+=1 log(string.format("ACK #%d first local world change=%.4fs",record.id,ack)) end
				local signature=(latest and string.format("%d/%.4f/%s/%s",latest.changed,latest.totalAfter,vec(latest.lo),vec(latest.hi)) or "no terrain")..table.concat(latestParts.examples,";")..partCount
				if signature~=lastSignature then lastSignature=signature lastChange=os.clock() end
				if os.clock()-lastChange>=math.max(.4,ping()*2) then break end
			end
		end
		if stopped then return end
		if latest then log(string.format("RESULT #%d %s changed=%d removed=%d added=%d materialOnly=%d bounds=%s..%s volumeDelta=%.3f studs^3 edge=%s overlappingActions=%s",record.id,ack and "CHANGED" or "NO_CHANGE",latest.changed,latest.removed,latest.added,latest.materialOnly,vec(latest.lo),vec(latest.hi),(latest.totalAfter-latest.totalBefore)*64,tostring(latest.touchesEdge==true),tostring(record.ambiguous==true))) end
		if latestParts then log(string.format("PART RESULT #%d added=%d removed=%d modified=%d examples=%s (other players/physics can also cause changes)",record.id,latestParts.added,latestParts.removed,latestParts.changed,table.concat(latestParts.examples," | "))) end
		if active==record then active=nil if status then status.Text="Действие #"..record.id..(ack and ": изменение замечено. Можно продолжать." or ": изменение не замечено; это ещё не доказательство предела.") end end
	end)
end
local watched=setmetatable({},{__mode="k"})
local function watchTool(t)
	if not t:IsA("Tool") or t.Name:lower()~="shovel" or watched[t] then return end
	watched[t]=true log("TOOL "..path(t))
	for _,o in ipairs(t:GetDescendants()) do
		if o:IsA("RemoteEvent") or o:IsA("RemoteFunction") then log("REMOTE "..path(o).." "..o.ClassName)
		elseif o:IsA("ValueBase") then log("VALUE "..path(o).."="..tostring(o.Value)) end
	end
	connect(t.Activated,function() capture("Activated") end)
	connect(t.Equipped,function() log("EQUIPPED mode="..uiMode()) end)
end
local function watchContainer(container)
	for _,t in ipairs(container:GetChildren()) do watchTool(t) end
	connect(container.ChildAdded,watchTool)
end
-- Optional passive packet observation. Every original call is forwarded unchanged.
-- One reusable inert hook avoids stacking hooks on repeated diagnostic runs.
local packetState=_G.AUTOBUILD_SHOVEL_PACKET_OBSERVER
if not packetState and hookmetamethod and getnamecallmethod then
	local state={} local original
	local function hook(self,...)
		local args=table.pack(...)
		if state.listener and getnamecallmethod()=="FireServer" then
			local tool=shovel()
			if tool and typeof(self)=="Instance" and self:IsDescendantOf(tool) then pcall(state.listener,self,args) end
		end
		return original(self,table.unpack(args,1,args.n))
	end
	local ok,err=pcall(function() original=hookmetamethod(game,"__namecall",newcclosure and newcclosure(hook) or hook) end)
	if ok then packetState=state _G.AUTOBUILD_SHOVEL_PACKET_OBSERVER=state else log("PACKET observer unavailable: "..tostring(err)) end
end
local listener
if packetState then
	listener=function(remote,args)
		local fields={}
		for i=1,args.n do
			local a=args[i] local kind=typeof(a)
			fields[i]=i..":"..kind.."="..(kind=="Instance" and path(a) or kind=="Vector3" and vec(a) or tostring(a):sub(1,160))
		end
		log("PACKET "..path(remote).." click="..tostring(active and active.id or "uncorrelated").." "..table.concat(fields," | "))
	end
	packetState.listener=listener log("PACKET passive observation enabled")
else log("PACKET unavailable; UI, mouse and terrain observations remain active") end
local function scan()
	if scanning or stopped then return end
	scanning=true
	task.spawn(function()
		local ok,err=pcall(function()
			local text=codeField.Text~="" and codeField.Text or _G.fullBuildString or ""
			local offset=_G.buildOffset or Vector3.zero
			local targets,invalid={},0
			for record in text:gmatch("|([^|]+)|") do
				local sx,sy,sz,px,py,pz=record:match("^%x%x%x%x%x%x.[%^]?(%d+),(%d+),(%d+)%.([%+%-]?%d+%.?%d*),([%+%-]?%d+%.?%d*),([%+%-]?%d+%.?%d*)%.")
				if sx and tonumber(sx)>0 and tonumber(sy)>0 and tonumber(sz)>0 then
					targets[#targets+1]={pos=Vector3.new(tonumber(px),tonumber(py),tonumber(pz))+offset,size=Vector3.new(tonumber(sx),tonumber(sy),tonumber(sz))}
				else invalid+=1 end
			end
			log(string.format("BUILD SCAN targets=%d invalid=%d offset=%s streaming=%s",#targets,invalid,vec(offset),tostring(workspace.StreamingEnabled)))
			local fullBlocks,possibleBlocks,wetBlocks,unknown,total=0,0,0,0,0
			local details=0
			local envelope
			for i,m in ipairs(targets) do
				if stopped then return end
				local box=T.box(m.pos,m.size) local _,count=T.region(box)
				if not envelope then envelope={lo=box.lo,hi=box.hi} else
					envelope.lo=Vector3.new(math.min(envelope.lo.X,box.lo.X),math.min(envelope.lo.Y,box.lo.Y),math.min(envelope.lo.Z,box.lo.Z))
					envelope.hi=Vector3.new(math.max(envelope.hi.X,box.hi.X),math.max(envelope.hi.Y,box.hi.Y),math.max(envelope.hi.Z,box.hi.Z))
				end
				if count>T.maxRead or total+count>250000 then unknown+=1
				else
					total+=count local sample,message=read(box)
					if sample then
						local full,partial,water=T.conflicts(sample)
						if full>0 then fullBlocks+=1 elseif partial>0 then possibleBlocks+=1 end
						if water>0 then wetBlocks+=1 end
						if (full+partial+water)>0 and details<48 then details+=1 log(string.format("CONFLICT #%d pos=%s size=%s full=%d partial=%d water=%d",i,vec(m.pos),vec(m.size),full,partial,water)) end
					else unknown+=1 if details<48 then details+=1 log("SCAN ERROR #"..i.." "..tostring(message)) end end
				end
				if i%16==0 then if status then status.Text="Проверка земли: "..i.."/"..#targets end task.wait() end
			end
			log(string.format("BUILD SUMMARY definiteVoxelOverlap=%d partialOnlyPossible=%d waterBlocks=%d unknownOrBudgetSkipped=%d inspectedVoxels=%d. Other blocks, streaming, hollow interior and resize/helper volumes require separate checks.",fullBlocks,possibleBlocks,wetBlocks,unknown,total))
			if envelope then
				local area,message=read(envelope)
				if area then local f,p,w=T.conflicts(area) log(string.format("ENVELOPE %s..%s full=%d partial=%d water=%d; includes gaps/interior, NOT an automatic excavation instruction",vec(envelope.lo),vec(envelope.hi),f,p,w))
				else log("ENVELOPE not fully inspected: "..tostring(message)) end
			end
			local root=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local point=targets[1] and targets[1].pos or root and root.Position
			if point then profile(point) end
			if #targets==0 then log("No build code: paste code in probe field, or load it in ORBIT before Scan") end
		end)
		scanning=false
		if not ok then log("SCAN FAILED "..tostring(err)) end
		if not stopped and status then status.Text=ok and "Проверка завершена; сделай ручные тесты лопатой" or "Ошибка проверки; подробности в F9" end
	end)
end
local function report()
	return table.concat(lines,"\n")..string.format("\nSUMMARY clicks=%d changedActions=%d overlapping=%d reads=%d elapsed=%.2fs stopped=%s\nNo-change can mean limit, invalid target, cooldown, tool loss, lag or permission. Boundaries are not inferred automatically.\n",clicks,changes,overlaps,reads,os.clock()-started,tostring(stopped))
end
local function copyReport()
	local text=report() local writer=setclipboard or (syn and syn.set_clipboard)
	local copied=writer and pcall(writer,text)
	if writefile then pcall(writefile,"Autobuild-shovel-report.txt",text) end
	if status then status.Text=copied and "Отчёт скопирован" or "Отчёт в файле/F9; буфер недоступен" end
	return text
end
gui=Instance.new("ScreenGui") gui.Name="AUTOBUILD_SHOVEL_PROBE_UI" gui.ResetOnSpawn=false gui.DisplayOrder=1002
local parented=pcall(function() gui.Parent=game:GetService("CoreGui") end)
if not parented then gui.Parent=player:WaitForChild("PlayerGui") end
local panel=Instance.new("Frame") panel.Parent=gui panel.Size=UDim2.fromOffset(410,222) panel.Position=UDim2.new(0,16,1,-240) panel.BackgroundColor3=Color3.fromRGB(21,19,34) panel.BorderSizePixel=0
local corner=Instance.new("UICorner") corner.CornerRadius=UDim.new(0,10) corner.Parent=panel
local function label(text,y,h)
	local l=Instance.new("TextLabel") l.Parent=panel l.Position=UDim2.fromOffset(12,y) l.Size=UDim2.new(1,-24,0,h) l.BackgroundTransparency=1 l.Text=text l.TextColor3=Color3.fromRGB(236,229,251) l.Font=Enum.Font.Gotham l.TextSize=12 l.TextWrapped=true l.TextXAlignment=Enum.TextXAlignment.Left return l
end
label("Shovel Probe · ручные действия, без автокопания",10,25)
label("Загрузи постройку в ORBIT или вставь код ниже.\nКопай/насыпай настоящей лопатой; между кликами ≥ 3 с.",37,39)
codeField=Instance.new("TextBox") codeField.Parent=panel codeField.Position=UDim2.fromOffset(12,82) codeField.Size=UDim2.new(1,-24,0,32) codeField.ClearTextOnFocus=false codeField.Text="" codeField.PlaceholderText="Код необязателен, если он уже загружен в ORBIT" codeField.TextSize=11 codeField.TextColor3=Color3.fromRGB(240,230,255) codeField.BackgroundColor3=Color3.fromRGB(37,32,54) codeField.TextTruncate=Enum.TextTruncate.AtEnd
status=label("Готово. Нажми «Проверить землю»",119,35)
local function button(text,x,y,w,callback)
	local b=Instance.new("TextButton") b.Parent=panel b.Position=UDim2.fromOffset(x,y) b.Size=UDim2.fromOffset(w,27) b.Text=text b.TextSize=11 b.Font=Enum.Font.Gotham b.TextColor3=Color3.fromRGB(244,238,255) b.BackgroundColor3=Color3.fromRGB(91,65,149) b.BorderSizePixel=0 connect(b.MouseButton1Click,callback)
end
local function stop()
	if not stopped then
		log("FINISH (unfinished samples remain unconfirmed)") stopped=true
		for _,c in ipairs(connections) do c:Disconnect() end
		if packetState and packetState.listener==listener then packetState.listener=nil end
		_G.AUTOBUILD_SHOVEL_PROBE_STOP=nil
		local text=copyReport() gui:Destroy() return text
	end
	return report()
end
button("Проверить землю",12,159,185,scan)
button("Профиль у персонажа",207,159,191,function() local r=player.Character and player.Character:FindFirstChild("HumanoidRootPart") if r then task.spawn(function() local ok,err=pcall(profile,r.Position) if not ok then log("PROFILE ERROR "..tostring(err)) end end) end end)
button("Скопировать",12,191,115,copyReport)
button("Завершить и скопировать",137,191,261,stop)
_G.AUTOBUILD_SHOVEL_PROBE_STOP=stop
local backpack=player:FindFirstChildOfClass("Backpack") if backpack then watchContainer(backpack) end
if player.Character then watchContainer(player.Character) end
connect(player.CharacterAdded,function(character) log("RESET character replaced; pending measurements may be ambiguous") if active then active.ambiguous=true end watchContainer(character) end)
connect(player.ChildAdded,function(o) if o:IsA("Backpack") then watchContainer(o) end end)
connect(UIS.InputBegan,function(input,processed) if not processed and input.UserInputType==Enum.UserInputType.MouseButton1 then capture("MouseBeforeAction") end end)
log("READY RTTx2="..ping().." shovel="..path(shovel()).." mode="..uiMode().." Terrain="..path(terrain))
