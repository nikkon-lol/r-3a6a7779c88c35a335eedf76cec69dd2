-- ============================================================================
-- AUTO-UNLOAD PREVIOUS SESSION (ПЕРЕЗАХОДИТЬ БОЛЬШЕ НЕ НУЖНО)
-- ============================================================================
if _G.AUTOBUILD_UNLOAD then
	pcall(_G.AUTOBUILD_UNLOAD)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local unloaded = false
local busySaving = false
local StudioHooks = {}
local resumeSession = type(_G.AUTOBUILD_RESUME)=="table" and _G.AUTOBUILD_RESUME.version==2 and _G.AUTOBUILD_RESUME.job==game.JobId and _G.AUTOBUILD_RESUME.session or nil
local invalidatePreparedPlan=function() end
_G.autobuildRunning = false
_G.stopautobuild = false
_G.fullBuildString = nil
local connections = {}
local function trackConn(conn)
	table.insert(connections, conn)
	return conn
end

local CONFIG = {
	BUILD_HEIGHT_OFFSET = 12,
	GRID_STEP = 4,
	-- Only change after comparing the actual position in the warning.
	DETAILED_INPUT_OFFSET = Vector3.zero
}

-- Persistence Setup
local SAVE_FILE = "AutobuildData.json"
local storageError = nil
local tabsData = {{name = "Build 1", content = ""}}
local activeTabIndex = 1
local updatingEditor = false
local rotationPivot = nil
local editorDisplayText = nil
local saveRevision = 0
local parseBlocks -- shared with early document/recovery closures
-- Full documents never depend on the visible TextBox page.
StudioHooks.documents=(function()
	local D={limit=12000,lines=160,cache={},written={},files={},serial=0,visualRevision=0}
	local function notice(message) if StudioHooks.documentStatus then StudioHooks.documentStatus(message,true) end end
	local function guid()
		D.serial+=1
		local ok,value=pcall(function() return HttpService:GenerateGUID(false) end)
		return (ok and type(value)=="string" and value:gsub("[^%w_-]","") or tostring(os.time()).."_"..tostring(math.floor(os.clock()*1000))).."_"..D.serial
	end
	function D.id(tab)
		if type(tab.id)~="string" or tab.id=="" then tab.id="build_"..guid() end
		return tab.id
	end
	local function safe(file) return type(file)=="string" and file:match("^OrbitBuild_[%w_-]+%.txt$")~=nil end
	function D.hydrate(tab)
		if type(tab)~="table" then return nil end
		if type(tab.content)=="string" then return tab.content end
		if not safe(tab.contentFile) then return nil end
		local ok,value=pcall(function() return readfile(tab.contentFile) end)
		if ok and type(value)=="string" and (tab.bytes==nil or #value==tab.bytes) then tab.unavailable=nil D.written[tab.contentFile]=value return value end
		local saved,backup=pcall(function() return readfile(tab.contentFile..".backup") end)
		if saved and type(backup)=="string" and tab.bytes==#backup then tab.unavailable=nil tab.recoveredBackup=true return backup end
		tab.unavailable=true return ""
	end
	function D.freezeLegacy(file,decoded)
		if not writefile or not readfile or not isfile then return end
		for _,tab in ipairs(decoded) do if type(tab)=="table" and type(tab.content)=="string" then
			pcall(function() if not isfile(file..".legacy-v5.backup") then writefile(file..".legacy-v5.backup",readfile(file)) end end)
			return
		end end
	end
	function D.manifest(tabs)
		local rows={} local owners={} local ids={}
		for _,tab in ipairs(tabs) do
			local id=D.id(tab)
			if ids[id] then tab.id="build_"..guid() id=tab.id end ids[id]=true
			local file=tab.contentFile
			if not safe(file) or owners[file] then file=D.files[id] or "OrbitBuild_"..guid()..".txt" if owners[file] then file="OrbitBuild_"..guid()..".txt" end end
			owners[file]=true
			D.files[id]=file tab.contentFile=file
			if not tab.unavailable and (tab.recoveredBackup or D.written[file]~=tab.content) then
				if readfile and isfile and isfile(file) then
					local old=readfile(file) if type(old)=="string" then writefile(file..(tab.recoveredBackup and ".damaged-backup" or ".backup"),old) end
				end
				writefile(file..".pending",tab.content) writefile(file,tab.content)
				if readfile and readfile(file)~=tab.content then error("Не подтверждена запись постройки "..tab.name,0) end
				D.written[file]=tab.content
				tab.recoveredBackup=nil
			end
			rows[#rows+1]={id=id,name=tab.name,contentFile=file,bytes=tab.unavailable and tab.bytes or #tab.content,placement=tab.placement,rotationPivot=tab.rotationPivot,unavailable=tab.unavailable or nil}
		end
		return rows
	end
	local function index(tab,value)
		local id=D.id(tab) local cached=D.cache[id]
		if cached and cached.raw==value then return cached end
		local pages={} local start=1
		local sep=value:find("||",1,true) local newline=value:find("\n",1,true)
		while start<=#value do
			local last=math.min(#value,start+D.limit-1) local rows=0
			while true do
				local stop=sep and newline and math.min(sep,newline) or sep or newline
				if not stop or stop>last then break end
				rows+=1
				if sep==stop then sep=value:find("||",stop+1,true) end
				if newline==stop then newline=value:find("\n",stop+1,true) end
				if rows>=D.lines then last=stop break end
			end
			-- Never split a UTF-8 character between pages.
			while last<#value and value:byte(last+1)>=128 and value:byte(last+1)<192 do last-=1 end
			pages[#pages+1]={first=start,last=last} start=last+1
		end
		if #pages==0 then pages={{first=1,last=0}} end
		local count=0 for _ in value:gmatch("|[^|]+|") do count+=1 end
		cached={raw=value,pages=pages,count=count,page=math.clamp(cached and cached.page or 1,1,#pages)}
		D.cache[id]=cached return cached
	end
	function D.view(tab,value)
		local cached=index(tab,value) local range=cached.pages[cached.page]
		D.active=tab D.range={first=range.first,last=range.last,raw=value}
		return value:sub(range.first,range.last):gsub("%|%|","|\n|")
	end
	function D.metrics()
		local tab=tabsData[activeTabIndex] local c=index(tab,tab.content or "")
		return c.count,c.page,#c.pages
	end
	function D.edit(display)
		local tab=tabsData[activeTabIndex] local value=display:gsub("%|\r?\n%|","||")
		local range=D.range
		if tab==D.active and range and range.raw==tab.content then
			value=range.raw:sub(1,range.first-1)..value..range.raw:sub(range.last+1)
		end
		tab.unavailable=nil return value
	end
	function D.page(delta)
		if _G.autobuildRunning or busySaving then return end
		local tab=tabsData[activeTabIndex] local c=index(tab,tab.content)
		c.page=math.clamp(c.page+delta,1,#c.pages)
		if StudioHooks.renderDocument then StudioHooks.renderDocument(D.view(tab,tab.content)) end
	end
	function D.runUI(action)
		if unloaded then return false end
		if busySaving then notice("Дождитесь сохранения") return false end
		if _G.autobuildRunning then
			local guard=StudioHooks.guard
			if guard and guard.autoExecuting then D.pendingUI=action _G.stopautobuild=true notice("Приостанавливаю фоновую защиту для действия в интерфейсе")
			else notice("Сначала поставь строительство на паузу") end
			return false
		end
		local ok,err=pcall(action) if not ok then notice("Действие интерфейса: "..tostring(err)) end
		return ok
	end
	function D.flushUI()
		local action=D.pendingUI D.pendingUI=nil
		if action and not unloaded then D.runUI(action) end
	end
	local registry=_G.AUTOBUILD_DOCUMENT_JOBS
	if type(registry)~="table" or registry.job~=game.JobId then registry={job=game.JobId,jobs={},orphans={}} _G.AUTOBUILD_DOCUMENT_JOBS=registry end
	D.jobs=registry.jobs D.orphans=registry.orphans
	function D.pending(session)
		if StudioHooks.runtimeState then return StudioHooks.runtimeState.pending(session) end
		for _,b in ipairs(session.blocks or {}) do
			if b.creation or b.pendingResize and b.pendingResize.brick and b.pendingResize.brick.Parent or (b.pendingCollision or b.repairDeleteRequested) and b.placedBrick and b.placedBrick.Parent then return true end
			for _,old in ipairs(b.retired or {}) do if (old.attempts or 1)>0 then return true end end
			for _,h in ipairs(b.work and b.work.helpers or {}) do if h.creation or h.brick and h.brick.Parent then return true end end
		end
		for part,state in pairs(session.obstacleDeletes or {}) do if state.requested and part.Parent then return true end end
		return false
	end
	function D.stash(session)
		if session and session.transient then return end
		if not session or not session.buildId then return end
		local old=D.jobs[session.buildId]
		if old and old~=session and D.pending(old) then
			local found=false for _,s in ipairs(D.orphans) do if s==old then found=true break end end
			if not found then D.orphans[#D.orphans+1]=old end
		end
		D.jobs[session.buildId]=session
	end
	function D.find(id,text,offset)
		local s=D.jobs[id]
		if s and s.text==text and s.offset==offset then return s end
		for _,old in ipairs(D.orphans) do if old.buildId==id and old.text==text and old.offset==offset then return old end end
	end
	function D.activate(tab,value)
		if StudioHooks.stairwell and StudioHooks.stairwell.context then return end
		local id=D.id(tab) D.stash(resumeSession)
		resumeSession=D.find(id,value,_G.buildOffset or Vector3.zero)
		local guard=StudioHooks.guard
		if guard and guard.session~=resumeSession then guard.close() if resumeSession then guard.watch(resumeSession) end end
		if tab.content~=value then tab.unavailable=nil end
	end
	function D.otherJobs(session)
		local result={} local seen={}
		for _,list in ipairs({D.jobs,D.orphans}) do for _,s in pairs(list) do if s~=session and not seen[s] and D.pending(s) then seen[s]=true result[#result+1]=s end end end
		return result
	end
	function D.reservations(session)
		local result={}
		for _,s in ipairs(D.otherJobs(session)) do
			local function add(box) if box then result[#result+1]={id="inactive:"..s.buildId..":"..#result,reservedTarget="inactive:"..s.buildId,pos=box.pos,size=box.size,color=Color3.new(1,1,1),material=Enum.Material.Plastic,collide=true,sprays={},eligible=false} end end
			local function holder(h)
				if h.creation then add(h.creation.initial) end
				for _,old in ipairs(h.retired or {}) do add(old.initial) end
				if h.brick and h.brick.Parent and (h.creation or h.temporary) then add({pos=h.brick.Position,size=h.brick.Size}) end
			end
			for i in pairs(StudioHooks.runtimeState.ensure(s).active) do
				local b=s.blocks[i]
				holder(b) for _,h in ipairs(b.work and b.work.helpers or {}) do holder(h) end
				if b.pendingResize then add(b.pendingResize.step.before) add(b.pendingResize.step.after) end
				if b.pendingCollision and b.placedBrick and b.placedBrick.Parent then add({pos=b.placedBrick.Position,size=b.placedBrick.Size}) end
			end
			for part,state in pairs(s.obstacleDeletes or {}) do if state.requested and part.Parent then add({pos=part.Position,size=part.Size}) end end
		end
		for _,row in ipairs(D.runtimeRows or {}) do
			if row.key~=session.recoveryKey and row.pending and row.job==game.JobId then
				local state=D.readRuntime(row.key,"pending")
				if state and state.job==game.JobId and state.buildId==row.buildId then
					local function add(packed)
						local m=D.box(packed)
						if m then result[#result+1]={id="disk-inactive:"..row.key..":"..#result,reservedTarget="inactive:"..row.buildId,pos=m.pos,size=m.size,color=Color3.new(1,1,1),material=Enum.Material.Plastic,collide=true,sprays={},eligible=false} end
					end
					local function holder(h)
						if type(h)~="table" then return end
						if type(h.creation)=="table" then add(h.creation.initial) end
						for _,old in ipairs(h.retired or {}) do add(old.initial) end
						if h.temporary then add(h.brick) end
					end
					for _,record in ipairs(state.records or {}) do
						holder(record.holder) for _,h in ipairs(record.helpers or {}) do holder(h) end
						if type(record.resize)=="table" then add(record.resize.before) add(record.resize.after) end
						if record.collision then add(record.holder and record.holder.brick) end
					end
					for _,record in ipairs(state.obstacles or {}) do add(record) end
				end
			end
		end
		return result
	end
	function D.discard(tab)
		local id=tab.id if not id then return end
		local s=D.jobs[id]
		if s and D.pending(s) then D.orphans[#D.orphans+1]=s end
		if resumeSession==s then resumeSession=nil end
		D.jobs[id]=nil D.cache[id]=nil
	end
	function D.pendingPart(session,part)
		for _,s in ipairs(D.otherJobs(session)) do
			if s.helpers and s.helpers[part] then return true end
			local state=s.obstacleDeletes and s.obstacleDeletes[part] if state and state.requested then return true end
			for i in pairs(StudioHooks.runtimeState.ensure(s).active) do local b=s.blocks[i] if b.placedBrick==part and (b.pendingResize or b.pendingCollision or b.repairDeleteRequested) then return true end end
		end
		return false
	end
	D.runtimeRows={} D.runtimeCache={}
	if readfile and isfile then pcall(function()
		if isfile("OrbitSessions.json") then
			local stored=HttpService:JSONDecode(readfile("OrbitSessions.json"))
			if type(stored)=="table" then for _,row in ipairs(stored) do if type(row)=="table" and type(row.key)=="string" and row.key:match("^[%w_-]+$") and type(row.buildId)=="string" then D.runtimeRows[#D.runtimeRows+1]=row end end end
		end
	end) end
	function D.box(packed)
		if type(packed)~="table" or type(packed.pos)~="table" or type(packed.size)~="table" or #packed.pos~=3 or #packed.size~=3 then return end
		for _,a in ipairs({packed.pos,packed.size}) do for _,n in ipairs(a) do if type(n)~="number" or n~=n or math.abs(n)>1000000 then return end end end
		return {pos=Vector3.new(unpack(packed.pos)),size=Vector3.new(unpack(packed.size))}
	end
	function D.readRuntime(key,kind)
		local file="OrbitRecovery_"..key.."."..kind..".json"
		if D.runtimeCache[file] then return D.runtimeCache[file] end
		local ok,value=pcall(function() return HttpService:JSONDecode(readfile(file)) end)
		if ok and type(value)=="table" then
			if kind=="pending" and StudioHooks.recovery and StudioHooks.recovery.mergeJournal and isfile and isfile(file..".journal") then
				local manifest=D.readRuntime(key,"manifest")
				if manifest and type(manifest.text)=="string" then
					local blocks=parseBlocks(manifest.text,Vector3.zero)
					local session={buildId=manifest.buildId,blocks=blocks}
					value=StudioHooks.recovery.mergeJournal(session,file,value)
					if session.recoveryBlocked then error(session.recoveryBlocked.." · "..key,0) end
				end
			end
			D.runtimeCache[file]=value return value
		end
	end
	function D.paths(session,create)
		if not session.recoveryKey then
			for _,row in ipairs(D.runtimeRows) do
				if row.job==game.JobId and row.buildId==session.buildId and row.bytes==#session.text and type(row.offset)=="table" and row.offset[1]==session.offset.X and row.offset[2]==session.offset.Y and row.offset[3]==session.offset.Z then
					local stored=D.readRuntime(row.key,"manifest")
					if stored and stored.text==session.text then session.recoveryKey=row.key break end
				end
			end
		end
		if not session.recoveryKey and create then
			session.recoveryKey=guid()
			D.runtimeRows[#D.runtimeRows+1]={key=session.recoveryKey,job=game.JobId,buildId=session.buildId,bytes=#session.text,offset={session.offset.X,session.offset.Y,session.offset.Z},pending=true}
		end
		if not session.recoveryKey then return "AutobuildRecovery.json","AutobuildPending.json" end
		return "OrbitRecovery_"..session.recoveryKey..".manifest.json","OrbitRecovery_"..session.recoveryKey..".pending.json"
	end
	function D.record(session)
		D.stash(session)
		local changed=false
		for _,row in ipairs(D.runtimeRows) do if row.key==session.recoveryKey then
			local pending=D.pending(session) if row.pending~=pending then row.pending=pending changed=true end
		end end
		if changed or D.savedRuntimeCount~=#D.runtimeRows then
			if writefile then pcall(function() writefile("OrbitSessions.json",HttpService:JSONEncode(D.runtimeRows)) end) end
			D.savedRuntimeCount=#D.runtimeRows
		end
		if session.recoveryKey then D.runtimeCache["OrbitRecovery_"..session.recoveryKey..".pending.json"]=nil D.runtimeCache["OrbitRecovery_"..session.recoveryKey..".manifest.json"]=nil end
	end
	if resumeSession then D.stash(resumeSession) end
	return D
end)()



local loadWarning=nil
if isfile and readfile then
	local ok, decoded=pcall(function()
		if not isfile(SAVE_FILE) then return nil end
		return HttpService:JSONDecode(readfile(SAVE_FILE))
	end)
	if ok and decoded~=nil and type(decoded)=="table" then
		StudioHooks.documents.freezeLegacy(SAVE_FILE,decoded)
		local clean, rejected={},0
		for _, tab in ipairs(decoded) do
			local content=StudioHooks.documents.hydrate(tab)
			if content~=nil then
				clean[#clean+1]={name=type(tab.name)=="string" and tab.name or "Build",content=content,contentFile=tab.contentFile,bytes=tab.bytes,unavailable=tab.unavailable,recoveredBackup=tab.recoveredBackup,id=type(tab.id)=="string" and tab.id or nil,placement=type(tab.placement)=="table" and tab.placement or nil,rotationPivot=type(tab.rotationPivot)=="table" and tab.rotationPivot or nil}
			else rejected=rejected+1 end
		end
		if #clean>0 then tabsData=clean end
		if rejected>0 or (#clean==0 and next(decoded)~=nil) then
			loadWarning="Часть файла вкладок не прочитана; исходный файл сохранён"
			SAVE_FILE="AutobuildData-v2-recovered.json"
		end
	elseif not ok or decoded~=nil then
		loadWarning="Ошибка чтения вкладок; исходный файл сохранён"
		SAVE_FILE="AutobuildData-v2-recovered.json"
	end
end
local function saveData()
	local historyOK,historyError=true,nil
	if StudioHooks.save then historyOK,historyError=pcall(StudioHooks.save) end
	if not writefile then storageError="Нет writefile; вкладки доступны только в этом запуске" return end
	local ok,err=pcall(function() local payload=HttpService:JSONEncode(StudioHooks.documents.manifest(tabsData))
		writefile(SAVE_FILE..".pending",payload)
		if readfile and isfile and isfile(SAVE_FILE) then
			local old=readfile(SAVE_FILE)
			local valid=pcall(function() HttpService:JSONDecode(old) end)
			if valid then writefile(SAVE_FILE..".backup",old) end
		end
		writefile(SAVE_FILE,payload)
		if readfile and readfile(SAVE_FILE)~=payload then error("Проверка сохранения не пройдена") end end)
	storageError=not ok and tostring(err) or not historyOK and tostring(historyError) or nil
end

-- Styling & Palette
local C_BLACK = Color3.fromRGB(10, 10, 14)
local C_GRAY = Color3.fromRGB(22, 24, 30)
local C_LIGHT_GRAY = Color3.fromRGB(36, 39, 48)
local C_GREEN = Color3.fromRGB(0, 255, 110)
local C_DARK_GREEN = Color3.fromRGB(0, 80, 35)
local C_RED = Color3.fromRGB(255, 60, 70)
local C_DARK_RED = Color3.fromRGB(110, 25, 30)
local C_WHITE = Color3.fromRGB(245, 245, 245)
local FONT_BOLD = Font.new([[rbxasset://fonts/families/Montserrat.json]], Enum.FontWeight.Medium, Enum.FontStyle.Normal)

local function create(className, properties)
	local instance = Instance.new(className)
	for k, v in pairs(properties) do instance[k] = v end
	if StudioHooks.style then StudioHooks.style(instance) end
	return instance
end

local function addCorner(parent, radius)
	return create("UICorner", {Parent = parent, CornerRadius = UDim.new(0, radius)})
end

local function addStroke(parent, thickness, color)
	return create("UIStroke", {
		Parent = parent,
		Thickness = thickness,
		Color = color,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	})
end

local gui = create("ScreenGui", {
	Name = "AUTOBUILD_TAG_UI",
	ResetOnSpawn = false,
	DisplayOrder = 999
})
local parentSuccess = pcall(function() gui.Parent = CoreGui end)
if not parentSuccess then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local normalSize = UDim2.new(0, 820, 0, 560)
local fullSize = UDim2.new(0, 1200, 0, 760)
local minimizedSize = UDim2.new(0, normalSize.X.Offset, 0, 46)
local isMinimized = false
local isMaximized = false

local mainFrame = create("Frame", {
	Parent = gui,
	Size = UDim2.new(0, 0, 0, 0),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = C_BLACK,
	Active = true,
	ClipsDescendants = true
})
addCorner(mainFrame, 14)

local mainStroke = addStroke(mainFrame, 2.5, C_GREEN)
local borderGradient = create("UIGradient", {
	Parent = mainStroke,
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C_GREEN),
		ColorSequenceKeypoint.new(0.3, C_DARK_GREEN),
		ColorSequenceKeypoint.new(0.5, C_GREEN),
		ColorSequenceKeypoint.new(0.8, C_DARK_GREEN),
		ColorSequenceKeypoint.new(1, C_GREEN)
	})
})

trackConn(RunService.RenderStepped:Connect(function(dt)
	-- Static border; no perpetual animation.
end))

-- Dragging Mechanics
local dragging, dragStart, startPos
local dragHeader = nil
trackConn(mainFrame.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if not dragHeader or input.Position.Y > dragHeader.AbsolutePosition.Y + dragHeader.AbsoluteSize.Y then return end
		dragging = true
		dragStart = input.Position
		startPos = mainFrame.Position
	end
end))
trackConn(mainFrame.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end))
trackConn(UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
end))

-- Header Bar
local header = create("Frame", {
	Parent = mainFrame,
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundTransparency = 1
})

dragHeader = header

local title = create("TextLabel", {
	Parent = header,
	Size = UDim2.new(1, -110, 1, 0),
	Position = UDim2.new(0, 12, 0, 0),
	BackgroundTransparency = 1,
	Text = "AUTO BUILD · GRID / PLAYERS / RESUME",
	TextColor3 = C_GREEN,
	FontFace = FONT_BOLD,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left
})

local controlContainer = create("Frame", {
	Parent = header,
	Size = UDim2.new(0, 95, 1, 0),
	Position = UDim2.new(1, -98, 0, 0),
	BackgroundTransparency = 1
})
create("UIListLayout", {
	Parent = controlContainer,
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 6)
})

local function createHeaderBtn(symbol, defaultColor, strokeColor, hoverBg)
	local btn = create("TextButton", {
		Parent = controlContainer,
		Size = UDim2.new(0, 24, 0, 24),
		BackgroundColor3 = C_GRAY,
		Text = symbol,
		TextColor3 = defaultColor or C_GREEN,
		FontFace = FONT_BOLD,
		TextSize = 13,
		AutoButtonColor = false
	})
	addCorner(btn, 6)
	local stroke = addStroke(btn, 1, strokeColor or C_DARK_GREEN)

	return btn
end

local btnMin = createHeaderBtn("-", C_GREEN, C_DARK_GREEN)
local btnMax = createHeaderBtn("□", C_GREEN, C_DARK_GREEN)
local btnClose = createHeaderBtn("✕", C_RED, C_DARK_RED, Color3.fromRGB(150, 30, 40))

local bodyFrame = create("Frame", {
	Parent = mainFrame,
	Size = UDim2.new(1, 0, 1, -36),
	Position = UDim2.new(0, 0, 0, 36),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Visible = false
})

local openTween = TweenService:Create(mainFrame, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Size = normalSize})
openTween:Play()
openTween.Completed:Connect(function()
	if not isMinimized then bodyFrame.Visible = true end
end)

btnMin.MouseButton1Click:Connect(function()
	isMinimized = not isMinimized
	btnMax.Visible = not isMinimized
	bodyFrame.Visible = false
	local targetSize = isMinimized and minimizedSize or (isMaximized and fullSize or normalSize)
	local tween = TweenService:Create(mainFrame, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = targetSize})
	tween:Play()
	tween.Completed:Connect(function()
		if not isMinimized then bodyFrame.Visible = true end
	end)
end)

btnMax.MouseButton1Click:Connect(function()
	if isMinimized then return end
	isMaximized = not isMaximized
	local targetSize = isMaximized and fullSize or normalSize
	TweenService:Create(mainFrame, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = targetSize}):Play()
end)

local unloadScript

trackConn(btnClose.MouseButton1Click:Connect(function()
	if unloadScript then unloadScript() end
end))

-- Tab Bar System
local tabSection = create("Frame", {
	Parent = bodyFrame,
	Size = UDim2.new(1, -20, 0, 34),
	Position = UDim2.new(0, 10, 0, 2),
	BackgroundTransparency = 1
})

local tabScroll = create("ScrollingFrame", {
	Parent = tabSection,
	Size = UDim2.new(1, -34, 1, 0),
	BackgroundTransparency = 1,
	ScrollBarThickness = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	ClipsDescendants = false
})

create("UIPadding", {
	Parent = tabScroll,
	PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
	PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3)
})

create("UIListLayout", {
	Parent = tabScroll,
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder
})

local addTabBtn = create("TextButton", {
	Parent = tabSection,
	Size = UDim2.new(0, 26, 0, 26),
	Position = UDim2.new(1, -26, 0, 3),
	BackgroundColor3 = C_GRAY,
	Text = "+",
	TextColor3 = C_GREEN,
	FontFace = FONT_BOLD,
	TextSize = 16
})
addCorner(addTabBtn, 6)
addStroke(addTabBtn, 1, C_DARK_GREEN)

-- Text Container
local editorFrame = create("Frame", {
	Parent = bodyFrame,
	Size = UDim2.new(1, -155, 1, -110),
	Position = UDim2.new(0, 10, 0, 40),
	BackgroundColor3 = C_GRAY
})
addCorner(editorFrame, 8)
addStroke(editorFrame, 1, C_DARK_GREEN)

local textScroll = create("ScrollingFrame", {
	Parent = editorFrame,
	Size = UDim2.new(1, -6, 1, -6),
	Position = UDim2.new(0, 3, 0, 3),
	BackgroundTransparency = 1,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = C_GREEN
})

local textBox = create("TextBox", {
	Parent = textScroll,
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1,
	TextColor3 = C_WHITE,
	FontFace = FONT_BOLD,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	MultiLine = true,
	ClearTextOnFocus = false,
	TextWrapped = true,
	PlaceholderText = "Paste your build code here..."
})

local function setEditorDisplay(value)
	updatingEditor=true
	local ok,err=pcall(function()
		textBox.Text=value editorDisplayText=value
		if StudioHooks.editor then StudioHooks.editor(value) end
	end)
	updatingEditor=false
	if StudioHooks.documents then StudioHooks.documents.renderFailed=not ok end
	pcall(function() textBox.TextEditable=ok and not _G.autobuildRunning and not busySaving end)
	if not ok and StudioHooks.documentStatus then StudioHooks.documentStatus("Отображение страницы: "..tostring(err),true) end
end
StudioHooks.renderDocument=setEditorDisplay

local function setBuildContent(value, keepRotationPivot)
	local tab=tabsData[activeTabIndex]
	if StudioHooks.documents then StudioHooks.documents.activate(tab,value) end
	if not keepRotationPivot then
		rotationPivot=tab.content==value and tab.rotationPivot or nil
		if type(rotationPivot)~="table" or type(rotationPivot.X)~="number" or type(rotationPivot.Z)~="number" then rotationPivot=nil end
	end
	tab.rotationPivot=rotationPivot
	if _G.buildOffset then local p=_G.buildOffset tab.placement={p.X,p.Y,p.Z} end
	_G.fullBuildString = value
	tabsData[activeTabIndex].content = value
	if StudioHooks.content then StudioHooks.content(value) end
	invalidatePreparedPlan()
	local displayValue=StudioHooks.documents and StudioHooks.documents.view(tab,value) or value:gsub("%|%|","|\n|")
	setEditorDisplay(displayValue)
	if tab.unavailable and StudioHooks.documentStatus then StudioHooks.documentStatus("Файл постройки недоступен: "..tostring(tab.contentFile)..". Ссылка и резервные файлы сохранены.",true) end
	saveData()
end

-- Action Buttons Column
local sideContainer = create("ScrollingFrame", {
	Parent = bodyFrame,
	Size = UDim2.new(0, 130, 1, -110),
	Position = UDim2.new(1, -140, 0, 40),
	BackgroundTransparency = 1,
	ScrollBarThickness = 2,
	ScrollBarImageColor3 = C_GREEN,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y
})
create("UIListLayout", {
	Parent = sideContainer,
	FillDirection = Enum.FillDirection.Vertical,
	Padding = UDim.new(0, 4),
	SortOrder = Enum.SortOrder.LayoutOrder
})

local function createActionButton(name, text, height, order)
	local btn = create("TextButton", {
		Parent = sideContainer,
		Size = UDim2.new(1, -4, 0, height),
		BackgroundColor3 = C_GRAY,
		Text = text,
		TextColor3 = C_GREEN,
		FontFace = FONT_BOLD,
		TextSize = 10,
		TextWrapped = true,
		LayoutOrder = order,
		Name = name,
		AutoButtonColor = false
	})
	addCorner(btn, 6)
	local stroke = addStroke(btn, 1, C_DARK_GREEN)

	return btn, stroke
end

local btnStart = createActionButton("Build", "СТРОИТЬ", 32, 1)
local btnImport = createActionButton("Import", "ПРЕДПРОСМОТР", 26, 2)
local btnToMe = createActionButton("ToMe", "КО МНЕ", 24, 3)
local btnRot90 = createActionButton("Rot90", "ПОВОРОТ 90°", 22, 4)
local btnRot180 = createActionButton("Rot180", "ПОВОРОТ 180°", 22, 5)
local btnRotNeg90 = createActionButton("RotNeg90", "ПОВОРОТ -90°", 22, 6)
local btnPaste = createActionButton("Paste", "ВСТАВИТЬ", 24, 7)
local btnCopy = createActionButton("Copy", "КОПИРОВАТЬ", 24, 8)
local btnSave = createActionButton("Save", "СОХРАНИТЬ", 24, 9)
local btnMode = createActionButton("SaveMode", "MODE: YOU", 22, 10)
local btnClear = createActionButton("Clear", "ОЧИСТИТЬ", 22, 11)
local btnSnap = createActionButton("SnapGrid", "НА СЕТКУ", 26, 12)
local btnNextChunk = createActionButton("NextChunk", "NEXT CHUNK", 22, 13)
btnNextChunk.Visible = false
local btnLog = createActionButton("Diagnostic", "ДИАГНОСТИКА", 26, 14)

-- Footer Stats Bar
local footerFrame = create("Frame", {
	Parent = bodyFrame,
	Size = UDim2.new(1, -20, 0, 58),
	Position = UDim2.new(0, 10, 1, -62),
	BackgroundTransparency = 1
})

local statDisplay = create("TextLabel", {
	Parent = footerFrame,
	Size = UDim2.new(0.68, 0, 0, 22),
	BackgroundTransparency = 1,
	TextColor3 = C_GREEN,
	FontFace = FONT_BOLD,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	RichText = true,
	Text = "Blocks: 0  |  Chars: 0"
})

local perfDisplay = create("TextLabel", {
	Parent = footerFrame,
	Size = UDim2.new(0.32, 0, 0, 22),
	Position = UDim2.new(0.68, 0, 0, 0),
	BackgroundTransparency = 1,
	TextColor3 = C_GREEN,
	FontFace = FONT_BOLD,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Right,
	RichText = true,
	Text = "FPS: 60  |  Ping: 0ms"
})

local statusLabel = create("TextLabel", {Parent=footerFrame, Size=UDim2.new(1,0,0,34), Position=UDim2.new(0,0,0,23), BackgroundTransparency=1, Text="Готов к работе · перемещение по сетке 4", TextColor3=C_WHITE, TextSize=12, FontFace=FONT_BOLD, TextWrapped=true, TextXAlignment=Enum.TextXAlignment.Left})
local diagnosticLog = {}
local function setStatus(message, failure)
	local stair=StudioHooks.stairwell
	if stair and stair.context and StudioHooks.stairStatus then
		stair.message="Этаж "..tostring(stair.context.stairFloor or "").." · "..tostring(message)
		StudioHooks.stairStatus(stair.message)
	end
	if unloaded then return end
	message=tostring(message or "")
	if storageError then message=message.." · вкладки не записаны в файл" end
	diagnosticLog[#diagnosticLog+1]=os.date("%H:%M:%S").." "..message
	if #diagnosticLog>100 then table.remove(diagnosticLog,1) end
	if StudioHooks.status then StudioHooks.status() end
	if failure then warn("AUTOBUILD: "..message) else print("AUTOBUILD: "..message) end
end
StudioHooks.documentStatus=setStatus
local function copyText(text)
	local writer=setclipboard or (syn and syn.set_clipboard) or (Clipboard and Clipboard.set)
	if not writer then return false end
	return pcall(writer,text)
end
local function exportToClipboard(text)
	_G.buildChunks=nil
	_G.totalChunks=nil
	_G.currentChunk=nil
	btnNextChunk.Visible=false
	if #text<=190000 then return copyText(text) end
	local chunks, current, length={}, {}, 0
	for record in text:gmatch("|[^|]+|") do
		if #record>190000 then setStatus("Одна запись превышает лимит буфера",true) return false end
		if length+#record>190000 then chunks[#chunks+1]=table.concat(current) current={} length=0 end
		current[#current+1]=record
		length=length+#record
	end
	if length>0 then chunks[#chunks+1]=table.concat(current) end
	if #chunks==0 then return false end
	_G.buildChunks=chunks
	_G.totalChunks=#chunks
	_G.currentChunk=1
	btnNextChunk.Visible=#chunks>1
	return copyText(chunks[1])
end

local function updateDefaultStats()
	local text = _G.fullBuildString or textBox.Text
	local blockCount = 0
	if StudioHooks.documents then blockCount=StudioHooks.documents.metrics() else for _ in text:gmatch("|[^|]+|") do blockCount=blockCount+1 end end
	statDisplay.Text = "Blocks: " .. blockCount .. "  |  Chars: " .. #text
end

btnLog.MouseButton1Click:Connect(function()
	local text="Autobuild Studio v5 / ORBIT · stairwell-20\n"..table.concat(diagnosticLog,"\n")
	if storageError then text=text.."\nStorage: "..storageError end
	if copyText(text) then setStatus("Диагностика скопирована") else setStatus("Буфер обмена недоступен",true) end
end)

-- Tab Management
local tabElements = {}
local function renderTabs()
	for _, v in ipairs(tabElements) do v:Destroy() end
	tabElements = {}

	for i, tab in ipairs(tabsData) do
		local isCurrent = (i == activeTabIndex)
		local tFrame = create("Frame", {
			Parent = tabScroll,
			Size = UDim2.new(0, 148, 1, -2),
			BackgroundColor3 = isCurrent and C_BLACK or C_GRAY,
			LayoutOrder = i
		})
		addCorner(tFrame, 6)
		local stroke = addStroke(tFrame, 1, C_DARK_GREEN)
		if isCurrent then create("Frame",{Parent=tFrame,Position=UDim2.new(0,0,1,-2),Size=UDim2.new(1,0,0,2),BackgroundColor3=C_GREEN,BorderSizePixel=0}) end

		local tBtn = create("TextButton", {
			Parent = tFrame,
			Size = UDim2.new(1, -20, 1, 0),
			BackgroundTransparency = 1,
			Text = tab.name,
			TextColor3 = isCurrent and C_GREEN or C_WHITE,
			FontFace = FONT_BOLD,
			TextSize = 11,
			TextTruncate = Enum.TextTruncate.AtEnd
		})

		local delBtn = create("TextButton", {
			Parent = tFrame,
			Size = UDim2.new(0, 16, 0, 16),
			Position = UDim2.new(1, -18, 0.5, -8),
			BackgroundTransparency = 1,
			Text = "×",
			TextColor3 = isCurrent and C_GREEN or Color3.fromRGB(150, 150, 150),
			FontFace = FONT_BOLD,
			TextSize = 10
		})

		tBtn.MouseButton1Click:Connect(function()
	local action=function()
			if _G.autobuildRunning or busySaving then return end
	local previous=tabsData[activeTabIndex] local p=_G.buildOffset or Vector3.zero
			previous.placement={p.X,p.Y,p.Z}
			activeTabIndex = i
			if StudioHooks.restorePlacement then StudioHooks.restorePlacement() else _G.buildOffset=Vector3.zero end
			if StudioHooks.hidePreview then StudioHooks.hidePreview() end
			setBuildContent(tab.content)
			renderTabs()
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
		end)

		tBtn.MouseButton2Click:Connect(function()
			if _G.autobuildRunning or busySaving then return end
			local rename=create("TextBox",{Parent=tFrame,Size=UDim2.new(1,-20,1,0),BackgroundColor3=C_GRAY,Text=tab.name,TextColor3=C_WHITE,FontFace=FONT_BOLD,TextSize=11,ClearTextOnFocus=false,ZIndex=5})
			rename:CaptureFocus()
			rename.FocusLost:Connect(function()
				local name=rename.Text:gsub("^%s+",""):gsub("%s+$","")
				if name~="" and not _G.autobuildRunning and not busySaving then tab.name=name saveData() end
				renderTabs()
			end)
		end)
		delBtn.MouseButton1Click:Connect(function()
	local action=function()
			if _G.autobuildRunning or busySaving then return end
	if StudioHooks.documents then StudioHooks.documents.discard(tab) end
	if #tabsData <= 1 then
				tabsData[1] = {name = "Build 1", content = ""}
				activeTabIndex = 1
			else
				table.remove(tabsData, i)
				if activeTabIndex >= i then
					activeTabIndex = math.max(1, activeTabIndex - 1)
				end
			end
			if StudioHooks.restorePlacement then StudioHooks.restorePlacement() end
			setBuildContent(tabsData[activeTabIndex].content)
			saveData()
			renderTabs()
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
		end)

		table.insert(tabElements, tFrame)
	end
	tabScroll.CanvasSize = UDim2.new(0, #tabsData * 156 + 6, 0, 0)
end

addTabBtn.MouseButton1Click:Connect(function()
	local action=function()
	if _G.autobuildRunning or busySaving then return end
	table.insert(tabsData, {name = "Build " .. (#tabsData + 1), content = ""})
	activeTabIndex = #tabsData
	_G.buildOffset=Vector3.zero
	if StudioHooks.hidePreview then StudioHooks.hidePreview() end
	setBuildContent("")
	saveData()
	renderTabs()
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
end)

textBox:GetPropertyChangedSignal("Text"):Connect(function()
	if updatingEditor or textBox.Text == editorDisplayText then return end
	if _G.autobuildRunning or busySaving then setEditorDisplay(StudioHooks.documents.view(tabsData[activeTabIndex],tabsData[activeTabIndex].content)) return end
	local value=StudioHooks.documents.edit(textBox.Text)
	editorDisplayText = nil
	rotationPivot = nil
	tabsData[activeTabIndex].rotationPivot=nil
	tabsData[activeTabIndex].content = value
	if StudioHooks.content then StudioHooks.content(value) end
	_G.fullBuildString = value
	if StudioHooks.hidePreview then StudioHooks.hidePreview() end
	invalidatePreparedPlan()
	saveRevision = saveRevision + 1
	local revision = saveRevision
	task.delay(.4, function() if not unloaded and revision == saveRevision then saveData() end end)

	setEditorDisplay(StudioHooks.documents.view(tabsData[activeTabIndex],value))

	if not _G.autobuildRunning then updateDefaultStats() end
end)

setBuildContent(tabsData[activeTabIndex].content or "")
renderTabs()
if loadWarning then setStatus(loadWarning,true) elseif storageError then setStatus(storageError,true) end

-- Mapping Tables
local SymbolToMaterial = {
	["!"] = Enum.Material.SmoothPlastic, ["@"] = Enum.Material.Plastic, ["#"] = Enum.Material.CeramicTiles,
	["$"] = Enum.Material.Brick, ["%"] = Enum.Material.WoodPlanks, ["^"] = Enum.Material.Ice,
	["&"] = Enum.Material.Grass, ["*"] = Enum.Material.Sand, ["("] = Enum.Material.Snow,
	[")"] = Enum.Material.Glass, ["-"] = Enum.Material.Wood, ["_"] = Enum.Material.Slate,
	["="] = Enum.Material.Pebble, ["+"] = Enum.Material.Marble, ["["] = Enum.Material.Granite,
	["]"] = Enum.Material.DiamondPlate, ["{"] = Enum.Material.Metal, ["}"] = Enum.Material.Asphalt,
	["~"] = Enum.Material.Concrete, ["`"] = Enum.Material.Pavement, ["?"] = Enum.Material.Neon
}
local MaterialSymbols = {}
for k, v in pairs(SymbolToMaterial) do MaterialSymbols[v] = k end

local MaterialToPaintName = {
	[Enum.Material.SmoothPlastic] = "smooth", [Enum.Material.Plastic] = "plastic",
	[Enum.Material.CeramicTiles] = "tiles", [Enum.Material.Brick] = "bricks",
	[Enum.Material.WoodPlanks] = "planks", [Enum.Material.Ice] = "ice",
	[Enum.Material.Grass] = "grass", [Enum.Material.Sand] = "sand",
	[Enum.Material.Snow] = "snow", [Enum.Material.Glass] = "glass",
	[Enum.Material.Wood] = "wood", [Enum.Material.Slate] = "stone",
	[Enum.Material.Pebble] = "pebble", [Enum.Material.Marble] = "marble",
	[Enum.Material.Granite] = "granite", [Enum.Material.DiamondPlate] = "steel",
	[Enum.Material.Metal] = "metal", [Enum.Material.Asphalt] = "asphalt",
	[Enum.Material.Concrete] = "concrete", [Enum.Material.Pavement] = "pavement",
	[Enum.Material.Neon] = "neon"
}

local FaceSymbols = {
	[Enum.NormalId.Left] = "L", [Enum.NormalId.Right] = "R", [Enum.NormalId.Top] = "T",
	[Enum.NormalId.Bottom] = "Bo", [Enum.NormalId.Front] = "F", [Enum.NormalId.Back] = "Ba"
}
local FaceSymbolsReverse = {
	L = Enum.NormalId.Left, R = Enum.NormalId.Right, T = Enum.NormalId.Top,
	Bo = Enum.NormalId.Bottom, F = Enum.NormalId.Front, Ba = Enum.NormalId.Back
}

local function hexToColor(hex)
	local r = (tonumber(hex:sub(1, 2), 16) or 255) / 255
	local g = (tonumber(hex:sub(3, 4), 16) or 255) / 255
	local b = (tonumber(hex:sub(5, 6), 16) or 255) / 255
	return Color3.new(r, g, b)
end

local function getSafePing()
	local ok, ping = pcall(function() return LocalPlayer:GetNetworkPing() end)
	if not ok or type(ping)~="number" or ping~=ping or ping<=0 or ping==math.huge then ping=0.05 end
	return ping
end

local function isGridAligned(coord)
	local m = ((coord % 4) + 4) % 4
	return math.abs(m - 2) < 0.001
end

local function colorHex(color)
	return string.format("%02X%02X%02X", math.clamp(math.round(color.R*255),0,255), math.clamp(math.round(color.G*255),0,255), math.clamp(math.round(color.B*255),0,255))
end
-- Mark escaped text explicitly, leaving legacy strings untouched.
local function encodeSpray(text)
	return "@E:" .. text:gsub("%%","%%25"):gsub('"',"%%22"):gsub("|","%%7C"):gsub("\r","%%0D"):gsub("\n","%%0A")
end
local function decodeSpray(text)
	if text:sub(1,3) ~= "@E:" then return text end
	return (text:sub(4):gsub("%%(%x%x)",function(hex) return string.char(tonumber(hex,16)) end))
end
local function serializeBlock(b)
	local sprays={}
	for _, spray in ipairs(b.sprays or {}) do
		sprays[#sprays+1]=string.format('%s"%s""%s"', FaceSymbols[spray.face], encodeSpray(spray.text), spray.colorHex)
	end
	local extra=#sprays>0 and "."..table.concat(sprays,"..") or ""
	return string.format("|%s%s%s%.0f,%.0f,%.0f.%.6f,%.6f,%.6f%s.|",colorHex(b.color), MaterialSymbols[b.material],b.canCollide and "" or "^",b.size.X,b.size.Y,b.size.Z,b.centerPos.X,b.centerPos.Y,b.centerPos.Z,extra)
end
parseBlocks=function(text, offset)
	offset=offset or Vector3.zero
	local blocks,invalid={},0
	if type(text)~="string" then return blocks,1 end
	local cursor=1
	local number="([%-]?%d+%.?%d*)"
	local pattern="^(%x%x%x%x%x%x)(.)(%^?)(%d+),(%d+),(%d+)%."..number..","..number..","..number.."(.*)$"
	while cursor<=#text do
		local left=text:find("|",cursor,true)
		if not left then
			if text:sub(cursor):find("%S") then invalid=invalid+1 end
			break
		end
		if text:sub(cursor,left-1):find("%S") then invalid=invalid+1 end
		local right=text:find("|",left+1,true)
		if not right then invalid=invalid+1 break end
		local record=text:sub(left+1,right-1)
		cursor=right+1
		if record=="" then continue end
		local hex,symbol,marker,sx,sy,sz,px,py,pz,extra=record:match(pattern)
		if not hex or not SymbolToMaterial[symbol] then invalid=invalid+1 continue end
		local size=Vector3.new(tonumber(sx),tonumber(sy),tonumber(sz))
		local position=Vector3.new(tonumber(px),tonumber(py),tonumber(pz))+offset
		if size.X<1 or size.Y<1 or size.Z<1 or size.X>4096 or size.Y>4096 or size.Z>4096 or math.abs(position.X)>1000000 or math.abs(position.Y)>1000000 or math.abs(position.Z)>1000000 then invalid=invalid+1 continue end
		local sprays={}
		local consumed=extra:gsub('(%a+)"([^"]*)""(%x%x%x%x%x%x)"',function(face,label,color)
			if not FaceSymbolsReverse[face] then invalid=invalid+1 return "" end
			sprays[#sprays+1]={face=FaceSymbolsReverse[face],text=decodeSpray(label),colorHex=color}
			return ""
		end)
		if consumed:gsub("%.",""):find("%S") then invalid=invalid+1 continue end
		local normal=size==Vector3.new(4,4,4) and isGridAligned(position.X) and isGridAligned(position.Y) and isGridAligned(position.Z)
		blocks[#blocks+1]={size=size,centerPos=position,color=hexToColor(hex),material=SymbolToMaterial[symbol],canCollide=marker~="^",needsResize=not normal,sprays=sprays}
	end
	return blocks,invalid
end


-- Snap the translation, never individual parts: mixed builds keep their geometry.
local function snapBuildOffset(offset)
	local step = CONFIG.GRID_STEP
	return Vector3.new(math.round(offset.X / step) * step,
		math.round(offset.Y / step) * step, math.round(offset.Z / step) * step)
end

-- Visuals & Handles
local visualsShowing = false
local visualFolder = nil
local centerPart = nil
local handles = nil
local originalCenterPos = Vector3.new()
_G.buildOffset = Vector3.zero

local function cleanupVisuals(preserveOffset)
	if StudioHooks.documents then StudioHooks.documents.visualRevision+=1 end
	if visualFolder then visualFolder:Destroy() visualFolder = nil end
	if handles then handles:Destroy() handles = nil end
	centerPart = nil
	visualsShowing = false
	_G.visualsEnabled = false
	if not preserveOffset then
		_G.buildOffset = Vector3.zero
	end
	btnImport.Text = "Предпросмотр"
end

StudioHooks.hidePreview=function() cleanupVisuals(true) end
local function showVisuals()
	local buildString = (_G.fullBuildString and _G.fullBuildString ~= "") and _G.fullBuildString or textBox.Text
	if buildString == "" then return end

	local blocks, invalid = parseBlocks(buildString, Vector3.zero)
	if #blocks == 0 or invalid > 0 then setStatus("Некорректное сохранение: " .. invalid, true) return end

	local savedOffset = snapBuildOffset(_G.buildOffset or Vector3.zero)
	cleanupVisuals(true)
	visualFolder = create("Folder", {Name = "BuildVisuals", Parent = workspace})
	local previewFolder=visualFolder
	local previewRevision=StudioHooks.documents and StudioHooks.documents.visualRevision

	local minB = Vector3.new(math.huge, math.huge, math.huge)
	local maxB = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, b in ipairs(blocks) do
		local half = b.size / 2
		minB = Vector3.new(math.min(minB.X, b.centerPos.X - half.X), math.min(minB.Y, b.centerPos.Y - half.Y), math.min(minB.Z, b.centerPos.Z - half.Z))
		maxB = Vector3.new(math.max(maxB.X, b.centerPos.X + half.X), math.max(maxB.Y, b.centerPos.Y + half.Y), math.max(maxB.Z, b.centerPos.Z + half.Z))
	end
	originalCenterPos = Vector3.new((minB.X + maxB.X) / 2, maxB.Y + 2, (minB.Z + maxB.Z) / 2)

	centerPart = create("Part", {
		Name = "CenterHandle",
		Size = Vector3.new(2, 2, 2),
		Position = originalCenterPos + savedOffset,
		Anchored = true,
		CanCollide = false,
		Transparency = 1,
		Parent = visualFolder
	})

	for i, b in ipairs(blocks) do
		if i%128==0 then task.wait() end
		if unloaded or visualFolder~=previewFolder or StudioHooks.documents and previewRevision~=StudioHooks.documents.visualRevision then return end
		if resumeSession and resumeSession.text == buildString and resumeSession.offset == savedOffset and resumeSession.done[i] and resumeSession.blocks[i].placedBrick and resumeSession.blocks[i].placedBrick.Parent then continue end
		create("Part", {
			Name = "Visual_" .. i,
			Size = b.size,
			CFrame = CFrame.new(b.centerPos + savedOffset),
			Anchored = true,
			CanCollide = false,
			Material = b.material,
			Color = b.color,
			Transparency = 0.45,
			Parent = visualFolder
		})
	end

	handles = create("Handles", {
		Parent = CoreGui,
		Style = Enum.HandlesStyle.Movement,
		Adornee = centerPart
	})

	local isDragging = false
	local startPositions = {}

	handles.MouseButton1Down:Connect(function()
		if _G.autobuildRunning then return end
		if StudioHooks.beforeTransform then local ok,message=StudioHooks.beforeTransform() if not ok then setStatus(message,true) return end end
		isDragging = true
		startPositions = {}
		for _, child in pairs(visualFolder:GetChildren()) do
			if child:IsA("BasePart") then
				startPositions[child] = child.Position
			end
		end
	end)

	handles.MouseDrag:Connect(function(face, distance)
		if not isDragging or not centerPart or visualFolder~=previewFolder or StudioHooks.documents and previewRevision~=StudioHooks.documents.visualRevision then return end
		local direction = Vector3.FromNormalId(face)
		local snappedDistance = math.round(distance / CONFIG.GRID_STEP) * CONFIG.GRID_STEP
		local offset = direction * snappedDistance
		for part, startPos in pairs(startPositions) do
			if part and part.Parent then
				part.Position = startPos + offset
			end
		end
		_G.buildOffset = centerPart.Position - originalCenterPos
	tabsData[activeTabIndex].placement={_G.buildOffset.X,_G.buildOffset.Y,_G.buildOffset.Z}
	saveData()
	invalidatePreparedPlan()
	end)

	handles.MouseButton1Up:Connect(function()
		isDragging = false
		startPositions = {}
	end)

	visualsShowing = true
	_G.visualsEnabled = true
	_G.buildOffset = savedOffset
	btnImport.Text = "Скрыть preview"
	if StudioHooks.preview then StudioHooks.preview() end
	return true
end

btnImport.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	if visualsShowing then
		cleanupVisuals(true)
	else
		showVisuals()
	end
end)

btnToMe.MouseButton1Click:Connect(function()
	local action=function()
	if StudioHooks.beforeTransform then local ok,message=StudioHooks.beforeTransform() if not ok then setStatus(message,true) return end end
	if _G.autobuildRunning or busySaving then return end
	if not visualsShowing or not centerPart or not visualFolder then if not showVisuals() then return end end
	if not centerPart or not visualFolder then return end
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local targetPos = hrp.Position + (hrp.CFrame.LookVector * 14)
	local targetOffset = snapBuildOffset(targetPos - originalCenterPos)
	local delta = originalCenterPos + targetOffset - centerPart.Position

	for _, child in pairs(visualFolder:GetChildren()) do
		if child:IsA("BasePart") then
			child.Position = child.Position + delta
		end
	end
	_G.buildOffset = centerPart.Position - originalCenterPos
	tabsData[activeTabIndex].placement={_G.buildOffset.X,_G.buildOffset.Y,_G.buildOffset.Z}
	saveData()
	invalidatePreparedPlan()
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
end)

btnSnap.MouseButton1Click:Connect(function()
	local action=function()
	if StudioHooks.beforeTransform then local ok,message=StudioHooks.beforeTransform() if not ok then setStatus(message,true) return end end
	if _G.autobuildRunning or busySaving then return end
	_G.buildOffset = snapBuildOffset(_G.buildOffset or Vector3.zero)
	showVisuals()
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
end)

-- ============================================================================
-- БРОНЕБОЙНАЯ МАТЕМАТИКА ПОВОРОТА ПО ВОКСЕЛЬНОЙ СЕТКЕ
-- ============================================================================
local function rotateBuild(angle)
	if _G.autobuildRunning and StudioHooks.documents then StudioHooks.documents.runUI(function() rotateBuild(angle) end) return end
	local buildString = (_G.fullBuildString and _G.fullBuildString ~= "") and _G.fullBuildString or textBox.Text
	if buildString == "" or _G.autobuildRunning or busySaving then return end
	if StudioHooks.beforeTransform then local ok,message=StudioHooks.beforeTransform() if not ok then setStatus(message,true) return end end

	local blocks, invalid = parseBlocks(buildString, Vector3.zero)
	if #blocks == 0 or invalid > 0 then setStatus("Некорректное сохранение: " .. invalid, true) return end

	-- 1. Вычисляем точные глобальные границы всей постройки
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local is4x4Structure = true

	for _, b in ipairs(blocks) do
		local hX = b.size.X / 2
		local hZ = b.size.Z / 2
		local bMinX = b.centerPos.X - hX
		local bMaxX = b.centerPos.X + hX
		local bMinZ = b.centerPos.Z - hZ
		local bMaxZ = b.centerPos.Z + hZ

		minX = math.min(minX, bMinX)
		maxX = math.max(maxX, bMaxX)
		minZ = math.min(minZ, bMinZ)
		maxZ = math.max(maxZ, bMaxZ)

		if b.size.X ~= 4 or b.size.Y ~= 4 or b.size.Z ~= 4 or not (isGridAligned(b.centerPos.X) and isGridAligned(b.centerPos.Z)) then
			is4x4Structure = false
		end
	end

	-- 2. Центр вращения привязывается к целочисленной или 4-студовой сетке
	-- A pivot on 4Z preserves the normal cube grid even in mixed builds.
	if not rotationPivot then rotationPivot = {X=math.floor((minX + maxX) / 8)*4, Z=math.floor((minZ + maxZ) / 8)*4} end
	local pivotX, pivotZ = rotationPivot.X, rotationPivot.Z

	-- 3. Маппинг сторон спреев
	local faceMap = {}
	if angle == 90 then
		faceMap = {
			[Enum.NormalId.Left] = Enum.NormalId.Front,
			[Enum.NormalId.Front] = Enum.NormalId.Right,
			[Enum.NormalId.Right] = Enum.NormalId.Back,
			[Enum.NormalId.Back] = Enum.NormalId.Left,
			[Enum.NormalId.Top] = Enum.NormalId.Top,
			[Enum.NormalId.Bottom] = Enum.NormalId.Bottom
		}
	elseif angle == -90 then
		faceMap = {
			[Enum.NormalId.Left] = Enum.NormalId.Back,
			[Enum.NormalId.Back] = Enum.NormalId.Right,
			[Enum.NormalId.Right] = Enum.NormalId.Front,
			[Enum.NormalId.Front] = Enum.NormalId.Left,
			[Enum.NormalId.Top] = Enum.NormalId.Top,
			[Enum.NormalId.Bottom] = Enum.NormalId.Bottom
		}
	elseif angle == 180 then
		faceMap = {
			[Enum.NormalId.Left] = Enum.NormalId.Right,
			[Enum.NormalId.Right] = Enum.NormalId.Left,
			[Enum.NormalId.Front] = Enum.NormalId.Back,
			[Enum.NormalId.Back] = Enum.NormalId.Front,
			[Enum.NormalId.Top] = Enum.NormalId.Top,
			[Enum.NormalId.Bottom] = Enum.NormalId.Bottom
		}
	end

	-- 4. Пересчет каждого блока с гарантией целостности сетки
	local rotatedRecords = {}
	for _, b in ipairs(blocks) do
		local minX_b = (b.centerPos.X - b.size.X / 2)
		local maxX_b = (b.centerPos.X + b.size.X / 2)
		local minZ_b = (b.centerPos.Z - b.size.Z / 2)
		local maxZ_b = (b.centerPos.Z + b.size.Z / 2)

		local nMinX, nMaxX, nMinZ, nMaxZ, nSize

		if angle == 90 then
			nMinX = pivotX - (maxZ_b - pivotZ)
			nMaxX = pivotX - (minZ_b - pivotZ)
			nMinZ = pivotZ + (minX_b - pivotX)
			nMaxZ = pivotZ + (maxX_b - pivotX)
			nSize = Vector3.new(b.size.Z, b.size.Y, b.size.X)
		elseif angle == -90 then
			nMinX = pivotX + (minZ_b - pivotZ)
			nMaxX = pivotX + (maxZ_b - pivotZ)
			nMinZ = pivotZ - (maxX_b - pivotX)
			nMaxZ = pivotZ - (minX_b - pivotX)
			nSize = Vector3.new(b.size.Z, b.size.Y, b.size.X)
		elseif angle == 180 then
			nMinX = pivotX - (maxX_b - pivotX)
			nMaxX = pivotX - (minX_b - pivotX)
			nMinZ = pivotZ - (maxZ_b - pivotZ)
			nMaxZ = pivotZ - (minZ_b - pivotZ)
			nSize = Vector3.new(b.size.X, b.size.Y, b.size.Z)
		end

		local nCenterX = (nMinX + nMaxX) / 2
		local nCenterZ = (nMinZ + nMaxZ) / 2
		local nCenterY = b.centerPos.Y -- Высота Y никогда не смещается!

		local colorHex = colorHex(b.color)
		local matSym = MaterialSymbols[b.material] or "!"
		local canColMarker = b.canCollide and "" or "^"

		local spraysList = {}
		if b.sprays then
			for _, sp in ipairs(b.sprays) do
				local rotFace = faceMap[sp.face] or sp.face
				local faceSym = FaceSymbols[rotFace] or "T"
				table.insert(spraysList, string.format('%s"%s""%s"', faceSym, encodeSpray(sp.text or ""), sp.colorHex or "FFFFFF"))
			end
		end
		local spraysStr = #spraysList > 0 and "." .. table.concat(spraysList, "..") or ""

		rotatedRecords[#rotatedRecords+1] = string.format("|%s%s%s%.0f,%.0f,%.0f.%.6f,%.6f,%.6f%s.|",
			colorHex, matSym, canColMarker, nSize.X, nSize.Y, nSize.Z, nCenterX, nCenterY, nCenterZ, spraysStr)
	end

	setBuildContent(table.concat(rotatedRecords), true)
	updateDefaultStats()

	if visualsShowing then
		showVisuals()
	end
end

btnRot90.MouseButton1Click:Connect(function() rotateBuild(90) end)
btnRot180.MouseButton1Click:Connect(function() rotateBuild(180) end)
btnRotNeg90.MouseButton1Click:Connect(function() rotateBuild(-90) end)

btnPaste.MouseButton1Click:Connect(function()
	local action=function()
	if _G.autobuildRunning or busySaving then return end
	local reader=getclipboard or (syn and syn.get_clipboard) or (Clipboard and Clipboard.get)
	local ok,value=false,nil
	if reader then ok,value=pcall(reader) end
	if not ok or type(value)~="string" or value=="" then setStatus("Буфер обмена пуст или недоступен",true) return end
	cleanupVisuals(false) setBuildContent(value) updateDefaultStats()
	if StudioHooks.controls then StudioHooks.controls() end
	setStatus("Код вставлен")
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
end)
btnCopy.MouseButton1Click:Connect(function()
	local ok=exportToClipboard(_G.fullBuildString or textBox.Text)
	setStatus(ok and "Код скопирован" or "Буфер обмена недоступен",not ok)
end)

btnClear.MouseButton1Click:Connect(function()
	local action=function()
	if _G.autobuildRunning or busySaving then return end
	setBuildContent("")
	_G.buildChunks = nil
	_G.totalChunks = nil
	_G.currentChunk = nil
	btnNextChunk.Visible = false
	cleanupVisuals(false)
	updateDefaultStats()
	end
	if StudioHooks.documents then StudioHooks.documents.runUI(action) else action() end
end)

local selectedOwners = {[LocalPlayer.Name] = true}
local picker = create("Frame", {Parent=mainFrame, Size=UDim2.new(1,-20,1,-48), Position=UDim2.new(0,10,0,40), BackgroundColor3=C_BLACK, Visible=false, ZIndex=20})
addCorner(picker, 10)
addStroke(picker, 1, C_GREEN)
local search = create("TextBox", {Parent=picker, Size=UDim2.new(1,-20,0,28), Position=UDim2.new(0,10,0,10), BackgroundColor3=C_GRAY, Text="", PlaceholderText="Поиск: имя или ник игрока", ClearTextOnFocus=false, TextColor3=C_WHITE, FontFace=FONT_BOLD, TextSize=13, ZIndex=21})
addCorner(search, 5)
local choices = create("ScrollingFrame", {Parent=picker, Size=UDim2.new(1,-20,1,-115), Position=UDim2.new(0,10,0,48), BackgroundTransparency=1, ScrollBarThickness=5, CanvasSize=UDim2.new(), AutomaticCanvasSize=Enum.AutomaticSize.Y, ZIndex=21})
create("UIListLayout", {Parent=choices, Padding=UDim.new(0,5), SortOrder=Enum.SortOrder.LayoutOrder})
local pickerButtons = create("Frame", {Parent=picker, Size=UDim2.new(1,-20,0,52), Position=UDim2.new(0,10,1,-60), BackgroundTransparency=1, ZIndex=21})
create("UIListLayout", {Parent=pickerButtons, FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,5)})
local function pickerButton(text)
	local button=create("TextButton", {Parent=pickerButtons, Size=UDim2.new(.24,0,1,0), BackgroundColor3=C_GRAY, Text=text, TextColor3=C_GREEN, TextWrapped=true, FontFace=FONT_BOLD, TextSize=12, ZIndex=22})
	addCorner(button,5)
	return button
end
local meButton, allButton, noneButton, doneButton = pickerButton("Я"), pickerButton("Все"), pickerButton("Снять"), pickerButton("Готово")
local function ownerNames()
	local folder=workspace:FindFirstChild("Bricks")
	local names={}
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Folder") or child:IsA("Model") then names[#names+1]=child.Name end
		end
	end
	if not table.find(names, LocalPlayer.Name) then names[#names+1]=LocalPlayer.Name end
	table.sort(names)
	return names
end
local function updateSelectionLabel()
	local count=0
	for _, value in pairs(selectedOwners) do if value then count=count+1 end end
	btnMode.Text="ИГРОКИ: "..count
end
local function renderOwnerList()
	for _, child in ipairs(choices:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
	local query=search.Text:lower()
	for i, name in ipairs(ownerNames()) do
		local player=Players:FindFirstChild(name)
		local display=player and player.DisplayName or "нет на сервере"
		if query=="" or (name.." "..display):lower():find(query,1,true) then
			local own=workspace:FindFirstChild("Bricks")
			own=own and own:FindFirstChild(name)
			local count=0
			if own then for _, obj in ipairs(own:GetDescendants()) do if obj:IsA("BasePart") and obj.Name=="Brick" then count=count+1 end end end
			local row=create("TextButton", {Parent=choices, Size=UDim2.new(1,-8,0,34), BackgroundColor3=selectedOwners[name] and C_DARK_GREEN or C_GRAY, Text=(selectedOwners[name] and "[✓] " or "[ ] ")..name.." · "..display.." · "..count.." бл.", TextColor3=C_WHITE, FontFace=FONT_BOLD, TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd, LayoutOrder=i, ZIndex=22})
			addCorner(row,5)
			row.MouseButton1Click:Connect(function() selectedOwners[name]=not selectedOwners[name] updateSelectionLabel() renderOwnerList() end)
		end
	end
end
search:GetPropertyChangedSignal("Text"):Connect(renderOwnerList)
btnMode.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then setStatus("Сначала поставьте стройку на паузу") return end
	picker.Visible=not picker.Visible
	if picker.Visible then renderOwnerList() end
end)
meButton.MouseButton1Click:Connect(function() selectedOwners={[LocalPlayer.Name]=true} updateSelectionLabel() renderOwnerList() end)
allButton.MouseButton1Click:Connect(function() selectedOwners={} for _, name in ipairs(ownerNames()) do selectedOwners[name]=true end updateSelectionLabel() renderOwnerList() end)
noneButton.MouseButton1Click:Connect(function() selectedOwners={} updateSelectionLabel() renderOwnerList() end)
doneButton.MouseButton1Click:Connect(function() picker.Visible=false end)
updateSelectionLabel()

local function worldFace(cf, face)
	local direction=cf:VectorToWorldSpace(Vector3.FromNormalId(face))
	local best, score=nil,-math.huge
	for id in pairs(FaceSymbols) do
		local dot=direction:Dot(Vector3.FromNormalId(id))
		if dot>score then best,score=id,dot end
	end
	return best
end
local saving=false
btnSave.MouseButton1Click:Connect(function()
	if saving or _G.autobuildRunning then setStatus("Сохранение недоступно во время строительства") return end
	saving=true
	busySaving=true
	local ownersSnapshot=table.clone(selectedOwners)
	textBox.TextEditable=false
	btnSave.Text="СОХРАНЯЮ…"
	task.spawn(function()
		local ok, message=pcall(function()
			local folder=workspace:FindFirstChild("Bricks")
			if not folder then return "Нет папки Bricks" end
			local records, skipped, names={},0,{}
			for _, name in ipairs(ownerNames()) do
				if ownersSnapshot[name] then
					local owner=folder:FindFirstChild(name)
					if owner then
						names[#names+1]=name
						for _, brick in ipairs(owner:GetDescendants()) do
							if unloaded then return "Отменено" end
							if brick:IsA("BasePart") and brick.Name=="Brick" then
								local cf, size=brick.CFrame,brick.Size
								local axisAligned=true
								for _, vector in ipairs({cf.RightVector,cf.UpVector,cf.LookVector}) do
									if math.max(math.abs(vector.X),math.abs(vector.Y),math.abs(vector.Z)) < .9999 then axisAligned=false end
								end
								local integerSize=math.abs(size.X-math.round(size.X))<.001 and math.abs(size.Y-math.round(size.Y))<.001 and math.abs(size.Z-math.round(size.Z))<.001
								local supportedTransparency=brick.Transparency<=.001 or (brick.Material==Enum.Material.Glass and math.abs(brick.Transparency-.5)<.001)
								if not brick.Anchored or not axisAligned or not integerSize or not MaterialSymbols[brick.Material] or not supportedTransparency or (not brick:IsA("Part")) or brick.Shape~=Enum.PartType.Block then
									skipped=skipped+1
								else
									local worldSize=Vector3.new(math.abs(cf.RightVector.X)*size.X+math.abs(cf.UpVector.X)*size.Y+math.abs(cf.LookVector.X)*size.Z,math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z,math.abs(cf.RightVector.Z)*size.X+math.abs(cf.UpVector.Z)*size.Y+math.abs(cf.LookVector.Z)*size.Z)
									local sprays={}
									for _, child in ipairs(brick:GetChildren()) do
										if child.Name=="Spray" and child:IsA("SurfaceGui") then
											local label=child:FindFirstChild("Label")
											if label and label:IsA("TextLabel") then sprays[#sprays+1]={face=worldFace(cf,child.Face),text=label.Text,colorHex=colorHex(label.TextColor3)} end
										end
									end
									records[#records+1]=serializeBlock({size=worldSize,centerPos=brick.Position,color=brick.Color,material=brick.Material,canCollide=brick.CanCollide,sprays=sprays})
								end
								if (#records+skipped)%100==0 then task.wait() end
							end
						end
					end
				end
			end
			if #records==0 then return "Нет поддерживаемых блоков. Пропущено: "..skipped end
			local text=table.concat(records)
			tabsData[#tabsData+1]={name=(#names==1 and names[1] or "Игроки "..#names),content=text}
			activeTabIndex=#tabsData
			setBuildContent(text)
			renderTabs()
			cleanupVisuals(false)
			updateDefaultStats()
			local copied=exportToClipboard(text)
			return "Сохранено: "..#records.." бл.; пропущено: "..skipped..(copied and ((_G.totalChunks and _G.totalChunks>1) and "; часть 1/".._G.totalChunks.." в буфере" or "; скопировано") or "; буфер недоступен")
		end)
		saving=false
		busySaving=false
		if unloaded then return end
		textBox.TextEditable=true
		btnSave.Text="СОХРАНИТЬ"
		setStatus(ok and message or tostring(message),not ok)
	end)
end)


btnNextChunk.MouseButton1Click:Connect(function()
	if not _G.buildChunks or not _G.currentChunk then return end
	_G.currentChunk = math.min(_G.currentChunk + 1, _G.totalChunks)
	if not copyText(_G.buildChunks[_G.currentChunk]) then setStatus("Буфер обмена недоступен", true) return end
	setStatus("Часть " .. _G.currentChunk .. "/" .. _G.totalChunks .. " скопирована")
	if _G.currentChunk == _G.totalChunks then
		btnNextChunk.Visible = false
	end
end)

-- ============================================================================
-- BUILD ENGINE
-- ============================================================================
local Planner=(function()
-- Pure preparation: never invokes a remote or changes an Instance.
local P={}
local EPS=.025
local function distanceSquared(a,b)
	local x,y,z=a.X-b.X,a.Y-b.Y,a.Z-b.Z
	return x*x+y*y+z*z
end
local dirs={
	{face=Enum.NormalId.Left,axis="X",sign=-1,unit=Vector3.new(-1,0,0)},
	{face=Enum.NormalId.Right,axis="X",sign=1,unit=Vector3.new(1,0,0)},
	{face=Enum.NormalId.Bottom,axis="Y",sign=-1,unit=Vector3.new(0,-1,0)},
	{face=Enum.NormalId.Top,axis="Y",sign=1,unit=Vector3.new(0,1,0)},
	{face=Enum.NormalId.Front,axis="Z",sign=-1,unit=Vector3.new(0,0,-1)},
	{face=Enum.NormalId.Back,axis="Z",sign=1,unit=Vector3.new(0,0,1)},
}
P.directions=dirs
local function bounds(m)
	if m._boundPosition~=m.pos or m._boundSize~=m.size then
		m._boundPosition=m.pos m._boundSize=m.size m._lo=m.pos-m.size/2 m._hi=m.pos+m.size/2
	end
	return m._lo,m._hi
end
local function geometry(a,b) return (a.pos-b.pos).Magnitude<EPS and (a.size-b.size).Magnitude<EPS end
P.geometry=geometry
local function colorEqual(a,b) return math.abs(a.R-b.R)<=1/255+.0001 and math.abs(a.G-b.G)<=1/255+.0001 and math.abs(a.B-b.B)<=1/255+.0001 end
local function styleCost(source,target)
	local cost=0
	local defaultColor=source and source.color or {R=192/255,G=192/255,B=192/255}
	local defaultMaterial=source and source.material or Enum.Material.Plastic
	if not colorEqual(defaultColor,target.color) or defaultMaterial~=target.material then cost=cost+1 end
	if (not source and not target.collide) or (source and source.collide~=target.collide) then cost=cost+1 end
	local wanted={}
	for _,sp in ipairs(target.sprays) do wanted[sp.face]=sp end
	if source then
		for _,sp in ipairs(source.sprays) do if not wanted[sp.face] then return nil end end
	end
	for _,sp in ipairs(target.sprays) do
		local found=false
		if source then for _,old in ipairs(source.sprays) do
			if old.face==sp.face and old.text==sp.text and old.colorHex:upper()==sp.colorHex:upper() then found=true break end
		end end
		if not found then cost=cost+1 end
	end
	return cost
end
local function changes(initial,target,countOnly)
	local lo,hi=bounds(initial)
	local tlo,thi=bounds(target)
	local ops,count=nil,0
	if not countOnly then ops={} end
	for _,d in ipairs(dirs) do
		local delta=(d.sign>0 and thi[d.axis]-hi[d.axis] or tlo[d.axis]-lo[d.axis])
		if math.abs(delta-math.round(delta))>.005 then return nil end
		local n=math.abs(math.round(delta))
		if not countOnly then ops[#ops+1]={d=d,left=n,mode=delta*d.sign>0 and "increase" or "decrease"} end
		count=count+n
	end
	return ops,count
end
P.changes=changes
local function makeRecipe(initial,target,source,kind,face,helpers,styling)
	local _,steps=changes(initial,target,true)
	if not steps or steps>20000 then return nil end
	if styling==nil then styling=styleCost(source,target) end
	if not styling then return nil end
	local helperCount=helpers and #helpers or 0
	return {kind=kind,initial=initial,target=target,source=source,face=face,helpers=helpers or {},shapeSteps=steps,styleSteps=styling,operations=(kind=="reuse" and 0 or 1)+steps+styling+helperCount*2}
end
P.recipe=makeRecipe
function P.baselines(target)
	local result={}
	local styling=styleCost(nil,target)
	local lo,hi=bounds(target)
	-- Every detailed corner has the same step count; different corners can
	-- avoid obstructions during intermediate growth.
	for x=0,1 do for y=0,1 do for z=0,1 do
		local position=Vector3.new(x==0 and lo.X+.5 or hi.X-.5,y==0 and lo.Y+.5 or hi.Y-.5,z==0 and lo.Z+.5 or hi.Z-.5)
		if math.abs(position.X%1-.5)<.005 and math.abs(position.Y%1-.5)<.005 and math.abs(position.Z%1-.5)<.005 then
			local r=makeRecipe({pos=position,size=Vector3.new(1,1,1)},target,nil,"detailed",nil,nil,styling)
			if r then result[#result+1]=r end
		end
	end end end
	-- The nearest lower/upper 4-grid centres minimize the L1 boundary work
	-- on each independent axis, allowing ordinary cubes followed by shrinkage.
	local function options(v)
		local lower=math.floor((v-2)/4)*4+2
		return {lower,lower+4}
	end
	for _,x in ipairs(options(target.pos.X)) do for _,y in ipairs(options(target.pos.Y)) do for _,z in ipairs(options(target.pos.Z)) do
		local r=makeRecipe({pos=Vector3.new(x,y,z),size=Vector3.new(4,4,4)},target,nil,"normal",nil,nil,styling)
		if r then result[#result+1]=r end
	end end end
	table.sort(result,function(a,b) return a.operations<b.operations end)
	return result
end
function P.copies(source,target,bridges)
	local result={}
	if source.eligible==false then return result end
	local styling=styleCost(source,target)
	if not styling then return result end
	for _,d in ipairs(dirs) do
		-- Conservative approach envelope: both the block centre and the hit
		-- point must be reachable without relying on an unverified range bypass.
		if source.size[d.axis]/2>39.8 then continue end
		local initial={pos=source.pos+d.unit*source.size[d.axis],size=source.size}
		local recipe=makeRecipe(initial,target,source,"clone",d.face,nil,styling)
		if recipe then result[#result+1]=recipe end
		if bridges then
			local helpers={}
			for extra=1,2 do
				helpers[#helpers+1]={pos=initial.pos,size=initial.size}
				initial={pos=initial.pos+d.unit*source.size[d.axis],size=source.size}
				local r=makeRecipe(initial,target,source,"bridge",d.face,table.clone(helpers),styling)
				if r then result[#result+1]=r end
			end
		end
	end
	table.sort(result,function(a,b) return a.operations<b.operations end)
	return result
end
local function intersects(a,b)
	local alo,ahi=bounds(a)
	local blo,bhi=bounds(b)
	return ahi.X>blo.X+.005 and bhi.X>alo.X+.005 and ahi.Y>blo.Y+.005 and bhi.Y>alo.Y+.005 and ahi.Z>blo.Z+.005 and bhi.Z>alo.Z+.005
end
P.intersects=intersects
-- Exact broad phase for immutable preparation snapshots. Every candidate still
-- passes the original AABB and intermediate-face checks. Large boxes fall back
-- to the complete list, so index limits cannot hide an obstacle.
local Spatial={}
Spatial.__index=Spatial
local function cells(model)
	local lo,hi=bounds(model)
	local x1,y1,z1=math.floor(lo.X/32),math.floor(lo.Y/32),math.floor(lo.Z/32)
	local x2,y2,z2=math.floor(hi.X/32),math.floor(hi.Y/32),math.floor(hi.Z/32)
	local count=(x2-x1+1)*(y2-y1+1)*(z2-z1+1)
	if count~=count or count==math.huge then return nil end
	return x1,y1,z1,x2,y2,z2,count
end
function Spatial.new(models)
	local self=setmetatable({models={},buckets={},large={},marks={},tick=0},Spatial)
	for _,m in ipairs(models) do self:add(m) end return self
end
function Spatial:add(model)
	local id=#self.models+1 self.models[id]=model
	local x1,y1,z1,x2,y2,z2,count=cells(model)
	if not x1 or count>512 then self.large[#self.large+1]=id return end
	for x=x1,x2 do
		local bx=self.buckets[x] if not bx then bx={} self.buckets[x]=bx end
		for y=y1,y2 do
			local by=bx[y] if not by then by={} bx[y]=by end
			for z=z1,z2 do local bucket=by[z] if not bucket then bucket={} by[z]=bucket end bucket[#bucket+1]=id end
		end
	end
end
function Spatial:query(model)
	local x1,y1,z1,x2,y2,z2,count=cells(model)
	if not x1 or count>4096 then return self.models end
	self.tick+=1 local stamp=self.tick local result={}
	local function append(id)
		if self.marks[id]~=stamp then self.marks[id]=stamp result[#result+1]=self.models[id] end
	end
	for _,id in ipairs(self.large) do append(id) end
	for x=x1,x2 do
		local bx=self.buckets[x]
		if bx then for y=y1,y2 do local by=bx[y] if by then for z=z1,z2 do local bucket=by[z] if bucket then for _,id in ipairs(bucket) do append(id) end end end end end end
	end
	return result
end
P.spatial=Spatial.new
local function safeBox(box,target,obstacles,exclude,strict,index)
	local tlo,thi=bounds(target)
	local lo,hi=bounds(box)
	for _,other in ipairs(index and index:query(box) or obstacles) do
		if other.reservedTarget and other.reservedTarget==target.id then continue end
		if other.id~=exclude and intersects(box,other) then
			if strict or other.reservedTarget then return false end
			local olo,ohi=bounds(other)
			-- Intended overlap in the final data is preserved, but a transient
			-- volume may never intersect an obstacle outside the final bounds.
			local ilo=Vector3.new(math.max(lo.X,olo.X),math.max(lo.Y,olo.Y),math.max(lo.Z,olo.Z))
			local ihi=Vector3.new(math.min(hi.X,ohi.X),math.min(hi.Y,ohi.Y),math.min(hi.Z,ohi.Z))
			if ilo.X<tlo.X-.005 or ilo.Y<tlo.Y-.005 or ilo.Z<tlo.Z-.005 or ihi.X>thi.X+.005 or ihi.Y>thi.Y+.005 or ihi.Z>thi.Z+.005 then return false end
		end
	end
	return true
end
P.safeBox=safeBox
local permutations={{"X","Y","Z"},{"X","Z","Y"},{"Y","X","Z"},{"Y","Z","X"},{"Z","X","Y"},{"Z","Y","X"}}
local liveTargetIndices=setmetatable({},{__mode="k"})
function P.compile(recipe,obstacles,allTargets,exclude,checkpoint,obstacleIndex,targetIndex)
	if not targetIndex and recipe.kind=="bridge" then
		targetIndex=liveTargetIndices[allTargets]
		if not targetIndex then targetIndex=Spatial.new(allTargets) liveTargetIndices[allTargets]=targetIndex end
	end
	if recipe.kind=="bridge" then
		for _,helper in ipairs(recipe.helpers) do
			if not safeBox(helper,recipe.target,obstacles,nil,true,obstacleIndex) or not safeBox(helper,recipe.target,allTargets,nil,true,targetIndex) then return nil end
		end
	end
	local ilo,ihi=bounds(recipe.initial) local tlo,thi=bounds(recipe.target)
	local lo=Vector3.new(math.min(ilo.X,tlo.X),math.min(ilo.Y,tlo.Y),math.min(ilo.Z,tlo.Z))
	local hi=Vector3.new(math.max(ihi.X,thi.X),math.max(ihi.Y,thi.Y),math.max(ihi.Z,thi.Z))
	local envelope={pos=(lo+hi)/2,size=hi-lo}
	local relevant={} for _,other in ipairs(obstacleIndex and obstacleIndex:query(envelope) or obstacles) do if intersects(envelope,other) then relevant[#relevant+1]=other end end
	obstacles=relevant
	if not safeBox(recipe.initial,recipe.target,obstacles,exclude,false) then return nil end
	if recipe.kind=="reuse" then
		local r=table.clone(recipe) r.steps={} return r
	end
	if recipe.shapeSteps==0 then
		if not geometry(recipe.initial,recipe.target) then return nil end
		local r=table.clone(recipe) r.steps={} return r
	end
	for _,axisOrder in ipairs(permutations) do
		for _,shrinkFirst in ipairs({true,false}) do
			local ops,total=changes(recipe.initial,recipe.target)
			if not ops then return nil end
			local current={pos=recipe.initial.pos,size=recipe.initial.size}
			local steps={}
			local valid=true
			for step=1,total do
				local chosen,nextModel
				for pass=1,2 do
					local mode=(pass==1)==shrinkFirst and "decrease" or "increase"
					for _,axis in ipairs(axisOrder) do
						for _,op in ipairs(ops) do
							if op.left>0 and op.d.axis==axis and op.mode==mode and (mode~="decrease" or current.size[axis]>1+.005) then
								local sign=mode=="increase" and 1 or -1
								local u=op.d.unit
								local nextSize=current.size+Vector3.new(math.abs(u.X),math.abs(u.Y),math.abs(u.Z))*sign
								local nextBox={size=nextSize,pos=current.pos+u*(sign/2)}
								if safeBox(nextBox,recipe.target,obstacles,exclude,false) then chosen,nextModel=op,nextBox break end
							end
						end
						if chosen then break end
					end
					if chosen then break end
				end
				if not chosen then valid=false break end
				steps[#steps+1]={face=chosen.d.face,axis=chosen.d.axis,unit=chosen.d.unit,mode=chosen.mode,before=current,after=nextModel}
				chosen.left=chosen.left-1 current=nextModel
				if checkpoint and step%128==0 then checkpoint() end
			end
			if valid and geometry(current,recipe.target) then local r=table.clone(recipe) r.steps=steps return r end
		end
	end
	return nil
end
local function nearestModels(target,models,maximum)
	-- Max heap retaining closest candidates; avoids sorting the whole scene
	-- independently for every target. This is a bounded search, not a proof
	-- of the globally optimal construction sequence.
	local heap={}
	local function distance(m)
		return distanceSquared(m.pos,target.pos)
	end
	for _,m in ipairs(models) do
		if m.id~=target.id then
			local d=distance(m)
			if #heap<maximum then
				local value={model=m,distance=d}
				heap[#heap+1]=value local i=#heap
				while i>1 do local parent=math.floor(i/2) if heap[parent].distance>=heap[i].distance then break end heap[parent],heap[i]=heap[i],heap[parent] i=parent end
			elseif d<heap[1].distance then
				local value=heap[1] value.model=m value.distance=d local i=1
				while i*2<=#heap do
					local child=i*2 if child+1<=#heap and heap[child+1].distance>heap[child].distance then child=child+1 end
					if heap[i].distance>=heap[child].distance then break end heap[i],heap[child]=heap[child],heap[i] i=child
				end
			end
		end
	end
	table.sort(heap,function(a,b) return a.distance<b.distance end)
	local result={} for _,v in ipairs(heap) do result[#result+1]=v.model end return result
end
P.version="bounds-v4-time-7"
function P.measurePlan(plan,position,timing)
	timing=timing or {pace=.24,move=.24,ack=.16,height=12,frame=1/60}
	local elapsed,lastCreate,moves,distance,descending=0,-math.huge,0,0,0
	local agent=position or plan.items[1].target.pos
	local previousBottom
	local function near(point,source)
		if (agent-point).Magnitude<=20 and (not source or (agent-source).Magnitude<=20) then return end
		local anchor=point local height=timing.height or 12
		if source then
			local gap=(point-source).Magnitude anchor=(point+source)/2
			if math.abs(point.Y-source.Y)>.01 then height=math.min(height,19.8-gap/2)
			else height=math.min(height,math.sqrt(math.max(0,19.8^2-(gap/2)^2))) end
		end
		local nextPosition=anchor+Vector3.new(0,height,0)
		distance+=(nextPosition-agent).Magnitude agent=nextPosition moves+=1 elapsed+=timing.move
	end
	local function clone(source,face)
		for _,d in ipairs(dirs) do if d.face==face then return source.pos+d.unit*(source.size[d.axis]/2) end end
		return source.pos
	end
	local function create(point,source)
		near(point,source) elapsed=math.max(elapsed,lastCreate+timing.pace) lastCreate=elapsed elapsed+=timing.ack
	end
	for _,r in ipairs(plan.items) do
		local bottom=r.target.pos.Y-r.target.size.Y/2
		if previousBottom and bottom<previousBottom-.025 then descending+=1 end previousBottom=bottom
		local source=r.source
		for _,helper in ipairs(r.helpers or {}) do
			create(clone(source,r.face),source.pos) source=helper
		end
		if r.kind~="reuse" and r.kind~="edit" then
			if source then create(clone(source,r.face),source.pos) else create(r.initial.pos) end
		end
		for _,step in ipairs(r.steps or {}) do near(step.before.pos) elapsed+=timing.ack end
		if r.styleSteps>0 then near(r.target.pos) elapsed+=r.styleSteps*timing.ack end
		for n=#(r.helpers or {}),1,-1 do near(r.helpers[n].pos) elapsed+=timing.ack end
	end
	plan.estimatedSeconds=elapsed plan.teleports=moves plan.travelDistance=distance plan.descending=descending plan.plannerVersion=P.version
	return elapsed
end
function P.reviewLive(reviewed,target,sources,obstacles,allTargets)
	if not reviewed or not reviewed.initial then return nil end
	if reviewed.kind=="normal" then
		if reviewed.initial.size~=Vector3.new(4,4,4) then return nil end
		for _,a in ipairs({"X","Y","Z"}) do if math.abs((reviewed.initial.pos[a]-2)%4)>.005 then return nil end end
	elseif reviewed.kind=="detailed" then
		if reviewed.initial.size~=Vector3.new(1,1,1) then return nil end
		for _,a in ipairs({"X","Y","Z"}) do if math.abs(reviewed.initial.pos[a]%1-.5)>.005 then return nil end end
	end
	local source
	if reviewed.source then
		for _,m in ipairs(sources) do if m.id==reviewed.source.id and geometry(m,reviewed.source) and m.eligible~=false then source=m break end end
		if not source then return nil end
	end
	if reviewed.kind=="reuse" and (not source or not geometry(source,target)) then return nil end
	if reviewed.kind=="clone" or reviewed.kind=="bridge" then
		if not source then return nil end
		local predicted
		for _,d in ipairs(dirs) do if d.face==reviewed.face then
			for n,h in ipairs(reviewed.helpers) do if (h.pos-(source.pos+d.unit*source.size[d.axis]*n)).Magnitude>.025 or (h.size-source.size).Magnitude>.025 then return nil end end
			predicted=source.pos+d.unit*source.size[d.axis]*(#reviewed.helpers+1) break
		end end
		if not predicted or (predicted-reviewed.initial.pos).Magnitude>.025 or (source.size-reviewed.initial.size).Magnitude>.025 then return nil end
	end
	local r=makeRecipe(reviewed.initial,target,source,reviewed.kind,reviewed.face,reviewed.helpers)
	if not r then return nil end
	return P.compile(r,obstacles,allTargets,(r.kind=="reuse" or r.kind=="edit") and source.id or nil)
end

function P.prepare(targets,world,options)
	options=options or {}
	local sliceAt=os.clock()
	local function slice()
		if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
		if options.yield and os.clock()-sliceAt>=.02 then options.yield() sliceAt=os.clock() end
	end
	local function checkpoint(text,fraction)
		if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
		if options.progress then options.progress(text,fraction) end
	end
	local models={}
	for _,m in ipairs(world) do if m.eligible~=false then models[#models+1]=m end end
	for _,m in ipairs(targets) do models[#models+1]=m end
	local targetIndex=Spatial.new(targets)
	local recipes,lowerCosts={},{ }
	for i,target in ipairs(targets) do
		slice()
		local usedFaces={} for _,sp in ipairs(target.sprays) do if usedFaces[sp.face] then error("Блок "..i..": несколько надписей на одной грани",0) end usedFaces[sp.face]=true end
		local baseline=P.baselines(target)
		if #baseline==0 then error("Блок "..i..": границы не совместимы с целыми шагами граней",0) end
		local list={} for _,r in ipairs(baseline) do list[#list+1]=r end
		local bestCost=baseline[1].operations
		local partial=options.partials and options.partials[i]
		if partial then local edit=makeRecipe({pos=partial.pos,size=partial.size},target,partial,"edit") if edit then list[#list+1]=edit end end
		local activeSource=options.activeSources and options.activeSources[i]
		if activeSource then for _,r in ipairs(P.copies(activeSource,target,false)) do list[#list+1]=r end end
		for _,source in ipairs(world) do
			if source.id==target.id and source.eligible~=false and geometry(source,target) then
				local r=makeRecipe({pos=source.pos,size=source.size},target,source,"reuse") if r then list[#list+1]=r end
			end
		end
		for _,source in ipairs(nearestModels(target,models,64)) do
			slice()
			if source.external and source.eligible~=false and geometry(source,target) then
				local reuse=makeRecipe({pos=source.pos,size=source.size},target,source,"reuse")
				if reuse then list[#list+1]=reuse end
			end
			local allowBridge=options.bridges==true and bestCost>=5
			for _,r in ipairs(P.copies(source,target,allowBridge)) do
				if r.operations<=bestCost+2 then
					if r.kind~="bridge" or (r.operations<=bestCost-2 and #targets>=3) then list[#list+1]=r end
				end
			end
		end
		table.sort(list,function(a,b) return a.operations<b.operations end)
		recipes[i]=list lowerCosts[i]=bestCost
		if i%8==0 or i==#targets then
			if options.visual then options.visual("analysis",targets,i) end
			checkpoint("Анализ способов: "..i.."/"..#targets,.45*i/#targets) end
	end
	local futureSavings={} local outgoing={}
	for j,list in ipairs(recipes) do
		slice()
		for _,r in ipairs(list) do
			if r.source then
				local id=r.source.id
				outgoing[id]=outgoing[id] or {} outgoing[id][#outgoing[id]+1]={index=j,recipe=r}
				futureSavings[id]=futureSavings[id] or {}
				futureSavings[id][j]=math.max(futureSavings[id][j] or 0,lowerCosts[j]-r.operations)
			end
		end
	end
	local futureList={}
	for id,map in pairs(futureSavings) do
		local list={} for index,saving in pairs(map) do if saving>0 then list[#list+1]={index=index,saving=saving} end end
		table.sort(list,function(a,b) return a.saving>b.saving end)
		futureList[id]={} for i=1,math.min(12,#list) do futureList[id][i]=list[i] end
	end
	local layerOrder={} for i,target in ipairs(targets) do layerOrder[#layerOrder+1]={index=i,bottom=target.pos.Y-target.size.Y/2} end
	table.sort(layerOrder,function(a,b) if a.bottom==b.bottom then return a.index<b.index end return a.bottom<b.bottom end)
	local timing=options.timing or {pace=.24,move=.24,ack=.16,height=12,frame=1/60}
	local function evaluate(name,spatial,lookahead,planNumber,layers,patches)
		local available={} local obstacles={} local done={} local plan={name=name,items={},operations=0,shapeSteps=0,helpers=0,score=0}
		for _,m in ipairs(world) do available[m.id]=true obstacles[#obstacles+1]=m end
		local obstacleIndex=Spatial.new(world)
		local ready={}
		local function refresh(i)
			ready[i]=nil
			for _,r in ipairs(recipes[i]) do if not r.source or available[r.source.id] then ready[i]=r break end end
		end
		for i in ipairs(targets) do refresh(i) end
		local position=options.position or targets[1].pos
		local layerCursor=1
		local patchCenter
		for step=1,#targets do
			slice()
			while layerOrder[layerCursor] and done[layerOrder[layerCursor].index] do layerCursor+=1 end
			local layerBottom=layerOrder[layerCursor] and layerOrder[layerCursor].bottom or math.huge
			local patchBottom=math.huge
			if patches then
				if patchCenter then
					for i,m in ipairs(targets) do if not done[i] and (m.pos.X-patchCenter.X)^2+(m.pos.Z-patchCenter.Z)^2<=24^2 then patchBottom=math.min(patchBottom,m.pos.Y-m.size.Y/2) end end
				end
				if patchBottom==math.huge then
					local closest=math.huge
					for i,m in ipairs(targets) do
						if not done[i] and (step>1 or m.pos.Y-m.size.Y/2<=layerBottom+.025) then
							local d=(m.pos.X-position.X)^2+(m.pos.Z-position.Z)^2
							if d<closest then closest=d patchCenter=m.pos end
						end
					end
					for i,m in ipairs(targets) do if not done[i] and (m.pos.X-patchCenter.X)^2+(m.pos.Z-patchCenter.Z)^2<=24^2 then patchBottom=math.min(patchBottom,m.pos.Y-m.size.Y/2) end end
				end
			end
			local best,bestIndex,bestScore=nil,nil,math.huge
			local evaluations={}
			for i,target in ipairs(targets) do
				if i%64==0 then slice() end
				if not done[i] and (not layers or target.pos.Y-target.size.Y/2<=layerBottom+.025) and (not patches or (target.pos.X-patchCenter.X)^2+(target.pos.Z-patchCenter.Z)^2<=24^2 and target.pos.Y-target.size.Y/2<=patchBottom+.025) then
					local r=ready[i]
					if r and r.source and not available[r.source.id] then refresh(i) r=ready[i] end
					if r then
						local distance=math.sqrt(distanceSquared(target.pos,position))
						local travel=(layers or patches) and (distance>16 and timing.move+.0001*distance or .0001*distance) or (distance>20 and 2+.002*distance or .001*distance)
						local unit=(layers or patches) and timing.ack or 1
						local score=spatial and distance or r.operations*unit+travel
						if lookahead then
							local counted=0
							for _,saving in ipairs(futureList[target.id] or {}) do
								if not done[saving.index] and saving.index~=i then score=score-.2*saving.saving*unit counted=counted+1 if counted==3 then break end end
							end
						end
						evaluations[#evaluations+1]={index=i,score=score,recipe=r}
					end
				end
			end
			table.sort(evaluations,function(a,b) if (layers or patches) and a.score==b.score then return a.index<b.index end return a.score<b.score end)
			for _,choice in ipairs(evaluations) do
				if best and choice.score>bestScore then break end
				for _,candidate in ipairs(recipes[choice.index]) do
					slice()
					if not candidate.source or available[candidate.source.id] then
						local compiled=P.compile(candidate,obstacles,targets,(candidate.kind=="reuse" or candidate.kind=="edit") and candidate.source.id or nil,function() checkpoint(name..": проверка промежуточных объёмов",.45+.55*(planNumber-1+step/#targets)/5) end,obstacleIndex,targetIndex)
						if compiled then
							local score=choice.score+(spatial and 0 or (compiled.operations-choice.recipe.operations)*((layers or patches) and timing.ack or 1))
							if score<bestScore then best,bestIndex,bestScore=compiled,choice.index,score end
							break
						end
					end
				end
				if best and spatial then break end
			end
			if not best then return nil,"Нет безопасного промежуточного размещения" end
			local target=targets[bestIndex]
			best.index=bestIndex
			plan.items[#plan.items+1]=best
			plan.operations=plan.operations+best.operations plan.shapeSteps=plan.shapeSteps+best.shapeSteps plan.helpers=plan.helpers+#best.helpers
			local distance=math.sqrt(distanceSquared(target.pos,position))
			plan.score=plan.score+best.operations+(distance>20 and 2+.002*distance or .001*distance)
			done[bestIndex]=true available[target.id]=true
			for _,edge in ipairs(outgoing[target.id] or {}) do
				local old=ready[edge.index]
				if not done[edge.index] and (not old or edge.recipe.operations<old.operations) then ready[edge.index]=edge.recipe end
			end
			if best.kind=="reuse" and best.source.id~=target.id then available[best.source.id]=false end
			obstacles[#obstacles+1]=target position=target.pos
			obstacleIndex:add(target)
			if step%8==0 or step==#targets then
				if options.visual then options.visual("candidate",plan,step) end
				checkpoint(name..": "..step.."/"..#targets,.45+.55*(planNumber-1+step/#targets)/5) end
		end
		P.measurePlan(plan,options.position or targets[1].pos,timing)
		return plan
	end
	local candidates={}
	for number,setting in ipairs({{"Пространственный",true,false},{"Стоимость операций",false,false},{"Выгодные шаблоны",false,true},{"Слои снизу",false,true,true},{"Участки снизу",false,true,false,true}}) do
		local plan,err=evaluate(setting[1],setting[2],setting[3],number,setting[4],setting[5])
		if plan then candidates[#candidates+1]=plan elseif options.progress then options.progress(setting[1]..": "..err,.9) end
	end
	if #candidates==0 then error("Безопасный план не найден; проверьте перекрытия и геометрию",0) end
	table.sort(candidates,function(a,b) if a.estimatedSeconds==b.estimatedSeconds then return a.descending<b.descending end return a.estimatedSeconds<b.estimatedSeconds end)
	local best=candidates[1]
	local fastest=best.estimatedSeconds
	-- Estimates cannot distinguish a few percent reliably; prefer fewer vertical
	-- reversals inside a small time margin, without choosing a costly full sweep.
	for _,candidate in ipairs(candidates) do if candidate.descending<best.descending and candidate.estimatedSeconds<=fastest*1.05 then best=candidate end end
	best.alternatives=candidates
	checkpoint("План готов: "..best.name,1)
	return best
end
function P.chooseLive(target,sources,obstacles,allTargets,bridges,partial)
	local recipes={}
	if partial then
		local r=makeRecipe({pos=partial.pos,size=partial.size},target,partial,"edit")
		if not r then return nil end
		return P.compile(r,obstacles,allTargets,partial.id)
	end
	for _,r in ipairs(P.baselines(target)) do recipes[#recipes+1]=r end
	local base=recipes[1] and recipes[1].operations or math.huge
	for _,source in ipairs(nearestModels(target,sources,64)) do
		if source.eligible~=false and geometry(source,target) then
			local r=makeRecipe({pos=source.pos,size=source.size},target,source,"reuse")
			if r then recipes[#recipes+1]=r end
		end
		for _,r in ipairs(P.copies(source,target,bridges and base>=5)) do
			if r.operations<=base+2 and (r.kind~="bridge" or r.operations<=base-2 and #allTargets>=3) then recipes[#recipes+1]=r end
		end
	end
	table.sort(recipes,function(a,b) return a.operations<b.operations end)
	for _,r in ipairs(recipes) do
		local result=P.compile(r,obstacles,allTargets,r.kind=="reuse" and r.source.id or nil)
		if result then return result end
	end
	return nil
end
-- Reusable plans provide an ordering template. Every recipe is compiled anew
-- against the current scene, dimensions, properties and future target volumes.
function P.prepareOrdered(targets,scene,options,order)
	options=options or {}
	for i,target in ipairs(targets) do
		local faces={}
		for _,spray in ipairs(target.sprays) do if faces[spray.face] then error("Блок "..i..": несколько надписей на одной грани",0) end faces[spray.face]=true end
		if #P.baselines(target)==0 then error("Блок "..i..": границы не совместимы с целыми шагами граней",0) end
	end
	local sources,obstacles={},table.clone(scene)
	for _,m in ipairs(scene) do if m.eligible then sources[#sources+1]=m end end
	local plan={name="Пользовательский маршрут",items={},operations=0,shapeSteps=0,helpers=0,score=0,alternatives={}}
	local seen={}
	for rank,index in ipairs(order) do
		if options.yield then options.yield() end
		if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
		local target=targets[index]
		if not target or seen[index] then error("Неверный порядок шаблона",0) end
		local currentSources=sources
		if options.activeSources and options.activeSources[index] then currentSources=table.clone(sources) currentSources[#currentSources+1]=options.activeSources[index] end
		local recipe=P.chooseLive(target,currentSources,obstacles,targets,options.bridges==true,options.partials and options.partials[index])
		if not recipe then error("Порядок шаблона закрывает безопасный путь блока "..index,0) end
		recipe.index=index seen[index]=true plan.items[#plan.items+1]=recipe
		plan.operations+=recipe.operations plan.shapeSteps+=recipe.shapeSteps plan.helpers+=#recipe.helpers
		obstacles[#obstacles+1]=target sources[#sources+1]=target
		if options.visual and (rank%8==0 or rank==#order) then options.visual("template",plan,rank) end
		if options.progress and (rank%8==0 or rank==#order) then options.progress("Адаптация маршрута: "..rank.."/"..#targets,rank/#targets) end
	end
	if #order~=#targets then error("Шаблон не охватывает все цели",0) end
	P.measurePlan(plan,options.position or targets[1].pos,options.timing)
	return plan
end

return P
end)()
-- A build request is never retried blindly: reconcile the world, wait for late replies, then apply a bounded retry.
local positionLock, positionPhysics, noclipConnection, toolEquipConnection
local isBuilding = false
local collisionState, toolState = {}, {}
local equippedCharacter=nil
local function cancelled() return unloaded or _G.stopautobuild==true or StudioHooks.control and StudioHooks.control.interrupted() or false end
local function roundTripPing() return getSafePing()*2 end
StudioHooks.timing=(function()
	local T={multiplier=2,frame=1/60,slowFrame=1/60,samples=0,acks={}}
	local file="AutobuildTiming.json"
	local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
	if readfile and isfile then pcall(function()
		if isfile(file) then local v=HttpService:JSONDecode(readfile(file)) if type(v)=="table" and finite(v.multiplier) then T.multiplier=math.clamp(v.multiplier,1.2,3) end end
	end) end
	function T.set(value)
		if not finite(value) then return false end
		T.multiplier=math.round(math.clamp(value,1.2,3)*10)/10
		if writefile then pcall(function() writefile(file,HttpService:JSONEncode({version=1,multiplier=T.multiplier})) end) end
		return true
	end
	function T.sample(dt)
		if not finite(dt) or dt<=0 then return end
		dt=math.clamp(dt,1/360,2)
		T.frame=T.samples==0 and dt or T.frame+(dt-T.frame)*.15
		T.slowFrame=math.max(T.frame,dt,T.slowFrame*.92) T.samples+=1
	end
	function T.frameBudget() return math.max(T.frame,T.slowFrame) end
	function T.pace() return math.max(.025,getSafePing()*T.multiplier,T.frameBudget()*2) end
	function T.settle(force) return T.pace()+(force and math.max(T.frameBudget(),getSafePing()*.5) or 0) end
	function T.timeout(minimum) return math.max(minimum,getSafePing()*8+T.frameBudget()*6+.1) end
	function T.observed(kind,seconds)
		if not finite(seconds) or seconds<=0 or seconds>5 then return end
		local old=T.acks[kind] T.acks[kind]=old and old+(seconds-old)*.15 or seconds
	end
	function T.profile()
		return {pace=T.pace(),move=T.settle(false),ack=math.max(T.frameBudget(),T.acks.create or getSafePing()*1.4),height=CONFIG.BUILD_HEIGHT_OFFSET,frame=T.frameBudget()}
	end
	function T.summary() return string.format("Пинг ×%.1f · FPS ~%d · интервал ≥%.0f мс",T.multiplier,math.round(1/math.max(T.frame,1/360)),T.pace()*1000) end
	trackConn(RunService.RenderStepped:Connect(function(dt) T.sample(dt) end))
	return T
end)()

local function responseTimeout(minimum) return StudioHooks.timing.timeout(minimum) end
local function waitUntil(predicate, seconds)
	local deadline = os.clock() + seconds
	repeat
		if cancelled() then return false end
		if predicate() then return true end
		task.wait()
	until os.clock() >= deadline
	return not cancelled() and predicate()
end
local noclipConnections = {}
local noclipCharacter = nil
local function sweepNoclip()
	local character = LocalPlayer.Character
	if not character then return end
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			if collisionState[part] == nil then collisionState[part] = part.CanCollide end
			part.CanCollide = false
		end
	end
end
local function disableNoclip()
	for _, connection in ipairs(noclipConnections) do connection:Disconnect() end
	table.clear(noclipConnections)
	noclipConnection = nil
	noclipCharacter = nil
	for part, original in pairs(collisionState) do
		if part.Parent then part.CanCollide = original end
	end
	table.clear(collisionState)
end
local function enableNoclip()
	if noclipConnection then sweepNoclip() return end
	local function bindCharacter(character)
		noclipCharacter = character
		sweepNoclip()
		if character then
			noclipConnections[#noclipConnections+1] = character.DescendantAdded:Connect(function(part)
				if part:IsA("BasePart") then
					if collisionState[part] == nil then collisionState[part] = part.CanCollide end
					part.CanCollide = false
				end
			end)
		end
	end
	bindCharacter(LocalPlayer.Character)
	noclipConnections[#noclipConnections+1] = LocalPlayer.CharacterAdded:Connect(bindCharacter)
	-- Before physics AND before the position lock: newly equipped handles cannot
	-- push the character out of its placement position for one simulation frame.
	noclipConnection = RunService.Stepped:Connect(sweepNoclip)
	noclipConnections[#noclipConnections+1] = noclipConnection
	noclipConnections[#noclipConnections+1] = RunService.Heartbeat:Connect(sweepNoclip)
end

local function startToolForcing()
	local function equip(tool)
		if cancelled() or not isBuilding then return end
		if tool:IsA("Tool") and (tool.Name == "Build" or tool.Name == "Paint" or tool.Name == "Shape" or tool.Name == "Delete") then
			if toolState[tool] == nil then toolState[tool] = tool.Parent end
			if LocalPlayer.Character then tool.Parent = LocalPlayer.Character end
		end
	end
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if not backpack then return end
	for _, tool in ipairs(backpack:GetChildren()) do equip(tool) end
	if toolEquipConnection then toolEquipConnection:Disconnect() end
	toolEquipConnection = backpack.ChildAdded:Connect(equip)
	equippedCharacter=LocalPlayer.Character
end
local function stopToolForcing()
	if toolEquipConnection then toolEquipConnection:Disconnect() toolEquipConnection = nil end
	for tool, parent in pairs(toolState) do
		if tool.Parent and parent.Parent then tool.Parent = parent end
	end
	table.clear(toolState)
	equippedCharacter=nil
end
local function unlockPosition()
	if positionPhysics then positionPhysics:Disconnect() positionPhysics=nil end
	if positionLock then positionLock:Disconnect() positionLock = nil end
end
local function lockPosition(pos)
	unlockPosition()
	-- Move immediately; the first Build request must not precede RenderStepped.
	local function move()
		if cancelled() then return end
		sweepNoclip()
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum=char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Sit then hum.Sit=false end
		if hrp then
			hrp.CFrame = CFrame.new(pos)
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end
	end
	move()
	positionPhysics=RunService.Stepped:Connect(move)
	positionLock = RunService.RenderStepped:Connect(function()
		move()
	end)
end
local function getValidHRP()
	local hrp
	local ready = waitUntil(function()
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		hrp = char and char:FindFirstChild("HumanoidRootPart")
		return hrp ~= nil and hum ~= nil and hum.Health > 0
	end, 20)
	if ready then if equippedCharacter~=LocalPlayer.Character then startToolForcing() end return hrp end
	return nil
end
local function findTool(name)
	local function search(loc)
		if not loc then return nil end
		for _, item in ipairs(loc:GetChildren()) do
			if item:IsA("Tool") and item.Name == name then
				local scriptObject = item:FindFirstChild("Script", true)
				local event = scriptObject and scriptObject:FindFirstChild("Event", true)
				if event and event:IsA("RemoteEvent") then return {tool = item, event = event} end
			end
		end
	end
	return search(LocalPlayer.Character) or search(LocalPlayer:FindFirstChildOfClass("Backpack"))
end
local function awaitTool(name)
	local tool=findTool(name)
	if tool then return tool end
	setStatus("Ожидаю инструмент "..name.." после ресета; новые команды не отправляются")
	local ready=waitUntil(function() tool=findTool(name) return tool~=nil end,10)
	if ready then startToolForcing() return tool end
	return nil
end
local function getPlayerBricksFolder()
	local bricks = workspace:FindFirstChild("Bricks")
	return bricks and bricks:FindFirstChild(LocalPlayer.Name)
end
local function getCornerPosition(pos, size) return pos - size / 2 + Vector3.new(.5, .5, .5) end
local function sameColor(a, b)
	return math.abs(a.R-b.R) <= 1/255+.0001 and math.abs(a.G-b.G) <= 1/255+.0001 and math.abs(a.B-b.B) <= 1/255+.0001
end
local function paintBlock(brick, data)
	if StudioHooks.stairwell and data.stairToxic then if data.stairToxic.defer then return StudioHooks.stairwell.paintShell(brick,data,paintBlock) end return StudioHooks.stairwell.paintToxic(brick,data) end
	local function matches() return brick.Parent and sameColor(brick.Color, data.color) and brick.Material == data.material end
	if matches() then return true end
	for _ = 1, 3 do
		local hrp, tool = getValidHRP(), awaitTool("Paint")
		if not hrp or not tool or cancelled() or not brick.Parent then return false end
		tool.event:FireServer(brick, Enum.NormalId.Left, hrp.Position, "both 🤝", data.color, MaterialToPaintName[data.material] or "smooth", "")
		if waitUntil(matches, responseTimeout(1)) then return true end
	end
	return false
end
local function sprayBlock(brick, spray)
	local function matches()
		if not brick.Parent then return false end
		for _, child in ipairs(brick:GetChildren()) do
			if child.Name == "Spray" and child:IsA("SurfaceGui") and child.Face == spray.face then
				local label = child:FindFirstChild("Label")
				if label and label:IsA("TextLabel") and label.Text == spray.text and sameColor(label.TextColor3, hexToColor(spray.colorHex)) then return true end
			end
		end
		return false
	end
	if matches() then return true end
	for _ = 1, 3 do
		local hrp, tool = getValidHRP(), awaitTool("Paint")
		if not hrp or not tool or cancelled() or not brick.Parent then return false end
		tool.event:FireServer(brick, spray.face, hrp.Position, "both 🤝", hexToColor(spray.colorHex), "spray", spray.text)
		if waitUntil(matches, responseTimeout(1)) then return true end
	end
	return false
end
local function setBlockCollision(brick, data)
	if brick.CanCollide == data.canCollide then return true end
	local hrp, tool = getValidHRP(), awaitTool("Paint")
	if not hrp or not tool or cancelled() then return false end
	tool.event:FireServer(brick, Enum.NormalId.Back, hrp.Position, "material", data.color, "collide", "")
	return waitUntil(function() return brick.Parent and brick.CanCollide == data.canCollide end, responseTimeout(2))
end
local function geometryMatches(brick, data)
	return brick and brick.Parent and (brick.Position-data.centerPos).Magnitude < .05 and (brick.Size-data.size).Magnitude < .05
end
local function clearPlanPreview()
	if not visualFolder then return end
	for _,child in ipairs(visualFolder:GetChildren()) do
		if child.Name:sub(1,5)=="Plan_" then child:Destroy() end
	end
end
local function markPlanProgress(session,index)
	if session.transient then return end
	if StudioHooks.runtimeState then StudioHooks.runtimeState.touch(session,index) end
	if not visualFolder or not (session.visiblePlanIndices and session.visiblePlanIndices[index]) then return end
	local m=session.models[index]
	local part=visualFolder:FindFirstChild("Plan_State_"..index)
	if not part then
		part=create("Part",{Name="Plan_State_"..index,Parent=visualFolder,Size=m.size,Position=m.pos,Anchored=true,CanCollide=false,CanQuery=false,CanTouch=false,Transparency=1})
		create("SelectionBox",{Name="StateOutline",Parent=part,Adornee=part,LineThickness=.02,SurfaceTransparency=1})
	end
	local partial=session.blocks[index].placedBrick
	local color=session.blocks[index].skipped and Color3.fromRGB(130,135,145) or session.blocks[index].failure and Color3.fromRGB(245,110,100) or session.done[index] and Color3.fromRGB(107,231,150) or (partial and partial.Parent and Color3.fromRGB(255,196,95) or Color3.fromRGB(162,136,234))
	part.StateOutline.Color3=color
end
local function refreshPlanProgress(session)
	if session.transient then return end
	local first
	for rank,item in ipairs(session.plan.items) do if not session.done[item.index] then first=rank break end end
	if first and (first<(session.routeWindowStart or 1) or first>=(session.routeWindowStart or 1)+192) then
		session.routeWindowStart=first session.renderedText=nil
	end
	for index in pairs(session.visiblePlanIndices or {}) do markPlanProgress(session,index) end
end
-- Planning callbacks contain actual examined targets and accepted safe recipes.
local PlanDrawing=(function()
	local D={}
	local route=Color3.fromRGB(92,178,255)
	local copy=Color3.fromRGB(105,233,161)
	local helper=Color3.fromRGB(255,184,82)
	local function segment(a,b,color,name,width)
		local length=(b-a).Magnitude
		if length<.01 then return end
		create("Part",{Name="Plan_"..name,Parent=visualFolder,Anchored=true,CanCollide=false,CanQuery=false,CanTouch=false,Size=Vector3.new(width,width,length),CFrame=CFrame.lookAt((a+b)/2,b),Material=Enum.Material.Neon,Color=color,Transparency=.3})
	end
	local function arrow(a,b,color,name,width)
		segment(a,b,color,name,width)
		local delta=b-a local length=delta.Magnitude
		if length<.15 then return end
		local direction=delta/length
		local side=direction:Cross(Vector3.new(0,1,0))
		if side.Magnitude<.01 then side=direction:Cross(Vector3.new(1,0,0)) end
		side=side/side.Magnitude
		local scale=math.min(1.1,length*.28)
		segment(b,b-direction*scale+side*scale*.45,color,name.."_ArrowL",width)
		segment(b,b-direction*scale-side*scale*.45,color,name.."_ArrowR",width)
	end
	local function outline(m,name,color)
		local p=create("Part",{Name="Plan_"..name,Parent=visualFolder,Size=m.size,Position=m.pos,Anchored=true,CanCollide=false,CanQuery=false,CanTouch=false,Transparency=1})
		create("SelectionBox",{Name="StateOutline",Parent=p,Adornee=p,Color3=color,LineThickness=.02,SurfaceTransparency=1})
		return p
	end
	function D.item(session,item,rank,previous,first)
		local target=session.models[item.index]
		local point=target.pos+Vector3.new(0,target.size.Y/2+.7,0)
		if previous then arrow(previous,point,route,"Route_"..rank,.06) end
		if first then create("Part",{Name="Plan_Start",Parent=visualFolder,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,Shape=Enum.PartType.Ball,Size=Vector3.new(.55,.55,.55),Position=point,Material=Enum.Material.Neon,Color=route,Transparency=.2}) end
		if item.source then arrow(item.source.pos,target.pos,copy,"Source_"..rank,.03) end
		for n,h in ipairs(item.helpers or {}) do
			outline(h,"Helper_"..rank.."_"..n,helper)
			local p=h.pos+Vector3.new(0,h.size.Y/2+.7,0)
			segment(p-Vector3.new(.7,0,.7),p+Vector3.new(.7,0,.7),helper,"HelperMark_"..rank.."_"..n.."_a",.08)
			segment(p-Vector3.new(.7,0,-.7),p+Vector3.new(.7,0,-.7),helper,"HelperMark_"..rank.."_"..n.."_b",.08)
		end
		session.visiblePlanIndices[item.index]=true
		return point
	end
	function D.reset(session,key)
		if not visualFolder then showVisuals() end
		clearPlanPreview()
		session.drawingKey=key session.drawingCount=0 session.drawingPrevious=nil
		session.visiblePlanIndices={} session.renderedText=nil
	end
	function D.progress(session,phase,payload,count)
		if unloaded or cancelled() then return end
		if phase=="analysis" then
			D.reset(session,"analysis")
			if not visualFolder then return end
			-- Only the most recently examined eight blocks are highlighted.
			for i=math.max(1,count-7),count do outline(session.models[i],"Examining_"..i,copy) end
			return
		end
		local key=phase..":"..tostring(payload.name)
		local first=session.drawingKey==key and (session.drawingFirst or 1) or 1
		if count>first+191 then first=math.max(1,count-159) end
		if session.drawingKey~=key or count<(session.drawingCount or 0) or first~=(session.drawingFirst or 1) then
			D.reset(session,key) session.drawingFirst=first session.drawingCount=first-1
		end
		if not visualFolder then return end
		for rank=(session.drawingCount or 0)+1,count do
			local item=payload.items[rank]
			session.drawingPrevious=D.item(session,item,rank,session.drawingPrevious,rank==first)
			markPlanProgress(session,item.index)
		end
		session.drawingCount=count
	end
	return D
end)()
local function drawPreparedPlan(session)
	if session.transient then return end
	if unloaded then return end
	if session.renderedText==session.text and session.renderedOffset==session.offset and visualFolder and visualFolder:FindFirstChild("Plan_Start") then return end
	PlanDrawing.reset(session,"final")
	if not visualFolder then return end
	local first=session.routeWindowStart or 1
	local previous
	for rank=first,math.min(#session.plan.items,first+191) do
		local item=session.plan.items[rank]
		previous=PlanDrawing.item(session,item,rank,previous,rank==first)
		markPlanProgress(session,item.index)
	end
	session.renderedOffset=session.offset session.renderedText=session.text session.previewInvalid=false
end

local function advancePlanPreview(session,rank)
	if session.transient then return end
	if rank>=(session.routeWindowStart or 1)+160 and rank<#session.plan.items then
		session.routeWindowStart=rank session.renderedText=nil
		drawPreparedPlan(session)
	end
end
invalidatePreparedPlan=function()
	if unloaded or not resumeSession or not resumeSession.plan then return end
	local text=_G.fullBuildString or textBox.Text
	local offset=snapBuildOffset(_G.buildOffset or Vector3.zero)
	if text~=resumeSession.text or offset~=resumeSession.offset then
		clearPlanPreview() resumeSession.previewInvalid=true
		if StudioHooks.preview then StudioHooks.preview() end
		btnStart.Text="СТРОИТЬ"
	end
end

local function targetModel(data,index)
	return {id="t:"..index,pos=data.centerPos,size=data.size,color=data.color,material=data.material,collide=data.canCollide,sprays=data.sprays,eligible=true}
end
local function readSprays(brick)
	local sprays={}
	for _,child in ipairs(brick:GetChildren()) do
		if child.Name=="Spray" and child:IsA("SurfaceGui") then
			local label=child:FindFirstChild("Label")
			if label and label:IsA("TextLabel") then sprays[#sprays+1]={face=child.Face,text=label.Text,colorHex=colorHex(label.TextColor3)} end
		end
	end
	return sprays
end
-- Mutable broad phase. Exact geometry and properties are checked by the caller.
StudioHooks.liveWorld=(function()
	local W={visited=0,queries=0}
	local root,parts,positions,added,removing
	local entries,buckets,large,dynamic,untracked={},{},{},{},{}
	local function unlink(part)
		local entry=entries[part]
		if entry then for _,key in ipairs(entry.keys) do local bucket=buckets[key] if bucket then bucket[part]=nil if not next(bucket) then buckets[key]=nil end end end end
		large[part]=nil
	end
	local function ranges(box)
		local lo,hi=box.pos-box.size/2,box.pos+box.size/2
		local x,y,z=math.floor(lo.X/16),math.floor(lo.Y/16),math.floor(lo.Z/16)
		local a,b,c=math.floor(hi.X/16),math.floor(hi.Y/16),math.floor(hi.Z/16)
		return x,y,z,a,b,c,(a-x+1)*(b-y+1)*(c-z+1)
	end
	local function worldBox(part)
		local cf,size=part.CFrame,part.Size
		if cf and cf.RightVector then
			size=Vector3.new(math.abs(cf.RightVector.X)*size.X+math.abs(cf.UpVector.X)*size.Y+math.abs(cf.LookVector.X)*size.Z,math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z,math.abs(cf.RightVector.Z)*size.X+math.abs(cf.UpVector.Z)*size.Y+math.abs(cf.LookVector.Z)*size.Z)
		end
		return {pos=part.Position,size=size}
	end
	local function update(part)
		local entry=entries[part] if not entry then return end
		unlink(part) entry.keys={}
		dynamic[part]=not part.Anchored and true or nil
		local x,y,z,a,b,c,count=ranges(worldBox(part))
		if count~=count or count>512 then large[part]=true return end
		for i=x,a do for j=y,b do for k=z,c do
			local key=i..":"..j..":"..k local bucket=buckets[key]
			if not bucket then bucket={} buckets[key]=bucket end
			bucket[part]=true entry.keys[#entry.keys+1]=key
		end end end
	end
	local function remove(part)
		local entry=entries[part] if not entry then return end
		unlink(part) if entry.connection then entry.connection:Disconnect() end
		entries[part]=nil dynamic[part]=nil untracked[part]=nil
		local index=positions[part] local last=parts[#parts]
		parts[index]=last parts[#parts]=nil positions[part]=nil
		if last~=part then positions[last]=index end
	end
	local function close()
		if added then added:Disconnect() added=nil end
		if removing then removing:Disconnect() removing=nil end
		for _,entry in pairs(entries) do if entry.connection then entry.connection:Disconnect() end end
		root=nil parts=nil positions=nil entries={} buckets={} large={} dynamic={} untracked={}
	end
	function W.parts(folder,cooperate)
		if not folder then return {} end
		if not folder.DescendantAdded or not folder.DescendantRemoving then return folder:GetDescendants() end
		if root~=folder then
			close() root=folder parts={} positions={}
			local function add(part)
				if not part:IsA("BasePart") or entries[part] then return end
				parts[#parts+1]=part positions[part]=#parts entries[part]={keys={}}
				if part.Changed then
					entries[part].connection=part.Changed:Connect(function(property)
						if property=="CFrame" or property=="Position" or property=="Orientation" or property=="Rotation" or property=="Size" or property=="Anchored" then update(part) end
					end)
				else untracked[part]=true end
				update(part)
			end
			added=trackConn(folder.DescendantAdded:Connect(add))
			removing=trackConn(folder.DescendantRemoving:Connect(remove))
			local slice=os.clock()
			for index,part in ipairs(folder:GetDescendants()) do
				add(part)
				if cooperate and index%128==0 and os.clock()-slice>=.004 then
					if cooperate()==false or root~=folder then return {} end slice=os.clock()
				end
			end
		end
		return parts
	end
	function W.focus(...)
		local lo,hi
		for _,model in ipairs({...}) do if model and model.pos and model.size then
			local a,b=model.pos-model.size/2,model.pos+model.size/2
			lo=lo and Vector3.new(math.min(lo.X,a.X),math.min(lo.Y,a.Y),math.min(lo.Z,a.Z)) or a
			hi=hi and Vector3.new(math.max(hi.X,b.X),math.max(hi.Y,b.Y),math.max(hi.Z,b.Z)) or b
		end end
		return lo and {pos=(lo+hi)/2,size=hi-lo+Vector3.new(.1,.1,.1)} or nil
	end
	function W.near(part,focus)
		if not focus then return true end
		local box=worldBox(part) local delta=box.pos-focus.pos local half=(box.size+focus.size)/2
		return math.abs(delta.X)<=half.X+.01 and math.abs(delta.Y)<=half.Y+.01 and math.abs(delta.Z)<=half.Z+.01
	end
	function W.query(folder,focus)
		local all=W.parts(folder) W.queries+=1
		if not focus or root~=folder then W.visited+=#all return all end
		local x,y,z,a,b,c,count=ranges(focus)
		if count>4096 then W.visited+=#all return all end
		local result,seen={},{}
		local function add(part)
			if seen[part] then return end seen[part]=true W.visited+=1
			if part.Parent and W.near(part,focus) then result[#result+1]=part end
		end
		for i=x,a do for j=y,b do for k=z,c do local bucket=buckets[i..":"..j..":"..k] if bucket then for part in pairs(bucket) do add(part) end end end end end
		for part in pairs(large) do add(part) end
		-- Physics motion can bypass property signals; moving parts remain live.
		for part in pairs(dynamic) do add(part) end
		for part in pairs(untracked) do add(part) end
		return result
	end
	W.close=close
	return W
end)()

-- Sparse sets describe only unfinished work and explicit user controls.
StudioHooks.runtimeState=(function()
	local R={scanned=0,touched=0}
	function R.touch(session,index)
		local state=session.runtimeState local data=index and session.blocks[index]
		if not state or not data then return end R.touched+=1
		state.dirty[index]=true
		local old=state.parts[index] if old then state.unfinished[old]=nil end
		local part=not session.done[index] and data.placedBrick or nil
		state.parts[index]=part if part then state.unfinished[part]=true end
		local pending=data.creation or data.pendingResize or data.pendingCollision or data.repairDeleteRequested or #(data.retired or {})>0
		for _,holder in ipairs(data.work and data.work.helpers or {}) do if holder.creation or holder.brick and holder.brick.Parent or #(holder.retired or {})>0 then pending=true break end end
		state.active[index]=pending or data.work and not session.done[index] and true or nil
		state.controls[index]=data.skipped or data.repairRequested or data.failure or data.repairDeleteRequested or nil
	end
	function R.rebuild(session)
		local old=session.runtimeState
		session.runtimeState={active={},controls={},parts={},unfinished={},dirty={}}
		for index in ipairs(session.blocks) do R.scanned+=1 R.touch(session,index) end
		local dirty={}
		for index in pairs(session.runtimeState.active) do dirty[index]=true end
		for index in pairs(session.runtimeState.controls) do dirty[index]=true end
		if old then for index in pairs(old.active) do dirty[index]=true end for index in pairs(old.controls) do dirty[index]=true end end
		session.runtimeState.dirty=dirty
		return session.runtimeState
	end
	function R.ensure(session)
		return session.runtimeState or R.rebuild(session)
	end
	function R.indices(session)
		local state=R.ensure(session) local result={}
		for index in pairs(state.active) do result[index]=true end
		for index in pairs(state.controls) do result[index]=true end
		return result
	end
	function R.pending(session)
		local state=R.ensure(session)
		for index in pairs(state.active) do
			local b=session.blocks[index]
			if b.creation or b.pendingResize and b.pendingResize.brick and b.pendingResize.brick.Parent or (b.pendingCollision or b.repairDeleteRequested) and b.placedBrick and b.placedBrick.Parent then return true end
			for _,old in ipairs(b.retired or {}) do if (old.attempts or 1)>0 then return true end end
			for _,h in ipairs(b.work and b.work.helpers or {}) do if h.creation or h.brick and h.brick.Parent then return true end end
		end
		for part,value in pairs(session.obstacleDeletes or {}) do if value.requested and part.Parent then return true end end
		return false
	end
	return R
end)()

local function snapshotWorld(session,geometryOnly,focus)
	local result,sources={},{}
	local state=StudioHooks.runtimeState.ensure(session)
	local unfinished=state.unfinished
	local own=getPlayerBricksFolder()
	local root=workspace:FindFirstChild("Bricks")
	if not root then result.liveFocus=focus
	return result,sources end
	for _,brick in ipairs(StudioHooks.liveWorld.query(root,focus)) do
		if brick:IsA("BasePart") and brick.Name=="Brick" and brick.Parent and StudioHooks.liveWorld.near(brick,focus) then
			local cf,size=brick.CFrame,brick.Size
			local identity=(cf.RightVector-Vector3.new(1,0,0)).Magnitude<.001 and (cf.UpVector-Vector3.new(0,1,0)).Magnitude<.001
			local worldSize=Vector3.new(math.abs(cf.RightVector.X)*size.X+math.abs(cf.UpVector.X)*size.Y+math.abs(cf.LookVector.X)*size.Z,math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z,math.abs(cf.RightVector.Z)*size.X+math.abs(cf.UpVector.Z)*size.Y+math.abs(cf.LookVector.Z)*size.Z)
			local id=session.ids[brick]
			if not id then session.nextWorld=session.nextWorld+1 id="w:"..session.nextWorld session.ids[brick]=id end
			local opaque=not geometryOnly and (brick.Transparency<.001 or (brick.Material==Enum.Material.Glass and math.abs(brick.Transparency-.5)<.001))
			local eligible=not geometryOnly and (not StudioHooks.documents or not StudioHooks.documents.pendingPart(session,brick)) and own and brick:IsDescendantOf(own) and identity and brick.Anchored and opaque and brick:IsA("Part") and brick.Shape==Enum.PartType.Block and SymbolToMaterial[MaterialSymbols[brick.Material]]~=nil
			if brick:GetAttribute("OrbitStairHazard") then eligible=false end
			local model={id=id,pos=brick.Position,size=worldSize,color=brick.Color,material=brick.Material,collide=brick.CanCollide,sprays=geometryOnly and {} or readSprays(brick),instance=brick,external=true,eligible=eligible==true and not session.helpers[brick] and not unfinished[brick]}
			result[#result+1]=model
			if model.eligible and not session.helpers[brick] then sources[#sources+1]=model end
			session.instances[id]=brick
		end
	end
	for i in pairs(state.active) do
		local data=session.blocks[i]
		local function reserve(holder,suffix)
			local function include(initial,tag)
				if initial then result[#result+1]={id="reserved:"..i..suffix..tag,reservedTarget=session.models[i].id,reservedHolder=holder,pos=initial.pos,size=initial.size,color=data.color,material=data.material,collide=true,sprays={},eligible=false} end
			end
			local pending=holder.creation
			if pending and (not pending.attempts or pending.attempts>0) then include(pending.initial or data.work and data.work.recipe.initial,"") end
			for n,old in ipairs(holder.retired or {}) do include(old.initial,":retired:"..n) end
		end
		reserve(data,"")
		for n,h in ipairs(data.work and data.work.helpers or {}) do reserve(h,":"..n) end
	end
	if StudioHooks.documents then
		local masks=StudioHooks.documents.reservations(session)
		for _,mask in ipairs(masks) do result[#result+1]=mask end
		for n=#sources,1,-1 do for _,mask in ipairs(masks) do if Planner.intersects(sources[n],mask) then sources[n].eligible=false table.remove(sources,n) break end end end
	end
	result.liveFocus=focus
	return result,sources
end
local function planVector(v) return {v.X,v.Y,v.Z} end
local function readPlanVector(value)
	if type(value)~="table" or #value~=3 then return nil end
	for _,n in ipairs(value) do if type(n)~="number" or n~=n or math.abs(n)>1000000 then return nil end end
	return Vector3.new(value[1],value[2],value[3])
end
local function planModelKey(model)
	local owner=model.instance and model.instance.Parent and model.instance.Parent.Name or ""
	local sprays={}
	for _,s in ipairs(model.sprays or {}) do sprays[#sprays+1]=(FaceSymbols[s.face] or "?")..encodeSpray(s.text)..s.colorHex:upper() end
	table.sort(sprays)
	return string.format("%.6f,%.6f,%.6f/%.6f,%.6f,%.6f/%s/%s/%s/%s/%s/%s",model.pos.X,model.pos.Y,model.pos.Z,model.size.X,model.size.Y,model.size.Z,colorHex(model.color),tostring(model.material),tostring(model.collide),tostring(model.eligible==true),owner,table.concat(sprays,";"))
end
local function planClearance(session)
	local lo=Vector3.new(math.huge,math.huge,math.huge)
	local hi=Vector3.new(-math.huge,-math.huge,-math.huge)
	local function include(m)
		if not m then return end
		local a,b=m.pos-m.size/2,m.pos+m.size/2
		lo=Vector3.new(math.min(lo.X,a.X),math.min(lo.Y,a.Y),math.min(lo.Z,a.Z))
		hi=Vector3.new(math.max(hi.X,b.X),math.max(hi.Y,b.Y),math.max(hi.Z,b.Z))
	end
	for _,m in ipairs(session.models) do include(m) end
	for _,item in ipairs(session.plan.items) do
		include(item.initial) include(item.source)
		for _,h in ipairs(item.helpers or {}) do include(h) end
	end
	local margin=Vector3.new(4,4,4)
	return {pos=(lo+hi)/2,size=hi-lo+margin*2}
end
local function planWorldKey(scene,clearance)
	local records={}
	for _,model in ipairs(scene) do
		if not clearance or Planner.intersects(model,clearance) then records[#records+1]=planModelKey(model) end
	end
	table.sort(records)
	return table.concat(records,"\n")
end
local function planFileName()
	local name=tabsData[activeTabIndex].name:gsub('[%c<>:"/\\|?*]',"_"):gsub("[%s%.]+$","")
	if name=="" then name="Build" end
	local cut=utf8.offset(name,65)
	if cut then name=name:sub(1,cut-1) end
	return "plan-"..name..".json"
end
local function savePreparedPlan(session,scene,bridges)
	if not writefile then return false end
	local plan=session.plan
	local clearance=planClearance(session)
	local stored={version=4,planner="bounds-v4-time-7",text=session.text,offset=planVector(session.offset),world=planWorldKey(scene,clearance),clearance={pos=planVector(clearance.pos),size=planVector(clearance.size)},bridges=bridges,name=plan.name,operations=plan.operations,shapeSteps=plan.shapeSteps,helpers=plan.helpers,items={}}
	for _,item in ipairs(plan.items) do
		local entry={index=item.index,kind=item.kind,operations=item.operations,shapeSteps=item.shapeSteps,helpers={}}
		if item.source then entry.source={id=item.source.id,external=item.source.external==true,key=item.source.external and planModelKey(item.source) or nil} end
		for _,h in ipairs(item.helpers or {}) do entry.helpers[#entry.helpers+1]={pos=planVector(h.pos),size=planVector(h.size)} end
		stored.items[#stored.items+1]=entry
	end
	local file=planFileName()
	local ok=pcall(function() writefile(file,HttpService:JSONEncode(stored)) end)
	if ok then session.planFile=file else setStatus("План готов; файл плана не удалось сохранить",true) end
	return ok
end
local function loadPreparedPlan(session,scene,bridges)
	if not readfile or not isfile then return nil end
	local file=planFileName()
	local ok,plan=pcall(function()
		if not isfile(file) then return nil end
		local stored=HttpService:JSONDecode(readfile(file))
		if stored.version~=4 or stored.planner~="bounds-v4-time-7" or stored.text~=session.text or readPlanVector(stored.offset)~=session.offset or stored.bridges~=bridges or type(stored.clearance)~="table" then return nil end
		local clearance={pos=readPlanVector(stored.clearance.pos),size=readPlanVector(stored.clearance.size)}
		if not clearance.pos or not clearance.size or clearance.size.X<=0 or clearance.size.Y<=0 or clearance.size.Z<=0 or stored.world~=planWorldKey(scene,clearance) then return nil end
		if type(stored.items)~="table" or #stored.items~=#session.models or type(stored.name)~="string" then return nil end
		local result={name=stored.name,operations=0,shapeSteps=0,helpers=0,items={},alternatives={}}
		local seen={}
		local kinds={normal=true,detailed=true,clone=true,reuse=true,bridge=true}
		local world={}
		for _,m in ipairs(scene) do local k=planModelKey(m) if world[k]~=nil then world[k]=false else world[k]=m end end
		for _,entry in ipairs(stored.items) do
			local i=entry.index
			if type(i)~="number" or i%1~=0 or not session.models[i] or seen[i] or not kinds[entry.kind] then return nil end
			if type(entry.operations)~="number" or entry.operations<0 or entry.operations%1~=0 or type(entry.shapeSteps)~="number" or entry.shapeSteps<0 or entry.shapeSteps%1~=0 or type(entry.helpers)~="table" or #entry.helpers>2 then return nil end
			local item={index=i,kind=entry.kind,operations=entry.operations,shapeSteps=entry.shapeSteps,helpers={},target=session.models[i]}
			item.face=FaceSymbolsReverse[entry.face]
			if entry.initial then
				local p,size=readPlanVector(entry.initial.pos),readPlanVector(entry.initial.size)
				if not p or not size or size.X<1 or size.Y<1 or size.Z<1 then return nil end
				item.initial={pos=p,size=size}
			end
			if entry.source then
				if type(entry.source)~="table" then return nil end
				if entry.source.external then
					item.source=world[entry.source.key]
					if not item.source or not item.source.eligible then return nil end
				else
					local sourceIndex=type(entry.source.id)=="string" and tonumber(entry.source.id:match("^t:(%d+)$"))
					if not sourceIndex or not seen[sourceIndex] then return nil end
					item.source=session.models[sourceIndex]
				end
			elseif entry.kind=="clone" or entry.kind=="bridge" or entry.kind=="reuse" then return nil end
			for _,helper in ipairs(entry.helpers) do
				local pos,size=readPlanVector(helper.pos),readPlanVector(helper.size)
				if not pos or not size or size.X<1 or size.Y<1 or size.Z<1 or size.X%1~=0 or size.Y%1~=0 or size.Z%1~=0 then return nil end
				item.helpers[#item.helpers+1]={pos=pos,size=size}
			end
			if entry.kind~="bridge" and #item.helpers>0 or entry.kind=="bridge" and #item.helpers==0 then return nil end
			seen[i]=true result.items[#result.items+1]=item
			result.operations+=item.operations result.shapeSteps+=item.shapeSteps result.helpers+=#item.helpers
		end
		session.planFile=file
		return result
	end)
	if ok and plan then setStatus("План загружен: "..file) return plan end
	return nil
end

local PlanLibrary=(function()
local PlanLibrary={}
local indexFile="AutobuildPlanLibrary.json"
local rows,memory,choices={},{},{}
local diskKnown={}
local function safeFile(name)
	return type(name)=="string" and #name<=220 and not name:find('[%c/\\<>:"|?*]') and name:sub(-5)==".plan" and not name:find("^%.")
end
local function cleanName()
	local name=tabsData[activeTabIndex].name:gsub('[%c<>:"/\\|?*]',"_"):gsub("[%s%.]+$",""):gsub("^%.*","")
	if name=="" then name="Build" end
	local stem=name:match("^[^%.]+") or name
	if ({CON=true,PRN=true,AUX=true,NUL=true})[stem:upper()] or stem:upper():match("^COM[1-9]$") or stem:upper():match("^LPT[1-9]$") then name="Build_"..name end
	local cut=utf8.offset(name,65) if cut then name=name:sub(1,cut-1) end
	return name
end
local function validStored(s)
	if not (type(s)=="table" and s.version==4 and type(s.text)=="string" and type(s.items)=="table" and #s.items>0 and type(s.offset)=="table" and readPlanVector(s.offset)~=nil and type(s.name)=="string") then return false end
	local seen={}
	for _,item in ipairs(s.items) do
		if type(item)~="table" or type(item.index)~="number" or item.index%1~=0 or item.index<1 or item.index>#s.items or seen[item.index] then return false end
		seen[item.index]=true
	end
	if s.createdAt~=nil and (type(s.createdAt)~="number" or s.createdAt~=s.createdAt or math.abs(s.createdAt)>1000000000000) then return false end
	if s.models~=nil then
		if type(s.models)~="table" or #s.models~=#s.items then return false end
		for _,m in ipairs(s.models) do
			if type(m)~="table" then return false end
			local p,size=readPlanVector(m.pos),readPlanVector(m.size)
			if not p or not size or size.X<1 or size.Y<1 or size.Z<1 then return false end
		end
	end
	return true
end
local function readStored(file)
	if not safeFile(file) then return nil end
	if memory[file] then return memory[file] end
	if not readfile then return nil end
	local ok,data=pcall(function() return HttpService:JSONDecode(readfile(file)) end)
	if ok and validStored(data) then
		local blocks,invalid=parseBlocks(data.text,readPlanVector(data.offset))
		if invalid>0 or #blocks~=#data.items then return nil end
		if data.models then for i,m in ipairs(data.models) do if readPlanVector(m.pos)~=blocks[i].centerPos or readPlanVector(m.size)~=blocks[i].size then return nil end end end
		diskKnown[file]=true memory[file]=data return data
	end
	return nil
end
local function persistIndex()
	if writefile then pcall(function() writefile(indexFile,HttpService:JSONEncode({version=1,plans=rows,choices=choices})) end) end
end
if isfile and readfile then
	pcall(function()
		if not isfile(indexFile) then return end
		local index=HttpService:JSONDecode(readfile(indexFile))
		if type(index)~="table" or index.version~=1 then return end
		if type(index.plans)=="table" then
			for _,r in ipairs(index.plans) do if type(r)=="table" and safeFile(r.file) and type(r.buildName)=="string" and (r.createdAt==nil or type(r.createdAt)=="number" and r.createdAt==r.createdAt) then rows[#rows+1]=r end end
		end
		if type(index.choices)=="table" then for name,file in pairs(index.choices) do if type(name)=="string" and (file=="auto" or safeFile(file)) then choices[name]=file end end end
	end)
end
local function meta(file,s)
	local points={}
	local models=s.models or {}
	local step=math.max(1,math.ceil(#s.items/28))
	for i=1,#s.items,step do local m=models[s.items[i].index] if m and readPlanVector(m.pos) then points[#points+1]=m.pos end end
	return {file=file,buildId=s.buildId,buildName=s.buildName or file:sub(1,-6),createdAt=s.createdAt or 0,count=#s.items,operations=s.operations or 0,shapeSteps=s.shapeSteps or 0,helpers=s.helpers or 0,points=points,parentPlan=s.requestedTemplate~="auto" and s.requestedTemplate or nil}
end
local function add(file,s)
	if not validStored(s) then return end
	if not s.models then
		local blocks,invalid=parseBlocks(s.text,readPlanVector(s.offset))
		if invalid>0 or #blocks~=#s.items then return end
		s.models={} for i,b in ipairs(blocks) do s.models[i]={pos=planVector(b.centerPos),size=planVector(b.size)} end
	end
	memory[file]=s
	for _,r in ipairs(rows) do if r.file==file then return end end
	rows[#rows+1]=meta(file,s)
end
local function reserveName(base)
	local suffix=0
	while true do
		local file=(suffix==0 and "" or "("..suffix..")")..base..".plan"
		local exists=memory[file]~=nil
		for _,r in ipairs(rows) do if r.file==file then exists=true break end end
		if isfile then local ok,value=pcall(isfile,file) exists=exists or ok and value end
		if not exists then return file end
		suffix+=1
	end
end
function PlanLibrary.list()
	local result={} for _,r in ipairs(rows) do result[#result+1]=r end
	table.sort(result,function(a,b) if (a.createdAt or 0)==(b.createdAt or 0) then return a.file>b.file end return (a.createdAt or 0)>(b.createdAt or 0) end)
	return result
end
function PlanLibrary.selection() return choices[tabsData[activeTabIndex].name] or "auto" end
function PlanLibrary.select(file)
	if _G.autobuildRunning or _G.autobuildPreparing then return false,"Останови строительство перед сменой плана" end
	if file==PlanLibrary.selection() then return true end
	if file~="auto" and not readStored(file) then return false,"Файл плана не читается" end
	if resumeSession and (not resumeSession.buildId or resumeSession.buildId==PlanLibrary.id()) then
		for _,b in ipairs(resumeSession.blocks or {}) do
			if b.creation or b.pendingResize or b.pendingCollision then return false,"Сначала продолжи и подтверди отправленные команды" end
			for _,h in ipairs(b.work and b.work.helpers or {}) do if h.creation or h.brick and h.brick.Parent then return false,"Сначала заверши текущие вспомогательные блоки" end end
		end
		resumeSession.plan=nil resumeSession.planByIndex=nil resumeSession.previewInvalid=true resumeSession.renderedText=nil
		clearPlanPreview()
	end
	choices[tabsData[activeTabIndex].name]=file persistIndex()
	return true
end
function PlanLibrary.scan()
	if not listfiles then return end
	local ok,files=pcall(listfiles,"") if not ok or type(files)~="table" then return end
	local seen={} for _,r in ipairs(rows) do seen[r.file]=true end
	for i,path in ipairs(files) do
		local file=type(path)=="string" and path:match("([^/\\]+)$") or nil
		if file and safeFile(file) and not seen[file] then local s=readStored(file) if s then add(file,s) seen[file]=true end end
		if i%40==0 then task.wait() if unloaded then return end end
	end
	persistIndex()
end
local function pack(session,scene,bridges)
	local p=session.plan local clearance=planClearance(session)
	local s={version=4,libraryVersion=1,planner="bounds-v4-time-7",buildName=tabsData[activeTabIndex].name,createdAt=os.time(),requestedTemplate=PlanLibrary.selection(),text=session.text,offset=planVector(session.offset),world=planWorldKey(scene,clearance),clearance={pos=planVector(clearance.pos),size=planVector(clearance.size)},bridges=bridges,name=p.name,operations=p.operations,shapeSteps=p.shapeSteps,helpers=p.helpers,items={},models={}}
	for i,m in ipairs(session.models) do s.models[i]={pos=planVector(m.pos),size=planVector(m.size)} end
	for _,item in ipairs(p.items) do
		local entry={index=item.index,kind=item.kind,operations=item.operations,shapeSteps=item.shapeSteps,helpers={}}
		entry.face=FaceSymbols[item.face]
		if item.initial then entry.initial={pos=planVector(item.initial.pos),size=planVector(item.initial.size)} end
		if item.source then entry.source={id=item.source.id,external=item.source.external==true,key=item.source.external and planModelKey(item.source) or nil} end
		for _,h in ipairs(item.helpers or {}) do entry.helpers[#entry.helpers+1]={pos=planVector(h.pos),size=planVector(h.size)} end
		s.items[#s.items+1]=entry
	end
	return s
end
savePreparedPlan=function(session,scene,bridges)
	local s=pack(session,scene,bridges)
	local file=reserveName(cleanName())
	local saved=false
	if writefile then saved=pcall(function() writefile(file,HttpService:JSONEncode(s)) end) end
	add(file,s) persistIndex() session.planFile=file
	setStatus(saved and "Сохранён план: "..file or "План в памяти: "..file.."; запись файла недоступна",not saved)
	return saved
end
-- Preserve the original exact-cache validator, including source dependencies,
-- the current clearance envelope and actual world properties.
local exactReader=loadPreparedPlan
local exactTarget=nil
local legacyFile=planFileName
planFileName=function() return exactTarget or legacyFile() end
loadPreparedPlan=function(session,scene,bridges)
	local selected=PlanLibrary.selection()
	local candidates={}
	if selected~="auto" then candidates[#candidates+1]=selected end
	for _,r in ipairs(PlanLibrary.list()) do if r.buildName==tabsData[activeTabIndex].name and r.file~=selected then candidates[#candidates+1]=r.file end end
	for _,file in ipairs(candidates) do
		local s=readStored(file)
		if s and (s.requestedTemplate or "auto")==selected then
			exactTarget=file
			local plan=exactReader(session,scene,bridges)
			exactTarget=nil
			if plan then return plan end
		end
	end
	if #candidates==0 and selected=="auto" then
		local previous=legacyFile()
		local ok,s=pcall(function() return readfile and HttpService:JSONDecode(readfile(previous)) end)
		if ok and validStored(s) then
			local plan=exactReader(session,scene,bridges)
			if plan then session.plan=plan savePreparedPlan(session,scene,bridges) return plan end
		end
	end
	return nil
end
local function bounds(models)
	local lo,hi=Vector3.new(math.huge,math.huge,math.huge),Vector3.new(-math.huge,-math.huge,-math.huge)
	for _,m in ipairs(models) do
		local p=m.pos
		lo=Vector3.new(math.min(lo.X,p.X),math.min(lo.Y,p.Y),math.min(lo.Z,p.Z)) hi=Vector3.new(math.max(hi.X,p.X),math.max(hi.Y,p.Y),math.max(hi.Z,p.Z))
	end
	return lo,hi-lo
end
local function geometrySignature(p,size)
	return string.format("%.3f,%.3f,%.3f/%.3f,%.3f,%.3f",p.X,p.Y,p.Z,size.X,size.Y,size.Z)
end
function PlanLibrary.order(stored,targets)
	local models={}
	for _,m in ipairs(stored.models or {}) do
		local p,size=readPlanVector(m.pos),readPlanVector(m.size)
		if not p or not size then return nil end
		models[#models+1]={pos=p,size=size}
	end
	if #models==0 then return nil end
	local route,seen={},{}
	for _,r in ipairs(stored.items) do
		if type(r.index)~="number" or not models[r.index] or seen[r.index] then return nil end
		seen[r.index]=true route[#route+1]=r.index
	end
	if #route~=#models then return nil end
	local from,span=bounds(models) local to,newSpan=bounds(targets)
	if #models==#targets then
		local lookup,duplicate={},false
		for i,m in ipairs(targets) do local key=geometrySignature(m.pos-to,m.size) if lookup[key] then duplicate=true end lookup[key]=i end
		local exact={}
		if not duplicate then
			for _,index in ipairs(route) do local m=models[index] local target=lookup[geometrySignature(m.pos-from,m.size)] if not target then exact={} break end exact[#exact+1]=target end
		end
		if #exact==#targets then return exact,"Точное соответствие геометрии" end
	end
	local function normalized(p,base,size)
		return {X=size.X>.001 and (p.X-base.X)/size.X or .5,Y=size.Y>.001 and (p.Y-base.Y)/size.Y or .5,Z=size.Z>.001 and (p.Z-base.Z)/size.Z or .5}
	end
	local samples={}
	local step=math.max(1,math.ceil(#route/128))
	for rank=1,#route,step do samples[#samples+1]=normalized(models[route[rank]].pos,from,span) end
	local groups={} for i=1,#samples do groups[i]={} end
	for i,m in ipairs(targets) do
		local p=normalized(m.pos,to,newSpan) local best,distance=1,math.huge
		for rank,s in ipairs(samples) do local d=(p.X-s.X)^2+(p.Y-s.Y)^2+(p.Z-s.Z)^2 if d<distance then distance=d best=rank end end
		groups[best][#groups[best]+1]={index=i,distance=distance}
	end
	local order={}
	for _,group in ipairs(groups) do
		table.sort(group,function(a,b) if a.distance==b.distance then return a.index<b.index end return a.distance<b.distance end)
		for _,r in ipairs(group) do order[#order+1]=r.index end
	end
	return order,"Маршрут адаптирован к другой геометрии"
end
function PlanLibrary.prepare(targets,scene,options)
	local selected=PlanLibrary.selection()
	if selected=="auto" then
		local id=PlanLibrary.id()
		if type(id)=="string" and id:sub(1,10)=="stairwell_" then
            local plan=StudioHooks.stairwell.fastPlan(targets,scene,options)
            plan.stairwell=true return plan
		end
		return Planner.prepare(targets,scene,options)
	end
	local stored=readStored(selected)
	local order,description
	if stored then order,description=PlanLibrary.order(stored,targets) end
	if not order then error("Выбранный шаблон плана повреждён; выбери Авто или другой план",0) end
	setStatus("Применяю "..selected.." · "..description)
	local ok,plan=pcall(Planner.prepareOrdered,targets,scene,options,order)
	if not ok then
		if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
		setStatus("Порядок шаблона небезопасен; ищу безопасный маршрут для текущей постройки")
		plan=Planner.prepare(targets,scene,options)
		plan.adaptation="Безопасный обход шаблона"
	else plan.adaptation=description end
	plan.name="По плану "..selected plan.appliedFrom=selected
	return plan
end

-- Stable ownership is independent of tab names and world placement.
local bindings={}
local serial=0
local function newIdentity()
	local ok,id=pcall(function() return HttpService:GenerateGUID(false) end)
	if ok and type(id)=="string" and #id>0 then return id end
	serial+=1 return "build-"..tostring(os.time()).."-"..tostring(os.clock()).."-"..serial
end
function PlanLibrary.id()
	if StudioHooks.stairwell and StudioHooks.stairwell.context then return StudioHooks.stairwell.context.buildId end
	local tab=tabsData[activeTabIndex]
	if type(tab.id)~="string" or tab.id=="" then tab.id=newIdentity() end
	return tab.id
end
function PlanLibrary.restorePlacement()
	local tab=tabsData[activeTabIndex]
	_G.buildOffset=snapBuildOffset(readPlanVector(tab.placement) or Vector3.zero)
	local p=tab.rotationPivot
	rotationPivot=type(p)=="table" and type(p.X)=="number" and type(p.Z)=="number" and p.X==p.X and p.Z==p.Z and math.abs(p.X)<=1000000 and math.abs(p.Z)<=1000000 and p or nil
end
local restorePlacement=PlanLibrary.restorePlacement
PlanLibrary.restorePlacement=function() restorePlacement() if StudioHooks.documents then StudioHooks.documents.activate(tabsData[activeTabIndex],tabsData[activeTabIndex].content) end end
StudioHooks.restorePlacement=PlanLibrary.restorePlacement
PlanLibrary.restorePlacement()
local legacyChoices=choices
choices={}
local index
if isfile and readfile then pcall(function() if isfile(indexFile) then index=HttpService:JSONDecode(readfile(indexFile)) end end) end
if type(index)=="table" and index.version==2 then
	local known={} for _,r in ipairs(rows) do known[r.file]=true end
	for _,r in ipairs(type(index.plans)=="table" and index.plans or {}) do
		if type(r)=="table" and safeFile(r.file) and type(r.buildName)=="string" and (r.createdAt==nil or type(r.createdAt)=="number" and r.createdAt==r.createdAt) and not known[r.file] then rows[#rows+1]=r known[r.file]=true end
	end
	for id,file in pairs(type(index.choices)=="table" and index.choices or {}) do if type(id)=="string" and (file=="auto" or safeFile(file)) then choices[id]=file end end
	for id,file in pairs(type(index.bindings)=="table" and index.bindings or {}) do if type(id)=="string" and safeFile(file) then bindings[id]=file end end
end
persistIndex=function()
	if writefile then pcall(function() writefile(indexFile,HttpService:JSONEncode({version=2,plans=rows,choices=choices,bindings=bindings})) end) end
end
local names,ids={},{}
for _,tab in ipairs(tabsData) do
	names[tab.name]=(names[tab.name] or 0)+1
	if type(tab.id)~="string" or tab.id=="" or ids[tab.id] then tab.id=newIdentity() end
	ids[tab.id]=true
end
for _,tab in ipairs(tabsData) do
	if names[tab.name]==1 then
		if not choices[tab.id] and legacyChoices[tab.name] and legacyChoices[tab.name]~="auto" then choices[tab.id]=legacyChoices[tab.name] end
		if not bindings[tab.id] then
			for _,row in ipairs(PlanLibrary.list()) do
				if row.buildName==tab.name and (not row.buildId or row.buildId==tab.id) and readStored(row.file) then
					row.buildId=tab.id bindings[tab.id]=row.file break
				end
			end
		end
	end
end
persistIndex() saveData()
local function owns(file,stored)
	local id=PlanLibrary.id()
	if stored.buildId then return stored.buildId==id end
	for _,row in ipairs(rows) do if row.file==file then return row.buildId==id end end
	return false
end
function PlanLibrary.selection()
	local id=PlanLibrary.id()
	return choices[id] and choices[id]~="auto" and choices[id] or bindings[id] or "auto"
end
function PlanLibrary.migrateHistory(data)
	if type(data)~="table" then return end
	local owners={}
	local function note(name,id)
		if type(name)~="string" or type(id)~="string" then return end
		if owners[name] and owners[name]~=id then owners[name]=false elseif owners[name]==nil then owners[name]=id end
	end
	for _,tab in ipairs(tabsData) do note(tab.name,tab.id) end
	for _,row in ipairs(rows) do note(row.buildName,row.buildId) end
	local function migrate(state)
		if type(state)~="table" or type(state.tabs)~="table" then return end
		local counts={} for _,tab in ipairs(state.tabs) do if type(tab)=="table" and type(tab.name)=="string" then counts[tab.name]=(counts[tab.name] or 0)+1 end end
		for _,tab in ipairs(state.tabs) do
			if type(tab)=="table" and (tab.id==nil or tab.id=="") then tab.id=counts[tab.name]==1 and owners[tab.name] or newIdentity() end
		end
	end
	migrate(data.current)
	for _,stack in ipairs({data.undo or {},data.redo or {}}) do if type(stack)=="table" then for _,state in ipairs(stack) do migrate(state) end end end
end
function PlanLibrary.canTransform()
	if _G.autobuildRunning then return false,"Сначала поставь строительство на паузу" end
	if resumeSession then
		for _,b in ipairs(resumeSession.blocks or {}) do
			if b.creation or b.pendingResize or b.pendingCollision then return false,"Есть неподтверждённая команда. Сначала продолжи её проверку." end
			for _,h in ipairs(b.work and b.work.helpers or {}) do if h.creation or h.brick and h.brick.Parent then return false,"Сначала заверши текущие вспомогательные блоки." end end
		end
	end
	return true
end
StudioHooks.beforeTransform=PlanLibrary.canTransform
function PlanLibrary.select(file)
	if file~="auto" and not readStored(file) then return false,"Файл плана не найден или повреждён: "..tostring(file) end
	if file==PlanLibrary.selection() then return true end
	local ok,message=PlanLibrary.canTransform() if not ok then return false,message end
	local id=PlanLibrary.id()
	choices[id]=file=="auto" and nil or file
	persistIndex()
	if resumeSession and (not resumeSession.buildId or resumeSession.buildId==id) then
		resumeSession.plan=nil resumeSession.planByIndex=nil resumeSession.previewInvalid=true resumeSession.renderedText=nil
		clearPlanPreview()
	end
	if StudioHooks.controls then StudioHooks.controls() end
	return true
end
local function turn(v,quarter)
	if quarter==1 then return Vector3.new(-v.Z,v.Y,v.X)
	elseif quarter==2 then return Vector3.new(-v.X,v.Y,-v.Z)
	elseif quarter==3 then return Vector3.new(v.Z,v.Y,-v.X) end
	return v
end
local function turnSize(size,quarter) return quarter%2==1 and Vector3.new(size.Z,size.Y,size.X) or size end
local function turnFace(face,quarter)
	local nextFace={[Enum.NormalId.Left]=Enum.NormalId.Front,[Enum.NormalId.Front]=Enum.NormalId.Right,[Enum.NormalId.Right]=Enum.NormalId.Back,[Enum.NormalId.Back]=Enum.NormalId.Left}
	for _=1,quarter do face=nextFace[face] or face end return face
end
local function styleKey(model,quarter)
	local sprays={}
	for _,s in ipairs(model.sprays or {}) do sprays[#sprays+1]=tostring(turnFace(s.face,quarter or 0))..":"..encodeSpray(s.text or "")..":"..(s.colorHex or "FFFFFF"):upper() end
	table.sort(sprays)
	return colorHex(model.color).."/"..tostring(model.material).."/"..tostring(model.collide).."/"..table.concat(sprays,";")
end
local adaptOrder=PlanLibrary.order
function PlanLibrary.match(stored,targets)
	local models={}
	local blocks,invalid=parseBlocks(stored.text,readPlanVector(stored.offset))
	if invalid>0 or #blocks~=#targets or #stored.items~=#targets then return nil end
	for i,b in ipairs(blocks) do models[i]={pos=b.centerPos,size=b.size,color=b.color,material=b.material,collide=b.canCollide,sprays=b.sprays} end
	local seen={}
	for _,entry in ipairs(stored.items) do if not models[entry.index] or seen[entry.index] then return nil end seen[entry.index]=true end
	local to=bounds(targets)
	local best
	for quarter=0,3 do
		local rotated={}
		for i,m in ipairs(models) do rotated[i]={pos=turn(m.pos,quarter),size=turnSize(m.size,quarter)} end
		local from=bounds(rotated)
		local mapping={} local sameIndices=true
		for i,m in ipairs(rotated) do
			if geometrySignature(m.pos-from,m.size)~=geometrySignature(targets[i].pos-to,targets[i].size) then sameIndices=false break end
		end
		if sameIndices then for i in ipairs(rotated) do mapping[i]=i end
		else
			local buckets={}
			for i,m in ipairs(targets) do local key=geometrySignature(m.pos-to,m.size) buckets[key]=buckets[key] or {} buckets[key][#buckets[key]+1]=i end
			for i,m in ipairs(rotated) do
				local bucket=buckets[geometrySignature(m.pos-from,m.size)]
				if not bucket or #bucket==0 then mapping={} break end
				local slot=1
				for j,index in ipairs(bucket) do if styleKey(models[i],quarter)==styleKey(targets[index],0) then slot=j break end end
				mapping[i]=table.remove(bucket,slot)
			end
		end
		if #mapping==#targets then
			local equal=true
			for i,index in ipairs(mapping) do if styleKey(models[i],quarter)~=styleKey(targets[index],0) then equal=false break end end
			local order={} for _,entry in ipairs(stored.items) do order[#order+1]=mapping[entry.index] end
			local match={order=order,mapping=mapping,quarter=quarter,translation=to-from,equivalent=equal}
			-- Stable record identity disambiguates symmetric geometry after rotation.
			if sameIndices and equal then return match end
			if not best or equal and not best.equivalent then best=match end
		end
	end
	return best
end
function PlanLibrary.order(stored,targets)
	local matched=PlanLibrary.match(stored,targets)
	if matched then return matched.order,matched.quarter==0 and "Точное соответствие геометрии" or "Тот же маршрут · поворот "..(matched.quarter*90).."°",matched end
	return adaptOrder(stored,targets)
end
savePreparedPlan=function(session,scene,bridges)
	local selected=PlanLibrary.selection()
	local old=selected~="auto" and readStored(selected)
	local matched=old and PlanLibrary.match(old,session.models)
	if old and owns(selected,old) and matched and matched.equivalent then
		if old.planner~=Planner.version then
			local upgraded=pack(session,scene,bridges) upgraded.buildId=PlanLibrary.id() upgraded.libraryVersion=2 upgraded.createdAt=old.createdAt
			if writefile then pcall(function() writefile(selected,HttpService:JSONEncode(upgraded)) end) end
			memory[selected]=upgraded
			for i,row in ipairs(rows) do if row.file==selected then rows[i]=meta(selected,upgraded) break end end
		end
		session.planFile=selected bindings[PlanLibrary.id()]=selected
		persistIndex() setStatus("План закреплён: "..selected.." · положение и поворот проверены") return true
	end
	local stored=pack(session,scene,bridges) stored.buildId=PlanLibrary.id() stored.libraryVersion=2
	local file=reserveName(cleanName()) local saved=false
	if writefile then saved=pcall(function() writefile(file,HttpService:JSONEncode(stored)) end) end
	if saved then diskKnown[file]=true end
	add(file,stored)
	bindings[stored.buildId]=file choices[stored.buildId]=nil session.planFile=file
	persistIndex()
	if StudioHooks.controls then StudioHooks.controls() end
	setStatus(saved and "План постройки: "..file or "План в памяти: "..file.."; файл не записан",not saved)
	return saved
end
loadPreparedPlan=function(session,scene,bridges)
	local file=PlanLibrary.selection()
	if file=="auto" then
		local ok,legacy=pcall(exactReader,session,scene,bridges)
		if ok and legacy then session.plan=legacy savePreparedPlan(session,scene,bridges) return legacy end
		return nil
	end
	local stored=readStored(file)
	if not stored or not owns(file,stored) then return nil end
	exactTarget=file
	local ok,plan=pcall(exactReader,session,scene,bridges)
	exactTarget=nil
	return ok and plan or nil
end
PlanLibrary.prepare=function(targets,scene,options)
	local file=PlanLibrary.selection()
	if file=="auto" then return Planner.prepare(targets,scene,options) end
	local stored=readStored(file)
	if not stored then
		setStatus("Закреплённый файл недоступен; рассчитываю новый план для этой постройки",true)
		return Planner.prepare(targets,scene,options)
	end
	if owns(file,stored) and not choices[PlanLibrary.id()] and stored.planner~=Planner.version then
		setStatus("Обновляю закреплённый план: расчёт времени и слои снизу")
		return Planner.prepare(targets,scene,options)
	end
	if owns(file,stored) and not PlanLibrary.match(stored,targets) then
		setStatus("Геометрия постройки изменена; рассчитываю новую версию её плана")
		return Planner.prepare(targets,scene,options)
	end
	local order,description=PlanLibrary.order(stored,targets)
	if not order then error("Выбранный план повреждён; выбери другой файл",0) end
	setStatus("План "..file.." · "..description)
	local ok,plan=pcall(Planner.prepareOrdered,targets,scene,options,order)
	if not ok then
		if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
		setStatus("Проверка маршрута выявила препятствие; рассчитываю безопасный порядок")
		plan=Planner.prepare(targets,scene,options)
	end
	plan.name="План "..file plan.appliedFrom=file plan.adaptation=description
	return plan
end
function PlanLibrary.preview()
	if not visualFolder or _G.autobuildRunning then return end
	local text=_G.fullBuildString or textBox.Text local offset=snapBuildOffset(_G.buildOffset or Vector3.zero)
	if resumeSession and resumeSession.buildId==PlanLibrary.id() and resumeSession.text==text and resumeSession.offset==offset and resumeSession.plan then drawPreparedPlan(resumeSession) return end
	local file=PlanLibrary.selection() local stored=file~="auto" and readStored(file)
	if not stored then return end
	local blocks,invalid=parseBlocks(text,offset) if invalid>0 or #blocks==0 then return end
	local models={}
	for i,b in ipairs(blocks) do models[i]={pos=b.centerPos,size=b.size,color=b.color,material=b.material,collide=b.canCollide,sprays=b.sprays} end
	local matched=PlanLibrary.match(stored,models) if not matched then return end
	local view={text=text,offset=offset,models=models,blocks=blocks,done={},plan={items={}}}
	for rank,index in ipairs(matched.order) do
		local saved=stored.items[rank] local item={index=index,helpers={}}
		local sourceIndex=saved.source and not saved.source.external and type(saved.source.id)=="string" and saved.source.id:match("^t:(%d+)$")
		if sourceIndex then item.source=models[matched.mapping[tonumber(sourceIndex)]] end
		view.plan.items[#view.plan.items+1]=item
	end
	-- This shows bound order only; live helpers and outside sources are revalidated
	-- during preparation, never replayed from the old world coordinates.
	drawPreparedPlan(view)
end
StudioHooks.preview=PlanLibrary.preview
local discover=PlanLibrary.scan
PlanLibrary.scan=function()
	-- Explicit refresh rereads changed existing files, not just new filenames.
	if isfile and readfile then
		for file in pairs(memory) do local ok,exists=pcall(isfile,file) if diskKnown[file] or ok and exists then memory[file]=nil end end
		for _,row in ipairs(rows) do
			local stored=readStored(row.file)
			row.unavailable=stored==nil
			if stored then row.count=#stored.items row.operations=stored.operations or 0 end
		end
	end
	discover()
end

return PlanLibrary
end)()
local function instanceModel(brick,id)
	return {id=id,pos=brick.Position,size=brick.Size,color=brick.Color,material=brick.Material,collide=brick.CanCollide,sprays=readSprays(brick),instance=brick,eligible=true}
end
local function matchesAll(brick,data)
	if StudioHooks.stairwell and data.stairToxic and not data.stairToxic.defer and not StudioHooks.stairwell.toxicReady(brick,data) then return false end
	if StudioHooks.guard and StudioHooks.guard.formChanged(brick,data) then return false end
	if not geometryMatches(brick,data) or not brick.Anchored or not sameColor(brick.Color,data.color) or not (StudioHooks.stairwell and data.stairToxic and StudioHooks.stairwell.materialMatches(brick,data) or not data.stairToxic and brick.Material==data.material) or brick.CanCollide~=data.canCollide then return false end
	local sprays=readSprays(brick)
	if #sprays~=#data.sprays then return false end
	for _,wanted in ipairs(data.sprays) do
		local found=false
		for _,actual in ipairs(sprays) do if actual.face==wanted.face and actual.text==wanted.text and actual.colorHex:upper()==wanted.colorHex:upper() then found=true break end end
		if not found then return false end
	end
	return true
end
local function reconcileBuild(session)
	local own=getPlayerBricksFolder()
	local world=own and own:GetDescendants() or {}
	local function bucket(pos,size)
		return string.format("%d,%d,%d/%.3f,%.3f,%.3f",math.round(pos.X*10),math.round(pos.Y*10),math.round(pos.Z*10),size.X,size.Y,size.Z)
	end
	local buckets={}
	for _,brick in ipairs(world) do
		if brick:IsA("BasePart") and brick.Name=="Brick" then
			local key=bucket(brick.Position,brick.Size)
			buckets[key]=buckets[key] or {} table.insert(buckets[key],brick)
		end
	end
	local claimed={}
	for i,data in ipairs(session.blocks) do
		if data.placedBrick and data.placedBrick.Parent then claimed[data.placedBrick]=i end
	end
	for i,data in ipairs(session.blocks) do
		if data.placedBrick and not data.placedBrick.Parent then
			if data.pendingResize and data.pendingResize.brick==data.placedBrick then data.pendingResize=nil end
			data.pendingCollision=nil data.placedBrick=nil data.brick=nil session.done[i]=nil
		end
		if not data.placedBrick and not data.creation then
			local found,ambiguous=nil,false
			for _,brick in ipairs(buckets[bucket(data.centerPos,data.size)] or {}) do
				if brick:IsA("BasePart") and brick.Name=="Brick" and not session.helpers[brick] and not claimed[brick] and matchesAll(brick,data) then
					if found then ambiguous=true break end
					found=brick
				end
			end
			if found and not ambiguous then data.placedBrick=found data.brick=found claimed[found]=i end
		end
		local cleanup=false
		for _,holder in ipairs(data.work and data.work.helpers or {}) do
			if holder.creation or holder.brick and holder.brick.Parent then cleanup=true end
			if holder.brick and not holder.brick.Parent then session.helpers[holder.brick]=nil end
		end
		if not data.skipped and not data.repairRequested and data.placedBrick and matchesAll(data.placedBrick,data) and not data.pendingResize and not data.pendingCollision and not data.creation and not cleanup then
			session.done[i]=true
			session.ids[data.placedBrick]="t:"..i session.instances["t:"..i]=data.placedBrick
		else session.done[i]=nil end
	end
end
local function pauseForReset(reason)
	if not isBuilding then return end
	_G.stopautobuild=true
	unlockPosition()
	setStatus(reason.." · план и подтверждения сохранены. После возвращения инструментов нажми «Продолжить».",true)
end
local function watchBuildCharacter(character)
	local watchedHumanoid=nil
	local function bindHumanoid(hum)
		if hum and hum~=watchedHumanoid and hum.Died then
			watchedHumanoid=hum
			trackConn(hum.Died:Connect(function() if LocalPlayer.Character==character then pauseForReset("Персонаж погиб") end end))
		end
	end
	bindHumanoid(character and character:FindFirstChildOfClass("Humanoid"))
	if character then
		trackConn(character.DescendantAdded:Connect(function(item) if item:IsA("Humanoid") then bindHumanoid(item) end end))
		trackConn(character.DescendantRemoving:Connect(function(item)
			if item:IsA("Tool") and (item.Name=="Build" or item.Name=="Paint" or item.Name=="Shape" or item.Name=="Delete") then
				local name=item.Name
				task.defer(function() if not unloaded and isBuilding and not findTool(name) then pauseForReset("Потерян инструмент "..name) end end)
			end
		end))
	end
end
trackConn(LocalPlayer.CharacterRemoving:Connect(function() pauseForReset("Ресет персонажа") end))
trackConn(LocalPlayer.CharacterAdded:Connect(function(character)
	pauseForReset("Персонаж заменён")
	watchBuildCharacter(character)
end))
watchBuildCharacter(LocalPlayer.Character)

local function ensureNear(position,sourcePosition,force)
	local hrp=getValidHRP()
	if not hrp or cancelled() then return false end
	if not force and positionLock and (hrp.Position-position).Magnitude<=20 and (not sourcePosition or (hrp.Position-sourcePosition).Magnitude<=20) then return true end
	local anchor=position
	local height=CONFIG.BUILD_HEIGHT_OFFSET
	if sourcePosition then
		local gap=(position-sourcePosition).Magnitude
		if gap>39.8 then return false end
		anchor=(position+sourcePosition)/2
		if math.abs(position.Y-sourcePosition.Y)>.01 then height=math.min(height,19.8-gap/2) else height=math.min(height,math.sqrt(math.max(0,19.8^2-(gap/2)^2))) end
	end
	local target=anchor+Vector3.new(0,height,0)
	lockPosition(target)
	local readyAt=os.clock()+StudioHooks.timing.settle(force)
	return waitUntil(function()
		local c=LocalPlayer.Character
		local r=c and c:FindFirstChild("HumanoidRootPart")
		return os.clock()>=readyAt and r and (r.Position-target).Magnitude<.1
	end,math.max(2,roundTripPing()*4+.5))
end
local function facePoint(model,face)
	for _,d in ipairs(Planner.directions) do
		if d.face==face then return model.pos+d.unit*(model.size[d.axis]/2) end
	end
	return model.pos
end
local createOnce=(function()
	local C={}
	local observerToken={}
	local active={}
	local manifestFile="AutobuildRecovery.json"
	local stateFile="AutobuildPending.json"
	local lastManifest
	local function descendants(folder,focus)
		local root=workspace:FindFirstChild("Bricks")
		if focus and root and (folder==root or folder.IsDescendantOf and folder:IsDescendantOf(root)) then
			local result={}
			for _,part in ipairs(StudioHooks.liveWorld.query(root,focus)) do if part:IsDescendantOf(folder) then result[#result+1]=part end end
			return result
		end
		return folder.GetDescendants and folder:GetDescendants() or folder:GetChildren()
	end
	local function ownPart(part,folder)
		return part and part.Parent and part:IsA("BasePart") and part.Name=="Brick" and part.Anchored and part:IsDescendantOf(folder)
	end
	local function same(part,model) return (part.Position-model.pos).Magnitude<.03 and (part.Size-model.size).Magnitude<.03 end
	local function packedBox(m) return m and {pos=planVector(m.pos),size=planVector(m.size)} end
	local function box(m)
		if type(m)~="table" then return nil end
		local p,s=readPlanVector(m.pos),readPlanVector(m.size)
		if not p or not s or s.X<1 or s.Y<1 or s.Z<1 then return nil end
		return {pos=p,size=s}
	end
	local function packedSource(m)
		if not m then return nil end
		return serializeBlock({centerPos=m.pos,size=m.size,color=m.color,material=m.material,canCollide=m.collide,sprays=m.sprays or {}})
	end
	local function unique(model)
		local folder=getPlayerBricksFolder() if not folder or not model then return nil end
		local found
		for _,part in ipairs(descendants(folder,model)) do if ownPart(part,folder) and same(part,model) then if found then return nil end found=part end end
		return found
	end
	local function packedHolder(holder)
		local value={temporary=holder.temporary==true,deleteRequested=holder.deleteRequested==true,brick=holder.brick and holder.brick.Parent and packedBox(instanceModel(holder.brick,"checkpoint")) or nil,retired={}}
		for _,old in ipairs(holder.retired or {}) do value.retired[#value.retired+1]={initial=packedBox(old.initial),beforeCount=old.beforeCount or 0} end
		local c=holder.creation
		if c then value.creation={initial=packedBox(c.initial),mode=c.mode,face=FaceSymbols[c.face],clone=c.expectedClone==true,beforeCount=c.beforeCount or 0,attempts=c.attempts or 1,sentUnix=c.sentUnix,source= c.source and c.source.Parent and packedSource(instanceModel(c.source,"checkpoint")) or nil} end
		return value
	end
		local function checkpointIndices(session,persist)
		local state=StudioHooks.runtimeState.ensure(session)
		if appendfile and session.journalReady and persist~="flush" then return state.dirty end
		return StudioHooks.runtimeState.indices(session)
	end
	local function writeCheckpoint(session,file,payload,persist)
		if appendfile and session.journalReady and persist~="flush" then
			session.journalSeq=(session.journalSeq or 0)+1 payload.seq=session.journalSeq payload.indices={}
			for index in pairs(session.runtimeState.dirty) do payload.indices[#payload.indices+1]=index end
			appendfile(file..".journal",HttpService:JSONEncode(payload).."\n")
		else
			payload.seq=session.journalSeq or 0
			writefile(file,HttpService:JSONEncode(payload))
			if appendfile then writefile(file..".journal","") session.journalReady=true end
		end
		session.runtimeState.dirty={}
	end
	local function mergeJournal(session,file,stored)
		if not readfile or not isfile or not isfile(file..".journal") then return stored end
		local text=readfile(file..".journal") if text=="" then return stored end
		if stored.seq~=nil and (type(stored.seq)~="number" or stored.seq~=stored.seq or stored.seq<0 or stored.seq%1~=0) then session.recoveryBlocked="Неверная последовательность контрольного снимка" return stored end
		local entries={}
		for line in text:gmatch("([^\n]+)\n") do
			local ok,value=pcall(function() return HttpService:JSONDecode(line) end)
			if not ok or type(value)~="table" or value.job~=game.JobId or value.buildId~=session.buildId or type(value.seq)~="number" or value.seq~=value.seq or value.seq<1 or value.seq%1~=0 or type(value.indices)~="table" or type(value.records)~="table" or type(value.controls)~="table" then
				session.recoveryBlocked="Повреждён журнал незавершённых команд; новые команды остановлены" return stored
			end
			if value.seq>(stored.seq or 0) then entries[#entries+1]=value end
		end
		if text:sub(-1)~="\n" then session.recoveryBlocked="Не завершена запись журнала команд; требуется сверка" return stored end
		table.sort(entries,function(a,b) return a.seq<b.seq end)
		local records,controls={},{}
		for _,record in ipairs(stored.records or {}) do records[record.index]=record end
		for _,control in ipairs(stored.controls or {}) do controls[control.index]=control end
		for _,value in ipairs(entries) do
			local changed={}
			for _,index in ipairs(value.indices) do
				if type(index)~="number" or index%1~=0 or index<1 or index>#session.blocks then session.recoveryBlocked="Неверный индекс в журнале команд" return stored end
				changed[index]=true
				records[index]=nil controls[index]=nil
			end
			for _,record in ipairs(value.records) do
				if type(record)~="table" or not changed[record.index] then session.recoveryBlocked="Неверная запись в журнале команд" return stored end
				records[record.index]=record
			end
			for _,control in ipairs(value.controls) do
				if type(control)~="table" or not changed[control.index] then session.recoveryBlocked="Неверная запись управления в журнале" return stored end
				controls[control.index]=control
			end
			stored.obstacles=value.obstacles stored.seq=value.seq
		end
		stored.records={} stored.controls={}
		for _,record in pairs(records) do stored.records[#stored.records+1]=record end
		for _,control in pairs(controls) do stored.controls[#stored.controls+1]=control end
		session.journalSeq=stored.seq or 0
		return stored
	end

	function C.capture(session,persist,index)
		if session.transient then StudioHooks.runtimeState.ensure(session) StudioHooks.runtimeState.touch(session,index or session.activeIndex or session.lastFailedIndex) return true end
		StudioHooks.runtimeState.ensure(session)
		StudioHooks.runtimeState.touch(session,index or session.activeIndex or session.lastFailedIndex)
		local manifestFile,stateFile=manifestFile,stateFile
		if StudioHooks.documents then manifestFile,stateFile=StudioHooks.documents.paths(session,true) end
		_G.AUTOBUILD_RESUME={version=2,job=game.JobId,session=session}
		if persist==false then return true end
		if not writefile then return false,"Нет writefile; состояние сохранено только в памяти" end
		local records={}
		local controls={}
		for index in pairs(checkpointIndices(session,persist)) do
			local data=session.blocks[index]
			if data.skipped or data.repairRequested or data.failure or data.repairDeleteRequested then controls[#controls+1]={index=index,skipped=data.skipped==true,repair=data.repairRequested==true,deleteRequested=data.repairDeleteRequested==true,failure=data.failure,guard=data.guardDamage==true} end
			if data.work and not session.done[index] then
				local recipe=data.work.recipe
				local record={index=index,holder=packedHolder(data),recipe={kind=recipe.kind,initial=packedBox(recipe.initial),face=FaceSymbols[recipe.face],source=packedSource(recipe.source),helpers={}},helpers={}}
				for _,h in ipairs(recipe.helpers or {}) do record.recipe.helpers[#record.recipe.helpers+1]=packedBox(h) end
				for _,h in ipairs(data.work.helpers or {}) do record.helpers[#record.helpers+1]=packedHolder(h) end
				if data.pendingResize then record.resize={before=packedBox(data.pendingResize.step.before),after=packedBox(data.pendingResize.step.after),mode=data.pendingResize.step.mode} end
				record.collision=data.pendingCollision==true records[#records+1]=record
			end
		end
		local ok,err=pcall(function()
			if not lastManifest or lastManifest.file~=manifestFile or lastManifest.id~=session.buildId or lastManifest.text~=session.text or lastManifest.offset~=session.offset then
				writefile(manifestFile,HttpService:JSONEncode({version=1,job=game.JobId,buildId=session.buildId,text=session.text,offset=planVector(session.offset)})) lastManifest={file=manifestFile,id=session.buildId,text=session.text,offset=session.offset}
			end
			writeCheckpoint(session,stateFile,{version=1,job=game.JobId,buildId=session.buildId,records=records,controls=controls,obstacles=StudioHooks.guard and StudioHooks.guard.pack(session) or nil},persist)
		end)
		if StudioHooks.documents then StudioHooks.documents.record(session) end
		if not ok then setStatus("Состояние в памяти; контрольная запись не удалась: "..tostring(err),true) end
		return ok,err
	end
	function C.restore(session)
		if session.transient then return end
		local manifestFile,stateFile=manifestFile,stateFile
		if StudioHooks.documents then manifestFile,stateFile=StudioHooks.documents.paths(session,false) end
		if not readfile or not isfile then return end
		pcall(function()
			if not isfile(manifestFile) or not isfile(stateFile) then return end
			local manifest=HttpService:JSONDecode(readfile(manifestFile)) local stored=HttpService:JSONDecode(readfile(stateFile))
			if type(manifest)~="table" or type(stored)~="table" or manifest.version~=1 or stored.version~=1 or manifest.job~=game.JobId or stored.job~=game.JobId or manifest.buildId~=session.buildId or stored.buildId~=session.buildId or manifest.text~=session.text or readPlanVector(manifest.offset)~=session.offset or type(stored.records)~="table" then return end
			stored=mergeJournal(session,stateFile,stored)
			if session.recoveryBlocked then setStatus(session.recoveryBlocked,true) return end
			for _,c in ipairs(stored.controls or {}) do
				local data=type(c)=="table" and session.blocks[c.index]
				if data then data.guardDamage=c.guard==true or nil data.skipped=c.skipped==true or nil data.repairRequested=c.repair==true or nil data.repairDeleteRequested=c.deleteRequested==true or nil data.failure=type(c.failure)=="string" and c.failure or nil end
			end
			if StudioHooks.guard then StudioHooks.guard.restore(session,stored.obstacles) end
			local folder=getPlayerBricksFolder() if not folder then return end
			local function holder(saved,final)
				if type(saved)~="table" then return nil end
				local result={temporary=saved.temporary==true,deleteRequested=saved.deleteRequested==true,finalModel=final}
				result.brick=unique(box(saved.brick))
				result.retired={}
				for _,old in ipairs(type(saved.retired)=="table" and saved.retired or {}) do
					local initial=type(old)=="table" and box(old.initial)
					if initial then
						local retired={initial=initial,candidates={},seen={},before={}}
						if type(old.beforeCount)=="number" and old.beforeCount>0 then for _,p in ipairs(descendants(folder,initial)) do if ownPart(p,folder) and same(p,initial) then retired.before[p]=true end end end
						result.retired[#result.retired+1]=retired
					end
				end
				if type(saved.creation)=="table" then
					local c=saved.creation local initial=box(c.initial) local source
					if type(c.source)=="string" then local parsed,bad=parseBlocks(c.source,Vector3.zero) if bad==0 and #parsed==1 then source=unique({pos=parsed[1].centerPos,size=parsed[1].size}) end end
					if initial and (c.mode=="normal" or c.mode=="detailed") then
						local age=type(c.sentUnix)=="number" and math.clamp(os.time()-c.sentUnix-1,0,600) or 0
						result.creation={initial=initial,mode=c.mode,face=FaceSymbolsReverse[c.face] or Enum.NormalId.Top,expectedClone=c.clone==true,source=source,candidates={},seen={},before={},beforeCount=type(c.beforeCount)=="number" and math.max(0,c.beforeCount) or 0,attempts=type(c.attempts)=="number" and math.clamp(c.attempts,1,10000) or 1,sentAt=os.clock()-age,sentUnix=os.time()-age}
						if result.creation.beforeCount>0 then for _,p in ipairs(descendants(folder,initial)) do if ownPart(p,folder) and same(p,initial) then result.creation.before[p]=true end end end
					end
				end
				return result
			end
			for _,record in ipairs(stored.records) do
				local index=type(record)=="table" and record.index
				local data=index and session.blocks[index] local target=index and session.models[index]
				if not data or type(record.recipe)~="table" then continue end
				local initial=box(record.recipe.initial) if not initial then continue end
				if not ({normal=true,detailed=true,clone=true,reuse=true,bridge=true,edit=true})[record.recipe.kind] then continue end
				local source
				if type(record.recipe.source)=="string" then
					local parsed,bad=parseBlocks(record.recipe.source,Vector3.zero)
					if bad==0 and #parsed==1 then source=targetModel(parsed[1],"recovered-source") source.instance=unique(source) end
				end
				local recipe={kind=record.recipe.kind,initial=initial,target=target,source=source,face=FaceSymbolsReverse[record.recipe.face],helpers={},shapeSteps=0}
				for _,packed in ipairs(record.recipe.helpers or {}) do local h=box(packed) if not h then return end recipe.helpers[#recipe.helpers+1]=h end
				if #recipe.helpers>2 then continue end
				local restored=holder(record.holder,target) if not restored then continue end
				if not restored.brick and type(record.resize)=="table" then restored.brick=unique(box(record.resize.after)) or unique(box(record.resize.before)) end
				data.brick=restored.brick data.placedBrick=restored.brick data.creation=restored.creation data.finalModel=target
				data.retired=restored.retired
				if data.placedBrick then session.ids[data.placedBrick]=target.id session.instances[target.id]=data.placedBrick end
				data.work={recipe=recipe,helpers={}}
				for n,h in ipairs(record.helpers or {}) do
					local helper=holder(h,recipe.helpers[n]) if not helper then break end
					data.work.helpers[n]=helper if helper.brick then session.helpers[helper.brick]=true end
				end
				if data.placedBrick and type(record.resize)=="table" and box(record.resize.after) and box(record.resize.before) then data.pendingResize={brick=data.placedBrick,step={before=box(record.resize.before),after=box(record.resize.after),mode=record.resize.mode}} end
				data.pendingCollision=record.collision==true and true or nil
			end
			setStatus("Восстановлена незавершённая работа; сверяю реальные блоки")
		end)
	end
	function C.preparation(session)
		local partials,sources={},{}
		for index,data in ipairs(session.blocks) do
			if data.placedBrick and data.placedBrick.Parent and not session.done[index] then partials[index]=instanceModel(data.placedBrick,session.ids[data.placedBrick] or session.models[index].id) end
			local helpers=data.work and data.work.helpers or {}
			for n=#helpers,1,-1 do
				local part=helpers[n].brick
				if part and part.Parent then local m=instanceModel(part,session.ids[part] or "resume:"..index..":"..n) m.external=true sources[index]=m break end
			end
		end
		return partials,sources
	end
	local function watch(c,folder)
		if c.observerToken==observerToken and c.folder==folder then return end
		if c.connection then c.connection:Disconnect() end
		c.folder=folder c.observerToken=observerToken c.seen=c.seen or {}
		c.connection=(folder.DescendantAdded or folder.ChildAdded):Connect(function(part)
			if part:IsA("BasePart") and not c.before[part] and not c.seen[part] and same(part,c.initial) then c.candidates[#c.candidates+1]=part c.seen[part]=true end
		end)
		active[c]=true c.nextScan=0
	end
	local function resolve(c,folder,holder,session)
		watch(c,folder)
		-- Poll as well as listen: streaming and delayed Name/Size replication can
		-- occur after the original hierarchy event, including under child Models.
		if os.clock()>=(c.nextScan or 0) then
			c.nextScan=os.clock()+.1
			for _,part in ipairs(descendants(folder,c.initial)) do
				if part:IsA("BasePart") and not c.before[part] and not c.seen[part] and same(part,c.initial) then c.candidates[#c.candidates+1]=part c.seen[part]=true end
			end
		end
		local found
		for _,part in ipairs(c.candidates) do
			if ownPart(part,folder) and same(part,c.initial) then
				if found and part~=found then return nil,"ambiguous" end
				local claimed=session.ids[part]
				if not claimed or claimed:sub(1,2)=="w:" or holder.brick==part then found=part end
			end
		end
		return found
	end
	local function accept(holder,part,session)
		local c=holder.creation c.connection:Disconnect() active[c]=nil holder.creation=nil holder.brick=part holder.createBlocked=nil
		if c.sentAt and c.attempts==1 then StudioHooks.timing.observed("create",os.clock()-c.sentAt) end
		C.capture(session,false) return part
	end
	function C.inspect(holder,session)
		local folder=getPlayerBricksFolder() if not folder then return false,"Нет вашей папки блоков" end
		local c=holder.creation
		if c then
			local part,reason=resolve(c,folder,holder,session)
			if not part then return false,reason=="ambiguous" and "Несколько кандидатов на неподтверждённый блок" or "Переделка ждёт прежний запрос создания; его нельзя забыть безопасно" end
			accept(holder,part,session)
		end
		for n=#(holder.retired or {}),1,-1 do
			local old=holder.retired[n] local part=resolve(old,folder,holder,session)
			if not part or holder.brick and holder.brick~=part then return false,"Переделка ждёт поздний запрос; блок можно пропустить" end
			holder.creation=old accept(holder,part,session) table.remove(holder.retired,n)
		end
		if holder.brick and holder.temporary then session.helpers[holder.brick]=true end
		if holder.brick and not holder.temporary then
			holder.placedBrick=holder.brick
			local index=session.activeIndex
			if index then session.ids[holder.brick]=session.models[index].id session.instances[session.models[index].id]=holder.brick end
		end
		return true
	end
	function C.create(holder,source,face,initial,mode,session,label)
		if holder.brick and holder.brick.Parent then return holder.brick end
		local folder=getPlayerBricksFolder() if not folder then return nil,"Нет вашей папки блоков" end
		local c=holder.creation
		for _,retired in ipairs(holder.retired or {}) do
			if retired.initial and (retired.initial.pos-initial.pos).Magnitude<.03 and (retired.initial.size-initial.size).Magnitude<.03 then
				local part=resolve(retired,folder,holder,session)
				if part then holder.creation=retired return accept(holder,part,session) end
			end
		end
		if not c then
			c={candidates={},seen={},before={},initial=initial,mode=mode,face=face or Enum.NormalId.Top,source=source,expectedClone=source~=nil,attempts=0,beforeCount=0,sentAt=-math.huge,roundAttempts=0}
			for _,part in ipairs(descendants(folder,initial)) do if ownPart(part,folder) and same(part,initial) then c.before[part]=true c.beforeCount+=1 end end
			holder.creation=c
		elseif not c.initial then
			-- Migrate an in-memory pending request from the previous implementation.
			local recipe=holder.work and holder.work.recipe
			c.initial=initial c.mode=mode c.face=face or Enum.NormalId.Top c.source=source or recipe and recipe.source and (recipe.source.instance or session.instances[recipe.source.id]) c.expectedClone=recipe and (recipe.kind=="clone" or recipe.kind=="bridge") or source~=nil c.attempts=1 c.sentAt=os.clock()-10 c.sentUnix=os.time() c.seen={}
			for _,part in ipairs(c.candidates) do c.seen[part]=true end
		end
		if c.roundAttempts==nil or c.action~=session.actionRevision then c.action=session.actionRevision c.roundAttempts=0 end
		local found,reason=resolve(c,folder,holder,session)
		if found then return accept(holder,found,session) end
		if reason then holder.createBlocked=true return nil,"Несколько новых блоков совпадают; требуется сверка, чужие детали не удаляются" end
		while c.roundAttempts<3 and not cancelled() do
			if c.attempts>0 then
				local deadline=c.sentAt+math.max(10,roundTripPing()*8+1)
				if session.queueCreations and os.clock()<deadline+math.max(.2,roundTripPing()*2) then
					return nil,"Целевой запрос отложен; сначала продолжаю остальные блоки"
				end
				if os.clock()<deadline then
					local ready=waitUntil(function()
						folder=getPlayerBricksFolder() or folder found,reason=resolve(c,folder,holder,session)
						return found~=nil or reason~=nil
					end,deadline-os.clock())
					if ready and found then return accept(holder,found,session) end
					if cancelled() then return nil,"Пауза; ожидание сохранено" end
					if reason then break end
				end
				-- A retry follows an extra quiet interval and a fresh world read.
				if not waitUntil(function() return os.clock()>=c.sentAt+math.max(10,roundTripPing()*8+1)+math.max(.2,roundTripPing()*2) end,math.max(.5,roundTripPing()*2+.1)) then return nil,"Пауза; ожидание сохранено" end
			end
			found,reason=resolve(c,folder,holder,session) if found then return accept(holder,found,session) end
			if reason then break end
			local tool=awaitTool("Build") if not tool then break end
			local currentSource=c.source
			if c.expectedClone and (not currentSource or not currentSource.Parent) then
				-- The source has been removed, so this recipe cannot be sent again.
				-- Keep its listener alive while the executor replans the missing stage.
				holder.retired=holder.retired or {} holder.retired[#holder.retired+1]=c
				holder.creation=nil holder.createBlocked=true C.capture(session)
				return nil,"Источник прежнего создания исчез; пересчитаю этот этап после сверки мира"
			end
			if currentSource then
				if not currentSource.Parent or not currentSource.Anchored then break end
				local prediction
				for _,d in ipairs(Planner.directions) do if d.face==c.face then prediction=currentSource.Position+d.unit*currentSource.Size[d.axis] break end end
				if not prediction or (prediction-c.initial.pos).Magnitude>.03 or (currentSource.Size-c.initial.size).Magnitude>.03 then
					holder.retired=holder.retired or {} holder.retired[#holder.retired+1]=c holder.creation=nil holder.createBlocked=true C.capture(session)
					return nil,"Источник изменился; пересчитаю этап, старый ответ остаётся под наблюдением"
				end
			end
			local input=currentSource and facePoint(instanceModel(currentSource,"input"),c.face) or c.initial.pos
			if not currentSource and c.mode=="detailed" then input+=CONFIG.DETAILED_INPUT_OFFSET end
			if not ensureNear(input,currentSource and currentSource.Position or nil,c.attempts>0) then break end
			found,reason=resolve(c,folder,holder,session) if found then return accept(holder,found,session) end
			local obstacles=snapshotWorld(session,true,c.initial)
			if StudioHooks.guard then
				local cleared,changed=StudioHooks.guard.clearBox(session,c.initial,currentSource,obstacles)
				if not cleared then holder.createBlocked=true return nil,changed end
				if changed then obstacles=snapshotWorld(session,true,c.initial) end
			end
			for n=#obstacles,1,-1 do if obstacles[n].reservedHolder==holder then table.remove(obstacles,n) end end
			if not Planner.safeBox(c.initial,holder.finalModel or c.initial,obstacles,nil,holder.temporary==true) then break end
			if cancelled() then return nil,"Пауза; ожидание сохранено" end
			if session.lastCreateSent then
				if not waitUntil(function() return os.clock()-session.lastCreateSent>=StudioHooks.timing.pace() end,math.max(.5,StudioHooks.timing.pace()+.1)) then return nil,"Пауза; ожидание сохранено" end
			end
			found,reason=resolve(c,folder,holder,session) if found then return accept(holder,found,session) end
			if reason then break end
			c.roundAttempts+=1 c.attempts+=1 c.sentAt=os.clock() c.sentUnix=os.time()
			session.lastCreateSent=c.sentAt
			C.capture(session)
			if c.attempts>1 then setStatus(label..": восстанавливаю создание, попытка "..c.roundAttempts.."/3") end
			session.actual.creates+=1
			local sent,err=pcall(function() tool.event:FireServer(currentSource or workspace.Terrain,c.face,input,c.mode) end)
			if not sent then c.sentAt=os.clock()-10 setStatus("Команда Build не отправлена: "..tostring(err),true) end
			local ready=waitUntil(function()
				folder=getPlayerBricksFolder() or folder found,reason=resolve(c,folder,holder,session)
				return found~=nil or reason~=nil
			end,responseTimeout(5))
			if ready and found then return accept(holder,found,session) end
			if reason then break end
			if session.queueCreations then break end
		end
		holder.createBlocked=true C.capture(session)
		return nil,string.format("Блок пока не появился: %s @ %s; попыток %d; RTT×2 %.3fс. Состояние сохранено; продолжение проверит мир и сможет повторить создание.",tostring(c.initial.size),tostring(c.initial.pos),c.attempts,roundTripPing())
	end
	function C.nextWake(data,session)
		local wake
		local function include(holder)
			local c=holder.creation
			if not c or not c.sentAt or (c.attempts or 0)==0 then return end
			local deadline=c.sentAt+math.max(10,roundTripPing()*8+1)+math.max(.2,roundTripPing()*2)
			local rounds=c.action==session.actionRevision and (c.roundAttempts or 0) or 0
			if rounds<3 or os.clock()<deadline then wake=math.min(wake or math.huge,math.max(os.clock(),deadline)) end
		end
		include(data) for _,h in ipairs(data.work and data.work.helpers or {}) do include(h) end
		return wake
	end
	function C.arrived(data,session)
		local folder=getPlayerBricksFolder() if not folder then return false end
		local function present(holder)
			local c=holder.creation
			if c then local part=resolve(c,folder,holder,session) return part~=nil end
			return false
		end
		if present(data) then return true end
		for _,h in ipairs(data.work and data.work.helpers or {}) do if present(h) then return true end end
		return false
	end
	function C.close()
		for c in pairs(active) do if c.connection then c.connection:Disconnect() end end table.clear(active)
	end
	function C.completed(data)
		local function clear(holder)
			for _,c in ipairs(holder.retired or {}) do if c.connection then c.connection:Disconnect() end active[c]=nil end
			holder.retired=nil holder.createBlocked=nil
		end
		clear(data) for _,h in ipairs(data.work and data.work.helpers or {}) do clear(h) end
	end
	C.mergeJournal=mergeJournal
	StudioHooks.recovery=C
	return C.create
end)()

local function boundaryEdit(brick,target,session,data)
	if data.pendingResize then
		local pending=data.pendingResize
		if pending.brick~=brick then return false,"Изменился блок ожидающего ресайза" end
		if not waitUntil(function() return brick.Parent and (brick.Size-pending.step.after.size).Magnitude<.03 and (brick.Position-pending.step.after.pos).Magnitude<.03 end,responseTimeout(2)) then return false,"Ожидаю подтверждение ранее отправленного шага грани; повтор не отправлен" end
		data.pendingResize=nil
	end
	if (brick.Position-target.pos).Magnitude<.03 and (brick.Size-target.size).Magnitude<.03 then return true end
	local partial=instanceModel(brick,session.ids[brick] or "partial")
	local obstacles=snapshotWorld(session,true,StudioHooks.liveWorld.focus(target,partial))
	local recipe=Planner.chooseLive(target,{},obstacles,session.models,false,partial)
	if not recipe then return false,"Нельзя безопасно изменить границы текущего блока" end
	for _,step in ipairs(recipe.steps) do
		if cancelled() then return false,"Пауза" end
		if (brick.Position-step.before.pos).Magnitude>.03 or (brick.Size-step.before.size).Magnitude>.03 then return false,"Блок изменился до шага ресайза" end
		local scene=snapshotWorld(session,true,step.after)
		if StudioHooks.guard then
			local cleared,changed=StudioHooks.guard.clearBox(session,step.after,brick,scene)
			if not cleared then return false,changed end
			if changed then scene=snapshotWorld(session,true,step.after) end
		end
		if not Planner.safeBox(step.after,target,scene,session.ids[brick],false) then return false,"Путь изменения грани занят другим блоком" end
		if not ensureNear(brick.Position) then return false,"Персонаж недоступен для ресайза" end
		local tool=awaitTool("Shape")
		local hrp=LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not tool or not hrp or cancelled() then return false,"Нет Shape или персонажа" end
		session.actual.shapes=session.actual.shapes+1
		data.pendingResize={brick=brick,step=step}
		StudioHooks.recovery.capture(session)
		local sent,sendError=pcall(function() tool.event:FireServer(brick,step.face,hrp.Position,step.mode) end)
		if not sent then data.pendingResize=nil return false,tostring(sendError) end
		if not waitUntil(function() return brick.Parent and (brick.Size-step.after.size).Magnitude<.03 and (brick.Position-step.after.pos).Magnitude<.03 end,responseTimeout(2)) then
			return false,"Шаг грани не подтверждён: "..step.mode.."; ожидалось "..tostring(step.after.size).." @ "..tostring(step.after.pos).."; повтор не отправлен"
		end
		data.pendingResize=nil
	end
	return brick.Parent~=nil and (brick.Position-target.pos).Magnitude<.03 and (brick.Size-target.size).Magnitude<.03,"Итоговая геометрия не совпала"
end
local function deleteHelper(holder,session)
	local brick=holder.brick
	if not brick or not brick.Parent then if brick then session.helpers[brick]=nil end return true end
	if not session.helpers[brick] or not holder.temporary then return false,"Объект не зарегистрирован как собственный временный блок" end
	local own=getPlayerBricksFolder()
	if not own or not brick:IsDescendantOf(own) then return false,"Временный блок больше не принадлежит вашей папке" end
	if cancelled() then return false,"Пауза; временные блоки сохраняются до продолжения" end
	if not holder.deleteRequested then
		if not ensureNear(brick.Position) then return false,"Не удалось подойти к временному блоку" end
		local tool=awaitTool("Delete")
		local hrp=LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not tool or not hrp then return false,"Нужен Delete для удаления временных блоков" end
		holder.deleteRequested=true session.actual.deletes=session.actual.deletes+1
		StudioHooks.recovery.capture(session)
		tool.event:FireServer(brick,hrp.Position)
	end
	if not waitUntil(function() return brick.Parent==nil end,responseTimeout(5)) then return false,"Удаление временного блока не подтверждено; повтор не отправлен" end
	session.helpers[brick]=nil
	return true
end
local function collisionConfirmed(brick,data)
	if data.pendingCollision then
		if not waitUntil(function() return brick.Parent and brick.CanCollide==data.canCollide end,responseTimeout(2)) then return false end
		data.pendingCollision=nil return true
	end
	if brick.CanCollide==data.canCollide then return true end
	local hrp=getValidHRP() local tool=awaitTool("Paint")
	if not tool or not hrp or cancelled() then return false end
	data.pendingCollision=true
	if resumeSession then StudioHooks.recovery.capture(resumeSession) end
	local sent=pcall(function() tool.event:FireServer(brick,Enum.NormalId.Back,hrp.Position,"material",data.color,"collide","") end)
	if not sent then data.pendingCollision=nil return false end
	if not waitUntil(function() return brick.Parent and brick.CanCollide==data.canCollide end,responseTimeout(2)) then return false end
	data.pendingCollision=nil return true
end
local function executeBlock(data,index,session)
	local target=session.models[index]
	if data.placedBrick and not data.placedBrick.Parent then
		-- A late operation references the removed Instance, never its replacement.
		if data.pendingResize and data.pendingResize.brick==data.placedBrick then data.pendingResize=nil end
		data.pendingCollision=nil data.brick=nil
	end
	if data.work and (not data.placedBrick or not data.placedBrick.Parent) and not data.creation then
		local started=false
		for _,holder in ipairs(data.work.helpers) do if holder.creation or holder.brick and holder.brick.Parent then started=true break end end
		if not started then data.work=nil data.brick=nil end
	end
	if data.placedBrick and data.placedBrick.Parent then
		data.work=data.work or {recipe={kind="reuse",target=target},helpers={}}
	end
	if not data.work then
		local reviewed=session.planByIndex[index]
		local focus=StudioHooks.liveWorld.focus(target,reviewed.initial,reviewed.source)
		for _,helper in ipairs(reviewed.helpers or {}) do focus=StudioHooks.liveWorld.focus(focus,helper) end
		local obstacles,sources=snapshotWorld(session,false,focus)
		local recipe=Planner.reviewLive(reviewed,target,sources,obstacles,session.models)
		if not recipe then
			obstacles,sources=snapshotWorld(session)
			recipe=Planner.chooseLive(target,sources,obstacles,session.models,reviewed.kind=="bridge" and findTool("Delete")~=nil)
		end
		if not recipe then return false,"Нет безопасного способа создания блока "..index end
		if recipe.kind=="bridge" then
			local unchanged=#recipe.helpers==#reviewed.helpers
			for n,helper in ipairs(recipe.helpers) do if not reviewed.helpers[n] or not Planner.geometry(helper,reviewed.helpers[n]) then unchanged=false end end
			if not unchanged then
				recipe=Planner.chooseLive(target,sources,obstacles,session.models,false)
				if not recipe then return false,"Изменился мостик; безопасного обхода пока нет" end
				setStatus("Мостик изменился; исправлен маршрут только текущего блока")
			end
		end
		data.work={recipe=recipe,helpers={}}
		if recipe.kind=="reuse" then data.placedBrick=recipe.source.instance end
	end
	local work,recipe=data.work,data.work.recipe
	-- Resolve an already sent creation before repairing its now missing source.
	-- The target may have arrived while the character or helper was removed.
	if data.creation then
		local created,message=createOnce(data,nil,recipe.face,recipe.initial,recipe.kind=="detailed" and "detailed" or "normal",session,"Целевой блок")
		if not created then return false,message end
		data.placedBrick=created
	end
	for n,holder in ipairs(work.helpers) do
		if holder.creation then
			local helper,message=createOnce(holder,nil,recipe.face,recipe.helpers[n],"normal",session,"Временный "..n)
			if not helper then return false,message end
			session.helpers[helper]=true
		end
	end
	setStatus("Блок "..((_G.autobuildPlaced or 0)+1).."/"..#session.blocks..": "..recipe.kind.."; грани "..(recipe.shapeSteps or 0))
	if not data.placedBrick or not data.placedBrick.Parent then
		local source=recipe.source and recipe.source.instance
		if recipe.source and not source then source=session.instances[recipe.source.id] end
		if recipe.source and (not source or not source.Parent or not Planner.geometry(instanceModel(source,"source"),recipe.source)) then
			local first=work.helpers[1]
			if not (first and first.brick and first.brick.Parent) then
				if data.creation then return false,"Ожидаю прежний запрос после потери источника" end
				for _,holder in ipairs(work.helpers) do
					if holder.creation then return false,"Ожидаю прежний запрос вспомогательного блока" end
					local removed,message=deleteHelper(holder,session) if not removed then return false,message end
				end
				local obstacles,sources=snapshotWorld(session)
				local replacement=Planner.chooseLive(target,sources,obstacles,session.models,false)
				if not replacement then return false,"Источник потерян; безопасного обхода пока нет" end
				data.work={recipe=replacement,helpers={}}
				if replacement.kind=="reuse" then data.placedBrick=replacement.source.instance end
				data.replans=(data.replans or 0)+1
				if data.replans>2 then return false,"Источник меняется повторно; блок отложен" end
				task.wait()
				if cancelled() then return false,"Пауза" end
				return executeBlock(data,index,session)
			end
		end
		for n,model in ipairs(recipe.helpers or {}) do
			local holder=work.helpers[n]
			if not holder then holder={temporary=true,finalModel=model} work.helpers[n]=holder end
			if holder.brick and not holder.brick.Parent then
				session.helpers[holder.brick]=nil holder.brick=nil holder.deleteRequested=nil
				setStatus("Восстанавливаю пропавший вспомогательный блок "..n)
			end
			local helper,err=createOnce(holder,source,recipe.face,model,"normal",session,"Временный "..n)
			if not helper then return false,err end
			session.helpers[helper]=true
			if not session.ids[helper] then session.nextWorld=session.nextWorld+1 session.ids[helper]="h:"..session.nextWorld end
			local sourceColor,sourceMaterial,sourceCollide=recipe.source.color,recipe.source.material,recipe.source.collide
			if not Planner.geometry(instanceModel(helper,"helper"),model) then return false,"Вспомогательный блок изменил геометрию" end
			if not waitUntil(function() return helper.Parent and sameColor(helper.Color,sourceColor) and helper.Material==sourceMaterial and helper.CanCollide==sourceCollide and helper.Anchored end,responseTimeout(2)) then return false,"Свойства временной копии не подтверждены" end
			source=helper
		end
		data.finalModel=target
		local created,err=createOnce(data,source,recipe.face,recipe.initial,recipe.kind=="detailed" and "detailed" or "normal",session,"Целевой блок")
		if not created then return false,err end
		data.placedBrick=created
	end
	local brick=data.placedBrick
	session.ids[brick]=target.id session.instances[target.id]=brick
	local ok,err=boundaryEdit(brick,target,session,data)
	if not ok then return false,err end
	if not matchesAll(brick,data) or data.pendingCollision then
	if not ensureNear(brick.Position) then return false,"Не удалось подойти для проверки свойств" end
	if not paintBlock(brick,data) then return false,"Цвет или материал не подтверждён" end
	if not collisionConfirmed(brick,data) then return false,"Столкновения не подтверждены; повтор переключения не отправлен" end
	for _,sp in ipairs(data.sprays) do if not sprayBlock(brick,sp) then return false,"Надпись не подтверждена" end end
	end
	if not matchesAll(brick,data) then return false,"Итоговая проверка геометрии или свойств не пройдена" end
	for n=#work.helpers,1,-1 do local removed,message=deleteHelper(work.helpers[n],session) if not removed then return false,message end end
	if not matchesAll(brick,data) then return false,"Целевой блок изменился после удаления временных деталей" end
	return true
end
-- Interrupt a single target without forgetting a command already in flight.
StudioHooks.control=(function()
	local C={}
	function C.interrupted()
		local s=resumeSession local d=s and s.activeIndex and s.blocks[s.activeIndex]
		return d and (d.skipped or d.repairInterrupt)==true
	end
	local function selected()
		local s=resumeSession if not s then return nil end
		local i=s.activeIndex or s.lastFailedIndex
		if not i then for n,d in ipairs(s.blocks) do if d.skipped or d.failure then i=n break end end end
		return s,i,i and s.blocks[i]
	end
	function C.skip()
		local s,i,d=selected()
		if not d or s.done[i] then setStatus("Нет текущего или проблемного блока",true) return false end
		d.skipped=true d.repairRequested=nil d.repairInterrupt=nil
		StudioHooks.recovery.capture(s,nil,i) markPlanProgress(s,i)
		setStatus("Пропущен блок №"..i..". Его отправленные запросы остаются под наблюдением.")
		return true
	end
	function C.repair()
		local s,i,d=selected()
		if not d or s.done[i] then setStatus("Нет проблемного блока для переделки",true) return false end
		d.skipped=nil d.repairRequested=true d.repairInterrupt=s.activeIndex==i or nil
		s.lastFailedIndex=i StudioHooks.recovery.capture(s,nil,i) markPlanProgress(s,i)
		setStatus("Переделка блока №"..i.." поставлена в очередь")
		if not isBuilding and StudioHooks.resumeRecovery then StudioHooks.resumeRecovery() end
		return true
	end
	local function rebuild(data,index,session)
		-- Resolve late creations first. Never clear an unknown Build request.
		local ok,err=StudioHooks.recovery.inspect(data,session)
		if not ok then return false,err end
		for _,h in ipairs(data.work and data.work.helpers or {}) do
			ok,err=StudioHooks.recovery.inspect(h,session) if not ok then return false,err end
		end
		local brick=data.placedBrick or data.brick
		if brick and brick.Parent then
			local own=getPlayerBricksFolder()
			if not own or not brick:IsDescendantOf(own) or session.instances[session.models[index].id]~=brick then return false,"Переделка отклонена: блок не закреплён за этой деталью" end
			if not data.repairDeleteRequested then
				if not ensureNear(brick.Position) then return false,"Не удалось подойти для переделки" end
				local tool=awaitTool("Delete") local hrp=getValidHRP()
				if not tool or not hrp or cancelled() then return false,"Для переделки нужны Delete и персонаж" end
				data.repairDeleteRequested=true StudioHooks.recovery.capture(session)
				local sent,message=pcall(function() tool.event:FireServer(brick,hrp.Position) end)
				if not sent then data.repairDeleteRequested=nil return false,tostring(message) end
				session.actual.deletes+=1
			end
			if not waitUntil(function() return not brick.Parent end,responseTimeout(5)) then return false,"Ожидаю удаление проблемного блока; повтор удаления не отправлен" end
		end
		for n=#(data.work and data.work.helpers or {}),1,-1 do
			ok,err=deleteHelper(data.work.helpers[n],session) if not ok then return false,err end
		end
		-- Old resize/paint replies reference the deleted Instance only.
		if brick then session.ids[brick]=nil end
		session.instances[session.models[index].id]=nil
		data.placedBrick=nil data.brick=nil data.work=nil data.pendingResize=nil data.pendingCollision=nil
		data.repairRequested=nil data.repairDeleteRequested=nil data.createBlocked=nil
		StudioHooks.recovery.completed(data) StudioHooks.recovery.capture(session)
		return true
	end
	function C.execute(data,index,session)
		session.activeIndex=index data.repairInterrupt=nil data.replans=0
		local function attempt()
			if StudioHooks.guard then
				local ok,message=StudioHooks.guard.clearBox(session,session.models[index],data.placedBrick)
				if not ok then return false,message end
				if data.placedBrick and StudioHooks.guard.formChanged(data.placedBrick,data) then data.repairRequested=true end
			end
			if data.repairRequested then local ok,err=rebuild(data,index,session) if not ok then return false,err end end
			return executeBlock(data,index,session)
		end
		local ran,ok,err=pcall(attempt)
		if not ran then err=tostring(ok) ok=false end
		if data.repairInterrupt and not data.skipped and not unloaded and not _G.stopautobuild then
			data.repairInterrupt=nil
			ran,ok,err=pcall(attempt) if not ran then err=tostring(ok) ok=false end
		end
		session.activeIndex=nil data.repairInterrupt=nil
		if data.skipped then ok=false err="Пропущено пользователем" end
		if not ok then data.failure=tostring(err or "Неизвестная ошибка") session.lastFailedIndex=index
		else data.failure=nil if session.lastFailedIndex==index then session.lastFailedIndex=nil end end
		if not ok then StudioHooks.recovery.capture(session,nil,index) end
		markPlanProgress(session,index)
		return ok,err
	end
	return C
end)()

StudioHooks.guard=(function()
	local G={enabled=true,clear=true,queue={},obstacles={},bindings={},cursor=1,nextRun=0}
	if readfile and isfile then pcall(function()
		if isfile("AutobuildGuard.json") then local v=HttpService:JSONDecode(readfile("AutobuildGuard.json")) if type(v)=="table" then G.enabled=v.enabled~=false G.clear=v.clear~=false end end
	end) end
	function G.set(key,value)
		if key~="enabled" and key~="clear" then return end
		G[key]=value==true
		if writefile then pcall(function() writefile("AutobuildGuard.json",HttpService:JSONEncode({enabled=G.enabled,clear=G.clear})) end) end
		setStatus(key=="enabled" and (G.enabled and "Защита постройки включена" or "Защита постройки выключена") or (G.clear and "Расчистка пересекающих блоков включена" or "Расчистка выключена"))
	end
	function G.formChanged(brick,data)
		if StudioHooks.extras and StudioHooks.extras.owns(brick) then return false end
		if not brick or not brick.Parent then return false end
		if brick.Name~="Brick" or not brick.Anchored then return true end
		for _,axis in ipairs({"X","Y","Z"}) do
			local n=brick.Size[axis] local edge=brick.Position[axis]-n/2
			if n<1 or math.abs(n-math.round(n))>.001 or math.abs(edge-math.round(edge))>.001 then return true end
		end
		local cf=brick.CFrame
		if cf and cf.RightVector and ((cf.RightVector-Vector3.new(1,0,0)).Magnitude>.001 or (cf.UpVector-Vector3.new(0,1,0)).Magnitude>.001) then return true end
		if brick:IsA("Part") and brick.Shape~=Enum.PartType.Block then return true end
		local transparency=data.material==Enum.Material.Glass and .5 or 0
		if math.abs(brick.Transparency-transparency)>.001 then return true end
		local wanted={} for _,sp in ipairs(data.sprays) do wanted[sp.face]=true end
		local seen={}
		for _,sp in ipairs(readSprays(brick)) do if not wanted[sp.face] or seen[sp.face] then return true end seen[sp.face]=true end
		return false
	end
	function G.protected(session,brick)
		if StudioHooks.extras and StudioHooks.extras.owns(brick) then return true end
		if session.helpers[brick] or StudioHooks.documents and StudioHooks.documents.pendingPart(session,brick) then return true end
		local id=session.ids[brick] local index=type(id)=="string" and tonumber(id:match("^t:(%d+)$"))
		local data=index and session.blocks[index]
		return data and (data.placedBrick==brick or data.brick==brick) or false
	end
	function G.worldBox(brick)
		local cf,size=brick.CFrame,brick.Size
		local worldSize=size
		if cf and cf.RightVector then
			worldSize=Vector3.new(math.abs(cf.RightVector.X)*size.X+math.abs(cf.UpVector.X)*size.Y+math.abs(cf.LookVector.X)*size.Z,math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z,math.abs(cf.RightVector.Z)*size.X+math.abs(cf.UpVector.Z)*size.Y+math.abs(cf.LookVector.Z)*size.Z)
		end
		return {pos=brick.Position,size=worldSize,instance=brick,color=brick.Color,material=brick.Material,collide=brick.CanCollide,sprays={},eligible=false}
	end
	function G.intersects(brick,box)
		-- Separating axes for a rotated block versus an axis-aligned target box.
		local cf=brick.CFrame local s=brick.Size/2 local h=box.size/2 local delta=brick.Position-box.pos
		local u=cf and cf.RightVector and {cf.RightVector,cf.UpVector,cf.LookVector} or {Vector3.new(1,0,0),Vector3.new(0,1,0),Vector3.new(0,0,1)}
		local axes={Vector3.new(1,0,0),Vector3.new(0,1,0),Vector3.new(0,0,1),u[1],u[2],u[3]}
		for i=1,3 do for j=1,3 do local a,b=axes[i],u[j] axes[#axes+1]=Vector3.new(a.Y*b.Z-a.Z*b.Y,a.Z*b.X-a.X*b.Z,a.X*b.Y-a.Y*b.X) end end
		local function dot(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
		for _,a in ipairs(axes) do
			local norm=a.Magnitude
			if norm>.00001 then
				local radius=h.X*math.abs(a.X)+h.Y*math.abs(a.Y)+h.Z*math.abs(a.Z)+s.X*math.abs(dot(a,u[1]))+s.Y*math.abs(dot(a,u[2]))+s.Z*math.abs(dot(a,u[3]))
				if math.abs(dot(delta,a))>=radius-.005*norm then return false end
			end
		end
		return true
	end
	function G.extendScene(session,scene)
		local root=workspace:FindFirstChild("Bricks") if not root then return scene end
		for _,brick in ipairs(StudioHooks.liveWorld.query(root,scene.liveFocus)) do
			if brick:IsA("BasePart") and brick.Name~="Brick" and brick.Parent and StudioHooks.liveWorld.near(brick,scene.liveFocus) then
				local m=G.worldBox(brick)
				if not session.ids[brick] then session.nextWorld+=1 session.ids[brick]="w:"..session.nextWorld end
				m.id=session.ids[brick] scene[#scene+1]=m
			end
		end
		return scene
	end
	function G.preserve(session) return session and type(session.buildId)=="string" and session.buildId:sub(1,10)=="stairwell_" end
	function G.planScene(session,scene)
		if G.preserve(session) then return G.extendScene(session,scene) end
		if not G.clear then return scene end
		scene=G.extendScene(session,scene)
		local index=Planner.spatial(session.models) local result={}
		local reserved={} for _,m in ipairs(scene) do if m.reservedTarget then reserved[#reserved+1]=m end end
		for _,m in ipairs(scene) do
			local remove=false
			if m.instance and not G.protected(session,m.instance) then
				for _,target in ipairs(index:query(m)) do if G.intersects(m.instance,target) then remove=true break end end
				for _,pending in ipairs(reserved) do if Planner.intersects(m,pending) then remove=false break end end
			end
			if not remove then result[#result+1]=m end
		end
		return result
	end
	function G.pack(session)
		local records={}
		for brick,state in pairs(session.obstacleDeletes or {}) do
			if brick.Parent and state.requested and brick.GetFullName then records[#records+1]={path=brick:GetFullName(),pos=planVector(brick.Position),size=planVector(brick.Size)} end
		end
		for _,record in ipairs(session.obstacleUnresolved or {}) do records[#records+1]=record end
		return records
	end
	function G.restore(session,records)
		if type(records)~="table" then return end
		local root=workspace:FindFirstChild("Bricks") if not root then return end
		session.obstacleDeletes=session.obstacleDeletes or {} session.obstacleUnresolved={}
		for _,record in ipairs(records) do
			local pos=type(record)=="table" and readPlanVector(record.pos) local size=type(record)=="table" and readPlanVector(record.size)
			if not pos or not size or type(record.path)~="string" then continue end
			local found,ambiguous
			for _,brick in ipairs(root:GetDescendants()) do
				if brick:IsA("BasePart") and brick.GetFullName and brick:GetFullName()==record.path and (brick.Position-pos).Magnitude<.03 and (brick.Size-size).Magnitude<.03 then if found then ambiguous=true break end found=brick end
			end
			if found and not ambiguous then session.obstacleDeletes[found]={requested=true}
			else session.obstacleUnresolved[#session.obstacleUnresolved+1]=record end
		end
	end
	function G.clearBox(session,box,exclude,scene)
		if G.preserve(session) then
			local root=workspace:FindFirstChild("Bricks")
			if root then for _,brick in ipairs(StudioHooks.liveWorld.query(root,box)) do
				if brick.Parent and brick~=exclude and not G.protected(session,brick) and G.intersects(brick,box) then return false,"Существующая постройка перекрыла Stairwell · удаление отключено" end
			end end
			return true,false
		end
		if not G.clear then return true,false end
		local changed=false local root=workspace:FindFirstChild("Bricks")
		if not root then return true,false end
		session.obstacleDeletes=session.obstacleDeletes or {}
		for brick in pairs(session.obstacleDeletes) do if not brick.Parent then session.obstacleDeletes[brick]=nil end end
		scene=G.extendScene(session,scene or snapshotWorld(session,true,box))
		local reserved={} for _,m in ipairs(scene) do if m.reservedTarget then reserved[#reserved+1]=m end end
		for _,m in ipairs(scene) do
			local brick=m.instance
			if not brick or brick==exclude or not brick.Parent or G.protected(session,brick) or not Planner.intersects(box,m) or not G.intersects(brick,box) then continue end
			local pendingMatch=false for _,pending in ipairs(reserved) do if Planner.intersects(m,pending) then pendingMatch=true break end end
			if pendingMatch then continue end -- It may be the late reply to our own Build command.
			-- Any owner's building block, but only a live positive-volume intersection.
			if not brick:IsDescendantOf(root) then return false,"Препятствие вышло из папки строительных блоков" end
			for _,old in ipairs(session.obstacleUnresolved or {}) do
				local p,s=readPlanVector(old.pos),readPlanVector(old.size)
				if p and s and (brick.Position-p).Magnitude<.03 and (brick.Size-s).Magnitude<.03 then return false,"Неоднозначный прежний запрос удаления препятствия; повтор не отправлен" end
			end
			local state=session.obstacleDeletes[brick] or {} session.obstacleDeletes[brick]=state
			if not state.requested then
				if not ensureNear(brick.Position) then return false,"Не удалось подойти к мешающему блоку" end
				local tool=awaitTool("Delete") local hrp=getValidHRP()
				if not tool or not hrp or cancelled() then return false,"Для расчистки нужен Delete и персонаж" end
				-- Recheck after movement, since another player may have moved it.
				if not brick.Parent or not brick:IsDescendantOf(root) or G.protected(session,brick) or not G.intersects(brick,box) then continue end
				state.requested=true StudioHooks.recovery.capture(session)
				local sent,err=pcall(function() tool.event:FireServer(brick,hrp.Position) end)
				if not sent then state.requested=nil return false,tostring(err) end
				session.actual.deletes+=1 setStatus("Удаляю мешающий блок: "..tostring(brick.Position))
			end
			if not waitUntil(function() return not brick.Parent end,responseTimeout(5)) then return false,"Сервер не подтвердил удаление мешающего блока; повтор не отправлен" end
			session.obstacleDeletes[brick]=nil session.ids[brick]=nil changed=true
			StudioHooks.recovery.capture(session)
		end
		return true,changed
	end
	function G.close()
		for _,entry in pairs(G.bindings) do for _,c in ipairs(entry.connections) do c:Disconnect() end end
		G.bindings={} G.queue={} G.obstacles={} G.session=nil G.worldScan=nil G.targetIndex=nil G.clearRetryAt=0
	end
	function G.dirty(session,index)
		local data=session.blocks[index]
		if StudioHooks.extras and StudioHooks.extras.owns(data.placedBrick) then return end
		if not G.enabled or G.session~=session or session~=resumeSession or session.buildId~=PlanLibrary.id() or not session.done[index] or data.skipped then return end
		local brick=data.placedBrick
		if matchesAll(brick,data) and not G.formChanged(brick,data) then return end
		session.done[index]=nil data.failure="Изменена подтверждённая деталь; восстанавливаю сохранённое состояние"
		data.guardDamage=true
		if brick and brick.Parent and G.formChanged(brick,data) then data.repairRequested=true end
		G.queue[index]=true _G.autobuildPlaced=math.max(0,(_G.autobuildPlaced or 0)-1)
		markPlanProgress(session,index) StudioHooks.recovery.capture(session)
	end
	function G.bind(session,index)
		StudioHooks.runtimeState.touch(session,index)
		if G.session~=session then G.close() G.session=session end
		local data=session.blocks[index] local brick=data.placedBrick local old=G.bindings[index]
		if old and old.brick==brick then return end
		if old then for _,c in ipairs(old.connections) do c:Disconnect() end end
		local entry={brick=brick,connections={}} G.bindings[index]=entry
		if not brick then return end
		local function dirty() local ok=pcall(G.dirty,session,index) if not ok then G.queue[index]=true end end
		for _,signal in ipairs({brick.Changed,brick.AncestryChanged,brick.DescendantAdded,brick.DescendantRemoving}) do
			if signal then entry.connections[#entry.connections+1]=signal:Connect(dirty) end
		end
	end
	function G.watch(session)
		if G.session~=session then G.close() G.session=session G.cursor=1 end
		G.targetIndex=G.targetIndex or Planner.spatial(session.models)
		for i in pairs(session.done) do G.bind(session,i) end
		for i,data in ipairs(session.blocks) do if data.guardDamage and not data.skipped and not session.done[i] then G.queue[i]=true end end
	end
	function G.scan(limit)
		local deadline=os.clock()+.0015
		local session=G.session if not session or not G.enabled then return end
		for _=1,math.min(limit or 96,#session.blocks) do
			if os.clock()>=deadline then break end
			local i=G.cursor G.cursor=i%#session.blocks+1
			if session.done[i] then G.dirty(session,i) end
		end
	end
	function G.drain(session,limit)
		if G.session~=session then return end
		local count=0
		if G.clear and (G.clearRetryAt or 0)<=os.clock() then
			for i in pairs(G.obstacles) do
				if cancelled() then return end
				local data=session.blocks[i]
				if data.skipped then G.obstacles[i]=nil continue end
				local ok,err=G.clearBox(session,session.models[i],data.placedBrick)
				if ok then G.obstacles[i]=nil else G.clearRetryAt=os.clock()+10 setStatus("Расчистка отложена: "..tostring(err),true) end
				count+=1 if count>=(limit or 1) then return end
			end
		end
		if not G.enabled then return end
		for i in pairs(G.queue) do
			if cancelled() then return end
			local data=session.blocks[i]
			if data.skipped or session.done[i] then G.queue[i]=nil continue end
			if (data.guardRetryAt or 0)>os.clock() then continue end
			count+=1 local ok,err=StudioHooks.control.execute(data,i,session)
			if ok then
				session.done[i]=true _G.autobuildPlaced+=1 data.guardDamage=nil data.guardFailures=nil data.guardRetryAt=nil G.queue[i]=nil
				StudioHooks.recovery.completed(data) G.bind(session,i) StudioHooks.recovery.capture(session) markPlanProgress(session,i)
				setStatus("Защита восстановила блок №"..i)
			else
				if data.placedBrick and data.placedBrick.Parent and not data.creation and not data.pendingResize and not data.pendingCollision then data.repairRequested=true end
				data.guardFailures=(data.guardFailures or 0)+1 data.guardRetryAt=os.clock()+math.min(60,5*2^math.min(data.guardFailures,4))
				StudioHooks.recovery.capture(session)
				setStatus("Защита отложила блок №"..i..": "..tostring(err),true)
			end
			if count>=(limit or 1) then break end
		end
	end
	function G.scanObstacles(session,limit)
		if not G.clear then return end
		local root=workspace:FindFirstChild("Bricks") if not root then return end
		if not G.worldScan then
			local reserved={}
			local function include(holder)
				if holder.creation and holder.creation.initial then reserved[#reserved+1]=holder.creation.initial end
				for _,old in ipairs(holder.retired or {}) do if old.initial then reserved[#reserved+1]=old.initial end end
			end
			for i in pairs(StudioHooks.runtimeState.ensure(session).active) do local data=session.blocks[i] include(data) for _,h in ipairs(data.work and data.work.helpers or {}) do include(h) end end
			if StudioHooks.documents then for _,m in ipairs(StudioHooks.documents.reservations(session)) do reserved[#reserved+1]=m end end
			G.worldScan={parts=StudioHooks.liveWorld.parts(root),cursor=1,reserved=Planner.spatial(reserved)}
		end
		local scan=G.worldScan local deadline=os.clock()+.0015
		for _=1,limit or 128 do
			if os.clock()>=deadline then break end
			local brick=scan.parts[scan.cursor]
			if not brick then G.worldScan=nil return end
			scan.cursor+=1
			if not brick.Parent or not brick:IsA("BasePart") or G.protected(session,brick) then continue end
			local box=G.worldBox(brick)
			local pendingMatch=false for _,pending in ipairs(scan.reserved:query(box)) do if Planner.intersects(box,pending) then pendingMatch=true break end end
			if pendingMatch then continue end
			for _,target in ipairs(G.targetIndex:query(box)) do
				local i=tonumber(target.id:match("^t:(%d+)$"))
				if i and not session.blocks[i].skipped and G.intersects(brick,target) then G.obstacles[i]=true end
			end
		end
	end
	function G.tick()
		if unloaded or not G.enabled and not G.clear then return end
		local session=G.session if not session or session~=resumeSession then return end
		if session.buildId~=PlanLibrary.id() or session.text~=(_G.fullBuildString or textBox.Text) or session.offset~=snapBuildOffset(_G.buildOffset or Vector3.zero) then return end
		G.scan(96)
		G.scanObstacles(session,128)
		if isBuilding or _G.autobuildRunning or _G.stopautobuild or busySaving or os.clock()<G.nextRun then return end
		for i in pairs(G.queue) do
			local d=session.blocks[i]
			if G.enabled and not d.skipped and (d.guardRetryAt or 0)<=os.clock() then
				if not getPlayerBricksFolder() or not LocalPlayer.Character or not findTool("Build") then return end
				G.nextRun=os.clock()+2
				G.autoClearOnly=not G.enabled G.autoCall=true
				if StudioHooks.resumeRecovery then StudioHooks.resumeRecovery() end
				G.autoClearOnly=nil G.autoCall=nil
				return
			end
		end
		if G.clear and next(G.obstacles) and (G.clearRetryAt or 0)<=os.clock() then
			if not findTool("Delete") then return end
			G.nextRun=os.clock()+2 G.autoClearOnly=not G.enabled G.autoCall=true
			if StudioHooks.resumeRecovery then StudioHooks.resumeRecovery() end
			G.autoClearOnly=nil G.autoCall=nil
		end
	end
	local elapsed=0
	trackConn(RunService.Heartbeat:Connect(function(dt)
		elapsed+=dt or 0 if elapsed<.25 then return end elapsed=0
		local ok,err=pcall(G.tick) if not ok then G.nextRun=os.clock()+5 setStatus("Проверка защиты: "..tostring(err),true) end
	end))
	if resumeSession then G.watch(resumeSession) end
	return G
end)()

local function runBuilderEngine(buildString,offset,prepareOnly)
	if not resumeSession or resumeSession.buildId~=PlanLibrary.id() or resumeSession.text~=buildString or resumeSession.offset~=offset then
		if StudioHooks.documents then StudioHooks.documents.stash(resumeSession) resumeSession=nil
		else
		if resumeSession then
			for helper in pairs(resumeSession.helpers or {}) do if helper.Parent then return false,"Остались временные блоки предыдущей стройки. Продолжите её для удаления." end end
			for _,old in ipairs(resumeSession.blocks) do
				if old.pendingResize or old.pendingCollision or old.creation then return false,"Есть неподтверждённый запрос предыдущей стройки. Продолжите её перед сменой данных." end
				for _,holder in ipairs(old.work and old.work.helpers or {}) do if holder.creation then return false,"Есть неподтверждённый временный блок. Продолжите предыдущую стройку." end end
			end
			for _,old in ipairs(resumeSession.blocks) do if old.creation then old.creation.connection:Disconnect() end end
		end
		end
		local blocks,invalid=parseBlocks(buildString,offset)
		if invalid>0 or #blocks==0 then return false,"Некорректные данные постройки" end
		resumeSession={buildId=PlanLibrary.id(),text=buildString,offset=offset,blocks=blocks,done={},models={},ids={},instances={},nextWorld=0,helpers={},actual={creates=0,shapes=0,deletes=0}}
		for i,data in ipairs(blocks) do resumeSession.models[i]=targetModel(data,i) end
		local root=workspace:FindFirstChild("Bricks")
		if root then StudioHooks.liveWorld.parts(root,function() task.wait() return not cancelled() end) end
		if cancelled() then return false,"Подготовка индекса остановлена" end
		StudioHooks.recovery.restore(resumeSession)
	end
	if resumeSession.recoveryBlocked then return false,resumeSession.recoveryBlocked end
	local session=resumeSession
	if StudioHooks.stairwell and StudioHooks.guard.preserve(session) then StudioHooks.stairwell.bind(session) if not prepareOnly then StudioHooks.stairwell.beginBuild(session) end end
	if StudioHooks.documents then StudioHooks.documents.stash(session) end
	session.activeIndex=nil
	if session.plan and session.plan.plannerVersion~=Planner.version then session.plan=nil session.planByIndex=nil session.previewInvalid=true end
	session.actionRevision=(session.actionRevision or 0)+1
	reconcileBuild(session)
	StudioHooks.runtimeState.rebuild(session)
	_G.autobuildTotal=#session.blocks _G.autobuildPlaced=0
	for i,data in ipairs(session.blocks) do
		if session.done[i] and not matchesAll(data.placedBrick,data) then session.done[i]=nil end
		if session.done[i] then _G.autobuildPlaced=_G.autobuildPlaced+1 end
	end
	if StudioHooks.guard and not prepareOnly then StudioHooks.guard.watch(session) end
	if not session.plan then
		local scene=snapshotWorld(session)
		if StudioHooks.guard then scene=StudioHooks.guard.planScene(session,scene) end
		local char=LocalPlayer.Character local root=char and char:FindFirstChild("HumanoidRootPart")
		local started=os.clock()
		btnStart.Text="ГОТОВЛЮ ПЛАН"
		local partials,activeSources=StudioHooks.recovery.preparation(session)
		local cached=loadPreparedPlan(session,scene,findTool("Delete")~=nil)
		if cached then cached.plannerVersion=Planner.version end
		session.plan=cached or PlanLibrary.prepare(session.models,scene,{partials=partials,activeSources=activeSources,timing=StudioHooks.timing.profile(),bridges=findTool("Delete")~=nil,position=root and root.Position or session.models[1].pos,cancelled=cancelled,yield=function() task.wait() end,visual=function(phase,payload,count) PlanDrawing.progress(session,phase,payload,count) end,progress=function(text,fraction)
			setStatus(string.format("Подготовка %d%% · %s",math.round(fraction*100),text))
			statDisplay.Text="Подготовка · "..#session.blocks.." блоков"
			task.wait()
		end})
		local plan=session.plan
		if not cached then savePreparedPlan(session,scene,findTool("Delete")~=nil) end
		session.planByIndex={}
		for _,item in ipairs(plan.items) do session.planByIndex[item.index]=item end
		setStatus(string.format("План: %s · операций ~%d · грани %d · временных %d · подготовка %.1fс",plan.name,plan.operations,plan.shapeSteps,plan.helpers,os.clock()-started))
		if plan.estimatedSeconds then setStatus(string.format("Прогноз ~%.1fс · перемещений %d · переходов вниз %d · %s",plan.estimatedSeconds,plan.teleports or 0,plan.descending or 0,StudioHooks.timing.summary())) end
		for _,alternative in ipairs(plan.alternatives) do
			setStatus(string.format("Вариант %s: операций ~%d, грани %d, временных %d",alternative.name,alternative.operations,alternative.shapeSteps,alternative.helpers))
		end
		btnStart.Text="ПАУЗА"
	end
	if cancelled() then return false,"Подготовка остановлена" end
	if prepareOnly then
		drawPreparedPlan(session)
		return true,string.format("План готов: %s · действий ~%d · граней %d. Нажмите СТРОИТЬ ПО ПЛАНУ. Синий маршрут, зелёные копии, фиолетовые детали, оранжевые мосты.",session.plan.name,session.plan.operations,session.plan.shapeSteps)
	end
	refreshPlanProgress(session)
	drawPreparedPlan(session)
	if not session.transient and handles then handles:Destroy() handles=nil end
	task.wait()
	enableNoclip() startToolForcing()
	if StudioHooks.guard then StudioHooks.guard.drain(session,4) end
	local deferred={}
	session.queueCreations=true
	local function finish(i,data)
		session.done[i]=true _G.autobuildPlaced+=1 data.failure=nil data.guardDamage=nil data.guardFailures=nil data.guardRetryAt=nil
		if StudioHooks.guard then StudioHooks.guard.queue[i]=nil StudioHooks.guard.bind(session,i) end
		StudioHooks.recovery.completed(data) StudioHooks.recovery.capture(session,false,i) markPlanProgress(session,i)
		if not session.transient and visualFolder then local visual=visualFolder:FindFirstChild("Visual_"..i) if visual then visual:Destroy() end end
	end
	for rank,item in ipairs(session.plan.items) do
		advancePlanPreview(session,rank)
		local i=item.index local data=session.blocks[i]
		if StudioHooks.guard then StudioHooks.guard.drain(session,1) end
		if cancelled() then return false,"Пауза. План и незавершённые запросы сохранены." end
		if not session.done[i] and not data.skipped and not (session.guardClearOnly and data.guardDamage) and (not data.guardDamage or (data.guardRetryAt or 0)<=os.clock()) then
			local ok,err=StudioHooks.control.execute(data,i,session)
			if cancelled() then return false,"Пауза. Незавершённый блок сохранён." end
			if ok then finish(i,data)
			elseif not data.skipped then deferred[#deferred+1]=i setStatus("Откладываю блок №"..i..": "..tostring(err),true) end
		end
		if rank%8==0 then task.wait() end
	end
	-- Each request owns its retry budget. Poll recent requests together.
	local visited={} local parked={}
	while true do
		local wake
		for _,i in ipairs(deferred) do
			if cancelled() then return false,"Пауза; незавершённые блоки сохранены" end
			local data=session.blocks[i]
			if not parked[i] and not data.skipped and not session.done[i] then
				local due=StudioHooks.recovery.nextWake(data,session)
				local arrived=StudioHooks.recovery.arrived(data,session)
				if not visited[i] or arrived or due and due<=os.clock() then
					visited[i]=true
					local beforeCreates=session.actual.creates
					local beforeCreation=data.creation
					local beforeHelpers=0 for _,h in ipairs(data.work and data.work.helpers or {}) do if h.creation then beforeHelpers+=1 end end
					local ok,err=StudioHooks.control.execute(data,i,session)
					if cancelled() then return false,"Пауза; незавершённые блоки сохранены" end
					if ok then finish(i,data) elseif not data.skipped then setStatus("Блок №"..i..": "..tostring(err),true) end
					local afterHelpers=0 for _,h in ipairs(data.work and data.work.helpers or {}) do if h.creation then afterHelpers+=1 end end
					if not ok and beforeCreates==session.actual.creates and beforeCreation==data.creation and beforeHelpers==afterHelpers and (arrived or due and due<=os.clock() or data.repairRequested) then
						parked[i]=true -- Geometry/repair cannot progress; keep its requests, never spin on this target.
					end
				end
				if not parked[i] and not data.skipped and not session.done[i] then
					due=StudioHooks.recovery.nextWake(data,session)
					if due then wake=math.min(wake or math.huge,due) end
				end
			end
		end
		if not wake then break end
		setStatus("Доступные блоки пройдены. Сверяю очередь целевых запросов.")
		if not waitUntil(function()
			if os.clock()>=wake then return true end
			local waiting=false
			for _,i in ipairs(deferred) do
				local d=session.blocks[i]
				if not parked[i] and not d.skipped and not session.done[i] then
					waiting=true if StudioHooks.recovery.arrived(d,session) then return true end
				end
			end
			return not waiting
		end,math.max(.1,wake-os.clock()+.1)) then return false,"Пауза; очередь сохранена" end
	end
	session.queueCreations=nil
	if StudioHooks.guard then StudioHooks.guard.scan(#session.blocks) StudioHooks.guard.drain(session,4) end

	StudioHooks.recovery.capture(session,"flush")
	local skipped=0
	for _,data in ipairs(session.blocks) do if data.skipped then skipped+=1 end end
	if _G.autobuildPlaced<#session.blocks then
		return false,string.format("Обход завершён: готово %d/%d · пропущено %d · ожидают восстановления %d. Продолжить / переделать проблемный блок.",_G.autobuildPlaced,#session.blocks,skipped,#session.blocks-_G.autobuildPlaced-skipped)
	end
	if StudioHooks.stairwell and StudioHooks.guard.preserve(session) then local ok,err=StudioHooks.stairwell.activatePits(session) if not ok then return false,err end end
	return true,string.format("Готово: %d блоков · созданий %d · изменений граней %d · удалений временных %d",#session.blocks,session.actual.creates,session.actual.shapes,session.actual.deletes)
end
local function launchAction(forcePreparation)
	if StudioHooks.stairwell and StudioHooks.stairwell.busy then setStatus("Дождись расчёта Stairwell",true) return end
	if StudioHooks.extras and (StudioHooks.extras.running or StudioHooks.extras.busy) then setStatus("Сначала останови двойника",true) return end
	if busySaving then setStatus("Дождитесь сохранения") return end
	if isBuilding then _G.stopautobuild=true btnStart.Text="ОСТАНОВКА…" setStatus("Останавливаю; отправленный запрос может завершиться") return end
	if resumeSession then resumeSession.guardClearOnly=StudioHooks.guard and StudioHooks.guard.autoClearOnly==true or false end
	local automatic=StudioHooks.guard and StudioHooks.guard.autoCall==true
	local text=_G.fullBuildString or textBox.Text
	local blocks,invalid=parseBlocks(text,Vector3.zero)
	if #blocks==0 or invalid>0 then setStatus("Некорректная постройка",true) return end
	local offset=snapBuildOffset(_G.buildOffset or Vector3.zero)
	local prepared=resumeSession and resumeSession.text==text and resumeSession.offset==offset and resumeSession.plan~=nil and not resumeSession.previewInvalid
	local prepareOnly=forcePreparation=="stairwellPreview"
	if forcePreparation and prepared then resumeSession.plan=nil end
	_G.buildOffset=offset _G.stopautobuild=false _G.autobuildRunning=true
	_G.autobuildTotal=#blocks _G.autobuildPlaced=0
	if StudioHooks.guard then StudioHooks.guard.autoExecuting=automatic end
	isBuilding=true textBox.TextEditable=false btnStart.Text="ГОТОВЛЮ ПЛАН" btnStart.TextColor3=C_RED
	if handles then handles:Destroy() handles=nil end
	task.spawn(function()
		local ok,finished,message=pcall(runBuilderEngine,text,offset,prepareOnly)
		if resumeSession and not unloaded then resumeSession.activeIndex=nil pcall(StudioHooks.recovery.capture,resumeSession,"flush") end
		pcall(unlockPosition) if StudioHooks.stairwell then StudioHooks.stairwell.returnCharacter() end pcall(stopToolForcing) pcall(disableNoclip) isBuilding=false
		if StudioHooks.guard then StudioHooks.guard.autoExecuting=false end
		if unloaded then return end
		_G.autobuildRunning=false textBox.TextEditable=true btnStart.TextColor3=C_WHITE
		btnStart.Text=ok and finished and (prepareOnly and "СТРОИТЬ ПО ПЛАНУ" or "СТРОИТЬ") or "ПРОДОЛЖИТЬ"
		if ok and finished and not prepareOnly then cleanupVisuals(true) end
		if prepareOnly and StudioHooks.stairwell then StudioHooks.stairwell.onPrepared(resumeSession,ok and finished,ok and message or tostring(finished)) end
		setStatus(ok and message or tostring(finished),not ok or not finished and not _G.stopautobuild)
		statDisplay.Text=prepareOnly and ok and finished and ("План · действий ~"..resumeSession.plan.operations) or string.format("Готово: %d/%d",_G.autobuildPlaced or 0,#blocks)
		if StudioHooks.documents then StudioHooks.documents.flushUI() end
	end)
end
-- Six tagged, confirmed own blocks. No world-wide pickup and no avatar scripts.
StudioHooks.extras=(function()
	local E={busy=false,running=false,message="Выбери форму и создай двойника",distance=14,side="back",preset="r6",models={},byPart={},movers={},localLook={},characterParts={}}
	local names={"Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"}
	local positions={Vector3.new(0,1.5,0),Vector3.zero,Vector3.new(-1.5,0,0),Vector3.new(1.5,0,0),Vector3.new(-.5,-2,0),Vector3.new(.5,-2,0)}
	local dimensions={Vector3.new(1,1,1),Vector3.new(2,2,1),Vector3.new(1,2,1),Vector3.new(1,2,1),Vector3.new(1,2,1),Vector3.new(1,2,1)}
	E.presets={r6={name="Двойник R6",scale=1,count=6},voxels={name="Кубический двойник",scale=1,count=13},voxels2={name="Кубический двойник ×2",scale=2,count=104},golem={name="Каменный голем",scale=2,count=104}}
	local function definitions(preset,body)
		local result={} local profile=E.presets[preset]
		for role,name in ipairs(names) do
			if preset=="r6" then
				local size=dimensions[role]
				if body and role~=1 then local s=body[role].Size size=Vector3.new(math.clamp(math.round(s.X),1,4),math.clamp(math.round(s.Y),1,4),math.clamp(math.round(s.Z),1,4)) end
				result[#result+1]={name=name,role=role,offset=Vector3.zero,size=size}
			else
				local size=dimensions[role]*profile.scale local count=0
				for x=1,size.X do for y=1,size.Y do for z=1,size.Z do
					count+=1 result[#result+1]={name=name.." "..count,role=role,offset=Vector3.new(x-.5-size.X/2,y-.5-size.Y/2,z-.5-size.Z/2),size=Vector3.new(1,1,1)}
				end end end
			end
		end
		return result
	end
	local function limbColor(preset,part)
		return preset=="golem" and Color3.new(137/255,145/255,156/255) or part.Color
	end
	-- Proximity is automatic on the server. This layer prevents avoidable loss;
	-- it never claims that a client can pin a server's network owner.
	E.network=(function()
		local N={guard=true,players={},lastPlayers=-math.huge,lost=0,known=0,owned=0,lossEvents=0,recovered=0,states={}}
		function N.begin() N.lost=0 N.known=0 N.owned=0 N.lossEvents=0 N.recovered=0 N.states={} end
		function N.observe(part)
			local ok,owned=false,nil
			if type(isnetworkowner)=="function" then ok,owned=pcall(isnetworkowner,part) end
			if not ok or type(owned)~="boolean" then return nil end
			N.known+=1 if owned then N.owned+=1 else N.lost+=1 end
			local previous=N.states[part]
			if previous==true and not owned then N.lossEvents+=1 elseif previous==false and owned then N.recovered+=1 end
			N.states[part]=owned return owned
		end
		function N.distance(body)
			local requested=E.distance local safe=requested N.nearest=nil
			if not N.guard then E.effectiveDistance=requested return requested end
			local now=os.clock()
			if now-N.lastPlayers>=1 then
				N.lastPlayers=now local ok,list=pcall(function() return Players:GetPlayers() end)
				if ok and type(list)=="table" then N.players=list else N.players={} end
			end
			local radius=4*E.presets[E.preset].scale
			for _,player in ipairs(N.players) do if player~=LocalPlayer then
				local char=player.Character local root=char and char:FindFirstChild("HumanoidRootPart")
				if root and root.Parent then
					local distance=(root.Position-body.root.Position).Magnitude
					N.nearest=N.nearest and math.min(N.nearest,distance) or distance
					local velocity=root.AssemblyLinearVelocity local speed=velocity and velocity.Magnitude or 16
					local margin=3+math.clamp((getSafePing()*2+.25)*math.max(16,speed),2,12)
					safe=math.min(safe,math.max(0,distance*.5-radius-margin))
				end
			end end
			if N.lost>0 then safe=0 end
			E.effectiveDistance=safe return safe
		end
		function N.summary()
			local actual=E.effectiveDistance or E.distance
			local text=string.format("%d/%d · отступ %.1f / %.1f",E.activeCount or 0,E.data and #E.data.records or 0,actual,E.distance)
			if N.known>0 then text..=string.format(" · контроль %d/%d",N.owned,N.known) end
			if N.lost>0 then text..=" · потерян: нажми «Вернуть контроль»" end
			return text
		end
		return N
	end)()
	function E.setNetworkGuard(value)
		E.network.guard=value==true E.effectiveDistance=E.distance E.save()
		return true
	end

	local stateFile="OrbitCompanion.json"
	local function say(message,failure)
		E.message=message
		if StudioHooks.extraStatus then StudioHooks.extraStatus(message) end
		setStatus(message,failure)
	end
	local function own(part)
		local folder=getPlayerBricksFolder()
		return part and part.Parent and folder and part:IsDescendantOf(folder) and part:IsA("BasePart") and part.Name=="Brick"
	end
	local function avatar()
		local char=LocalPlayer.Character local hum=char and char:FindFirstChildOfClass("Humanoid") local root=char and char:FindFirstChild("HumanoidRootPart")
		if not hum or not root or hum.Health<=0 or hum.RigType~=Enum.HumanoidRigType.R6 then return nil,"Нужен живой персонаж R6" end
		local body={root=root,char=char}
		for i,name in ipairs(names) do local part=char:FindFirstChild(name) if not part or not part:IsA("BasePart") then return nil,"Не найдена конечность "..name end body[i]=part end
		return body
	end
	local function token()
		local ok,id=pcall(function() return HttpService:GenerateGUID(false) end)
		return ok and id or tostring(os.time()).."_"..tostring(math.random(1,100000000))
	end
	local function model(row)
		return {centerPos=row.pos,size=row.size,color=row.color,material=row.material or Enum.Material.SmoothPlastic,canCollide=false,sprays={}}
	end
	local function code(rows)
		local blocks={} for _,row in ipairs(rows) do blocks[#blocks+1]=serializeBlock(model(row)) end return table.concat(blocks)
	end
	local function registered(record,data)
		return data and own(record.part) and record.part:GetAttribute("OrbitCompanionId")==data.token and record.part:GetAttribute("OrbitCompanionBody")==record.name
	end
	local function validRecord(record)
		return registered(record,E.data)
	end
	function E.owns(part)
		if not part then return false end
		local found=E.byPart[part]
		return found~=nil and found.record.part==part and registered(found.record,found.data)==true
	end
	function E.save()
		if not writefile then return false,"Нет записи файлов" end
		local payload={version=2,distance=E.distance,side=E.side,preset=E.preset,networkGuard=E.network.guard,job=game.JobId,models={}}
		for preset,data in pairs(E.models) do
			local saved={token=data.token,stageId=data.stageId,code=data.code,records={}}
			for i,record in ipairs(data.records) do saved.records[i]={name=record.name,neutral=serializeBlock(model(data.rows[i])),pending=record.pending,original=record.original} end
			payload.models[preset]=saved
		end
		local ok,err=pcall(function() writefile(stateFile,HttpService:JSONEncode(payload)) end)
		return ok,err
	end
	local function acceptCached(data,preset)
		local profile=E.presets[preset]
		if not profile or type(data)~="table" or data.version~=1 or data.job~=game.JobId or type(data.rows)~="table" or type(data.records)~="table" or #data.rows~=profile.count or #data.records~=profile.count then return end
		local specs=definitions(preset)
		for i,row in ipairs(data.rows) do row.role=specs[i].role row.offset=specs[i].offset row.material=row.material or (preset=="golem" and Enum.Material.Slate or Enum.Material.SmoothPlastic) end
		data.preset=preset E.models[preset]=data
	end
	local cache=_G.ORBIT_COMPANION_MODELS
	if type(cache)=="table" and cache.job==game.JobId and type(cache.models)=="table" then for preset,data in pairs(cache.models) do acceptCached(data,preset) end if E.presets[cache.preset] then E.preset=cache.preset end end
	local cached=_G.ORBIT_COMPANION_STATE
	if type(cached)=="table" and not E.models[cached.preset or "r6"] then acceptCached(cached,cached.preset or "r6") end
	local function loadModel(saved,preset)
		local profile=E.presets[preset]
		if not profile or type(saved)~="table" or type(saved.token)~="string" or type(saved.stageId)~="string" or type(saved.code)~="string" or type(saved.records)~="table" or #saved.records~=profile.count then return end
		local data={version=1,job=game.JobId,preset=preset,token=saved.token,stageId=saved.stageId,code=saved.code,rows={},records={}}
		local specs=definitions(preset)
		for i,s in ipairs(saved.records) do
			if type(s)~="table" or s.name~=specs[i].name or type(s.neutral)~="string" then return end
			local parsed,bad=parseBlocks(s.neutral,Vector3.zero) if bad>0 or #parsed~=1 then return end
			local b=parsed[1] local material=preset=="golem" and Enum.Material.Slate or Enum.Material.SmoothPlastic
			if b.material~=material or #b.sprays>0 or preset~="r6" and b.size~=Vector3.new(1,1,1) then return end
			data.rows[i]={pos=b.centerPos,size=b.size,color=b.color,material=material,role=specs[i].role,offset=specs[i].offset}
			data.records[i]={name=s.name,pending=type(s.pending)=="table" and s.pending or {},original=type(s.original)=="table" and s.original or nil}
		end
		local stage,bad=parseBlocks(data.code,Vector3.zero) if bad>0 or #stage~=profile.count then return end
		for i,b in ipairs(stage) do local row=data.rows[i] if b.centerPos~=row.pos or b.size~=row.size or not sameColor(b.color,row.color) or b.material~=row.material or #b.sprays>0 then return end end
		local folder=getPlayerBricksFolder()
		if folder then for _,part in ipairs(folder:GetDescendants()) do if part:IsA("BasePart") and part:GetAttribute("OrbitCompanionId")==data.token then
			for _,r in ipairs(data.records) do if r.name==part:GetAttribute("OrbitCompanionBody") then if r.part then return end r.part=part end end
		end end end
		E.models[preset]=data
	end
	if readfile and isfile then pcall(function()
		if not isfile(stateFile) then return end
		local saved=HttpService:JSONDecode(readfile(stateFile)) if type(saved)~="table" or saved.version~=1 and saved.version~=2 then return end
		if type(saved.distance)=="number" and saved.distance==saved.distance then E.distance=math.clamp(saved.distance,0,64) end
		if ({back=true,front=true,left=true,right=true})[saved.side] then E.side=saved.side end
		if type(saved.networkGuard)=="boolean" then E.network.guard=saved.networkGuard end
		if saved.version==2 and E.presets[saved.preset] then E.preset=saved.preset end
		if saved.job~=game.JobId then return end
		if saved.version==1 then if not E.models.r6 then loadModel(saved,"r6") end
		elseif type(saved.models)=="table" then for preset,data in pairs(saved.models) do if not E.models[preset] then loadModel(data,preset) end end end
	end) end
	E.data=E.models[E.preset]
	for _,data in pairs(E.models) do for _,record in ipairs(data.records) do if record.part then E.byPart[record.part]={record=record,data=data} end end end
	_G.ORBIT_COMPANION_MODELS={job=game.JobId,preset=E.preset,models=E.models}
	_G.ORBIT_COMPANION_STATE=E.data
	if E.data then E.message="Форма сохранена · запусти или припаркуй блоки" end
	function E.setPreset(preset)
		local stopping=E.busy and E.stopRequested
		if not E.presets[preset] or E.busy and not stopping or E.running or _G.autobuildRunning and not stopping or unloaded then say("Сначала останови двойника и текущую операцию",true) return false end
		E.preset=preset E.data=E.models[preset] _G.ORBIT_COMPANION_STATE=E.data _G.ORBIT_COMPANION_MODELS.preset=preset E.save()
		say(E.presets[preset].name.." · "..E.presets[preset].count.." деталей") return true
	end
	function E.setDistance(value)
		value=tonumber(value) if not value or value~=value or math.abs(value)==math.huge then return false end
		E.distance=math.clamp(value,0,64) if E.syncAvatar then E.syncAvatar() end E.save() return true
	end
	function E.setSide(value)
		if not ({back=true,front=true,left=true,right=true})[value] then return false end
		E.side=value E.save() return true
	end
	local function interrupted() return unloaded or E.cancel or _G.stopautobuild==true end
	local function waitFor(predicate,seconds)
		local deadline=os.clock()+seconds
		repeat if interrupted() then return false end if predicate() then return true end task.wait() until os.clock()>=deadline
		return not interrupted() and predicate()
	end
	local function release()
		E.running=false E.rootPose=nil E.parked=false E.activeCount=0 E.fixedTargets=nil
		if E.connection then E.connection:Disconnect() E.connection=nil end
		for _,connection in ipairs(E.characterConnections or {}) do connection:Disconnect() end
		for part,look in pairs(E.characterParts) do if part.Parent then pcall(function() part.LocalTransparencyModifier=look.transparency end) end end
		E.characterConnections={} E.characterParts={}
		for part,mover in pairs(E.movers) do
			for _,object in ipairs(mover.objects) do pcall(function() object:Destroy() end) end
			for _,object in pairs(mover.pairs) do pcall(function() object:Destroy() end) end
			if part.Parent then pcall(function() part.CustomPhysicalProperties=mover.physical end) end
		end
		E.movers={}
	end
	local function applyLook(part)
		if not E.localLook[part] then E.localLook[part]={transparency=part.LocalTransparencyModifier,touch=part.CanTouch,query=part.CanQuery} end
		if part.LocalTransparencyModifier~=.2 then part.LocalTransparencyModifier=.2 end
		if part.CanTouch then part.CanTouch=false end
		if part.CanQuery then part.CanQuery=false end
	end
	local function protectPair(part,mover,other)
		if not mover.pairs[other] then mover.pairs[other]=create("NoCollisionConstraint",{Name="OrbitCompanionPassThrough",Parent=part,Part0=part,Part1=other,Enabled=true}) end
	end
	local function watchCharacter(char)
		local function add(part)
			if not part:IsA("BasePart") or E.characterParts[part] then return end
			E.characterParts[part]={transparency=part.LocalTransparencyModifier or 0}
			if E.running and E.distance==0 then part.LocalTransparencyModifier=1 end
			for ownPart,mover in pairs(E.movers) do if E.owns(ownPart) then protectPair(ownPart,mover,part) end end
		end
		for _,part in ipairs(char:GetDescendants()) do add(part) end
		E.characterConnections={char.DescendantAdded:Connect(add),char.DescendantRemoving:Connect(function(part)
			local look=E.characterParts[part] if look then pcall(function() part.LocalTransparencyModifier=look.transparency end) end
			E.characterParts[part]=nil
			for _,mover in pairs(E.movers) do local pair=mover.pairs[part] if pair then pair:Destroy() mover.pairs[part]=nil end end
		end)}
	end
	function E.syncAvatar()
		for part,look in pairs(E.characterParts) do if part.Parent then local wanted=E.running and E.distance==0 and 1 or look.transparency if part.LocalTransparencyModifier~=wanted then part.LocalTransparencyModifier=wanted end end end
	end
	local function createMover(record)
		if E.movers[record.part] then return E.movers[record.part] end
		if not validRecord(record) then error("Блок двойника больше не принадлежит этой модели",0) end
		local part=record.part local mover={objects={},pairs={},physical=part.CustomPhysicalProperties}
		E.movers[part]=mover
		local function object(class,properties) local made=create(class,properties) mover.objects[#mover.objects+1]=made return made end
		local attachment=object("Attachment",{Name="OrbitCompanionAttachment",Parent=part})
		local mass=math.max(.1,part:GetMass())
		mover.position=object("AlignPosition",{Name="OrbitCompanionPosition",Parent=part,Attachment0=attachment,Mode=Enum.PositionAlignmentMode.OneAttachment,Position=part.Position,ApplyAtCenterOfMass=true,ReactionForceEnabled=false,RigidityEnabled=false,Responsiveness=100,MaxVelocity=80,MaxForce=mass*80000})
		mover.orientation=object("AlignOrientation",{Name="OrbitCompanionOrientation",Parent=part,Attachment0=attachment,Mode=Enum.OrientationAlignmentMode.OneAttachment,AlignType=Enum.AlignType.AllAxes,CFrame=part.CFrame.Rotation,ReactionTorqueEnabled=false,RigidityEnabled=false,Responsiveness=100,MaxAngularVelocity=40,MaxTorque=mass*80000})
		applyLook(part) part.CustomPhysicalProperties=PhysicalProperties.new(.1,0,0,0,0)
		for other in pairs(E.characterParts) do protectPair(part,mover,other) end
		return mover
	end
	local function pose(record,goal)
		local mover=createMover(record) applyLook(record.part) mover.position.Position=goal.Position mover.orientation.CFrame=goal.Rotation
	end
	local function forgetMissing(record)
		local part=record.part local mover=part and E.movers[part]
		if mover then
			for _,object in ipairs(mover.objects) do pcall(function() object:Destroy() end) end
			for _,object in pairs(mover.pairs) do pcall(function() object:Destroy() end) end
			if part.Parent then pcall(function() part.CustomPhysicalProperties=mover.physical end) end
			E.movers[part]=nil
		end
		local look=part and E.localLook[part]
		if look and part.Parent then pcall(function() part.LocalTransparencyModifier=look.transparency part.CanTouch=look.touch part.CanQuery=look.query end) end
		if part then E.localLook[part]=nil E.byPart[part]=nil E.network.states[part]=nil end
		record.part=nil record.pending={} record.original=nil
	end
	local function desiredRoot(root)
		local d=E.effectiveDistance or E.distance local lift=3*(E.presets[E.preset].scale-1)
		local offset=E.side=="front" and Vector3.new(0,lift,-d) or E.side=="left" and Vector3.new(-d,lift,0) or E.side=="right" and Vector3.new(d,lift,0) or Vector3.new(0,lift,d)
		return root*CFrame.new(offset)
	end
	function E.targets(body,dt)
		local desired=desiredRoot(body.root.CFrame)
		E.rootPose=E.rootPose and E.rootPose:Lerp(desired,1-math.exp(-math.min(dt or 1/60,.1)*14)) or desired
		local targets={}
		local scale=E.presets[E.preset].scale
		for i,row in ipairs(E.data.rows) do
			local relative=body.root.CFrame:ToObjectSpace(body[row.role].CFrame)
			targets[i]=E.rootPose*CFrame.new(relative.Position*scale)*relative.Rotation*CFrame.new(row.offset)
		end
		return targets
	end
	local function toggle(record,property,wanted)
		if property~="Anchored" and property~="CanCollide" then return false,"Неподдерживаемое свойство" end
		if not validRecord(record) then return false,"Нельзя изменять чужой или заменённый блок" end
		local part=record.part record.pending=record.pending or {}
		local pending=record.pending[property]
		if pending then
			if not waitFor(function() return not part.Parent or part[property]==pending.desired end,responseTimeout(5)) then return false,"Ожидаю прежний "..property.."; повтор не отправлен" end
			record.pending[property]=nil E.save()
		end
		if not validRecord(record) then return false,"Блок исчез" end
		if part[property]==wanted then return true end
		if not ensureNear(part.Position) then return false,"Не удалось подойти к блоку" end
		local tool=awaitTool("Paint") local hrp=getValidHRP()
		if not tool or not hrp or interrupted() then return false,"Нужен настоящий Paint" end
		-- Intent is retained before this non-idempotent server toggle.
		record.pending[property]={desired=wanted,at=os.time()} E.save()
		local ok,err=pcall(function() tool.event:FireServer(part,Enum.NormalId.Top,hrp.Position,"material",part.Color,property=="Anchored" and "anchor" or "collide","") end)
		if not ok then return false,tostring(err) end
		if not waitFor(function() return not part.Parent or part[property]==wanted end,responseTimeout(5)) then return false,property.." не подтверждено; запрос сохранён" end
		if not validRecord(record) then return false,"Блок удалён" end
		record.pending[property]=nil E.save() return true
	end
	E.toggle=toggle
	local function checked(result,message) if not result then error(message or "Действие не подтверждено",0) end end
	local function upgradeHead()
		if E.preset~="r6" then return end
		local data=E.data local row=data.rows[1] local record=data.records[1] local part=record.part
		if row.size==Vector3.new(1,1,1) then return end
		checked(row.size==Vector3.new(2,1,1) and validRecord(record),"Не удалось обновить старую голову")
		local after={pos=row.pos-Vector3.new(.5,0,0),size=Vector3.new(1,1,1)}
		local pending=record.pending.HeadResize
		if pending then
			checked(type(pending.after)=="table" and pending.after.pos[1]==after.pos.X and pending.after.pos[2]==after.pos.Y and pending.after.pos[3]==after.pos.Z,"Запись изменения головы повреждена")
		else
			pose(record,CFrame.new(row.pos))
			if not part.Anchored then checked(waitFor(function() return (part.Position-row.pos).Magnitude<.03 and (part.CFrame.RightVector-Vector3.new(1,0,0)).Magnitude<.03 and (part.CFrame.UpVector-Vector3.new(0,1,0)).Magnitude<.03 end,6),"Не удалось вернуть голову перед уменьшением") end
			checked(toggle(record,"Anchored",true))
			checked((part.Size-row.size).Magnitude<.03 and (part.Position-row.pos).Magnitude<.03,"Голова изменилась перед уменьшением")
			checked(ensureNear(part.Position),"Не удалось подойти к голове")
			local tool=awaitTool("Shape") local hrp=getValidHRP()
			checked(tool and hrp and not interrupted(),"Нужен настоящий Shape для уменьшения головы")
			-- One inward face step, wholly inside the old head. Keep intent before sending.
			record.pending.HeadResize={desired=true,after={pos={after.pos.X,after.pos.Y,after.pos.Z},size={1,1,1}}} E.save()
			tool.event:FireServer(part,Enum.NormalId.Right,hrp.Position,"decrease")
		end
		checked(waitFor(function() return validRecord(record) and (part.Size-after.size).Magnitude<.03 and (part.Position-after.pos).Magnitude<.03 end,responseTimeout(5)),"Уменьшение головы не подтверждено; повтор не отправлен")
		checked(not interrupted() and E.data==data,"Прежняя модель отменена")
		row.pos=after.pos row.size=after.size record.pending.HeadResize=nil data.code=code(data.rows) E.save()
		if StudioHooks.stageCompanion then StudioHooks.stageCompanion(data.code,data.stageId,E.presets[E.preset].name) end
	end
	local function activate(body)
		local data=E.data
		local current=avatar()
		checked(current and current.char==body.char,"Персонаж сменился · запусти двойника снова")
		body=current
		E.network.begin() E.network.distance(body)
		watchCharacter(body.char) upgradeHead()
		for i,record in ipairs(data.records) do
			checked(not interrupted() and E.data==data,"Прежняя модель отменена")
			checked(validRecord(record),"Не хватает детали выбранной формы")
			checked((record.part.Size-data.rows[i].size).Magnitude<.05,"Размер блока двойника изменён")
			record.original=record.original or {collide=record.part.CanCollide,touch=record.part.CanTouch}
			pose(record,CFrame.new(data.rows[i].pos))
			checked(toggle(record,"CanCollide",false))
			checked(toggle(record,"Anchored",false))
			local row=data.rows[i] local wanted=model(row) wanted.color=limbColor(E.preset,body[row.role])
			checked(paintBlock(record.part,wanted),"Цвет конечности не подтверждён")
		end
		-- Unlock before capturing the following target; building temporarily moves us.
		checked(not interrupted() and E.data==data,"Действие остановлено")
		unlockPosition() stopToolForcing() disableNoclip()
		E.running=true E.cancel=false E.sourceCharacter=body.char E.rootPose=nil
		E.syncAvatar()
		local elapsed=0 local reportAt=0
		E.connection=RunService.Heartbeat:Connect(function(dt)
			if unloaded or not E.running then return end
			elapsed+=dt if elapsed<1/30 then return end local step=elapsed elapsed=0
			local current=avatar()
			if not current or current.char~=E.sourceCharacter then release() E.save() say("Персонаж сменился · верни блоки или запусти снова",true) return end
			local ok,err=pcall(function()
				E.syncAvatar() E.network.distance(current)
				local targets=E.fixedTargets or E.targets(current,step) E.maxError=0 E.ownedCount=0 E.activeCount=0 local removed=false
				E.network.lost=0 E.network.known=0 E.network.owned=0
				for i,record in ipairs(E.data.records) do
					if not validRecord(record) then
						if record.part or next(record.pending or {}) then forgetMissing(record) removed=true end
					else
						checked((record.part.Size-E.data.rows[i].size).Magnitude<.05,"Изменился размер блока")
						pose(record,targets[i]) E.activeCount+=1 E.maxError=math.max(E.maxError,(record.part.Position-targets[i].Position).Magnitude)
						if E.network.observe(record.part) then E.ownedCount+=1 end
					end
				end
				if removed then E.save() end
				if E.activeCount==0 then release() say("Пул пуст · все детали отвязаны") end
			end)
			if not ok then release() E.save() say(tostring(err),true) return end
			reportAt+=step if E.running and reportAt>=.5 then reportAt=0 if StudioHooks.extraStatus then StudioHooks.extraStatus("Следует · "..E.network.summary()) end end
		end)
		E.save() say("Двойник следует и повторяет позы R6")
	end
	local function runAction(action)
		if E.busy or _G.autobuildRunning or busySaving or unloaded then say("Дождись текущей операции или останови её",true) return false end
		local character=LocalPlayer.Character local returnRoot=character and character:FindFirstChild("HumanoidRootPart")
		E.returnRoot=returnRoot E.returnPose=returnRoot and returnRoot.CFrame
		E.busy=true E.cancel=false E.stopRequested=false _G.stopautobuild=false _G.autobuildRunning=true isBuilding=true textBox.TextEditable=false
		task.spawn(function()
			local ok,err=pcall(function() enableNoclip() startToolForcing() action() end)
			E.fixedTargets=nil E.reclaiming=false
			if not ok then release() end
			pcall(unlockPosition) pcall(stopToolForcing) pcall(disableNoclip) isBuilding=false E.busy=false
			if unloaded then return end
			if E.returnRoot and E.returnRoot.Parent and LocalPlayer.Character==character then E.returnRoot.CFrame=E.returnPose end
			E.returnRoot=nil E.returnPose=nil
			_G.autobuildRunning=false textBox.TextEditable=true
			if resumeSession and not E.stopRequested then pcall(StudioHooks.recovery.capture,resumeSession,"flush") end
			E.save() if E.stopRequested then say("Остановлен · управление и старый пул отвязаны") elseif not ok then say(tostring(err),true) end
			if StudioHooks.documents then StudioHooks.documents.flushUI() end
			if E.nextCreate and not unloaded then E.nextCreate=nil task.defer(function() E.create(true) end) end
		end)
		return true
	end
	function E.reclaim()
		if not E.running or E.busy or _G.autobuildRunning or unloaded then say("Сначала запусти форму и дождись текущей операции",true) return false end
		local body,err=avatar() if not body then say(err,true) return false end
		local root=body.root local original=root.CFrame local data=E.data
		E.rootPose=nil E.effectiveDistance=0
		local targets=E.targets(body,1)
		return runAction(function()
			E.fixedTargets=targets E.reclaiming=true
			say("Возвращаю контроль · временно подхожу к своим деталям")
			local deadline=os.clock()+8 local recovered,failed=0,0
			for i,record in ipairs(data.records) do
				if interrupted() or not E.running or os.clock()>=deadline then break end
				if validRecord(record) and ((record.part.Position-targets[i].Position).Magnitude>1 or E.network.states[record.part]==false) then
					local part=record.part local remaining=math.min(2.5,deadline-os.clock())
					local ok=waitFor(function()
						if not E.running or LocalPlayer.Character~=body.char or not root.Parent or not validRecord(record) then return true end
						root.CFrame=CFrame.new(part.Position+Vector3.new(0,.15,0))*original.Rotation
						pose(record,targets[i])
						local control=true
						if type(isnetworkowner)=="function" then local available,value=pcall(isnetworkowner,part) if available then control=value==true end end
						return control and (part.Position-targets[i].Position).Magnitude<1
					end,remaining)
					if ok and validRecord(record) and (part.Position-targets[i].Position).Magnitude<1 then recovered+=1 else failed+=1 end
				end
			end
			if root.Parent and LocalPlayer.Character==body.char then root.CFrame=original end
			E.rootPose=nil E.network.lost=0 E.network.known=0 E.network.owned=0
			local remaining=0
			for i,record in ipairs(data.records) do if validRecord(record) then E.network.observe(record.part) if (record.part.Position-targets[i].Position).Magnitude>=1 then remaining+=1 end end end
			say(string.format("Возврат контроля · поднято %d · не дошло %d · без контроля %d",recovered,remaining,E.network.lost),failed>0 or remaining>0 or E.network.lost>0)
		end)
	end
	local function newData(body)
		local origin=body.root.Position local rows local specs=definitions(E.preset,body) local profile=E.presets[E.preset]
		local root=workspace:FindFirstChild("Bricks")
		for _,shift in ipairs({Vector3.new(8,0,8),Vector3.new(-8,0,8),Vector3.new(12,0,-8),Vector3.new(-12,0,-8),Vector3.new(16,0,12),Vector3.new(32,0,0),Vector3.new(-32,0,0),Vector3.new(0,0,32),Vector3.new(0,0,-32)}) do
			local center=Vector3.new(math.floor(origin.X)+shift.X,math.floor(origin.Y+.5)+3*(profile.scale-1),math.floor(origin.Z)+.5+shift.Z)
			local candidate={} local clear=true
			for i,spec in ipairs(specs) do
				local part=body[spec.role] local size=spec.size
				local p=center+positions[spec.role]*profile.scale+spec.offset local edge=p-size/2
				p=Vector3.new(math.floor(edge.X+.5),math.floor(edge.Y+.5),math.floor(edge.Z+.5))+size/2
				candidate[i]={pos=p,size=size,color=limbColor(E.preset,part),material=E.preset=="golem" and Enum.Material.Slate or Enum.Material.SmoothPlastic,role=spec.role,offset=spec.offset}
				if root then for _,other in ipairs(StudioHooks.liveWorld.query(root,candidate[i])) do
					local box=StudioHooks.guard.worldBox(other) if Planner.intersects(candidate[i],box) then clear=false break end
				end end
			end
			if clear then rows=candidate break end
		end
		if not rows then return nil,"Нет свободного места рядом для выбранной формы" end
		local id=token() local data={version=1,job=game.JobId,preset=E.preset,token=id,stageId="companion_"..id,rows=rows,records={},code=code(rows)}
		for i,spec in ipairs(specs) do data.records[i]={name=spec.name,pending={}} end
		return data
	end
	function E.create(forceFresh)
		if StudioHooks.stairwell and StudioHooks.stairwell.busy then say("Дождись расчёта Stairwell",true) return false end
		if forceFresh and not unloaded then
			E.restore()
			if E.busy then E.nextCreate=true say("Новая форма в приоритете · отменяю прежнюю операцию") return true end
		end
		if E.running then say("Двойник уже запущен") return false end
		if E.busy or _G.autobuildRunning or busySaving or unloaded then say("Сначала останови текущую работу",true) return false end
		local body,err=avatar() if not body then say(err,true) return false end
		if not E.data then local data,message=newData(body) if not data then say(message,true) return false end E.data=data E.models[E.preset]=data _G.ORBIT_COMPANION_STATE=data end
		local all=true for _,r in ipairs(E.data.records) do if not validRecord(r) then all=false break end end
		if all then return runAction(function() activate(body) end) end
		for _,r in ipairs(E.data.records) do if validRecord(r) and (not r.part.Anchored or next(r.pending or {})) then say("Сначала припаркуй оставшиеся блоки",true) return false end end
		if not StudioHooks.stageCompanion then say("Каталог ещё не готов",true) return false end
		StudioHooks.stageCompanion(E.data.code,E.data.stageId,E.presets[E.preset].name)
		E.save()
		local data=E.data
		return runAction(function()
			say("Строю форму · "..#data.rows.." деталей")
			local complete,message=runBuilderEngine(data.code,Vector3.zero,false)
			checked(not unloaded and not interrupted() and E.data==data,"Прежняя модель отменена")
			if resumeSession and resumeSession.buildId==data.stageId then
				for i,b in ipairs(resumeSession.blocks) do if own(b.placedBrick) and geometryMatches(b.placedBrick,b) then
					local r=data.records[i] r.part=b.placedBrick
					r.part:SetAttribute("OrbitCompanionId",data.token) r.part:SetAttribute("OrbitCompanionBody",r.name)
					E.byPart[r.part]={record=r,data=data}
				end end
			end
			E.save() checked(complete,message)
			cleanupVisuals(true) activate(body)
		end)
	end
	function E.pause()
		E.cancel=true E.stopRequested=true E.activeCount=0 release()
		if E.busy then _G.stopautobuild=true end
		if E.data then for _,record in ipairs(E.data.records) do if not validRecord(record) then forgetMissing(record) end end end
		E.save() say(E.busy and "Управление снято · останавливаю текущую команду" or "Остановлен · управление и старый пул отвязаны")
		return true
	end
	local function clearLocalLook()
		for part,look in pairs(E.localLook) do if part.Parent then pcall(function() part.LocalTransparencyModifier=look.transparency part.CanTouch=look.touch part.CanQuery=look.query end) end end
		E.localLook={}
	end
	function E.restore()
		E.nextCreate=nil E.pause() clearLocalLook()
		local abandoned=E.models
		E.models={} E.byPart={} E.data=nil E.network.begin()
		_G.ORBIT_COMPANION_STATE=nil _G.ORBIT_COMPANION_MODELS={job=game.JobId,preset=E.preset,models=E.models}
		for _,data in pairs(abandoned) do if StudioHooks.forgetCompanion then pcall(StudioHooks.forgetCompanion,data.stageId) end end
		E.save() say(E.busy and "Старая модель забыта · отменяю последнюю операцию" or "Старая модель и запросы забыты · можно создать новую")
		return true
	end
	function E.park()
		if E.busy then say("Сначала останови текущую операцию",true) return false end
		if not E.data then say("Модель ещё не создана") return false end
		local data=E.data
		release()
		return runAction(function()
			say("Возвращаю блоки на место")
			local available,failed,missing=0,0,0
			for i,r in ipairs(data.records) do
				if interrupted() then break end
				if not validRecord(r) then forgetMissing(r) missing+=1 else
				local ok=pcall(function()
				pose(r,CFrame.new(data.rows[i].pos))
				if not r.part.Anchored then checked(waitFor(function() return (r.part.Position-data.rows[i].pos).Magnitude<.2 and (r.part.CFrame.RightVector-Vector3.new(1,0,0)).Magnitude<.05 and (r.part.CFrame.UpVector-Vector3.new(0,1,0)).Magnitude<.05 end,6),"Не удалось вернуть блок: нет физического контроля") end
				checked(toggle(r,"Anchored",true))
				checked(toggle(r,"CanCollide",false))
				end)
				if ok then available+=1 else failed+=1 end
			end end
			release() say(string.format("Припарковано %d · отсутствует %d · не подтверждено %d",available,missing,failed),failed>0)
		end)
	end
	function E.close()
		E.cancel=true E.afterStop=nil E.nextCreate=nil release()
		clearLocalLook()
		if E.returnRoot and E.returnRoot.Parent then pcall(function() E.returnRoot.CFrame=E.returnPose end) end
		E.returnRoot=nil E.returnPose=nil
		local ok,err=E.save()
		if _G.ORBIT_COMPANION_API==E then _G.ORBIT_COMPANION_API=nil end
		if not ok and writefile then error(err,0) end
	end
	function E.snapshot()
		local body,err=avatar() local result={version=3,preset=E.preset,activeCount=E.activeCount or 0,expectedCount=E.presets[E.preset].count,running=E.running,busy=E.busy,message=E.message,distance=E.distance,effectiveDistance=E.effectiveDistance,networkGuard=E.network.guard,lostControl=E.network.lost,knownControl=E.network.known,ownershipLosses=E.network.lossEvents,recoveredControl=E.network.recovered,nearestPlayer=E.network.nearest,reclaiming=E.reclaiming,side=E.side,rig=body and "R6" or err,parts={},error=E.maxError}
		if E.data then for i,r in ipairs(E.data.records) do
			local part=r.part result.parts[i]={name=r.name,own=validRecord(r)==true,present=part and part.Parent~=nil or false,anchored=part and part.Anchored,collide=part and part.CanCollide,pos=part and part.Position,size=part and part.Size,color=part and colorHex(part.Color),pending=r.pending,goal=E.movers[part] and E.movers[part].position.Position}
			local item=result.parts[i] local mover=E.movers[part]
			if part and part.Parent then
				item.localTransparency=part.LocalTransparencyModifier item.touch=part.CanTouch item.query=part.CanQuery
				if isnetworkowner then local ok,value=pcall(isnetworkowner,part) if ok then item.networkOwner=value==true end end
				if mover then item.axisError=math.max((part.CFrame.RightVector-mover.orientation.CFrame.RightVector).Magnitude,(part.CFrame.UpVector-mover.orientation.CFrame.UpVector).Magnitude) end
				pcall(function() local assembly=part.AssemblyRootPart item.assemblyRoot=assembly and assembly.Name item.assemblyAnchored=assembly and assembly.Anchored item.connected=#part:GetConnectedParts(true) end)
			end
		end end
		return result
	end
	_G.ORBIT_COMPANION_API=E
	return E
end)()

-- Bounded layout search, once before building. Never picks up or removes world parts.
StudioHooks.stairwell=(function()
	local S={busy=false,job=0,message="Открытый вход у ног · подъём в темноту",options={floors=6,rise=16,seed=math.random(1,1000000)},metadata={}}
	local function status(message,failure)
		S.message=message if StudioHooks.stairStatus then StudioHooks.stairStatus(message) end setStatus(message,failure)
	end
	function S.configure(options)
		local floors,rise,seed=tonumber(options.floors),tonumber(options.rise),tonumber(options.seed) or S.options.seed or 1
		if not floors or floors~=floors or not rise or rise~=rise or seed~=seed then return nil,"Введи числа" end
		local result={floors=math.clamp(math.round(floors),1,64),rise=math.clamp(math.round(rise/4)*4,12,24),seed=math.clamp(math.round(seed),1,1000000000)}
		S.options=result
		return result
	end
	if not S.configure(S.options) then S.configure({floors=6,rise=16,seed=1}) end
	local function box(lo,hi) return {pos=(lo+hi)/2,size=hi-lo} end
	local function bounds(rows)
		local lo,hi
		for _,r in ipairs(rows) do local a,b=r.pos-r.size/2,r.pos+r.size/2
			lo=lo and Vector3.new(math.min(lo.X,a.X),math.min(lo.Y,a.Y),math.min(lo.Z,a.Z)) or a
			hi=hi and Vector3.new(math.max(hi.X,b.X),math.max(hi.Y,b.Y),math.max(hi.Z,b.Z)) or b
		end
		return box(lo,hi)
	end
	-- Coarse boxes and uneven joins intentionally follow the 9mzee example.
	-- Translate/quarter-turn independent metadata; editing/reordering invalidates it.
	local function turn(p,q) if q==1 then return Vector3.new(-p.Z,p.Y,p.X) elseif q==2 then return Vector3.new(-p.X,p.Y,-p.Z) elseif q==3 then return Vector3.new(p.Z,p.Y,-p.X) end return p end
	local function signature(models,q)
		if #models==0 then return end
		local function clean(n) return math.abs(n)<.0005 and 0 or n end
		local anchor=models[1].pos local a,b=1,7
		for _,m in ipairs(models) do
			if #(m.sprays or {})>0 then return end
			local p=turn(m.pos-anchor,q) local s=q%2==1 and Vector3.new(m.size.Z,m.size.Y,m.size.X) or m.size
			local key=string.format("%.3f,%.3f,%.3f/%.3f,%.3f,%.3f/%s/%s/%s;",clean(p.X),clean(p.Y),clean(p.Z),s.X,s.Y,s.Z,colorHex(m.color),tostring(m.material),tostring(m.collide))
			for i=1,#key do local n=key:byte(i) a=(a*65599+n)%2147483647 b=(b*131+n)%2147483629 end
		end
		return tostring(#models)..":"..a..":"..b
	end
	local function metaFile(id) if type(id)=="string" and id:match("^stairwell_[%w_%-]+$") then return "OrbitStairwell_"..id..".json" end end
	function S.saveMeta(meta)
		if meta.transient then return true end
		if not writefile then return true end
		local file=metaFile(meta.id) if not file then return false end
		return pcall(function() writefile(file,HttpService:JSONEncode(meta)) end)
	end
	function S.loadMeta(id)
		if S.metadata[id] then return S.metadata[id] end
		local file=metaFile(id) if not file or not readfile or not isfile or not isfile(file) then return end
		local ok,v=pcall(function() return HttpService:JSONDecode(readfile(file)) end)
		if ok and type(v)=="table" and v.version==2 and v.id==id and type(v.keys)=="table" and type(v.hazards)=="table" and type(v.states)=="table" then S.metadata[id]=v return v end
	end
	function S.remember(id,code,path)
		local parsed,invalid=parseBlocks(code,Vector3.zero) if invalid>0 then error("Некорректный Stairwell",0) end
		local models={} for i,b in ipairs(parsed) do models[i]=targetModel(b,i) end
		local meta={version=2,id=id,keys={},hazards={},states={}}
		for q=0,3 do meta.keys[q+1]=signature(models,q) end
		local index=0 for _,floor in ipairs(path) do for _,r in ipairs(floor.rows) do index+=1 if r.hazard then meta.hazards[#meta.hazards+1]=index end end end
		S.metadata[id]=meta local ok,err=S.saveMeta(meta) if not ok then error("Не удалось сохранить ловушки: "..tostring(err),0) end
		return meta
	end
	function S.bind(session)
		if session.transient then
			for _,d in ipairs(session.blocks) do if d.stairToxic then d.stairToxic.defer=true end end
			return
		end
		if session.stairBoundText==session.text and session.stairBoundOffset==session.offset then
			for _,d in ipairs(session.blocks) do if d.stairToxic then d.stairToxic.defer=true end end
			return
		end
		for i,d in ipairs(session.blocks) do d.stairToxic=nil session.models[i].eligible=true end
		session.stairBoundText=session.text session.stairBoundOffset=session.offset session.stairMeta=nil
		local meta=S.loadMeta(session.buildId) if not meta then return end
		local key=signature(session.models,0) local matches=false for _,v in ipairs(meta.keys) do if v==key then matches=true break end end
		if not matches then status("Stairwell изменён: метки toxic отключены; создай новый вариант для новых ловушек",true) return end
		session.stairMeta=meta
		for _,index in ipairs(meta.hazards) do if type(index)=="number" and index%1==0 and session.blocks[index] then
			local d=session.blocks[index] d.stairToxic={id=meta.id,index=index,defer=true} session.models[index].eligible=false
			if not d.placedBrick then
				local root=workspace:FindFirstChild("Bricks") local own=getPlayerBricksFolder() local found,ambiguous
				if root and own and meta.states[tostring(index)] then for _,p in ipairs(StudioHooks.liveWorld.query(root,session.models[index])) do
					if p.Parent and p:IsDescendantOf(own) and p:GetAttribute("OrbitStairHazard")==meta.id..":"..index and geometryMatches(p,d) then if found then ambiguous=true break end found=p end
				end end
				if found and not ambiguous then d.placedBrick=found d.brick=found session.ids[found]="t:"..index session.instances["t:"..index]=found end
			end
		end end
	end
	local function knownOwn(brick,data)
		local folder=getPlayerBricksFolder()
		return folder and brick and brick.Parent and brick:IsDescendantOf(folder) and (not data.placedBrick or data.placedBrick==brick) and geometryMatches(brick,data)
	end
	function S.toxicReady(brick,data)
		local tag=data.stairToxic if not tag then return true end
		local meta=S.metadata[tag.id] local record=meta and meta.states[tostring(tag.index)]
		return knownOwn(brick,data) and record and record.phase=="confirmed" and brick:GetAttribute("OrbitStairToxic")==tag.id..":"..tag.index
	end
	function S.materialMatches(brick,data)
		if not data.stairToxic or not data.stairToxic.defer then return brick.Material==data.material end
		return brick.Material==(S.toxicReady(brick,data) and Enum.Material.Neon or Enum.Material.Brick)
	end
	function S.paintShell(brick,data,ordinaryPaint)
		if not knownOwn(brick,data) or data.placedBrick~=brick then return false end
		local tag=data.stairToxic local meta=S.metadata[tag.id] if not meta then return false end
		local id=tag.id..":"..tag.index local key=tostring(tag.index) local record=meta.states[key]
		if not record or brick:GetAttribute("OrbitStairHazard")~=id then record={phase="shell"} meta.states[key]=record brick:SetAttribute("OrbitStairHazard",id) S.saveMeta(meta) end
		if record.phase=="sent" then
			if not waitUntil(function() return brick.Parent and brick.Material==Enum.Material.Neon end,responseTimeout(2)) then return false end
			record.phase="confirmed" brick:SetAttribute("OrbitStairToxic",id) S.saveMeta(meta)
		elseif record.phase=="reset" then
			if not waitUntil(function() return brick.Parent and brick.Material==Enum.Material.Brick end,responseTimeout(2)) then return false end
			record.phase="shell" S.saveMeta(meta)
		end
		if S.toxicReady(brick,data) and brick.Material==Enum.Material.Neon and sameColor(brick.Color,data.color) then return true end
		local shell=table.clone(data) shell.stairToxic=nil shell.material=Enum.Material.Brick
		return ordinaryPaint(brick,shell)
	end
	function S.beginBuild(session)
		if S.returnRoot then return end
		local root=getValidHRP() if root then S.returnRoot=root S.returnPose=root.CFrame S.returnChar=LocalPlayer.Character end
	end
	function S.returnCharacter()
		local root=S.returnRoot
		if root and root.Parent and S.returnChar==LocalPlayer.Character then pcall(function() root.CFrame=S.returnPose end) end
		S.returnRoot=nil S.returnPose=nil S.returnChar=nil
	end
	function S.paintToxic(brick,data)
		if not knownOwn(brick,data) or data.placedBrick~=brick then return false end
		local tag=data.stairToxic local meta=tag and S.metadata[tag.id] if not meta then return false end
		local id=tag.id..":"..tag.index local key=tostring(tag.index)
		local record=meta.states[key]
		if not record or brick:GetAttribute("OrbitStairHazard")~=id then record={} meta.states[key]=record brick:SetAttribute("OrbitStairHazard",id) end
		local function waitMaterial(mat) return waitUntil(function() return brick.Parent and brick.Material==mat end,responseTimeout(2)) end
		if S.toxicReady(brick,data) and brick.Material==Enum.Material.Neon and sameColor(brick.Color,data.color) then return true end
		if not ensureNear(brick.Position,nil,true) then return false end
		local tool,hrp=awaitTool("Paint"),getValidHRP() if not tool or not hrp or cancelled() then return false end
		local function send(phase,material)
			record.phase=phase
			local ok=S.saveMeta(meta) if not ok then return false end
			return pcall(function() tool.event:FireServer(brick,Enum.NormalId.Top,hrp.Position,"both 🤝",data.color,material,"") end)
		end
		-- Neon alone cannot acknowledge toxic. Observe a real material transition.
		if record.phase=="reset" then if not waitMaterial(Enum.Material.Brick) then return false end record.phase=nil end
		if record.phase~="sent" and brick.Material==Enum.Material.Neon then
			if not send("reset","bricks") or not waitMaterial(Enum.Material.Brick) then return false end record.phase=nil
		end
		if record.phase~="sent" then if not send("sent","toxic") then return false end end
		if not waitMaterial(Enum.Material.Neon) or not knownOwn(brick,data) or not sameColor(brick.Color,data.color) then return false end
		record.phase="confirmed" brick:SetAttribute("OrbitStairToxic",id) S.saveMeta(meta)
		return true
	end
	function S.activatePits(session)
		local list={} for i,d in ipairs(session.blocks) do if d.stairToxic then d.stairToxic.defer=false list[#list+1]={index=i,data=d} end end
		table.sort(list,function(a,b) return a.data.centerPos.Y<b.data.centerPos.Y end)
		local failed=0
		for n,item in ipairs(list) do
			local data=item.data local i=item.index
			local ok=not cancelled() and S.paintToxic(data.placedBrick,data)
			if ok then
				if not session.done[i] then session.done[i]=true _G.autobuildPlaced+=1 end
				data.failure=nil data.guardDamage=nil data.guardFailures=nil data.guardRetryAt=nil
				if StudioHooks.guard then StudioHooks.guard.queue[i]=nil end
			else
				failed+=1 if session.done[i] then session.done[i]=nil _G.autobuildPlaced=math.max(0,_G.autobuildPlaced-1) end
				data.failure="Toxic не подтверждён; дно сохранено, продолжи строительство"
			end
			StudioHooks.recovery.capture(session,false,i) markPlanProgress(session,i)
			status(string.format("Toxic-дно · %d/%d · не подтверждено %d",n,#list,failed),not ok)
		end
		return failed==0,failed==0 and "Ловушки обработаны" or ("Toxic: не подтверждено "..failed.."; продолжи строительство")
	end
	local function geometryKey(m)
		return string.format("%.3f,%.3f,%.3f/%.3f,%.3f,%.3f",m.pos.X,m.pos.Y,m.pos.Z,m.size.X,m.size.Y,m.size.Z)
	end
	function S.fastPlan(targets,scene,options)
		options=options or {} local byGeometry,placed={},{ } local obstacles=table.clone(scene) local index=Planner.spatial(obstacles) local targetIndex=Planner.spatial(targets)
		for _,m in ipairs(scene) do if m.eligible then byGeometry[geometryKey(m)]=m end if m.instance and type(m.id)=="string" and m.id:match("^t:%d+$") then placed[m.id]=m end end
		local plan={name="Stairwell · готовые модули",items={},operations=0,shapeSteps=0,helpers=0,alternatives={},templateVersion=20}
		local blueprints=options.blueprints or {} local compiledCount=0 local cacheHits=0
		for i,target in ipairs(targets) do
			if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
			if i%128==0 and options.yield then options.yield() end
			local recipe local same=placed[target.id] or byGeometry[geometryKey(target)]
			if same and Planner.geometry(same,target) then recipe=Planner.recipe(target,target,same,"reuse") end
			if not recipe or recipe.operations>0 then
				for _,dir in ipairs(Planner.directions) do
					local source=byGeometry[geometryKey({pos=target.pos-dir.unit*target.size[dir.axis],size=target.size})]
					if source then local r=Planner.recipe(target,target,source,"clone",dir.face) if r and (not recipe or r.operations<recipe.operations) then recipe=r end end
				end
			end
			if not recipe then
				local initial,kind
				if target.size==Vector3.new(4,4,4) then initial={pos=target.pos,size=target.size} kind="normal"
				else initial={pos=target.pos-target.size/2+Vector3.new(.5,.5,.5),size=Vector3.new(1,1,1)} kind="detailed" end
				recipe=Planner.recipe(initial,target,nil,kind)
			end
			if options.partials and options.partials[i] then recipe=Planner.chooseLive(target,{},obstacles,targets,false,options.partials[i]) end
			if not recipe then error("Не найден рецепт модуля "..i,0) end
			for _,other in ipairs(index:query(target)) do
				if other.id~=target.id and (not recipe.source or other.id~=recipe.source.id) and other.reservedTarget~=target.id and Planner.intersects(target,other) then error("Существующий блок перекрыл Stairwell: "..i,0) end
			end
			-- Geometry growth is cached; live obstacle validation is still per target.
			local key=geometryKey({pos=recipe.initial.pos-target.pos,size=target.size}).."/"..geometryKey({pos=Vector3.zero,size=recipe.initial.size}).."/"..recipe.kind
			local cached=blueprints[key] local compiled
			if cached then
				local shift=target.pos-cached.origin compiled=table.clone(recipe) compiled.steps={}
				for _,s in ipairs(cached.steps) do local step=table.clone(s) step.before={pos=s.before.pos+shift,size=s.before.size} step.after={pos=s.after.pos+shift,size=s.after.size} compiled.steps[#compiled.steps+1]=step end
				if not Planner.safeBox(compiled.initial,target,index:query(compiled.initial),recipe.source and recipe.source.id,false) then compiled=nil end
				if compiled then for _,step in ipairs(compiled.steps) do if not Planner.safeBox(step.after,target,index:query(step.after),recipe.source and recipe.source.id,false) then compiled=nil break end end end
				cacheHits+=1
			else compiled=Planner.compile(recipe,obstacles,targets,recipe.source and recipe.source.id,nil,index,targetIndex) compiledCount+=1
				if compiled then blueprints[key]={origin=target.pos,steps=compiled.steps} end
			end
			if not compiled then error("Мир перекрыл готовый рецепт Stairwell: блок "..i,0) end
			compiled.index=i plan.items[#plan.items+1]=compiled plan.operations+=compiled.operations plan.shapeSteps+=compiled.shapeSteps
			if target.eligible==false then plan.operations+=1 end
			obstacles[#obstacles+1]=target index:add(target) if target.eligible~=false then byGeometry[geometryKey(target)]=target end
			if i%128==0 or i==#targets then
				if options.progress then options.progress("Готовые модули: "..i.."/"..#targets,i/#targets) end
				if options.visual then options.visual("template",plan,i) end
			end
		end
		plan.templateCompiles=compiledCount plan.templateHits=cacheHits Planner.measurePlan(plan,options.position or targets[1].pos,options.timing)
		return plan
	end

	function S.module(origin,direction,drop,level,turn,options)
		options=options or S.options
		local rows,routes,reserved={},{},{} local exits={}
		local seed=options.seed or 1
		local function noise(salt)
			local n=(seed+level*104729+salt*69621)%2147483647
			n=bit32.bxor(n,bit32.rshift(n,16)) n=(n*48271)%2147483647
			return bit32.bxor(n,bit32.rshift(n,13))
		end
		local width=noise(1)%2==0 and 32 or 40 local depth=noise(2)%3==0 and 24 or 16
		local right=Vector3.new(direction.Z,0,-direction.X)
		local shade=math.clamp(math.round(255*(20-level)/19),0,255)
		local color=Color3.new(shade/255,shade/255,shade/255)
		local function transform(lo,hi,start,heading)
			start=start or origin heading=heading or direction
			local r=box(lo,hi) local p=r.pos local side=Vector3.new(heading.Z,0,-heading.X)
			r.pos=start+side*p.X+Vector3.new(0,p.Y,0)+heading*p.Z
			if heading.X~=0 then r.size=Vector3.new(r.size.Z,r.size.Y,r.size.X) end
			return r
		end
		local function part(lo,hi,neon,start,heading,hazard)
			if hi.X<=lo.X or hi.Y<=lo.Y or hi.Z<=lo.Z then return end
			local r=transform(lo,hi,start,heading) r.color=color r.material=neon and Enum.Material.Neon or Enum.Material.Brick r.level=level r.hazard=hazard==true
			rows[#rows+1]=r
		end
		local function cubes(lo,hi,start,heading,hazard)
			for x=lo.X,hi.X-4,4 do for y=lo.Y,hi.Y-4,4 do for z=lo.Z,hi.Z-4,4 do part(Vector3.new(x,y,z),Vector3.new(x+4,y+4,z+4),hazard,start,heading,hazard) end end end
		end
		local function passage(lo,hi,start,heading) routes[#routes+1]=transform(lo,hi,start,heading) end
		local function exit(which)
			if which=="right" then return origin+right*(width-8)+direction*(depth-8),right
			elseif which=="left" then return origin-right*8+direction*(depth-8),right*-1
			else return origin+direction*depth,direction end
		end
		local style=noise(3)%3 -- down/up, up/down, or two upward beginnings.
		local fake
		if level>1 and turn~="end" and not options.noBranch and noise(4)%4~=0 then
			local choices={"right","left","straight"}
			local start=noise(5)%3+1
			for j=0,2 do local v=choices[(start+j-1)%3+1] if v~=turn then fake=v break end end
		end
		exits[turn]=turn~="end" or nil if fake then exits[fake]=true end
		-- No trim or rails: thick grids, low beams and differently sized chambers.
		cubes(Vector3.new(-8,-4,0),Vector3.new(width-8,0,depth))
		if level>1 then cubes(Vector3.new(-8,12,0),Vector3.new(width-8,16,depth)) end
		if level>1 then
			cubes(Vector3.new(-8,0,0),Vector3.new(-4,12,4))
			cubes(Vector3.new(4,0,0),Vector3.new(width-8,12,4))
		end
		if not exits.straight then cubes(Vector3.new(-8,0,depth-4),Vector3.new(width-8,12,depth))
		else
			cubes(Vector3.new(-8,0,depth-4),Vector3.new(-4,12,depth))
			cubes(Vector3.new(4,0,depth-4),Vector3.new(width-8,12,depth))
		end
		for z=4,depth-8,4 do
			if not exits.left or z<depth-12 then cubes(Vector3.new(-8,0,z),Vector3.new(-4,12,z+4)) end
			if not exits.right or z<depth-12 then cubes(Vector3.new(width-12,0,z),Vector3.new(width-8,12,z+4)) end
		end
		-- An awkward beam gives 8 studs of real clearance, not a decorative railing.
		if level>1 and noise(6)%2==0 then cubes(Vector3.new(-4,8,4),Vector3.new(width-12,12,8)) end
		if level%2==0 then part(Vector3.new(0,10,depth-6),Vector3.new(1,11,depth-5),true) end
		passage(Vector3.new(-4,0,-4),Vector3.new(4,8,4))
		passage(Vector3.new(-4,0,4),Vector3.new(width-12,8,depth-4))
		for which in pairs(exits) do
			if which=="right" then passage(Vector3.new(width-12,0,depth-12),Vector3.new(width-8,8,depth-4))
			elseif which=="left" then passage(Vector3.new(-8,0,depth-12),Vector3.new(-4,8,depth-4))
			elseif which=="straight" then passage(Vector3.new(-4,0,depth-4),Vector3.new(4,8,depth)) end
		end
		local function flight(start,heading,length,up,broken,trapBottom)
			for z=0,length-1 do
				local base=up and math.floor(z/4)*4 or -4*(math.floor(z/4)+1)
				local height=up and (z%4+1) or (4-z%4)
				if not broken or z<length-2 then for x=-4,0,4 do part(Vector3.new(x,base,z),Vector3.new(x+4,base+height,z+1),false,start,heading) end end
				if not broken then passage(Vector3.new(-4,base+height,z),Vector3.new(4,base+height+8,z+1),start,heading) end
			end
			for z=0,length-4,4 do
				local base=up and z or -z
				local bottom=trapBottom or base-4
				cubes(Vector3.new(-8,bottom,z),Vector3.new(-4,base+12,z+4),start,heading)
				cubes(Vector3.new(4,bottom,z),Vector3.new(8,base+12,z+4),start,heading)
				cubes(Vector3.new(-4,base+12,z),Vector3.new(4,base+16,z+4),start,heading)
				if not broken and z==4 and level%3==0 then part(Vector3.new(-.0,base+10,z+1),Vector3.new(1,base+11,z+2),true,start,heading) end
			end
			local height=up and length or -length
			return start+heading*length+Vector3.new(0,height,0),height
		end
		local nextOrigin,nextDirection=origin,direction
		local routePoints={origin,origin+direction*(depth-8)}
		if turn~="end" then
			local start,heading=exit(turn) nextDirection=heading
			routePoints[#routePoints+1]=start
			local hump=style~=0
			if hump then
				local raised=flight(start,heading,4,true)
				cubes(Vector3.new(-4,-4,0),Vector3.new(4,0,8),raised,heading)
				cubes(Vector3.new(-8,0,0),Vector3.new(-4,12,8),raised,heading)
				cubes(Vector3.new(4,0,0),Vector3.new(8,12,8),raised,heading)
				cubes(Vector3.new(-4,12,0),Vector3.new(4,16,8),raised,heading)
				passage(Vector3.new(-4,0,0),Vector3.new(4,8,8),raised,heading)
				start=raised+heading*8
				routePoints[#routePoints+1]=raised routePoints[#routePoints+1]=start
			end
			nextOrigin=flight(start,heading,drop-(hump and 4 or 0),true)
			routePoints[#routePoints+1]=nextOrigin
		end
		local branch
		if fake then
			local start,heading=exit(fake) local up=style~=1 local height=up and 8 or -8 local bottom=math.min(0,height)-20
			flight(start,heading,8,up,true,bottom)
			-- Closed under the broken stairs as well: falling never exits the shell.
			cubes(Vector3.new(-4,bottom-4,0),Vector3.new(4,bottom,20),start,heading,true)
			cubes(Vector3.new(-4,bottom,0),Vector3.new(4,-4,4),start,heading)
			cubes(Vector3.new(-8,bottom,8),Vector3.new(-4,height+12,24),start,heading)
			cubes(Vector3.new(4,bottom,8),Vector3.new(8,height+12,24),start,heading)
			cubes(Vector3.new(-4,bottom,20),Vector3.new(4,height+12,24),start,heading)
			cubes(Vector3.new(-4,height+12,8),Vector3.new(4,height+16,24),start,heading)
			cubes(Vector3.new(-4,bottom,8),Vector3.new(4,height-4,12),start,heading)
			cubes(Vector3.new(-4,height+8,8),Vector3.new(4,height+12,12),start,heading)
			reserved[#reserved+1]=transform(Vector3.new(-4,bottom,0),Vector3.new(4,height+8,20),start,heading)
			branch={exit=fake,up=up,broken=true,bottom=bottom,start=start,direction=heading,height=height}
		end
		local solidBounds=bounds(rows)
		return {rows=rows,routes=routes,reserved=reserved,routePoints=routePoints,origin=origin,nextOrigin=nextOrigin,nextDirection=nextDirection,turn=turn,level=level,branch=branch,style=style,bounds=solidBounds,clearBounds=solidBounds}
	end

	local function clear(candidate,previous,obstacles)
		local solids,passages,world={},{},{}
		for _,old in ipairs(previous) do if Planner.intersects(candidate.clearBounds,old.clearBounds) then
			for _,r in ipairs(old.rows) do solids[#solids+1]=r end for _,r in ipairs(old.routes) do passages[#passages+1]=r end for _,r in ipairs(old.reserved or {}) do passages[#passages+1]=r end
		end end
		for _,part in ipairs(obstacles) do if part.Parent then local r=StudioHooks.guard.worldBox(part) r.instance=part world[#world+1]=r end end
		local solidIndex,routeIndex,worldIndex=Planner.spatial(solids),Planner.spatial(passages),Planner.spatial(world)
		for _,r in ipairs(candidate.rows) do
			for _,v in ipairs(worldIndex:query(r)) do if v.instance.Parent and StudioHooks.guard.intersects(v.instance,r) then return false end end
			for _,v in ipairs(solidIndex:query(r)) do if Planner.intersects(r,v) then return false end end
			for _,v in ipairs(routeIndex:query(r)) do if Planner.intersects(r,v) then return false end end
		end
		for _,r in ipairs(candidate.routes) do
			for _,v in ipairs(worldIndex:query(r)) do if v.instance.Parent and StudioHooks.guard.intersects(v.instance,r) then return false end end
			for _,v in ipairs(solidIndex:query(r)) do if Planner.intersects(r,v) then return false end end
		end
		for _,r in ipairs(candidate.reserved or {}) do
			for _,v in ipairs(worldIndex:query(r)) do if v.instance.Parent and StudioHooks.guard.intersects(v.instance,r) then return false end end
			for _,v in ipairs(solidIndex:query(r)) do if Planner.intersects(r,v) then return false end end
		end
		return true
	end
	function S.layout(origin,direction,options,query,cooperate)
		local path={} local attempts=0 local exhausted=false
		local function search(start,heading,level)
			if level>options.floors then return true end
			local turns=level==options.floors and {"end"} or {"right","left","straight"}
			if #turns>1 then
				local state=((options.seed or 1)+level*69621)%2147483647
				for i=3,2,-1 do state=(state*48271)%2147483647 local j=state%i+1 turns[i],turns[j]=turns[j],turns[i] end
			end
			for variant=1,2 do for _,turn in ipairs(turns) do
				attempts+=1 if attempts>256 then exhausted=true return false end
				if cooperate and cooperate(level,attempts)==false then return false end
				local config=table.clone(options) config.noBranch=variant==2
				local rise=math.clamp(options.rise+(((options.seed or 1)+level*31)%3-1)*4,12,24)
				local candidate=S.module(start,heading,rise,level,turn,config)
				local focus=StudioHooks.liveWorld.focus(candidate.bounds,bounds(candidate.routes))
				if clear(candidate,path,query(focus)) then
					path[#path+1]=candidate
					if search(candidate.nextOrigin,candidate.nextDirection,level+1) then return true end
					path[#path]=nil
				end
			end end
			return false
		end
		if not search(origin,direction,1) then return nil,exhausted and "Лимит поиска: свободный маршрут не найден" or "Нет свободного маршрута: измени место или число этажей" end
		return path,attempts
	end
	-- Stairwell has its own memory-only sessions. It never edits a document.
	function S.removePreview()
		if S.preview then S.preview:Destroy() S.preview=nil end
		S.previewRows={}
		S.previewRoutes={}
	end
	local function discard()
		if not S.last then return end
		for _,floor in ipairs(S.last.path or {}) do
			local session=floor.session
			if session then
				for _,d in ipairs(session.blocks) do
					if d.creation and d.creation.connection then d.creation.connection:Disconnect() end
					StudioHooks.recovery.completed(d)
				end
				S.metadata[session.buildId]=nil
			end
		end
		S.last=nil
	end
	local function pending()
		if not S.last then return false end
		for _,floor in ipairs(S.last.path) do
			if floor.session and StudioHooks.documents.pending(floor.session) then return true end
			local meta=floor.session and floor.session.stairMeta
			if meta then for _,record in pairs(meta.states) do if record.phase=="sent" or record.phase=="reset" then return true end end end
		end
		return false
	end
	function S.cancel()
		if S.running then _G.stopautobuild=true status("Останавливаю · отправленный запрос остаётся под наблюдением") return end
		S.job+=1 S.busy=false status("Расчёт остановлен")
	end
	function S.regenerate(options)
		options=table.clone(options or S.options)
		options.seed=(tonumber(options.seed) or S.options.seed)+1
		return S.generate(options)
	end
	local function playerPose()
		local char=LocalPlayer.Character local root=char and char:FindFirstChild("HumanoidRootPart")
		if not root or not root.Parent then return end
		local pos,look=root.Position,root.CFrame.LookVector
		local heading=math.abs(look.X)>math.abs(look.Z) and Vector3.new(look.X>0 and 1 or -1,0,0) or Vector3.new(0,0,look.Z>0 and 1 or -1)
		local ground=pos.Y-3
		pcall(function()
			local params=RaycastParams.new() params.FilterType=Enum.RaycastFilterType.Exclude
			local ignore={char} if visualFolder then ignore[#ignore+1]=visualFolder end
			if S.preview then ignore[#ignore+1]=S.preview end
			local imaginary=workspace:FindFirstChild("Autobuild_Imaginary_"..LocalPlayer.UserId) if imaginary then ignore[#ignore+1]=imaginary end
			params.FilterDescendantsInstances=ignore
			local hit=workspace:Raycast(pos+Vector3.new(0,2,0),Vector3.new(0,-80,0),params) if hit then ground=hit.Position.Y end
		end)
		-- Snap the room floor to the block grid, without elevating the whole tower.
		return {origin=Vector3.new(math.round(pos.X/4)*4,math.round(ground/4)*4,math.round(pos.Z/4)*4)+heading*4,heading=heading}
	end
	local function drawRoute(floor,parent)
		local lines={}
		local function line(a,b)
			local length=(b-a).Magnitude if length<.05 then return end
			lines[#lines+1]=create("Part",{Name="Stairwell_Route",Parent=parent,Size=Vector3.new(.08,.08,length),CFrame=CFrame.lookAt((a+b)/2,b),Color=Color3.fromRGB(110,180,255),Material=Enum.Material.SmoothPlastic,Transparency=.2,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,CastShadow=false})
		end
		for i=2,#floor.routePoints do
			local a,b=floor.routePoints[i-1]+Vector3.new(0,2,0),floor.routePoints[i]+Vector3.new(0,2,0)
			local delta=b-a local length=delta.Magnitude
			if length>.05 then
				line(a,b) local direction=delta/length local side=direction:Cross(Vector3.new(0,1,0))
				if side.Magnitude>.05 then side=side/side.Magnitude line(b,b-direction+side*.4) line(b,b-direction-side*.4) end
			end
		end
		if floor.branch then
			local point=floor.branch.start+floor.branch.direction*8+Vector3.new(0,floor.branch.height+1,0)
			local p=create("Part",{Name="Stairwell_BrokenRoute",Parent=parent,Position=point,Size=Vector3.new(2,2,2),Transparency=1,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false})
			create("SelectionBox",{Parent=p,Adornee=p,LineThickness=.03,SurfaceTransparency=1,Color3=Color3.fromRGB(235,171,91)}) lines[#lines+1]=p
		end
		return lines
	end
	function S.generate(options)
		-- Clicking Generate always removes the old local preview, even while paused.
		S.removePreview()
		if unloaded or _G.autobuildRunning or busySaving or StudioHooks.extras and (StudioHooks.extras.busy or StudioHooks.extras.running) then status("Сначала останови текущую работу",true) return false end
		if pending() then status("Есть ожидающий запрос · продолжи текущий этаж перед новой генерацией",true) return false end
		local config,err=S.configure(options or S.options) if not config then status(err,true) return false end
		discard() S.job+=1 local job=S.job S.busy=true S.blueprints={}
		task.spawn(function()
			local ok,result=pcall(function()
				local pose=playerPose() or S.pose
				if not pose then
					status("Жду появления персонажа · генерацию можно отменить")
					repeat task.wait(.1) pose=playerPose() until pose or unloaded or job~=S.job
				end
				if unloaded or job~=S.job then return end
				S.pose=pose
				local root=workspace:FindFirstChild("Bricks")
				local lastYield=os.clock()
				local function cooperate(level,attempt)
					if unloaded or job~=S.job then return false end
					if os.clock()-lastYield>=.012 then status(string.format("Геометрия · этаж %d/%d",level,config.floors)) task.wait() lastYield=os.clock() end
					return not unloaded and job==S.job
				end
				if root then StudioHooks.liveWorld.parts(root,function() task.wait() return not unloaded and job==S.job end) end
				local query=function(focus) return root and StudioHooks.liveWorld.query(root,focus) or {} end
				local path,message=S.layout(pose.origin,pose.heading,config,query,cooperate)
				if not path then error(message,0) end
				if unloaded or job~=S.job then return end
				local previous={} local count=0
				for _,floor in ipairs(path) do
					if not clear(floor,previous,query(StudioHooks.liveWorld.focus(floor.bounds,bounds(floor.routes)))) then error("Мир изменился · создай preview заново",0) end
					previous[#previous+1]=floor count+=#floor.rows
				end
				local id="stairwell_"..HttpService:GenerateGUID(false)
				S.last={id=id,path=path,count=count,floor=1}
				S.preview=create("Folder",{Name="Orbit_Stairwell_Preview",Parent=workspace}) S.previewRows={} S.previewRoutes={}
				local started=os.clock() local renderYield=os.clock()
				for level,floor in ipairs(path) do
					if S.preview then S.previewRoutes[level]=drawRoute(floor,S.preview) end
					local encoded={}
					local meta={version=2,id=id.."_"..level,transient=true,hazards={},states={}}
					local visuals={} S.previewRows[level]=visuals
					for i,row in ipairs(floor.rows) do
						if unloaded or job~=S.job then return end
						encoded[i]=serializeBlock({centerPos=row.pos,size=row.size,color=row.color,material=row.material,canCollide=true,sprays={}})
						if row.hazard then meta.hazards[#meta.hazards+1]=i end
						if S.preview then visuals[i]=create("Part",{Name="Stairwell_"..level.."_"..i,Parent=S.preview,Position=row.pos,Size=row.size,Color=row.color,Material=row.hazard and Enum.Material.Brick or row.material,Transparency=.55,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,CastShadow=false}) end
						if os.clock()-renderYield>=.008 then task.wait() renderYield=os.clock() end
					end
					local code=table.concat(encoded) local blocks,bad=parseBlocks(code,Vector3.zero) if bad>0 then error("Ошибка геометрии этажа",0) end
					local session={buildId=meta.id,transient=true,text=code,offset=Vector3.zero,blocks=blocks,models={},done={},ids={},instances={},helpers={},actual={creates=0,shapes=0,deletes=0},nextWorld=0,stairMeta=meta,stairFloor=level}
					S.metadata[meta.id]=meta floor.session=session
					for i,data in ipairs(blocks) do session.models[i]=targetModel(data,i) end
					for _,i in ipairs(meta.hazards) do blocks[i].stairToxic={id=meta.id,index=i,defer=true} session.models[i].eligible=false end
					-- Layout already checked the world. Recheck live world per request at build time.
					-- Small growth recipes are shared by every floor; there is no global search.
					session.plan=S.fastPlan(session.models,{}, {blueprints=S.blueprints,position=pose.origin,cancelled=function() return unloaded or job~=S.job end,yield=function() task.wait() end})
					session.plan.plannerVersion=Planner.version session.planByIndex={}
					for _,item in ipairs(session.plan.items) do session.planByIndex[item.index]=item end
					status(string.format("Preview и план · этаж %d/%d",level,#path)) task.wait()
				end
				S.last.ready=true
				status(string.format("Готово · %d этажей · %d блоков · план %.1fс",#path,count,os.clock()-started))
			end)
			if job==S.job then
				S.busy=false
				if not ok then S.removePreview() discard() if not unloaded then status(tostring(result),true) end end
			end
		end)
		return true
	end
	function S.build()
		if S.running then S.cancel() return false end
		if S.busy or _G.autobuildRunning or busySaving then status("Дождись подготовки",true) return false end
		if not S.last or not S.last.ready then status("Сначала создай preview",true) return false end
		if StudioHooks.extras and (StudioHooks.extras.busy or StudioHooks.extras.running) then status("Сначала останови двойника",true) return false end
		local savedSession=resumeSession local savedResume=_G.AUTOBUILD_RESUME
		local savedTotal,savedPlaced=_G.autobuildTotal,_G.autobuildPlaced
		local savedButton,savedStats=btnStart.Text,statDisplay.Text
		S.running=true _G.stopautobuild=false _G.autobuildRunning=true isBuilding=true
		if StudioHooks.guard then StudioHooks.guard.close() end
		task.spawn(function()
			local ok,completed,message=pcall(function()
				for level=S.last.floor,#S.last.path do
					if cancelled() then return false,"Пауза · продолжи в этом окне" end
					local floor=S.last.path[level] local session=floor.session
					S.context=session resumeSession=session
					status(string.format("Строю этаж %d/%d",level,#S.last.path))
					local finished,err=runBuilderEngine(session.text,session.offset,false)
					if not finished then return false,"Этаж "..level.." · "..tostring(err) end
					floor.complete=true S.last.floor=level+1
					local visuals=S.previewRows[level] or {} for _,v in pairs(visuals) do if v.Parent then v:Destroy() end end S.previewRows[level]=nil
					for _,v in ipairs(S.previewRoutes and S.previewRoutes[level] or {}) do if v.Parent then v:Destroy() end end if S.previewRoutes then S.previewRoutes[level]=nil end
				end
				return true,"Stairwell построен · все этажи проверены"
			end)
			pcall(unlockPosition) S.returnCharacter() pcall(stopToolForcing) pcall(disableNoclip)
			if StudioHooks.guard then StudioHooks.guard.close() end
			S.context=nil resumeSession=savedSession _G.AUTOBUILD_RESUME=savedResume
			_G.autobuildTotal=savedTotal _G.autobuildPlaced=savedPlaced _G.autobuildRunning=false
			S.running=false isBuilding=false
			if not unloaded then
				btnStart.Text=savedButton statDisplay.Text=savedStats
				if savedSession and StudioHooks.guard then StudioHooks.guard.watch(savedSession) end
				status(ok and message or tostring(completed),not ok or not completed)
				if ok and completed then S.removePreview() end
			end
		end)
		return true
	end
	function S.close()
		S.job+=1 S.busy=false if S.running then _G.stopautobuild=true end
		S.removePreview() if not S.running then discard() S.returnCharacter() end
	end
	function S.onPrepared() end

	return S
end)()

StudioHooks.resumeRecovery=function() launchAction(false) end
StudioHooks.prepareStairwell=function() if busySaving or isBuilding or unloaded then return false end launchAction("stairwellPreview") return true end
btnStart.MouseButton1Click:Connect(function() launchAction(false) end)


-- All imaginary tools operate on this client-owned scene. No tool in this
-- module has a RemoteEvent, and editing never calls the server builder.
do
(function()
	local Model=(function()
local M = {}
local function validNumber(n) return type(n)=="number" and n==n and math.abs(n)<=1000000 end
function M.valid(b)
	for _, axis in ipairs({"X","Y","Z"}) do
		if not validNumber(b.centerPos[axis]) or not validNumber(b.size[axis]) then return false end
		if b.size[axis]<1 or b.size[axis]>4096 or b.size[axis]%1~=0 then return false end
		-- Integer boundaries match the game's one-stud face changes. Fine cubes
		-- have half-integer centres; an even-size block has an integer centre.
		if math.abs((b.centerPos[axis]-b.size[axis]/2)-math.round(b.centerPos[axis]-b.size[axis]/2))>.001 then return false end
	end
	return true
end
function M.copy(b)
	local sprays={}
	for i,s in ipairs(b.sprays or {}) do sprays[i]={face=s.face,text=s.text,colorHex=s.colorHex} end
	return {size=b.size,centerPos=b.centerPos,color=b.color,material=b.material,canCollide=b.canCollide,sprays=sprays}
end
function M.overlaps(a,b)
	local d=a.centerPos-b.centerPos
	local h=(a.size+b.size)/2
	return math.abs(d.X)<h.X-.001 and math.abs(d.Y)<h.Y-.001 and math.abs(d.Z)<h.Z-.001
end
function M.resize(b,face,delta)
	local n=Vector3.FromNormalId(face)
	local axis=Vector3.new(math.abs(n.X),math.abs(n.Y),math.abs(n.Z))
	local next=M.copy(b)
	next.size=b.size+axis*delta
	next.centerPos=b.centerPos+n*delta/2
	if not M.valid(next) then return nil end
	return next
end
function M.place(point,normal,step)
	local p=point+normal*(step/2-.0001)
	return Vector3.new(math.floor(p.X/step)*step+step/2,math.floor(p.Y/step)*step+step/2,math.floor(p.Z/step)*step+step/2)
end
function M.clone(b,face)
	local next=M.copy(b)
	next.centerPos=b.centerPos+Vector3.FromNormalId(face)*b.size
	return next
end
return M

	end)()
	local History=(function()
local H={undo={},redo={},bytes=0,limit=8*1024*1024,count=80}
function H.valid(s)
	if type(s)~="table" or type(s.tabs)~="table" or #s.tabs<1 or #s.tabs>500 then return false end
	if type(s.active)~="number" or s.active%1~=0 or s.active<1 or s.active>#s.tabs then return false end
	for _,t in ipairs(s.tabs) do
		if type(t)~="table" or type(t.name)~="string" or type(t.content)~="string" then return false end
		if t.id~=nil and (type(t.id)~="string" or #t.id>200) then return false end
		if t.rotationPivot~=nil then
			if type(t.rotationPivot)~="table" then return false end
			for _,k in ipairs({"X","Z"}) do local n=t.rotationPivot[k] if type(n)~="number" or n~=n or math.abs(n)>1000000 then return false end end
		end
		if t.placement~=nil then
			if type(t.placement)~="table" or #t.placement~=3 then return false end
			for _,n in ipairs(t.placement) do if type(n)~="number" or n~=n or math.abs(n)>1000000 then return false end end
		end
	end
	return true
end
function H.clone(s)
	local next={tabs={},active=s.active}
	for i,t in ipairs(s.tabs) do
		next.tabs[i]={id=t.id,name=t.name,content=t.content,rotationPivot=t.rotationPivot and {X=t.rotationPivot.X,Z=t.rotationPivot.Z} or nil,placement=t.placement and {t.placement[1],t.placement[2],t.placement[3]} or nil}
	end
	return next
end
function H.size(s)
	local bytes=64
	for _,t in ipairs(s.tabs) do bytes+=#t.name+#t.content+64 end
	return bytes
end
function H.equal(a,b)
	if #a.tabs~=#b.tabs then return false end
	for i,t in ipairs(a.tabs) do
		if t.name~=b.tabs[i].name or t.content~=b.tabs[i].content then return false end
	end
	return true -- Selecting a tab alone is not a history operation.
end
function H.trim()
	H.bytes=0
	for _,stack in ipairs({H.undo,H.redo}) do for _,s in ipairs(stack) do H.bytes+=H.size(s) end end
	while #H.undo+#H.redo>H.count or H.bytes>H.limit do
		local stack=#H.undo>0 and H.undo or H.redo
		if #stack==0 then break end
		H.bytes-=H.size(table.remove(stack,1))
	end
end
function H.record(before,after)
	if H.equal(before,after) then return false end
	H.undo[#H.undo+1]=H.clone(before)
	table.clear(H.redo)
	H.trim()
	return true
end
function H.take(direction,current)
	local from=direction=="undo" and H.undo or H.redo
	local to=direction=="undo" and H.redo or H.undo
	if #from==0 then return nil end
	local snapshot=table.remove(from)
	to[#to+1]=H.clone(current)
	H.trim()
	return H.clone(snapshot)
end
function H.load(decoded,current)
	if type(decoded)~="table" or decoded.version~=4 or not H.valid(decoded.current) or not H.equal(decoded.current,current) then return false end
	for _,name in ipairs({"undo","redo"}) do
		local clean={}
		if type(decoded[name])=="table" then
			for _,s in ipairs(decoded[name]) do if H.valid(s) then clean[#clean+1]=H.clone(s) end end
		end
		H[name]=clean
	end
	H.trim()
	return true
end
return H

	end)()
	local mode="welcome"
	local activeTool=nil
	local tools={}
	local scene=create("Folder",{Name="Autobuild_Imaginary_"..LocalPlayer.UserId,Parent=workspace})
	local parts,order,selected,highlights={},{},{},{}
	local updatingScene=false
	local sceneLoading=false
	local sceneInvalid=false
	local pendingContent=nil
	local loadedOffset=nil
	local sceneRevision=0
	local small=false
	local sizeDecrease=false
	local copyStyle=true
	local allowOverlap=false
	local paintMode="both"
	local paintColor=Color3.fromRGB(192,192,192)
	local paintMaterial=Enum.Material.Plastic
	local paintCollide=true
	local paintText=""
	local paintTextHex="FFFFFF"
	local codeOpen=false
	local moreOpen=false
	local held=false
	local visited={}
	local pressPoint=nil
	local mouse=LocalPlayer:GetMouse()
	local loadedContent=nil
	local lastContentTab=nil
	local loadedTabId=nil
	local mutedHistory=false
	local historyFile="AutobuildStudioHistory-v4.json"
	local function snapshot()
		return History.clone({tabs=tabsData,active=activeTabIndex})
	end
	local baseline=snapshot()
	if isfile and readfile then
		pcall(function()
			if isfile(historyFile) then local recovered=HttpService:JSONDecode(readfile(historyFile))
				PlanLibrary.migrateHistory(recovered) History.load(recovered,baseline) end
		end)
	end
	local function persistHistory()
		if not writefile then return end
		local ok=pcall(function()
			writefile(historyFile,HttpService:JSONEncode({version=4,current=snapshot(),undo=History.undo,redo=History.redo}))
		end)
		if not ok then if unloaded then error("История отмены не записана",0) end setStatus("Вкладки сохранены; история отмены не записана",true) end
	end
	local function remember()
		local current=snapshot()
		if not mutedHistory and History.record(baseline,current) then persistHistory() end
		baseline=current
	end
	StudioHooks.save=remember
	local View=(function()
-- ORBIT: the window, navigation and inspector are rebuilt as one UI.
local UI={}
local Fonts={regular=Font.new("rbxasset://fonts/families/Montserrat.json",Enum.FontWeight.Regular,Enum.FontStyle.Normal),medium=Font.new("rbxasset://fonts/families/Montserrat.json",Enum.FontWeight.Medium,Enum.FontStyle.Normal),strong=Font.new("rbxasset://fonts/families/Montserrat.json",Enum.FontWeight.SemiBold,Enum.FontStyle.Normal),code=Font.new("rbxasset://fonts/families/Inconsolata.json",Enum.FontWeight.Regular,Enum.FontStyle.Normal)}
local themes={
	create={base=Color3.fromRGB(12,13,23),deep=Color3.fromRGB(15,17,29),panel=Color3.fromRGB(21,23,38),hover=Color3.fromRGB(31,32,51),accent=Color3.fromRGB(177,147,255),primary=Color3.fromRGB(116,78,222),soft=Color3.fromRGB(33,25,56),line=Color3.fromRGB(46,47,68),muted=Color3.fromRGB(128,134,161),text=Color3.fromRGB(237,239,251)},
	load={base=Color3.fromRGB(12,13,23),deep=Color3.fromRGB(15,17,29),panel=Color3.fromRGB(21,23,38),hover=Color3.fromRGB(31,32,51),accent=Color3.fromRGB(239,205,146),primary=Color3.fromRGB(137,99,41),soft=Color3.fromRGB(25,24,45),line=Color3.fromRGB(46,47,68),muted=Color3.fromRGB(128,134,161),text=Color3.fromRGB(237,239,251)},
}
local palette=themes.create
local roles=setmetatable({},{__mode="k"})
local themedGradients={}
local settings={stars=true,width=820,height=560}
if isfile and readfile then pcall(function() if isfile("AutobuildAppearance.json") then local v=HttpService:JSONDecode(readfile("AutobuildAppearance.json")) if type(v)=="table" then
	settings.stars=v.stars~=false
	if type(v.width)=="number" and v.width==v.width then settings.width=math.clamp(v.width,740,1600) end
	if type(v.height)=="number" and v.height==v.height then settings.height=math.clamp(v.height,520,1000) end
end end end) end
local function saveAppearance() if writefile then pcall(function() writefile("AutobuildAppearance.json",HttpService:JSONEncode(settings)) end) end end
normalSize=UDim2.fromOffset(settings.width,settings.height)
minimizedSize=UDim2.fromOffset(settings.width,46)
if openTween then openTween:Cancel() end
mainFrame.Size=normalSize bodyFrame.Visible=true
local stars={}
local function style(o)
	if not o:IsDescendantOf(gui) or o:GetAttribute("StudioFixedColor") then return end
	if o:IsA("GuiObject") then
		o.BorderSizePixel=0
		local r=roles[o]
		if not r then
			local c=o.BackgroundColor3
			r={bg=c==C_BLACK and "base" or c==C_GRAY and "panel" or c==C_LIGHT_GRAY and "hover" or nil,text="text"}
			roles[o]=r
		end
		local bg=o:GetAttribute("NovaBackground") or r.bg
		if bg and palette[bg] then o.BackgroundColor3=palette[bg] end
		if o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox") then
			local role=o:GetAttribute("NovaText") or r.text
			o.TextColor3=role=="white" and Color3.fromRGB(255,255,255) or palette[role] or palette.text
			o.FontFace=Fonts[o:GetAttribute("NovaFont") or (o:IsA("TextButton") and "medium" or "regular")]
		end
		if o:IsA("TextBox") then o.PlaceholderColor3=palette.muted end
		if o:IsA("ScrollingFrame") then o.ScrollBarImageColor3=palette.line end
	elseif o:IsA("UIStroke") then o.Color=palette[o:GetAttribute("NovaStroke") or "line"] o.Thickness=1 end
end
local function skin(o,bg,text,font)
	if bg then o:SetAttribute("NovaBackground",bg) end
	if text then o:SetAttribute("NovaText",text) end
	if font then o:SetAttribute("NovaFont",font) end
	style(o) return o
end
local function corners(o,radius)
	local found=o:FindFirstChildOfClass("UICorner")
	if found then found.CornerRadius=UDim.new(0,radius) else addCorner(o,radius) end
end
local function stroke(o)
	return o:FindFirstChildOfClass("UIStroke") or addStroke(o,1,palette.line)
end
local function label(parent,text,pos,size,fontSize,role,font)
	local l=create("TextLabel",{Parent=parent,BackgroundTransparency=1,Position=pos,Size=size,Text=text,TextSize=fontSize or 12,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center,TextColor3=C_WHITE,FontFace=Fonts.regular})
	return skin(l,nil,role or "text",font or "regular")
end
local function button(parent,text,pos,size,bg)
	local b=create("TextButton",{Parent=parent,Position=pos,Size=size,Text=text,TextSize=12,TextWrapped=false,BackgroundColor3=C_GRAY,TextColor3=C_WHITE,FontFace=Fonts.medium,AutoButtonColor=false})
	corners(b,7) skin(b,bg or "panel",bg=="primary" and "white" or "text","medium")
	if bg~="primary" then stroke(b) end
	return b
end
local function field(parent,text,pos,size)
	local f=create("TextBox",{Parent=parent,Text=text,Position=pos,Size=size,BackgroundColor3=C_BLACK,TextColor3=C_WHITE,ClearTextOnFocus=false,FontFace=Fonts.code,TextSize=13})
	corners(f,6) stroke(f) return skin(f,"deep","text","code")
end
local function line(parent,a,b,color,width,z)
	local delta=b-a
	local o=create("Frame",{Parent=parent,AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromOffset((a.X+b.X)/2,(a.Y+b.Y)/2),Size=UDim2.fromOffset(delta.Magnitude,width or 1.5),Rotation=math.deg(math.atan2(delta.Y,delta.X)),BackgroundColor3=color,BorderSizePixel=0,ZIndex=z or 3})
	o:SetAttribute("StudioFixedColor",true) return o
end
local function icon(parent,kind,pos,size,color)
	local art=create("Frame",{Name="Icon_"..kind,Parent=parent,Position=pos,Size=UDim2.fromOffset(size,size),BackgroundTransparency=1})
	local function edge(x1,y1,x2,y2) return line(art,Vector2.new(x1*size,y1*size),Vector2.new(x2*size,y2*size),color,1.5,parent.ZIndex or 3) end
	if kind=="cube" then
		for _,e in ipairs({{.5,.08,.9,.3},{.9,.3,.9,.72},{.9,.72,.5,.94},{.5,.94,.1,.72},{.1,.72,.1,.3},{.1,.3,.5,.08},{.1,.3,.5,.53},{.9,.3,.5,.53},{.5,.53,.5,.94}}) do edge(unpack(e)) end
	elseif kind=="load" then
		for _,e in ipairs({{.5,.1,.5,.66},{.3,.46,.5,.66},{.7,.46,.5,.66},{.12,.65,.12,.88},{.12,.88,.88,.88},{.88,.88,.88,.65}}) do edge(unpack(e)) end
	elseif kind=="paint" then
		edge(.2,.8,.64,.36) edge(.55,.15,.87,.47) edge(.55,.15,.34,.36) edge(.87,.47,.66,.68) edge(.34,.36,.66,.68)
	elseif kind=="size" then
		edge(.14,.5,.86,.5) edge(.14,.5,.32,.32) edge(.14,.5,.32,.68) edge(.86,.5,.68,.32) edge(.86,.5,.68,.68)
	elseif kind=="delete" then
		edge(.23,.27,.77,.27) edge(.32,.27,.36,.85) edge(.68,.27,.64,.85) edge(.36,.85,.64,.85) edge(.4,.14,.6,.14)
	elseif kind=="select" then
		for _,e in ipairs({{.15,.35,.15,.15},{.15,.15,.35,.15},{.65,.15,.85,.15},{.85,.15,.85,.35},{.15,.65,.15,.85},{.15,.85,.35,.85},{.65,.85,.85,.85},{.85,.85,.85,.65}}) do edge(unpack(e)) end
	elseif kind=="settings" then
		for i=1,3 do local y=i*.24 edge(.15,y,.85,y) edge(i==2 and .65 or .35,y-.1,i==2 and .65 or .35,y+.1) end
	elseif kind=="undo" or kind=="redo" then
		for _,e in ipairs({{.42,.18,.16,.4},{.16,.4,.42,.6},{.16,.4,.7,.4},{.7,.4,.84,.58},{.84,.58,.8,.75},{.8,.75,.64,.83}}) do
			if kind=="redo" then e={1-e[1],e[2],1-e[3],e[4]} end edge(unpack(e))
		end
	elseif kind=="chevron" then edge(.2,.35,.5,.65) edge(.5,.65,.8,.35)
	elseif kind=="orbit" then
		for i=1,2 do
			local ring=create("Frame",{Parent=art,AnchorPoint=Vector2.new(.5,.5),Position=UDim2.fromScale(.5,.5),Size=UDim2.fromOffset(size*.94,size*.48),Rotation=i==1 and 35 or -35,BackgroundTransparency=1})
			corners(ring,size) local s=stroke(ring) s.Color=color s:SetAttribute("StudioFixedColor",true)
		end
		local dot=create("Frame",{Parent=art,Position=UDim2.fromScale(.41,.41),Size=UDim2.fromScale(.18,.18),BackgroundColor3=color,BorderSizePixel=0}) dot:SetAttribute("StudioFixedColor",true) corners(dot,size)
	end
	return art
end
local function bindHover(b)
	if b:GetAttribute("NovaHoverBound") then return end
	b:SetAttribute("NovaHoverBound",true)
	trackConn(b.MouseEnter:Connect(function()
		local primary=b:GetAttribute("NovaBackground")=="primary"
		TweenService:Create(b,TweenInfo.new(.13),{BackgroundColor3=primary and palette.primary:Lerp(palette.accent,.15) or palette.hover}):Play()
	end))
	trackConn(b.MouseLeave:Connect(function() style(b) end))
end
function UI.applyTheme(which)
	palette=themes[which] or themes.create
	for _,o in ipairs(gui:GetDescendants()) do style(o) end
	C_BLACK=palette.base C_GRAY=palette.panel C_LIGHT_GRAY=palette.hover C_GREEN=palette.accent C_DARK_GREEN=palette.line C_WHITE=palette.text
	for _,g in ipairs(themedGradients) do g.Color=ColorSequence.new(palette.soft,palette.base) end
	borderGradient.Color=ColorSequence.new(palette.line)
end
for _,o in ipairs(gui:GetDescendants()) do style(o) end
UI.applyTheme("create") StudioHooks.style=style
mainStroke.Thickness=1 corners(mainFrame,12)
gui.IgnoreGuiInset=true
header.Size=UDim2.new(1,0,0,46)
bodyFrame.Position=UDim2.fromOffset(0,46) bodyFrame.Size=UDim2.new(1,0,1,-46)
skin(mainFrame,"base")
local backdrop=create("UIGradient",{Parent=mainFrame,Rotation=24,Color=ColorSequence.new(palette.soft,palette.base)}) themedGradients[#themedGradients+1]=backdrop
title.Text="ORBIT" title.Position=UDim2.fromOffset(50,0) title.Size=UDim2.fromOffset(86,46) title.TextSize=16 skin(title,nil,"text","strong")
icon(header,"orbit",UDim2.fromOffset(19,12),22,Color3.fromRGB(179,151,255))
label(header,"BUILD STUDIO",UDim2.fromOffset(134,0),UDim2.fromOffset(138,46),10,"muted","medium")
UI.homeBtn=button(header,"",UDim2.fromOffset(14,4),UDim2.fromOffset(113,38),"base") UI.homeBtn.BackgroundTransparency=1
local homeStroke=UI.homeBtn:FindFirstChildOfClass("UIStroke") if homeStroke then homeStroke:Destroy() end
for _,b in ipairs({btnMin,btnMax,btnClose}) do b.Size=UDim2.fromOffset(28,28) corners(b,5) b.BackgroundTransparency=1 skin(b,"hover",b==btnClose and "text" or "muted") bindHover(b) end
local scale=create("UIScale",{Parent=mainFrame,Scale=1})
local resizing=nil
local function fit()
	if resizing then return end
	local camera=workspace.CurrentCamera
	if camera then local size=isMaximized and fullSize or normalSize scale.Scale=math.min(1,(camera.ViewportSize.X-24)/size.X.Offset,(camera.ViewportSize.Y-24)/size.Y.Offset) end
end
local fitClock=0
trackConn(RunService.RenderStepped:Connect(function(dt) fitClock+=dt if fitClock>.5 then fitClock=0 fit() end end)) fit()
local rail=create("Frame",{Name="Navigation",Parent=bodyFrame,Size=UDim2.new(0,84,1,0),BackgroundTransparency=1})
local divider=create("Frame",{Parent=rail,Position=UDim2.new(1,-1,0,0),Size=UDim2.new(0,1,1,0),BackgroundColor3=palette.line,BorderSizePixel=0}) skin(divider,"line")
UI.createModeBtn=button(rail,"Творить",UDim2.fromOffset(8,23),UDim2.fromOffset(68,70),"base")
UI.loadModeBtn=button(rail,"Грузить",UDim2.fromOffset(8,104),UDim2.fromOffset(68,70),"base")
UI.extrasModeBtn=button(rail,"Приколы",UDim2.fromOffset(8,185),UDim2.fromOffset(68,70),"base") UI.extrasModeBtn.Name="ExtrasMode"
local settingsBtn=button(rail,"Настр.",UDim2.fromOffset(8,266),UDim2.fromOffset(68,70),"base")
local consoleBtn=button(rail,"Журнал",UDim2.new(0,8,1,-91),UDim2.fromOffset(68,70),"base")
for _,pair in ipairs({{UI.createModeBtn,"cube"},{UI.loadModeBtn,"load"},{UI.extrasModeBtn,"orbit"},{settingsBtn,"settings"}}) do
	local b=pair[1] b.TextSize=10 b.TextYAlignment=Enum.TextYAlignment.Bottom create("UIPadding",{Parent=b,PaddingBottom=UDim.new(0,10)}) icon(b,pair[2],UDim2.fromOffset(22,13),24,Color3.fromRGB(158,160,191))
end
label(consoleBtn,"≡",UDim2.fromOffset(0,7),UDim2.new(1,0,0,28),24,"muted").TextXAlignment=Enum.TextXAlignment.Center
consoleBtn.TextSize=10 consoleBtn.TextYAlignment=Enum.TextYAlignment.Bottom create("UIPadding",{Parent=consoleBtn,PaddingBottom=UDim.new(0,10)})
local modeBar=create("Frame",{Parent=bodyFrame,Position=UDim2.fromOffset(108,6),Size=UDim2.new(1,-128,0,36),BackgroundTransparency=1})
local screenTitle=label(modeBar,"Рабочее пространство",UDim2.new(),UDim2.new(1,-240,1,0),15,"text","strong")
UI.undoBtn=button(modeBar,"↶",UDim2.new(1,-174,0,3),UDim2.fromOffset(30,30),"deep")
UI.redoBtn=button(modeBar,"↷",UDim2.new(1,-136,0,3),UDim2.fromOffset(30,30),"deep")
UI.undoBtn.Text="" UI.redoBtn.Text=""
icon(UI.undoBtn,"undo",UDim2.fromOffset(7,7),16,Color3.fromRGB(156,157,187))
icon(UI.redoBtn,"redo",UDim2.fromOffset(7,7),16,Color3.fromRGB(156,157,187))
UI.codeBtn=button(modeBar,"Код",UDim2.new(1,-98,0,3),UDim2.fromOffset(98,30),"deep")
tabSection.Position=UDim2.fromOffset(108,50) tabSection.Size=UDim2.new(1,-128,0,32)
editorFrame.Position=UDim2.fromOffset(108,92) editorFrame.Size=UDim2.new(1,-376,1,-194) skin(editorFrame,"deep") corners(editorFrame,8)
sideContainer.Position=UDim2.new(1,-248,0,92) sideContainer.Size=UDim2.new(0,228,1,-194) sideContainer.BackgroundTransparency=0 skin(sideContainer,"panel") corners(sideContainer,8)
for _,child in ipairs(sideContainer:GetChildren()) do if child:IsA("UIListLayout") then child:Destroy() end end
textScroll.Position=UDim2.fromOffset(10,42) textScroll.Size=UDim2.new(1,-20,1,-56) textScroll.ScrollBarThickness=3
textBox.Position=UDim2.fromOffset(38,0) textBox.TextSize=14 textBox.TextWrapped=false textBox.PlaceholderText="" textBox.TextXAlignment=Enum.TextXAlignment.Left textBox.TextYAlignment=Enum.TextYAlignment.Top skin(textBox,nil,"text","code")
local lineNumbers=label(textScroll,"1",UDim2.new(),UDim2.fromOffset(28,28),14,"muted","code") lineNumbers.TextXAlignment=Enum.TextXAlignment.Right lineNumbers.TextYAlignment=Enum.TextYAlignment.Top
label(editorFrame,"BUILD DATA",UDim2.fromOffset(16,10),UDim2.fromOffset(110,20),10,"muted","medium")
local recordBadge=label(editorFrame,"0 деталей",UDim2.new(1,-136,0,10),UDim2.fromOffset(120,20),10,"muted") recordBadge.TextXAlignment=Enum.TextXAlignment.Right
local emptyState=create("Frame",{Parent=editorFrame,Position=UDim2.new(.5,-150,.5,-65),Size=UDim2.fromOffset(300,140),BackgroundTransparency=1})
icon(emptyState,"load",UDim2.fromOffset(127,0),46,Color3.fromRGB(110,113,146))
local emptyHeading=label(emptyState,"Начни с постройки",UDim2.fromOffset(0,64),UDim2.fromOffset(300,28),17,"text","strong") emptyHeading.TextXAlignment=Enum.TextXAlignment.Center
label(emptyState,"Вставь код или сохрани блоки игроков.",UDim2.fromOffset(0,100),UDim2.fromOffset(300,24),11,"muted").TextXAlignment=Enum.TextXAlignment.Center
local bottom=create("Frame",{Parent=bodyFrame,Position=UDim2.new(0,108,1,-94),Size=UDim2.new(1,-128,0,38),BackgroundTransparency=1})
local function place(b,parent,pos,size,caption,bg)
	b.Parent=parent b.Position=pos b.Size=size b.Text=caption b.TextSize=12 b.TextWrapped=false b.BackgroundTransparency=0 b.AutoButtonColor=false skin(b,bg or "panel",bg=="primary" and "white" or "text","medium") corners(b,7) bindHover(b)
end
place(btnPaste,bottom,UDim2.new(),UDim2.fromOffset(78,38),"Вставить")
place(btnCopy,bottom,UDim2.fromOffset(86,0),UDim2.fromOffset(78,38),"Копировать")
place(btnImport,bottom,UDim2.fromOffset(172,0),UDim2.fromOffset(106,38),"Предпросмотр")
place(btnStart,bottom,UDim2.new(1,-140,0,0),UDim2.fromOffset(140,38),"Строить","primary")
UI.planBtn=button(bottom,"План: Авто",UDim2.new(1,-286,0,0),UDim2.fromOffset(138,38),"deep") UI.planBtn.Name="ChoosePlan" UI.planBtn.TextTruncate=Enum.TextTruncate.AtEnd
UI.moreBtn=button(editorFrame,"···",UDim2.new(1,-46,0,6),UDim2.fromOffset(32,28),"deep")
recordBadge.Position=UDim2.new(1,-174,0,10)
UI.primary={btnStart,btnPaste,btnCopy,btnImport,btnToMe}
UI.pagePrevious=button(editorFrame,"‹",UDim2.fromOffset(16,36),UDim2.fromOffset(28,26),"deep") UI.pagePrevious.Name="DocumentPagePrevious"
UI.pageNext=button(editorFrame,"›",UDim2.fromOffset(50,36),UDim2.fromOffset(28,26),"deep") UI.pageNext.Name="DocumentPageNext"
UI.pageInfo=label(editorFrame,"",UDim2.fromOffset(88,39),UDim2.new(1,-104,0,20),10,"muted") UI.pageInfo.Name="DocumentPageInfo"
UI.pagePrevious.MouseButton1Click:Connect(function() if StudioHooks.documents then StudioHooks.documents.page(-1) end end)
UI.pageNext.MouseButton1Click:Connect(function() if StudioHooks.documents then StudioHooks.documents.page(1) end end)
local loadInspector=create("Frame",{Parent=sideContainer,Size=UDim2.new(1,0,0,470),BackgroundTransparency=1})
label(loadInspector,"ПОСТРОЙКА",UDim2.fromOffset(16,14),UDim2.new(1,-32,0,22),10,"muted","medium")
label(loadInspector,"Текущий / последний проблемный",UDim2.fromOffset(16,42),UDim2.new(1,-32,0,25),11,"muted","medium")
place(btnMode,loadInspector,UDim2.fromOffset(16,164),UDim2.new(1,-32,0,32),"Выбрать игроков","deep")
place(btnSave,loadInspector,UDim2.fromOffset(16,202),UDim2.new(1,-32,0,32),"Сохранить их блоки","deep")
label(loadInspector,"ТРАНСФОРМАЦИЯ",UDim2.fromOffset(16,249),UDim2.new(1,-32,0,20),10,"muted","medium")
place(btnSnap,loadInspector,UDim2.fromOffset(16,276),UDim2.new(1,-32,0,32),"Выровнять по сетке","deep")
for i,b in ipairs({btnRot90,btnRot180,btnRotNeg90}) do place(b,loadInspector,UDim2.new((i-1)/3,16-(i-1)*10.5,0,316),UDim2.new(1/3,-15,0,32),({"+90°","180°","−90°"})[i],"deep") end
place(btnToMe,loadInspector,UDim2.fromOffset(16,356),UDim2.new(1,-32,0,32),"Ко мне","deep")
UI.skipBtn=button(loadInspector,"Пропустить блок",UDim2.fromOffset(16,72),UDim2.new(1,-32,0,32),"deep")
UI.repairBtn=button(loadInspector,"Переделать проблемный",UDim2.fromOffset(16,110),UDim2.new(1,-32,0,32),"deep")
UI.skipBtn.MouseButton1Click:Connect(function() if StudioHooks.control then StudioHooks.control.skip() end end)
UI.repairBtn.MouseButton1Click:Connect(function() if StudioHooks.control then StudioHooks.control.repair() end end)
UI.guardBtn=button(loadInspector,"Защита: вкл",UDim2.fromOffset(16,152),UDim2.new(.5,-20,0,30),"deep") UI.guardBtn.TextSize=10
UI.clearObstaclesBtn=button(loadInspector,"Помехи: вкл",UDim2.new(.5,4,0,152),UDim2.new(.5,-20,0,30),"deep") UI.clearObstaclesBtn.TextSize=10
local function guardButtons()
	local g=StudioHooks.guard
	UI.guardBtn.Text="Защита: "..((not g or g.enabled) and "вкл" or "выкл")
	UI.clearObstaclesBtn.Text="Помехи: "..((not g or g.clear) and "вкл" or "выкл")
end
UI.guardBtn.MouseButton1Click:Connect(function() local g=StudioHooks.guard if g then g.set("enabled",not g.enabled) guardButtons() end end)
UI.clearObstaclesBtn.MouseButton1Click:Connect(function() local g=StudioHooks.guard if g then g.set("clear",not g.clear) guardButtons() end end)
guardButtons()
for _,child in ipairs(loadInspector:GetChildren()) do
	if child:IsA("GuiObject") and child.Position.Y.Offset>=164 then child.Position=UDim2.new(child.Position.X.Scale,child.Position.X.Offset,child.Position.Y.Scale,child.Position.Y.Offset+34) end
end
loadInspector.Size=UDim2.new(1,0,0,504)
local menu=create("Frame",{Name="MoreActions",Parent=bodyFrame,Position=UDim2.new(1,-448,0,134),Size=UDim2.fromOffset(200,86),BackgroundColor3=C_GRAY,Visible=false,ZIndex=25}) skin(menu,"panel") corners(menu,8) stroke(menu)
place(btnClear,menu,UDim2.fromOffset(8,8),UDim2.new(1,-16,0,31),"Очистить код","deep") btnClear.ZIndex=26
place(btnLog,menu,UDim2.fromOffset(8,47),UDim2.new(1,-16,0,31),"Скопировать журнал","deep") btnLog.ZIndex=26
UI.extra={btnClear,btnLog}
place(btnNextChunk,modeBar,UDim2.new(1,-284,0,3),UDim2.fromOffset(102,30),"Следующая часть","deep") btnNextChunk.Visible=false
UI.creator=create("Frame",{Name="CreationWorkspace",Parent=bodyFrame,Position=editorFrame.Position,Size=editorFrame.Size,BackgroundColor3=C_GRAY,Visible=false}) skin(UI.creator,"deep") corners(UI.creator,8) stroke(UI.creator)
UI.editorTools=create("Frame",{Parent=UI.creator,Position=UDim2.fromOffset(12,14),Size=UDim2.new(1,-24,0,40),BackgroundTransparency=1})
UI.toolNames={"mbuild","mpaint","mdelete","msize","mchoose"}
UI.toolLabels={mbuild="Блок",mpaint="Цвет",mdelete="Удалить",msize="Размер",mchoose="Выбрать"}
UI.toolButtons={}
for i,name in ipairs(UI.toolNames) do
	local b=button(UI.editorTools,UI.toolLabels[name],UDim2.new((i-1)/5,0,0,0),UDim2.new(1/5,-5,1,0),"panel") b.TextSize=11 b.TextXAlignment=Enum.TextXAlignment.Right create("UIPadding",{Parent=b,PaddingRight=UDim.new(0,8)})
	icon(b,({"cube","paint","delete","size","select"})[i],UDim2.fromOffset(9,11),18,Color3.fromRGB(171,157,218)) UI.toolButtons[name]=b
end
UI.sceneStats=label(UI.creator,"0 деталей",UDim2.fromOffset(16,64),UDim2.new(1,-32,0,22),11,"muted")
UI.selectionStats=label(sideContainer,"Выбрано: 0",UDim2.fromOffset(16,44),UDim2.new(1,-32,0,22),11,"muted")
UI.toolHint=label(UI.creator,"Выбери инструмент сверху или в инвентаре.",UDim2.new(0,16,1,-48),UDim2.new(1,-32,0,36),11,"muted")
local viewport=create("ViewportFrame",{Name="SceneOverview",Parent=UI.creator,Position=UDim2.fromOffset(12,98),Size=UDim2.new(1,-24,1,-154),BackgroundColor3=palette.panel,Ambient=Color3.fromRGB(190,177,225),LightColor=Color3.fromRGB(231,220,255),LightDirection=Vector3.new(-1,-1,-1)}) skin(viewport,"panel") corners(viewport,7)
local previewWorld=create("WorldModel",{Parent=viewport})
local previewCamera=create("Camera",{Parent=viewport,FieldOfView=42}) viewport.CurrentCamera=previewCamera
local overviewEmpty=label(viewport,"Твоя мастерская",UDim2.new(.5,-150,.5,-20),UDim2.fromOffset(300,40),19,"muted","strong") overviewEmpty.TextXAlignment=Enum.TextXAlignment.Center
local creatorInspector=create("Frame",{Parent=sideContainer,Size=UDim2.new(1,0,0,570),BackgroundTransparency=1,Visible=false})
label(creatorInspector,"СВОЙСТВА",UDim2.fromOffset(16,14),UDim2.new(1,-32,0,22),10,"muted","medium")
UI.selectionStats.Parent=creatorInspector
UI.toolOptions=create("Frame",{Parent=creatorInspector,Position=UDim2.fromOffset(16,80),Size=UDim2.new(1,-32,0,410),BackgroundTransparency=1})
UI.buildToggle=button(UI.toolOptions,"Куб 4 × 4 × 4 · R",UDim2.new(),UDim2.new(1,0,0,34),"deep")
UI.sizeToggle=button(UI.toolOptions,"Увеличить грань · R",UDim2.fromOffset(0,42),UDim2.new(1,0,0,34),"deep")
UI.copyToggle=button(UI.toolOptions,"Копировать деталь: да",UDim2.fromOffset(0,84),UDim2.new(1,0,0,34),"deep")
UI.overlapToggle=button(UI.toolOptions,"Пересечения: нет",UDim2.fromOffset(0,126),UDim2.new(1,0,0,34),"deep")
local colorCaption=label(UI.toolOptions,"ЦВЕТ HEX",UDim2.fromOffset(0,176),UDim2.new(1,0,0,20),10,"muted","medium")
UI.hexField=field(UI.toolOptions,"C0C0C0",UDim2.fromOffset(0,204),UDim2.new(1,-44,0,34))
UI.swatch=create("Frame",{Parent=UI.toolOptions,BackgroundColor3=Color3.fromRGB(192,192,192),Position=UDim2.new(1,-34,0,204),Size=UDim2.fromOffset(34,34)}) UI.swatch:SetAttribute("StudioFixedColor",true) corners(UI.swatch,6)
UI.materialButton=button(UI.toolOptions,"Материал: Plastic",UDim2.fromOffset(0,246),UDim2.new(1,0,0,34),"deep") UI.materialButton.TextSize=11
icon(UI.materialButton,"chevron",UDim2.new(1,-22,0,10),14,Color3.fromRGB(141,145,173))
UI.paintModeButton=button(UI.toolOptions,"Покраска: цвет + материал",UDim2.fromOffset(0,288),UDim2.new(1,0,0,34),"deep") UI.paintModeButton.TextSize=10
UI.collideToggle=button(UI.toolOptions,"Collide в коде: включён",UDim2.fromOffset(0,330),UDim2.new(1,0,0,34),"deep") UI.collideToggle.TextSize=10
UI.sprayField=field(UI.toolOptions,"",UDim2.fromOffset(0,372),UDim2.new(1,0,0,34)) UI.sprayField.PlaceholderText="Текст на грани"
UI.sprayColorField=field(UI.toolOptions,"FFFFFF",UDim2.fromOffset(0,414),UDim2.new(1,0,0,34))
creatorInspector.Size=UDim2.new(1,0,0,556)
UI.materialList=create("ScrollingFrame",{Name="Materials",Parent=bodyFrame,Position=UDim2.new(1,-244,0,170),Size=UDim2.fromOffset(220,330),BackgroundColor3=C_BLACK,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=3,Visible=false,ZIndex=35}) skin(UI.materialList,"deep") corners(UI.materialList,8) stroke(UI.materialList)
create("UIListLayout",{Parent=UI.materialList,Padding=UDim.new(0,3)})
local materials={} for m in pairs(MaterialSymbols) do materials[#materials+1]=m end table.sort(materials,function(a,b) return a.Name<b.Name end)
UI.materialChoices={}
for _,m in ipairs(materials) do local b=button(UI.materialList,m.Name,UDim2.new(),UDim2.new(1,-5,0,32),"deep") b.ZIndex=36 UI.materialChoices[m]=b end
UI.selectionCopy=button(bottom,"Копировать выбор",UDim2.new(),UDim2.fromOffset(154,38),"panel")
UI.selectionClear=button(bottom,"Снять выбор",UDim2.fromOffset(162,0),UDim2.fromOffset(118,38),"panel")
UI.toCodeBtn=button(bottom,"Выделенное → вкладка",UDim2.new(1,-218,0,0),UDim2.fromOffset(218,38),"primary")
UI.welcome=create("Frame",{Name="Welcome",Parent=bodyFrame,Position=UDim2.fromOffset(84,0),Size=UDim2.new(1,-84,1,0),BackgroundColor3=C_BLACK,ZIndex=20}) skin(UI.welcome,"base")
local welcomeGradient=create("UIGradient",{Parent=UI.welcome,Rotation=35,Color=ColorSequence.new(palette.soft,palette.base)}) themedGradients[#themedGradients+1]=welcomeGradient
local bigHeading=label(UI.welcome,"Одна идея.\nЦелый мир.",UDim2.fromOffset(36,40),UDim2.new(1,-72,0,94),34,"text","strong") bigHeading.ZIndex=22 bigHeading.TextYAlignment=Enum.TextYAlignment.Top
local subHeading=label(UI.welcome,"Построй с нуля или загрузи то, что уже придумал.",UDim2.fromOffset(38,143),UDim2.new(1,-76,0,28),13,"muted") subHeading.ZIndex=22
for i=1,36 do
	local size=i%9==0 and 3 or 2
	local s=create("Frame",{Parent=UI.welcome,Position=UDim2.new(((i*73)%997)/997,0,((i*47)%311)/311,0),Size=UDim2.fromOffset(size,size),BackgroundColor3=Color3.fromRGB(150,142,192),BackgroundTransparency=.45+(i%4)*.1,BorderSizePixel=0,ZIndex=21}) s:SetAttribute("StudioFixedColor",true) corners(s,3) stars[#stars+1]=s s.Visible=settings.stars
end
for i=1,3 do
	local r=create("Frame",{Parent=UI.welcome,AnchorPoint=Vector2.new(.5,.5),Position=UDim2.new(.87,0,.15,0),Size=UDim2.fromOffset(140+i*48,58+i*19),Rotation=-31+i*12,BackgroundTransparency=1,ZIndex=21}) corners(r,200)
	local s=stroke(r) s:SetAttribute("StudioFixedColor",true) s.Color=Color3.fromRGB(68,53,109) s.Transparency=.35
end
UI.cards={}
for i,which in ipairs({"create","load"}) do
	local b=button(UI.welcome,"",UDim2.new((i-1)*.5,36-(i-1)*20,0,200),UDim2.new(.5,-52,1,-276),"panel") b.Name="NovaCard_"..which b.ZIndex=22 corners(b,12)
	local ink=which=="create" and Color3.fromRGB(189,158,255) or Color3.fromRGB(239,205,146)
	local art=icon(b,which=="create" and "cube" or "load",UDim2.fromOffset(25,20),44,ink)
	for _,o in ipairs(art:GetDescendants()) do if o:IsA("GuiObject") then o.ZIndex=23 end end
	local tag=label(b,which=="create" and "WORKSPACE" or "LOADER",UDim2.new(1,-120,0,30),UDim2.fromOffset(94,24),9,"muted","medium") tag.ZIndex=23 tag.TextXAlignment=Enum.TextXAlignment.Right
	local h=label(b,which=="create" and "Творить" or "Грузить",UDim2.fromOffset(26,84),UDim2.new(1,-52,0,34),24,"text","strong") h.ZIndex=23
	local d=label(b,which=="create" and "Мнимый bkit. Твои детали,\nцвета и формы." or "Готовый код. Маршрут\nс проверкой каждого блока.",UDim2.fromOffset(26,126),UDim2.new(1,-52,0,48),12,"muted") d.ZIndex=23
	local arrow=label(b,"→",UDim2.new(1,-54,1,-48),UDim2.fromOffset(26,28),20,"accent") arrow.ZIndex=23
	UI.cards[which]=b
end
local welcomeFoot=label(UI.welcome,"R — режим инструмента     Ctrl + Z — отмена     Right Shift — скрыть окно",UDim2.new(0,38,1,-63),UDim2.new(1,-76,0,26),10,"muted") welcomeFoot.ZIndex=22
footerFrame.Position=UDim2.new(0,108,1,-46) footerFrame.Size=UDim2.new(1,-128,0,40)
statDisplay.Size=UDim2.new(.65,0,0,18) statDisplay.TextSize=10 statDisplay.TextXAlignment=Enum.TextXAlignment.Left skin(statDisplay,nil,"muted")
perfDisplay.Position=UDim2.new(.65,0,0,0) perfDisplay.Size=UDim2.new(.35,0,0,18) perfDisplay.TextSize=10 perfDisplay.TextXAlignment=Enum.TextXAlignment.Right skin(perfDisplay,nil,"muted")
statusLabel.Text="" statusLabel.Visible=false statusLabel.Active=false
local console=create("Frame",{Name="ConsoleDrawer",Parent=bodyFrame,Position=UDim2.new(0,108,1,-292),Size=UDim2.new(1,-128,0,188),BackgroundColor3=C_GRAY,Visible=false,ZIndex=40}) skin(console,"panel") corners(console,8) stroke(console)
local consoleTitle=label(console,"ЖУРНАЛ",UDim2.fromOffset(14,8),UDim2.fromOffset(160,22),10,"muted","medium") consoleTitle.ZIndex=41
local closeConsole=button(console,"×",UDim2.new(1,-38,0,6),UDim2.fromOffset(28,26),"deep") closeConsole.ZIndex=41
local consoleScroll=create("ScrollingFrame",{Parent=console,Position=UDim2.fromOffset(12,38),Size=UDim2.new(1,-24,1,-50),BackgroundTransparency=1,CanvasSize=UDim2.new(),ScrollBarThickness=3,ZIndex=41})
local consoleText=create("TextBox",{Parent=consoleScroll,Position=UDim2.new(),Size=UDim2.new(1,0,1,0),Text="",BackgroundTransparency=1,TextEditable=false,MultiLine=true,ClearTextOnFocus=false,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,FontFace=Fonts.code,TextColor3=C_WHITE,TextSize=11,ZIndex=42}) skin(consoleText,nil,"muted","code")
local function refreshConsole()
	consoleText.Text=table.concat(diagnosticLog,"\n")
	local columns=math.max(30,math.floor(consoleScroll.AbsoluteSize.X/6)) local rows=0
	for l in consoleText.Text:gmatch("[^\n]+") do rows+=math.max(1,math.ceil(#l/columns)) end
	local height=math.max(138,rows*16)
	consoleText.Size=UDim2.new(1,0,0,height) consoleScroll.CanvasSize=UDim2.fromOffset(0,height) consoleScroll.CanvasPosition=Vector2.new(0,math.max(0,height-138))
end
StudioHooks.status=function() if console.Visible then refreshConsole() end end
local function toggleConsole() console.Visible=not console.Visible if console.Visible then refreshConsole() end end
trackConn(consoleBtn.MouseButton1Click:Connect(toggleConsole)) trackConn(closeConsole.MouseButton1Click:Connect(function() console.Visible=false end))
local appearance=create("ScrollingFrame",{Name="Appearance",Parent=bodyFrame,Position=UDim2.fromOffset(108,50),Size=UDim2.new(1,-128,1,-108),CanvasSize=UDim2.fromOffset(0,390),ScrollBarThickness=4,BackgroundColor3=C_GRAY,Visible=false}) skin(appearance,"deep") corners(appearance,8)
label(appearance,"Настройки",UDim2.fromOffset(28,16),UDim2.new(1,-56,0,34),22,"text","strong")
label(appearance,"Множитель пинга · от 1,2× до 3×",UDim2.fromOffset(28,60),UDim2.new(1,-56,0,25),13,"text")
local pingMinus=button(appearance,"−",UDim2.fromOffset(28,92),UDim2.fromOffset(42,34)) pingMinus.Name="PingMinus"
local pingValue=field(appearance,"2.0",UDim2.fromOffset(78,92),UDim2.fromOffset(92,34)) pingValue.Name="PingMultiplier"
local pingPlus=button(appearance,"+",UDim2.fromOffset(178,92),UDim2.fromOffset(42,34)) pingPlus.Name="PingPlus"
local pingInfo=label(appearance,"",UDim2.fromOffset(28,136),UDim2.new(1,-56,0,30),12,"muted")
local function refreshPing()
	pingValue.Text=string.format("%.1f",StudioHooks.timing.multiplier)
	pingInfo.Text=StudioHooks.timing.summary()
end
local function changePing(value)
	if StudioHooks.timing.set(value) then setStatus("Темп: "..StudioHooks.timing.summary()) end refreshPing()
end
trackConn(pingMinus.MouseButton1Click:Connect(function() changePing(StudioHooks.timing.multiplier-.1) end))
trackConn(pingPlus.MouseButton1Click:Connect(function() changePing(StudioHooks.timing.multiplier+.1) end))
trackConn(pingValue.FocusLost:Connect(function() changePing(tonumber((pingValue.Text:gsub(",",".")))) end))
label(appearance,"При низком FPS интервалы увеличиваются автоматически. Каждый блок ожидает подтверждение; меньший множитель сокращает паузы между действиями.",UDim2.fromOffset(28,175),UDim2.new(1,-56,0,60),12,"muted")
local starsToggle=button(appearance,"Звёзды: включены",UDim2.fromOffset(28,244),UDim2.fromOffset(270,34),"panel")
label(appearance,"Right Shift скрывает окно. Перетаскивай за верхнюю панель; нижний правый угол меняет размер.",UDim2.fromOffset(28,296),UDim2.new(1,-56,0,70),12,"muted")
refreshPing()
StudioHooks.timingDisplay=function() if appearance.Visible then pingInfo.Text=StudioHooks.timing.summary() end end
local appearanceOpen=false
-- Catalog groups open a single reusable floating tool window.
UI.extrasPage=create("ScrollingFrame",{Name="ExtrasCatalog",Parent=bodyFrame,Position=UDim2.fromOffset(108,50),Size=UDim2.new(1,-128,1,-72),BackgroundTransparency=1,CanvasSize=UDim2.fromOffset(0,280),ScrollBarThickness=3,Visible=false})
label(UI.extrasPage,"ПРИКОЛЫ",UDim2.fromOffset(0,4),UDim2.new(1,0,0,22),11,"muted","medium")
label(UI.extrasPage,"Инструменты открываются в отдельных окнах.",UDim2.fromOffset(0,34),UDim2.new(1,0,0,28),13,"text")
local extrasGroup=create("Frame",{Name="UnanchorGroup",Parent=UI.extrasPage,Position=UDim2.fromOffset(0,82),Size=UDim2.new(1,0,0,160),BackgroundColor3=palette.panel}) skin(extrasGroup,"panel") corners(extrasGroup,9) stroke(extrasGroup)
label(extrasGroup,"Unanchor",UDim2.fromOffset(18,12),UDim2.new(1,-36,0,26),17,"accent","strong")
label(extrasGroup,"ПЕРСОНАЖИ",UDim2.fromOffset(18,46),UDim2.new(1,-36,0,20),10,"muted","medium")
local companionOpen=button(extrasGroup,"Двойник R6   ↗",UDim2.fromOffset(18,78),UDim2.new(1,-36,0,38),"deep") companionOpen.Name="OpenR6Companion"
label(extrasGroup,"Собственные блоки · четыре формы · повторение поз",UDim2.fromOffset(18,120),UDim2.new(1,-36,0,26),11,"muted")
local companionWindow=create("Frame",{Name="R6CompanionWindow",Parent=gui,Position=UDim2.new(.5,70,.5,-265),Size=UDim2.fromOffset(344,530),BackgroundColor3=palette.base,Visible=false,Active=true,ZIndex=80}) skin(companionWindow,"base") corners(companionWindow,11) stroke(companionWindow)
local miniHeader=create("Frame",{Parent=companionWindow,Size=UDim2.new(1,0,0,44),BackgroundTransparency=1,Active=true})
label(miniHeader,"Unanchor / Двойник R6",UDim2.fromOffset(16,10),UDim2.new(1,-60,0,26),13,"text","strong")
local miniClose=button(miniHeader,"×",UDim2.new(1,-38,0,8),UDim2.fromOffset(28,28),"deep") miniClose.Name="CloseR6Companion"
local miniStatus=label(companionWindow,"Создай модель или используй сохранённую.",UDim2.fromOffset(16,54),UDim2.new(1,-32,0,52),12,"accent") miniStatus.Name="R6CompanionStatus"
label(companionWindow,"Форма · смена после остановки",UDim2.fromOffset(16,110),UDim2.new(1,-32,0,22),11,"muted")
local forms={}
for i,pair in ipairs({{"r6","R6 · 6"},{"voxels","Кубики · 13"},{"voxels2","Кубики ×2 · 104"},{"golem","Голем · 104"}}) do
	local b=button(companionWindow,pair[2],UDim2.fromOffset(16+((i-1)%2)*160,136+math.floor((i-1)/2)*34),UDim2.fromOffset(152,28),"deep") forms[pair[1]]=b b.Name="CompanionForm_"..pair[1]
	trackConn(b.MouseButton1Click:Connect(function() local E=StudioHooks.extras if E and E.setPreset(pair[1]) then for key,item in pairs(forms) do skin(item,key==E.preset and "soft" or "deep") end end end))
end
label(companionWindow,"Отступ · стады",UDim2.fromOffset(16,206),UDim2.fromOffset(152,22),11,"muted")
local networkGuard=button(companionWindow,"Защита: ВКЛ",UDim2.fromOffset(184,206),UDim2.fromOffset(144,22),"soft") networkGuard.Name="CompanionNetworkGuard"
trackConn(networkGuard.MouseButton1Click:Connect(function() local E=StudioHooks.extras if E and E.network then E.setNetworkGuard(not E.network.guard) networkGuard.Text=E.network.guard and "Защита: ВКЛ" or "Защита: ВЫКЛ" end end))
local distance=field(companionWindow,"14",UDim2.fromOffset(16,234),UDim2.fromOffset(74,32)) distance.Name="R6CompanionDistance"
local together=button(companionWindow,"Во мне",UDim2.fromOffset(100,234),UDim2.fromOffset(100,32),"deep")
local near=button(companionWindow,"Рядом · 14",UDim2.fromOffset(210,234),UDim2.fromOffset(118,32),"deep")
label(companionWindow,"Расположение",UDim2.fromOffset(16,276),UDim2.new(1,-32,0,22),11,"muted")
local directions={}
for i,pair in ipairs({{"back","Сзади"},{"right","Справа"},{"left","Слева"},{"front","Спереди"}}) do
	local b=button(companionWindow,pair[2],UDim2.fromOffset(16+(i-1)*80,304),UDim2.fromOffset(72,32),"deep") directions[pair[1]]=b
	trackConn(b.MouseButton1Click:Connect(function() if StudioHooks.extras then StudioHooks.extras.setSide(pair[1]) for key,button in pairs(directions) do skin(button,key==pair[1] and "soft" or "deep") end end end))
end
local start=button(companionWindow,"Создать новую форму",UDim2.fromOffset(16,348),UDim2.new(1,-32,0,38),"primary") start.Name="StartR6Companion"
local restore=button(companionWindow,"Остановить",UDim2.fromOffset(16,396),UDim2.fromOffset(152,32),"deep") restore.Name="RestoreR6Companion"
local reclaim=button(companionWindow,"Вернуть контроль",UDim2.fromOffset(176,396),UDim2.fromOffset(152,32),"deep") reclaim.Name="ReclaimR6Companion"
local park=button(companionWindow,"Припарковать оставшиеся",UDim2.fromOffset(16,438),UDim2.new(1,-32,0,32),"deep") park.Name="ParkR6Companion"
label(companionWindow,"Build / Paint / Shape · прозрачность для тебя 20%\nОстановка мгновенная. Для закрепления — парковка.",UDim2.fromOffset(16,484),UDim2.new(1,-32,0,36),10,"muted")
for _,o in ipairs(companionWindow:GetDescendants()) do if o:IsA("GuiObject") then o.ZIndex=82 end end
local miniOpened=false
local function miniVisible() companionWindow.Visible=miniOpened and mainFrame.Visible end
trackConn(mainFrame:GetPropertyChangedSignal("Visible"):Connect(miniVisible))
trackConn(companionOpen.MouseButton1Click:Connect(function()
	miniOpened=true miniVisible()
	local E=StudioHooks.extras
	if E then distance.Text=tostring(E.distance) miniStatus.Text=E.message for key,b in pairs(directions) do skin(b,key==E.side and "soft" or "deep") end end
	if E then for key,b in pairs(forms) do skin(b,key==E.preset and "soft" or "deep") end end
	if E and E.network then networkGuard.Text=E.network.guard and "Защита: ВКЛ" or "Защита: ВЫКЛ" end
	local camera=workspace.CurrentCamera local viewport=camera and camera.ViewportSize or Vector2.new(1920,1080) local p=companionWindow.AbsolutePosition
	companionWindow.Position=UDim2.fromOffset(math.clamp(p.X,0,math.max(0,viewport.X-344)),math.clamp(p.Y,0,math.max(0,viewport.Y-530)))
end))
trackConn(miniClose.MouseButton1Click:Connect(function() miniOpened=false miniVisible() end))
trackConn(start.MouseButton1Click:Connect(function() if StudioHooks.extras then StudioHooks.extras.create(true) end end))
trackConn(restore.MouseButton1Click:Connect(function() if StudioHooks.extras then StudioHooks.extras.restore() end end))
trackConn(reclaim.MouseButton1Click:Connect(function() if StudioHooks.extras then StudioHooks.extras.reclaim() end end))
trackConn(park.MouseButton1Click:Connect(function() if StudioHooks.extras then StudioHooks.extras.park() end end))
local function applyDistance(value)
	if StudioHooks.extras then StudioHooks.extras.setDistance(value) distance.Text=tostring(StudioHooks.extras.distance) end
end
trackConn(distance.FocusLost:Connect(function() applyDistance(distance.Text:gsub(",",".")) end))
trackConn(together.MouseButton1Click:Connect(function() applyDistance(0) end))
trackConn(near.MouseButton1Click:Connect(function() applyDistance(14) end))
StudioHooks.extraStatus=function(message) miniStatus.Text=message end
function UI.extraHit(point)
	local p,s=companionWindow.AbsolutePosition,companionWindow.AbsoluteSize
	return companionWindow.Visible and point.X>=p.X and point.X<=p.X+s.X and point.Y>=p.Y and point.Y<=p.Y+s.Y
end
local miniDragging=nil
trackConn(miniHeader.InputBegan:Connect(function(input)
	if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then miniDragging={input=input,start=input.Position,position=companionWindow.AbsolutePosition} end
end))
trackConn(UserInputService.InputChanged:Connect(function(input)
	if not miniDragging or not companionWindow.Visible then return end
	if input.UserInputType~=Enum.UserInputType.MouseMovement and input~=miniDragging.input then return end
	local camera=workspace.CurrentCamera local viewport=camera and camera.ViewportSize or Vector2.new(1920,1080)
	local delta=input.Position-miniDragging.start local point=miniDragging.position+Vector2.new(delta.X,delta.Y)
	companionWindow.Position=UDim2.fromOffset(math.clamp(point.X,0,math.max(0,viewport.X-344)),math.clamp(point.Y,0,math.max(0,viewport.Y-530)))
end))
trackConn(UserInputService.InputEnded:Connect(function(input) if miniDragging and input==miniDragging.input then miniDragging=nil end end))
trackConn(UserInputService.WindowFocusReleased:Connect(function() miniDragging=nil end))

UI.extrasPage.CanvasSize=UDim2.fromOffset(0,438)
local stairGroup=create("Frame",{Name="GeneratorGroup",Parent=UI.extrasPage,Position=UDim2.fromOffset(0,256),Size=UDim2.new(1,0,0,154),BackgroundColor3=palette.panel}) skin(stairGroup,"panel") corners(stairGroup,9) stroke(stairGroup)
label(stairGroup,"Генераторы",UDim2.fromOffset(18,12),UDim2.new(1,-36,0,26),17,"accent","strong")
label(stairGroup,"ПЛОЩАДКИ И ЛЕСТНИЦЫ",UDim2.fromOffset(18,46),UDim2.new(1,-36,0,20),10,"muted","medium")
local stairOpen=button(stairGroup,"Stairwell   ↗",UDim2.fromOffset(18,78),UDim2.new(1,-36,0,38),"deep") stairOpen.Name="OpenStairwell"
label(stairGroup,"9mzee · подъём в темноту · закрытые провалы",UDim2.fromOffset(18,120),UDim2.new(1,-36,0,24),11,"muted")
local stairWindow=create("Frame",{Name="StairwellWindow",Parent=gui,Position=UDim2.new(.5,-180,.5,-205),Size=UDim2.fromOffset(360,410),BackgroundColor3=palette.base,Visible=false,Active=true,ZIndex=84}) skin(stairWindow,"base") corners(stairWindow,11) stroke(stairWindow)
local stairHeader=create("Frame",{Parent=stairWindow,Size=UDim2.new(1,0,0,44),BackgroundTransparency=1,Active=true})
label(stairHeader,"Stairwell / Генератор",UDim2.fromOffset(16,10),UDim2.new(1,-60,0,26),13,"text","strong")
local stairClose=button(stairHeader,"×",UDim2.new(1,-38,0,8),UDim2.fromOffset(28,28),"deep") stairClose.Name="CloseStairwell"
local stairStatus=label(stairWindow,"Открытый вход у ног · подъём в темноту.",UDim2.fromOffset(16,54),UDim2.new(1,-32,0,50),12,"accent") stairStatus.Name="StairwellStatus"
local stairFields={}
for i,item in ipairs({{"floors","Уровней · 1–64","6"},{"rise","Перепад","16"},{"seed","Вариант / seed","1"}}) do
	label(stairWindow,item[2],UDim2.fromOffset(16+(i-1)*112,112),UDim2.fromOffset(104,22),10,"muted")
	local f=field(stairWindow,item[3],UDim2.fromOffset(16+(i-1)*112,140),UDim2.fromOffset(104,32)) f.Name="Stairwell_"..item[1] stairFields[item[1]]=f
end
label(stairWindow,"Первый этаж открыт, перед тобой на уровне ног.\nМаршрут: ровные коридоры и подъёмы.\nРедкий маленький свет · 20-й этаж уже чёрный.\nСломанные ветки ведут в закрытый провал с toxic.",UDim2.fromOffset(16,184),UDim2.new(1,-32,0,70),10,"muted")
local stairPreview=button(stairWindow,"Генерация",UDim2.fromOffset(16,264),UDim2.fromOffset(160,32),"primary") stairPreview.Name="GenerateStairwell"
local stairRegenerate=button(stairWindow,"Другой вариант",UDim2.fromOffset(184,264),UDim2.fromOffset(160,32),"soft") stairRegenerate.Name="RegenerateStairwell"
local stairBuild=button(stairWindow,"Строить / продолжить",UDim2.fromOffset(16,306),UDim2.fromOffset(160,32),"soft") stairBuild.Name="BuildStairwell"
local stairCancel=button(stairWindow,"Пауза / отмена",UDim2.fromOffset(184,306),UDim2.fromOffset(160,32),"deep") stairCancel.Name="CancelStairwell"
local stairRemove=button(stairWindow,"Удалить превью",UDim2.fromOffset(16,348),UDim2.fromOffset(160,30),"deep") stairRemove.Name="RemoveStairwellPreview"
label(stairWindow,"Без сохранения.\nСтроится этаж за этажом.",UDim2.fromOffset(184,344),UDim2.fromOffset(160,42),10,"muted")
for _,o in ipairs(stairWindow:GetDescendants()) do if o:IsA("GuiObject") then o.ZIndex=86 end end
local stairOpened=false
local function stairVisible() stairWindow.Visible=stairOpened and mainFrame.Visible end
trackConn(mainFrame:GetPropertyChangedSignal("Visible"):Connect(stairVisible))
trackConn(stairOpen.MouseButton1Click:Connect(function()
	stairOpened=true stairVisible()
	local S=StudioHooks.stairwell if S then stairStatus.Text=S.message for key,f in pairs(stairFields) do f.Text=tostring(S.options[key]) end end
	local camera=workspace.CurrentCamera local viewport=camera and camera.ViewportSize or Vector2.new(1920,1080) local p=stairWindow.AbsolutePosition
	stairWindow.Position=UDim2.fromOffset(math.clamp(p.X,0,math.max(0,viewport.X-360)),math.clamp(p.Y,0,math.max(0,viewport.Y-410)))
end))
trackConn(stairClose.MouseButton1Click:Connect(function() stairOpened=false stairVisible() end))
trackConn(stairPreview.MouseButton1Click:Connect(function()
	local S=StudioHooks.stairwell if not S then return end
	local options={} for key,f in pairs(stairFields) do options[key]=f.Text:gsub(",",".") end
	S.generate(options) for key,f in pairs(stairFields) do f.Text=tostring(S.options[key]) end
end))
trackConn(stairBuild.MouseButton1Click:Connect(function() if StudioHooks.stairwell then StudioHooks.stairwell.build() end end))
trackConn(stairCancel.MouseButton1Click:Connect(function() if StudioHooks.stairwell then StudioHooks.stairwell.cancel() end end))
trackConn(stairRemove.MouseButton1Click:Connect(function() if StudioHooks.stairwell then StudioHooks.stairwell.removePreview() end end))
trackConn(stairRegenerate.MouseButton1Click:Connect(function()
	local S=StudioHooks.stairwell if not S then return end
	local options={} for key,f in pairs(stairFields) do options[key]=f.Text:gsub(",",".") end
	S.regenerate(options) for key,f in pairs(stairFields) do f.Text=tostring(S.options[key]) end
end))
StudioHooks.stairStatus=function(message) stairStatus.Text=message end
local otherExtraHit=UI.extraHit
function UI.extraHit(point)
	local p,s=stairWindow.AbsolutePosition,stairWindow.AbsoluteSize
	return otherExtraHit(point) or stairWindow.Visible and point.X>=p.X and point.X<=p.X+s.X and point.Y>=p.Y and point.Y<=p.Y+s.Y
end
local stairDrag
trackConn(stairHeader.InputBegan:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then stairDrag={input=input,start=input.Position,position=stairWindow.AbsolutePosition} end end))
trackConn(UserInputService.InputChanged:Connect(function(input)
	if not stairDrag or not stairWindow.Visible or input.UserInputType~=Enum.UserInputType.MouseMovement and input~=stairDrag.input then return end
	local camera=workspace.CurrentCamera local viewport=camera and camera.ViewportSize or Vector2.new(1920,1080)
	local delta=input.Position-stairDrag.start local point=stairDrag.position+Vector2.new(delta.X,delta.Y)
	stairWindow.Position=UDim2.fromOffset(math.clamp(point.X,0,math.max(0,viewport.X-360)),math.clamp(point.Y,0,math.max(0,viewport.Y-410)))
end))
trackConn(UserInputService.InputEnded:Connect(function(input) if stairDrag and input==stairDrag.input then stairDrag=nil end end))
trackConn(UserInputService.WindowFocusReleased:Connect(function() stairDrag=nil end))

local state={mode="welcome",code=false,more=false,tool=nil,paint="both"}
local function refreshVisibility()
	local creating=state.mode=="create"
	local building=creating or state.mode=="load"
	UI.extrasPage.Visible=state.mode=="extras" and not appearanceOpen
	UI.welcome.Visible=state.mode=="welcome" and not appearanceOpen
	tabSection.Visible=building and not appearanceOpen
	editorFrame.Visible=(state.mode=="load" or creating and state.code) and not appearanceOpen
	UI.creator.Visible=creating and not state.code and not appearanceOpen
	sideContainer.Visible=building and not appearanceOpen
	loadInspector.Visible=not creating creatorInspector.Visible=creating
	bottom.Visible=building and not appearanceOpen
	menu.Visible=state.mode=="load" and state.more and not appearanceOpen
	appearance.Visible=appearanceOpen
	UI.moreBtn.Visible=not creating
	UI.planBtn.Visible=not creating
	UI.planBtn.Text="План: "..(PlanLibrary.selection()=="auto" and "Авто" or PlanLibrary.selection())
	for _,b in ipairs(UI.primary) do b.Visible=not creating end
	for _,b in ipairs(UI.extra) do b.Visible=not creating and state.more end
	UI.selectionCopy.Visible=creating UI.selectionClear.Visible=creating UI.toCodeBtn.Visible=creating
	UI.codeBtn.Visible=building and not appearanceOpen
	UI.codeBtn.Text=creating and (state.code and "Обзор" or "Код") or "К редактору"
	screenTitle.Text=appearanceOpen and "Настройки" or creating and "Мастерская" or state.mode=="load" and "Загрузка постройки" or state.mode=="extras" and "Приколы" or "Добро пожаловать"
	for _,pair in ipairs({{UI.createModeBtn,creating},{UI.loadModeBtn,state.mode=="load"},{UI.extrasModeBtn,state.mode=="extras"},{settingsBtn,appearanceOpen}}) do skin(pair[1],pair[2] and "soft" or "base",pair[2] and "accent" or "muted") end
	local tool=state.tool or "mbuild"
	UI.buildToggle.Visible=tool=="mbuild" UI.copyToggle.Visible=tool=="mbuild"
	UI.sizeToggle.Visible=tool=="msize"
	UI.overlapToggle.Visible=tool=="mbuild" or tool=="msize"
	local painting=tool=="mpaint" or tool=="mbuild"
	colorCaption.Visible=painting UI.hexField.Visible=painting UI.swatch.Visible=painting UI.materialButton.Visible=painting
	UI.paintModeButton.Visible=tool=="mpaint" UI.collideToggle.Visible=painting and state.paint~="spray" UI.sprayField.Visible=tool=="mpaint" and state.paint=="spray" UI.sprayColorField.Visible=UI.sprayField.Visible
	if tool=="mpaint" then
		local colour=state.paint=="both" or state.paint=="color"
		colorCaption.Visible=colour UI.hexField.Visible=colour UI.swatch.Visible=colour
		UI.materialButton.Visible=state.paint=="both" or state.paint=="material"
	end
	-- Compact the inspector instead of leaving blank rows for hidden controls.
	local y=0
	for _,b in ipairs({UI.buildToggle,UI.sizeToggle,UI.copyToggle,UI.overlapToggle}) do if b.Visible then b.Position=UDim2.fromOffset(0,y) y+=42 end end
	if colorCaption.Visible then
		colorCaption.Position=UDim2.fromOffset(0,y+4) y+=30 UI.hexField.Position=UDim2.fromOffset(0,y) UI.swatch.Position=UDim2.new(1,-34,0,y) y+=42
	end
	for _,b in ipairs({UI.materialButton,UI.paintModeButton,UI.collideToggle,UI.sprayField,UI.sprayColorField}) do if b.Visible then b.Position=UDim2.fromOffset(0,y) y+=42 end end
	creatorInspector.Size=UDim2.new(1,0,0,math.max(240,y+96))
	for name,b in pairs(UI.toolButtons) do skin(b,name==state.tool and "soft" or "panel",name==state.tool and "accent" or "text") end
	UI.materialList.Visible=false
end
function UI.mode(mode,code,more) state.mode=mode state.code=code state.more=more appearanceOpen=false refreshVisibility() end
function UI.tool(name) state.tool=name refreshVisibility() end
function UI.paint(name) state.paint=name refreshVisibility() end
trackConn(settingsBtn.MouseButton1Click:Connect(function() appearanceOpen=not appearanceOpen refreshPing() refreshVisibility() end))
trackConn(starsToggle.MouseButton1Click:Connect(function()
	settings.stars=not settings.stars starsToggle.Text=settings.stars and "Звёзды: включены" or "Звёзды: выключены"
	for _,s in ipairs(stars) do s.Visible=settings.stars end
	saveAppearance()
end))
starsToggle.Text=settings.stars and "Звёзды: включены" or "Звёзды: выключены"
trackConn(UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode==Enum.KeyCode.RightShift and not UserInputService:GetFocusedTextBox() then mainFrame.Visible=not mainFrame.Visible end
end))
function UI.editor(text)
	if StudioHooks.controls then StudioHooks.controls() end
	local lines=1 local longest=0
	for l in (text.."\n"):gmatch("([^\n]*)\n") do longest=math.max(longest,#l) end
	for _ in text:gmatch("\n") do lines+=1 end
	local numbers={} for i=1,math.min(lines,4000) do numbers[i]=tostring(i) end
	lineNumbers.Text=table.concat(numbers,"\n")
	local height=math.max(textScroll.AbsoluteSize.Y,lines*16+24)
	local width=math.max(textScroll.AbsoluteSize.X,longest*7+66)
	textBox.Size=UDim2.fromOffset(width-40,height) lineNumbers.Size=UDim2.fromOffset(28,height) textScroll.CanvasSize=UDim2.fromOffset(width,height)
	emptyState.Visible=text==""
	local count,page,pages=0,1,1
	if StudioHooks.documents then count,page,pages=StudioHooks.documents.metrics()
	else for _ in (_G.fullBuildString or text):gmatch("|[^|]+|") do count+=1 end end
	recordBadge.Text=count.." деталей"
	UI.pagePrevious.Visible=pages>1 UI.pageNext.Visible=pages>1 UI.pageInfo.Visible=pages>1
	UI.pageInfo.Text="Страница "..page.."/"..pages.." · правка этой страницы"
	textScroll.Position=UDim2.fromOffset(10,pages>1 and 72 or 42)
	textScroll.Size=UDim2.new(1,-20,1,pages>1 and -86 or -56)
end
function UI.controls()
	UI.planBtn.Text="План: "..(PlanLibrary.selection()=="auto" and "Авто" or PlanLibrary.selection())
	btnImport.Text=visualsShowing and "Скрыть preview" or "Предпросмотр"
	btnPaste.Text="Вставить" btnCopy.Text="Копировать"
	btnRot90.Text="+90°" btnRot180.Text="180°" btnRotNeg90.Text="−90°"
end
StudioHooks.controls=UI.controls
StudioHooks.editor=UI.editor UI.editor(textBox.Text)
local function responsive()
	local width=mainFrame.Size.X.Offset
	local compact=width<940
	for name,b in pairs(UI.toolButtons) do
		b.Name="Tool_"..name b.Text=compact and "" or UI.toolLabels[name]
		local art=b:FindFirstChild("Icon_"..({mbuild="cube",mpaint="paint",mdelete="delete",msize="size",mchoose="select"})[name])
		if art then art.Position=compact and UDim2.new(.5,-9,0,11) or UDim2.fromOffset(9,11) end
	end
	UI.editor(textBox.Text)
end
trackConn(mainFrame:GetPropertyChangedSignal("Size"):Connect(responsive)) responsive()
local grip=button(bodyFrame,"",UDim2.new(1,-24,1,-24),UDim2.fromOffset(22,22),"base") grip.Name="ResizeGrip" grip.ZIndex=65 grip.BackgroundTransparency=1
local gripStroke=grip:FindFirstChildOfClass("UIStroke") if gripStroke then gripStroke:Destroy() end
for i=1,3 do line(grip,Vector2.new(20-i*5,20),Vector2.new(20,20-i*5),Color3.fromRGB(128,120,160),1,66) end
trackConn(grip.InputBegan:Connect(function(input)
	if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch or isMinimized then return end
	if openTween then openTween:Cancel() end
	local size=mainFrame.Size local topLeft=mainFrame.AbsolutePosition
	resizing={origin=input.Position,topLeft=topLeft,width=size.X.Offset,height=size.Y.Offset,scale=scale.Scale}
	isMaximized=false mainFrame.AnchorPoint=Vector2.new(0,0) mainFrame.Position=UDim2.fromOffset(topLeft.X,topLeft.Y)
end))
trackConn(UserInputService.InputChanged:Connect(function(input)
	if not resizing or input.UserInputType~=Enum.UserInputType.MouseMovement and input.UserInputType~=Enum.UserInputType.Touch then return end
	local delta=(input.Position-resizing.origin)/math.max(.1,resizing.scale)
	local width=math.clamp(math.floor(resizing.width+delta.X+.5),740,1600)
	local height=math.clamp(math.floor(resizing.height+delta.Y+.5),520,1000)
	normalSize=UDim2.fromOffset(width,height) mainFrame.Size=normalSize responsive()
end))
local function finishResize()
	if not resizing then return end
	local r=resizing resizing=nil
	mainFrame.AnchorPoint=Vector2.new(.5,.5)
	mainFrame.Position=UDim2.fromOffset(r.topLeft.X+normalSize.X.Offset*r.scale/2,r.topLeft.Y+normalSize.Y.Offset*r.scale/2)
	settings.width=normalSize.X.Offset settings.height=normalSize.Y.Offset minimizedSize=UDim2.fromOffset(settings.width,46)
	saveAppearance() fit()
end
trackConn(UserInputService.InputEnded:Connect(function(input) if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then finishResize() end end))
trackConn(UserInputService.WindowFocusReleased:Connect(finishResize))
-- Search plus six cards per page; no dropdown or scrolling list.
do
	local shade=create("Frame",{Name="PlanPicker",Parent=bodyFrame,Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.fromRGB(5,6,13),BackgroundTransparency=.15,Visible=false,Active=true,ZIndex=70}) shade:SetAttribute("StudioFixedColor",true)
	local panel=create("Frame",{Parent=shade,Position=UDim2.fromOffset(100,18),Size=UDim2.new(1,-118,1,-36),BackgroundColor3=C_GRAY,ZIndex=71}) skin(panel,"deep") corners(panel,10) stroke(panel)
	label(panel,"Библиотека планов",UDim2.fromOffset(20,12),UDim2.new(1,-70,0,30),19,"text","strong").ZIndex=72
	local close=button(panel,"×",UDim2.new(1,-44,0,14),UDim2.fromOffset(28,28),"panel") close.ZIndex=72
	local search=field(panel,"",UDim2.fromOffset(20,54),UDim2.new(1,-250,0,34)) search.Name="PlanSearch" search.PlaceholderText="Найти по названию…" search.ZIndex=72
	local reload=button(panel,"Обновить",UDim2.new(1,-222,0,54),UDim2.fromOffset(92,34),"deep") reload.ZIndex=72
	local automatic=button(panel,"Свой план",UDim2.new(1,-122,0,54),UDim2.fromOffset(102,34),"soft") automatic.ZIndex=72
	local message=label(panel,"План закрепляется за этой постройкой и поворачивается вместе с ней.",UDim2.fromOffset(20,96),UDim2.new(1,-40,0,28),10,"muted") message.Name="PlanChoiceMessage" message.ZIndex=72
	local area=create("Frame",{Parent=panel,Position=UDim2.fromOffset(20,132),Size=UDim2.new(1,-40,1,-198),BackgroundTransparency=1,ZIndex=72})
	local empty=label(area,"Пока нет планов.\nПервый сохранится при начале строительства.",UDim2.fromOffset(0,20),UDim2.new(1,0,0,80),13,"muted") empty.Name="PlansEmpty" empty.ZIndex=73 empty.TextXAlignment=Enum.TextXAlignment.Center
	local prev=button(panel,"←",UDim2.new(0,20,1,-48),UDim2.fromOffset(38,30),"panel") prev.ZIndex=72
	local nextPage=button(panel,"→",UDim2.new(1,-58,1,-48),UDim2.fromOffset(38,30),"panel") nextPage.ZIndex=72
	local pageLabel=label(panel,"",UDim2.new(.5,-140,1,-48),UDim2.fromOffset(280,30),11,"muted") pageLabel.ZIndex=72 pageLabel.TextXAlignment=Enum.TextXAlignment.Center
	local page,cardObjects,cardConnections=1,{},{}
	local generation=0
	local refresh
	local function choose(file)
		local ok,message=PlanLibrary.select(file)
		if not ok then
			local detail=message or "План не выбран"
			panel:FindFirstChild("PlanChoiceMessage").Text=detail setStatus(detail,true) return
		end
		generation+=1 shade.Visible=false UI.controls()
		if StudioHooks.preview then StudioHooks.preview() end
		setStatus(file=="auto" and "План будет выбран автоматически" or "Шаблон: "..file.." · пересчитается перед строительством")
	end
	refresh=function()
		for _,connection in ipairs(cardConnections) do connection:Disconnect() end cardConnections={}
		for _,card in ipairs(cardObjects) do card:Destroy() end cardObjects={}
		local query=search.Text:lower() local filtered={}
		for _,r in ipairs(PlanLibrary.list()) do if query=="" or (r.file.." "..r.buildName):lower():find(query,1,true) then filtered[#filtered+1]=r end end
		local pages=math.max(1,math.ceil(#filtered/6)) page=math.clamp(page,1,pages)
		pageLabel.Text=string.format("%d / %d  ·  %d планов",page,pages,#filtered) empty.Visible=#filtered==0
		prev.Visible=page>1 nextPage.Visible=page<pages
		for slot=1,6 do
			local r=filtered[(page-1)*6+slot] if not r then break end
			local column,row=(slot-1)%3,math.floor((slot-1)/3)
			local selected=PlanLibrary.selection()==r.file
			local card=button(area,"",UDim2.new(column/3,column*3, row/2,row*4),UDim2.new(1/3,-8,.5,-8),selected and "soft" or "panel") card.Name="PlanCard_"..slot card.ZIndex=73 cardObjects[#cardObjects+1]=card
			local caption=label(card,r.file,UDim2.fromOffset(12,10),UDim2.new(1,-24,0,24),12,selected and "accent" or "text","medium") caption.TextWrapped=false caption.TextTruncate=Enum.TextTruncate.AtEnd caption.ZIndex=74
			local source=label(card,r.unavailable and "Файл недоступен/повреждён" or r.buildName,UDim2.fromOffset(12,36),UDim2.new(1,-24,0,18),10,"muted") source.TextWrapped=false source.TextTruncate=Enum.TextTruncate.AtEnd source.ZIndex=74
			label(card,tostring(r.count or 0).." блоков · "..tostring(r.operations or 0).." действий",UDim2.new(0,12,1,-34),UDim2.new(1,-24,0,24),10,"muted").ZIndex=74
			cardConnections[#cardConnections+1]=card.MouseButton1Click:Connect(function() choose(r.file) end)
		end
	end
	trackConn(close.MouseButton1Click:Connect(function() generation+=1 shade.Visible=false end))
	trackConn(automatic.MouseButton1Click:Connect(function() choose("auto") end))
	trackConn(prev.MouseButton1Click:Connect(function() page-=1 refresh() end))
	trackConn(nextPage.MouseButton1Click:Connect(function() page+=1 refresh() end))
	trackConn(search:GetPropertyChangedSignal("Text"):Connect(function() page=1 refresh() end))
	local function rescan()
		generation+=1 local request=generation
		message.Text="Читаю файлы планов…"
		task.defer(function()
			PlanLibrary.scan()
			if unloaded or not shade.Visible or request~=generation then return end
			-- A rescan is explicitly requested; choosing a card cancels its redraw.
			refresh() message.Text="Выбери план. Для другой постройки сохранится отдельная привязанная копия."
		end)
	end
	trackConn(reload.MouseButton1Click:Connect(rescan))
	trackConn(UI.planBtn.MouseButton1Click:Connect(function()
		generation+=1 shade.Visible=true page=1 refresh()
		message.Text=_G.autobuildRunning and "Можно просмотреть планы. Для смены сначала поставь стройку на паузу." or "Выбери план; поворот и перемещение сохраняют его привязку."
		-- Do not destroy selectable cards in a background scan while clicking.
		if #PlanLibrary.list()==0 then rescan() end
	end))
	trackConn(mainFrame:GetPropertyChangedSignal("Visible"):Connect(function() if not mainFrame.Visible then shade.Visible=false end end))
end
local overviewRevision=0
local overviewBounds=nil
local function fitOverview()
	if not overviewBounds then return end
	local center,radius=overviewBounds.center,overviewBounds.radius
	local aspect=math.max(.5,viewport.AbsoluteSize.X/math.max(1,viewport.AbsoluteSize.Y))
	local distance=radius/math.min(1,aspect)
	previewCamera.CFrame=CFrame.lookAt(center+Vector3.new(distance*.75,distance*.55,distance*.9),center) previewCamera.Focus=CFrame.new(center)
end
trackConn(viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitOverview))
function UI.updatePreview(blocks)
	overviewRevision+=1 local revision=overviewRevision
	task.defer(function()
		if unloaded or revision~=overviewRevision then return end
		for _,p in ipairs(previewWorld:GetChildren()) do p:Destroy() end
		overviewEmpty.Visible=#blocks==0
		if #blocks==0 then overviewBounds=nil return end
		local lo,hi=Vector3.new(math.huge,math.huge,math.huge),Vector3.new(-math.huge,-math.huge,-math.huge)
		for _,b in ipairs(blocks) do
			local a,c=b.centerPos-b.size/2,b.centerPos+b.size/2
			lo=Vector3.new(math.min(lo.X,a.X),math.min(lo.Y,a.Y),math.min(lo.Z,a.Z)) hi=Vector3.new(math.max(hi.X,c.X),math.max(hi.Y,c.Y),math.max(hi.Z,c.Z))
		end
		local stride=math.max(1,math.ceil(#blocks/240))
		for i=1,#blocks,stride do
			local b=blocks[i]
			create("Part",{Name="OverviewBlock",Parent=previewWorld,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,Size=b.size,CFrame=CFrame.new(b.centerPos),Color=b.color,Material=b.material,Transparency=b.material==Enum.Material.Glass and .5 or 0})
		end
		overviewBounds={center=(lo+hi)/2,radius=math.max(6,(hi-lo).Magnitude)} fitOverview()
	end)
end
for _,o in ipairs(gui:GetDescendants()) do if o:IsA("TextButton") then bindHover(o) end end
refreshVisibility()
return UI

	end)()
	local creator=View.creator
	local editorTools=View.editorTools
	local toolButtons=View.toolButtons
	local toolNames=View.toolNames
	local toolLabels=View.toolLabels
	local sceneStats=View.sceneStats
	local selectionStats=View.selectionStats
	local toolHint=View.toolHint
	local toCodeBtn=View.toCodeBtn
	local toolOptions=View.toolOptions
	local buildToggle=View.buildToggle
	local sizeToggle=View.sizeToggle
	local copyToggle=View.copyToggle
	local overlapToggle=View.overlapToggle
	local hexField=View.hexField
	local swatch=View.swatch
	local materialButton=View.materialButton
	local materialList=View.materialList
	local paintModeButton=View.paintModeButton
	local collideToggle=View.collideToggle
	local sprayField=View.sprayField
	local sprayColorField=View.sprayColorField
	local selectionCopy=View.selectionCopy
	local selectionClear=View.selectionClear
	local welcome=View.welcome
	local cards=View.cards
	local createModeBtn=View.createModeBtn
	local loadModeBtn=View.loadModeBtn
	local undoBtn=View.undoBtn
	local redoBtn=View.redoBtn
	local codeBtn=View.codeBtn
	local moreBtn=View.moreBtn
	local primary=View.primary
	local extra=View.extra
	local applyTheme=View.applyTheme
	for material,choice in pairs(View.materialChoices) do
		trackConn(choice.MouseButton1Click:Connect(function()
			paintMaterial=material materialButton.Text="Материал: "..material.Name materialList.Visible=false
		end))
	end
	local function blocked() return unloaded or _G.autobuildRunning or busySaving or sceneLoading or pendingContent~=nil end
	local function uiHit(point)
		if View.extraHit and View.extraHit(point) then return true end
		if not mainFrame.Visible then return false end
		local p=mainFrame.AbsolutePosition local s=mainFrame.AbsoluteSize
		return point.X>=p.X and point.X<=p.X+s.X and point.Y>=p.Y and point.Y<=p.Y+s.Y
	end
	local function clearSelection()
		for _,h in pairs(highlights) do h:Destroy() end
		table.clear(highlights) table.clear(selected)
		selectionStats.Text="Выбрано: 0"
	end
	local function refreshSelection()
		local count=0
		for part in pairs(selected) do
			if not part.Parent then selected[part]=nil if highlights[part] then highlights[part]:Destroy() highlights[part]=nil end
			else count+=1 end
		end
		selectionStats.Text="Выбрано: "..count
	end
	local function selectPart(part,remove,silent)
		if not part or not part:IsA("BasePart") then return end
		if remove then
			selected[part]=nil
			if highlights[part] then highlights[part]:Destroy() highlights[part]=nil end
		elseif not selected[part] then
			selected[part]=true
			local h=create("SelectionBox",{Parent=scene,Adornee=part,Color3=Color3.fromRGB(206,151,255),LineThickness=.035,SurfaceTransparency=.9})
			highlights[part]=h
		end
		if not silent then refreshSelection() end
	end
	local function renderSprays(part,b)
		for _,child in ipairs(part:GetChildren()) do if child:IsA("SurfaceGui") then child:Destroy() end end
		for _,s in ipairs(b.sprays or {}) do
			local surface=create("SurfaceGui",{Name="Spray",Parent=part,Face=s.face,SizingMode=Enum.SurfaceGuiSizingMode.PixelsPerStud,PixelsPerStud=150})
			create("TextLabel",{Name="Label",Parent=surface,Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Text=s.text,TextColor3=hexToColor(s.colorHex),Font=Enum.Font.SourceSans,TextScaled=true,TextWrapped=true})
		end
	end
	local function updatePart(part,b)
		part.Size=b.size part.CFrame=CFrame.new(b.centerPos) part.Color=b.color part.Material=b.material
		part.Transparency=b.material==Enum.Material.Glass and .5 or 0
		part.CanCollide=false part.CanTouch=false part.CanQuery=true part.Anchored=true
		parts[part]=b renderSprays(part,b)
	end
	local function addPart(b)
		local part=create("Part",{Name="ImaginaryBlock",Parent=scene,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=true,TopSurface=Enum.SurfaceType.Smooth,BottomSurface=Enum.SurfaceType.Smooth})
		updatePart(part,Model.copy(b)) order[#order+1]=part
		return part
	end
	local function collect(selectionOnly)
		local result={}
		for _,part in ipairs(order) do if parts[part] and part.Parent and (not selectionOnly or selected[part]) then result[#result+1]=Model.copy(parts[part]) end end
		return result
	end
	local function codeFor(blocks)
		local records={}
		for _,b in ipairs(blocks) do records[#records+1]=serializeBlock(b) end
		return table.concat(records)
	end
	local function updateSceneStats()
		sceneStats.Text=string.format("%d деталей · сохранено локально",#collect(false))
		View.updatePreview(collect(false))
		refreshSelection()
	end
	local function commit()
		if sceneLoading or sceneInvalid or pendingContent~=nil or lastContentTab~=activeTabIndex then return false end
		local code=codeFor(collect(false))
		updatingScene=true
		_G.buildOffset=Vector3.zero
		setBuildContent(code)
		updatingScene=false
		loadedContent=code lastContentTab=activeTabIndex loadedTabId=tabsData[activeTabIndex].id or tabsData[activeTabIndex] loadedOffset=Vector3.zero sceneInvalid=false
		updateDefaultStats() updateSceneStats()
	end
	local loadScene
	loadScene=function(code)
		if sceneLoading then pendingContent=code return false end
		pendingContent=nil
		if loadedContent==code and loadedTabId==(tabsData[activeTabIndex].id or tabsData[activeTabIndex]) and loadedOffset==(_G.buildOffset or Vector3.zero) then lastContentTab=activeTabIndex sceneInvalid=false return true end
		local blocks,invalid=parseBlocks(code,_G.buildOffset or Vector3.zero)
		if invalid>0 then sceneInvalid=true setStatus("Импорт мастерской отклонён: некорректных записей "..invalid..", распознано деталей "..#blocks..". Исходная вкладка сохранена.",true) return false end
		sceneLoading=true sceneInvalid=false
		local loadRevision=sceneRevision
		local tab=activeTabIndex
		local tabId=tabsData[activeTabIndex].id or tabsData[activeTabIndex]
		local offset=_G.buildOffset or Vector3.zero
		clearSelection()
		for part in pairs(parts) do part:Destroy() end
		table.clear(parts) table.clear(order)
		for i,b in ipairs(blocks) do
			addPart(b)
			if i%128==0 then task.wait() end
			if unloaded or loadRevision~=sceneRevision or tab~=activeTabIndex then
				sceneLoading=false sceneInvalid=true loadedContent=nil
				for part in pairs(parts) do part:Destroy() end table.clear(parts) table.clear(order)
				local latest=pendingContent pendingContent=nil
				if latest~=nil and not unloaded and mode=="create" then task.defer(function() if not unloaded and mode=="create" then loadScene(latest) end end) end
				return false
			end
		end
		loadedContent=code lastContentTab=activeTabIndex loadedTabId=tabId loadedOffset=offset
		sceneLoading=false
		updateSceneStats()
		if pendingContent~=nil then
			local latest=pendingContent
			task.defer(function() if not unloaded then loadScene(latest) end end)
		end
		return true
	end
	StudioHooks.content=function(value)
		if updatingScene then return end
		sceneRevision+=1
		local revision=sceneRevision
		if mode=="create" and not sceneLoading and loadedContent==value and loadedTabId==(tabsData[activeTabIndex].id or tabsData[activeTabIndex]) and loadedOffset==(_G.buildOffset or Vector3.zero) then lastContentTab=activeTabIndex sceneInvalid=false return end
		if mode=="create" then
			pendingContent=value
			task.defer(function()
				if revision~=sceneRevision or unloaded or mode~="create" then if revision==sceneRevision then pendingContent=nil end return end
				loadScene(value)
			end)
		end
	end
	local function syncVisibility()
		local creating=mode=="create"
		View.mode(mode,codeOpen,moreOpen)
		btnNextChunk.Visible=not creating and _G.totalChunks~=nil and _G.totalChunks>1

		for _,part in ipairs(order) do
			if part.Parent then
				part.LocalTransparencyModifier=creating and 0 or 1 part.CanQuery=creating
				for _,child in ipairs(part:GetChildren()) do if child:IsA("SurfaceGui") then child.Enabled=creating end end
			end
		end
		for _,h in pairs(highlights) do h.Visible=creating end
	end
	local ToolView
	local setMode
	local function releaseTool()
		if ToolView then ToolView.clear() end
		activeTool=nil held=false pressPoint=nil
		local backpack=LocalPlayer:FindFirstChildOfClass("Backpack")
		for _,tool in pairs(tools) do if tool.Parent and tool.Parent==LocalPlayer.Character and backpack then tool.Parent=backpack end end
	end
	setMode=function(nextMode)
		if _G.autobuildRunning and StudioHooks.documents then StudioHooks.documents.runUI(function() setMode(nextMode) end) return end
		if unloaded or _G.autobuildRunning or busySaving then setStatus("Сначала поставь строительство на паузу",true) return end
		if nextMode~="create" and (sceneLoading or pendingContent~=nil) then
			sceneRevision+=1 pendingContent=nil sceneInvalid=true loadedContent=nil
			releaseTool() clearSelection()
			mode=nextMode codeOpen=false moreOpen=false
			for _,tool in pairs(tools) do tool.Enabled=false end
			applyTheme(nextMode=="load" and "load" or "create") syncVisibility() renderTabs()
			return
		end
		if nextMode=="create" and mode~="create" then
			local code=_G.fullBuildString or textBox.Text
			local _,invalid=parseBlocks(code,Vector3.zero)
			if invalid>0 then
				local originalName=tabsData[activeTabIndex].name
				local used={} for _,tab in ipairs(tabsData) do used[tab.name]=true end
				local name="Мастерская" local suffix=1
				while used[name] do name="Мастерская "..suffix suffix+=1 end
				tabsData[#tabsData+1]={name=name,content=""} activeTabIndex=#tabsData
				_G.buildOffset=Vector3.zero setBuildContent("")
				setStatus("Создана пустая мастерская «"..name.."». Вкладка «"..originalName.."» сохранена без изменений; некорректных записей: "..invalid,true)
				code=""
			end
			cleanupVisuals(true)
			if not loadScene(code) then if pendingContent~=nil then mode="create" codeOpen=false syncVisibility() end return end
		elseif mode=="create" and nextMode~="create" then
			if not sceneInvalid and loadedContent~=tabsData[activeTabIndex].content then commit() end
			releaseTool() clearSelection()
		end
		mode=nextMode codeOpen=false materialList.Visible=false
		for _,tool in pairs(tools) do tool.Enabled=nextMode=="create" end
		applyTheme(nextMode=="load" and "load" or "create")
		syncVisibility() renderTabs()
		setStatus(nextMode=="create" and "Мастерская · R меняет режим инструмента · Ctrl+Z отменяет действие" or nextMode=="extras" and "Приколы · выбери группу и открой мини-окно" or "Загрузи код → рассчитай план → проверь → строй")
	end
	StudioHooks.stageCompanion=function(code,id,name)
		setMode("extras")
		local previous=tabsData[activeTabIndex] local p=_G.buildOffset or Vector3.zero previous.placement={p.X,p.Y,p.Z}
		local index
		for i,tab in ipairs(tabsData) do if tab.id==id then index=i break end end
		if not index then tabsData[#tabsData+1]={id=id,name=name or "Двойник R6",content=code,placement={0,0,0}} index=#tabsData end
		activeTabIndex=index cleanupVisuals(true) _G.buildOffset=Vector3.zero
		setBuildContent(code) renderTabs() updateDefaultStats()
	end
	StudioHooks.forgetCompanion=function(id)
		local index
		for i,tab in ipairs(tabsData) do if tab.id==id then index=i break end end
		if not index then return end
		local tab=tabsData[index]
		if StudioHooks.documents then StudioHooks.documents.discard(tab) end
		if StudioHooks.guard and StudioHooks.guard.session and StudioHooks.guard.session.buildId==id then StudioHooks.guard.close() end
		if resumeSession and resumeSession.buildId==id then resumeSession=nil end
		table.remove(tabsData,index)
		if #tabsData==0 then tabsData[1]={name="Build 1",content="",placement={0,0,0}} end
		if activeTabIndex>index then activeTabIndex-=1 elseif activeTabIndex==index then activeTabIndex=math.min(index,#tabsData) end
		cleanupVisuals(true)
		local current=tabsData[activeTabIndex] local p=current.placement or {0,0,0} _G.buildOffset=Vector3.new(p[1],p[2],p[3])
		setBuildContent(current.content or "") renderTabs() updateDefaultStats()
	end
	local function restore(direction)
		if blocked() then return end
		-- Flush the latest typing before moving through history.
		remember()
		local state=History.take(direction,snapshot())
		if not state then setStatus(direction=="undo" and "Нечего отменять" or "Нечего повторять") return end
		mutedHistory=true
		tabsData=state.tabs activeTabIndex=state.active
		_G.buildOffset=Vector3.zero loadedContent=nil
		cleanupVisuals(true)
		if StudioHooks.restorePlacement then StudioHooks.restorePlacement() end
			setBuildContent(tabsData[activeTabIndex].content) renderTabs() updateDefaultStats()
		baseline=snapshot() mutedHistory=false persistHistory()
		setStatus(direction=="undo" and "Действие отменено" or "Действие повторено")
	end
	trackConn(undoBtn.MouseButton1Click:Connect(function() restore("undo") end))
	trackConn(redoBtn.MouseButton1Click:Connect(function() restore("redo") end))
	trackConn(View.homeBtn.MouseButton1Click:Connect(function() setMode("welcome") end))
	trackConn(createModeBtn.MouseButton1Click:Connect(function() setMode("create") end))
	trackConn(loadModeBtn.MouseButton1Click:Connect(function() setMode("load") end))
	trackConn(View.extrasModeBtn.MouseButton1Click:Connect(function() setMode("extras") end))
	for which,card in pairs(cards) do trackConn(card.MouseButton1Click:Connect(function() setMode(which) end)) end
	trackConn(moreBtn.MouseButton1Click:Connect(function() moreOpen=not moreOpen syncVisibility() end))
	trackConn(codeBtn.MouseButton1Click:Connect(function()
		if mode=="create" then codeOpen=not codeOpen syncVisibility()
		else textBox:CaptureFocus() end
	end))
	trackConn(buildToggle.MouseButton1Click:Connect(function() small=not small buildToggle.Text=small and "Куб 1 × 1 × 1 · R" or "Куб 4 × 4 × 4 · R" end))
	trackConn(sizeToggle.MouseButton1Click:Connect(function() sizeDecrease=not sizeDecrease sizeToggle.Text=sizeDecrease and "Уменьшить грань · R" or "Увеличить грань · R" end))
	trackConn(copyToggle.MouseButton1Click:Connect(function() copyStyle=not copyStyle copyToggle.Text=copyStyle and "Копировать деталь: да" or "Копировать деталь: нет" end))
	trackConn(overlapToggle.MouseButton1Click:Connect(function() allowOverlap=not allowOverlap overlapToggle.Text=allowOverlap and "Пересечения: да" or "Пересечения: нет" end))
	trackConn(materialButton.MouseButton1Click:Connect(function() materialList.Visible=not materialList.Visible end))
	trackConn(hexField.FocusLost:Connect(function()
		local value=hexField.Text:gsub("#",""):upper()
		if not value:match("^%x%x%x%x%x%x$") then hexField.Text=colorHex(paintColor) setStatus("Цвет: шесть HEX-цифр, например E0F4FF",true) return end
		paintColor=hexToColor(value) hexField.Text=value swatch.BackgroundColor3=paintColor
	end))
	trackConn(sprayField.FocusLost:Connect(function() paintText=sprayField.Text end))
	trackConn(sprayColorField.FocusLost:Connect(function()
		local value=sprayColorField.Text:gsub("#",""):upper()
		if value:match("^%x%x%x%x%x%x$") then paintTextHex=value else sprayColorField.Text=paintTextHex end
	end))
	trackConn(paintModeButton.MouseButton1Click:Connect(function()
		local names={both="color",color="material",material="spray",spray="both"}
		paintMode=names[paintMode]
		View.paint(paintMode)
		local titles={both="цвет + материал",color="только цвет",material="только материал",spray="текст на грани"}
		paintModeButton.Text="Покраска: "..titles[paintMode]
	end))
	trackConn(collideToggle.MouseButton1Click:Connect(function()
		paintCollide=not paintCollide collideToggle.Text=paintCollide and "Collide в коде: включён" or "Collide в коде: выключен"
	end))
	trackConn(selectionClear.MouseButton1Click:Connect(clearSelection))
	local function realData(part)
		if parts[part] then return Model.copy(parts[part]) end
		local bricks=workspace:FindFirstChild("Bricks")
		if not bricks or not part:IsDescendantOf(bricks) or not part:IsA("Part") or part.Shape~=Enum.PartType.Block or not part.Anchored or not MaterialSymbols[part.Material] then return nil end
		local cf=part.CFrame
		for _,axis in ipairs({cf.RightVector,cf.UpVector,cf.LookVector}) do
			if math.max(math.abs(axis.X),math.abs(axis.Y),math.abs(axis.Z))<.9999 then return nil end
		end
		if part.Transparency~=0 and not (part.Material==Enum.Material.Glass and math.abs(part.Transparency-.5)<.01) then return nil end
		local size=part.Size
		local worldSize=Vector3.new(math.abs(cf.RightVector.X)*size.X+math.abs(cf.UpVector.X)*size.Y+math.abs(cf.LookVector.X)*size.Z,math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z,math.abs(cf.RightVector.Z)*size.X+math.abs(cf.UpVector.Z)*size.Y+math.abs(cf.LookVector.Z)*size.Z)
		local b={size=worldSize,centerPos=part.Position,color=part.Color,material=part.Material,canCollide=part.CanCollide,sprays={}}
		if not Model.valid(b) then return nil end
		for _,s in ipairs(part:GetChildren()) do
			local l=s:IsA("SurfaceGui") and s.Name=="Spray" and s:FindFirstChild("Label")
			if l and l:IsA("TextLabel") then b.sprays[#b.sprays+1]={face=worldFace(cf,s.Face),text=l.Text,colorHex=colorHex(l.TextColor3)} end
		end
		return b
	end
	local function selectionCode()
		local result,skipped={},0
		-- Stable local order, then deterministic world coordinates.
		local chosen={}
		for part in pairs(selected) do if part.Parent then chosen[#chosen+1]=part end end
		table.sort(chosen,function(a,b)
			if a.Position.Y~=b.Position.Y then return a.Position.Y<b.Position.Y end
			if a.Position.X~=b.Position.X then return a.Position.X<b.Position.X end
			return a.Position.Z<b.Position.Z
		end)
		for _,part in ipairs(chosen) do local b=realData(part) if b then result[#result+1]=b else skipped+=1 end end
		return codeFor(result),#result,skipped
	end
	trackConn(selectionCopy.MouseButton1Click:Connect(function()
		local code,count,skipped=selectionCode()
		if count==0 then setStatus("Выдели поддерживаемые детали инструментом mchoose",true) return end
		if exportToClipboard(code) then setStatus("Скопировано деталей: "..count.." · пропущено: "..skipped) else setStatus("Буфер обмена недоступен",true) end
	end))
	trackConn(toCodeBtn.MouseButton1Click:Connect(function()
		if blocked() then return end
		local code,count,skipped=selectionCode()
		if count==0 then setStatus("Нет поддерживаемых деталей в выделении",true) return end
		commit()
		mode="load" releaseTool() clearSelection()
		tabsData[#tabsData+1]={name="Выделение "..os.date("%H-%M-%S"),content=code}
		activeTabIndex=#tabsData
		setBuildContent(code) renderTabs() updateDefaultStats()
		applyTheme("load") syncVisibility()
		setStatus("Выделение записано в новую вкладку: "..count.." · пропущено: "..skipped)
	end))
	local hints={
		mbuild="ЛКМ — поставить куб. R — 1 или 4. С копированием клик по мнимой детали дублирует её с выбранной стороны.",
		mpaint="ЛКМ — покрасить деталь или выделение. Выбери HEX, материал или текст на грани ниже.",
		mdelete="ЛКМ — удалить мнимую деталь. Delete удаляет выделенные мнимые детали. Ctrl+Z возвращает их.",
		msize="ЛКМ по грани — изменить её на 1 стад. R — увеличить / уменьшить. Shift+ЛКМ — на 4 стада.",
		mchoose="Зажми ЛКМ и проведи по деталям или обведи рамкой. Shift добавляет, Ctrl исключает. Можно читать реальные блоки."
	}
	local function setTool(name,equip)
		if blocked() then releaseTool() return end
		if mode~="create" then setMode("create") if mode~="create" then return end end
		activeTool=name
		codeOpen=false syncVisibility() View.tool(name)
		toolHint.Text=hints[name]
		-- Responsive labels are handled by View.tool.
		if equip then
			ToolView.refresh()
			local hum=LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum and tools[name] then hum:EquipTool(tools[name]) end
		end
	end
	ToolView=(function()
local V={}
local sourceNames={mbuild={"Build"},mpaint={"Paint"},mdelete={"Delete"},msize={"Shape","Size"},mchoose={"Choose","Select"}}
local data=setmetatable({},{__mode="k"})
local tracks={}
local reported={}
local function sourceFor(name)
	for i=1,2 do
		local container
		if i==1 then container=LocalPlayer.Character else container=LocalPlayer:FindFirstChildOfClass("Backpack") end
		if container then for _,sourceName in ipairs(sourceNames[name] or {}) do local source=container:FindFirstChild(sourceName) if source and source:IsA("Tool") then return source end end end
	end
end
local function physical(part)
	part.Anchored=false part.CanCollide=false part.CanTouch=false part.CanQuery=false part.Massless=true
	part.LocalTransparencyModifier=0
end
local function fallback(tool,name)
	local colours={mbuild=Color3.fromRGB(177,147,255),mpaint=Color3.fromRGB(128,196,255),mdelete=Color3.fromRGB(244,115,141),msize=Color3.fromRGB(241,205,137),mchoose=Color3.fromRGB(148,230,207)}
	local sizes={mbuild=Vector3.new(.8,.8,.8),mpaint=Vector3.new(.22,1,.22),mdelete=Vector3.new(.65,.65,.65),msize=Vector3.new(1,.2,.3),mchoose=Vector3.new(.55,.55,.55)}
	local h=create("Part",{Name="Handle",Parent=tool,Size=sizes[name],Color=colours[name],Material=Enum.Material.SmoothPlastic,Transparency=0,TopSurface=Enum.SurfaceType.Smooth,BottomSurface=Enum.SurfaceType.Smooth})
	physical(h)
	if name=="mpaint" then
		local head=create("Part",{Name="Brush",Parent=h,Size=Vector3.new(.6,.32,.3),Color=Color3.fromRGB(183,146,255),Material=Enum.Material.SmoothPlastic,CFrame=h.CFrame*CFrame.new(0,.55,0)}) physical(head)
		create("WeldConstraint",{Parent=h,Part0=h,Part1=head})
	elseif name=="mchoose" then create("SelectionBox",{Parent=h,Adornee=h,Color3=colours[name],LineThickness=.04,SurfaceTransparency=1}) end
	return h
end
function V.decorate(tool,name)
	local source=sourceFor(name)
	local info=data[tool]
	if info and info.source==source and tool:FindFirstChild("Handle") then return end
	if tool.Parent==LocalPlayer.Character then return end
	local old=tool:FindFirstChild("Handle") if old then old:Destroy() end
	local h=nil
	local original=source and source:FindFirstChild("Handle")
	if original and original:IsA("BasePart") then
		local ok,copy=pcall(function() return original:Clone() end)
		if ok and copy then
			h=copy
			-- Only appearance data survives. Never copy behaviour, remotes,
			-- external joints, physical actuators or activation callbacks.
			for _,o in ipairs(h:GetDescendants()) do
				if not (o:IsA("BasePart") or o:IsA("DataModelMesh") or o:IsA("Decal") or o:IsA("Texture") or o:IsA("SurfaceAppearance") or o:IsA("Attachment") or o:IsA("Folder") or o:IsA("Model")) then o:Destroy() end
			end
			physical(h) h.Transparency=math.min(h.Transparency,.35)
			for _,o in ipairs(h:GetDescendants()) do if o:IsA("BasePart") then physical(o) create("WeldConstraint",{Parent=h,Part0=h,Part1=o}) end end
			h.Name="Handle" h.Parent=tool
			tool.Grip=source.Grip
		end
	end
	if not h then h=fallback(tool,name) end
	tool.RequiresHandle=true
	tool:SetAttribute("ImaginaryTool",true)
	data[tool]={source=source,lastAction=-math.huge,serial=0}
end
function V.refresh()
	for name,tool in pairs(tools) do if tool.Parent and tool.Parent~=LocalPlayer.Character then V.decorate(tool,name) end end
end
local function findAnimation(tool,kind)
	local info=data[tool]
	local source=info and info.source
	if source and source.Parent then
		for _,a in ipairs(source:GetDescendants()) do
			if a:IsA("Animation") and a.AnimationId~="" then
				local name=a.Name:lower()
				local idle=name:find("idle",1,true) or name:find("hold",1,true) or name:find("toolnone",1,true)
				local equip=name:find("equip",1,true) and not name:find("unequip",1,true)
				local action=name:find("activate",1,true) or name:find("action",1,true) or name:find("slash",1,true) or name:find("use",1,true) or name:find("click",1,true) or name:find("build",1,true) or name:find("paint",1,true)
				if kind=="idle" and idle or kind=="action" and action and not idle or kind=="equip" and equip then return a end
			end
		end
	end
	if kind~="idle" then return nil end
	local character=LocalPlayer.Character
	local animate=character and character:FindFirstChild("Animate")
	local folder=animate and animate:FindFirstChild("toolnone")
	if folder then for _,a in ipairs(folder:GetDescendants()) do if a:IsA("Animation") and a.AnimationId~="" then return a end end end
end
local function loadTrack(tool,kind,animation)
	local character=LocalPlayer.Character
	local hum=character and character:FindFirstChildOfClass("Humanoid")
	local animator=hum and hum:FindFirstChildOfClass("Animator")
	if not animator or not animation then return end
	local key=animation.AnimationId
	local owned=tracks[tool] or {} tracks[tool]=owned
	local entry=owned[kind]
	if entry and (entry.animator~=animator or entry.id~=key) then pcall(function() entry.track:Stop(.1) entry.track:Destroy() end) owned[kind]=nil entry=nil end
	if not entry then
		local loaded,track=pcall(function() return animator:LoadAnimation(animation) end)
		if not loaded then if not reported[key] then reported[key]=true setStatus("Анимация предмета недоступна: "..key,true) end return end
		entry={id=key,animator=animator,track=track} owned[kind]=entry
	end
	return entry.track
end
local function play(tool,kind)
	local animation=findAnimation(tool,kind)
	if not animation then return end
	-- Standard Animate may already be playing the same pose; leave it alone.
	local character=LocalPlayer.Character
	local hum=character and character:FindFirstChildOfClass("Humanoid")
	local animator=hum and hum:FindFirstChildOfClass("Animator")
	if kind=="idle" and animator then
		local ok,playing=pcall(function() return animator:GetPlayingAnimationTracks() end)
		if ok then for _,t in ipairs(playing) do if t.Animation and t.Animation.AnimationId==animation.AnimationId and t.IsPlaying then return end end end
	end
	local track=loadTrack(tool,kind,animation) if not track then return end
	pcall(function()
		track.Priority=kind=="idle" and Enum.AnimationPriority.Idle or Enum.AnimationPriority.Action
		track.Looped=kind=="idle"
		if kind~="idle" or not track.IsPlaying then track:Play(.1,1,1) end
	end)
end
-- R15 sequence observed with Build/Delete; the user confirmed all bkit tools share it.
-- These Animation instances are made dynamically by the game, outside Tools.
local verifiedSequence={"rbxassetid://17755758967","rbxassetid://17755760862"}
local function playVerified(tool)
	local character=LocalPlayer.Character
	local hum=character and character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.RigType~=Enum.HumanoidRigType.R15 or not sourceNames[tool.Name] then return false end
	local info=data[tool]
	info.serial+=1 local serial=info.serial
	local loaded={}
	for i,id in ipairs(verifiedSequence) do
		local name="ImaginaryAction"..i
		local animation=tool:FindFirstChild(name)
		if not animation then animation=create("Animation",{Name=name,AnimationId=id,Parent=tool}) end
		local track=loadTrack(tool,"phase"..i,animation)
		if not track then V.clear(tool) return true end -- Missing asset must not leave half a sequence playing.
		loaded[i]=track
	end
	local first,second=loaded[1],loaded[2]
	local function current()
		return not unloaded and info.serial==serial and mode=="create" and tool.Parent==character and LocalPlayer.Character==character and activeTool==tool.Name
	end
	local ok=pcall(function()
		first:Stop(.1) second:Stop(.1)
		first.Priority=Enum.AnimationPriority.Action second.Priority=Enum.AnimationPriority.Action
		first.Looped=false second.Looped=false
		first:Play(.1,1,1) first.TimePosition=0
	end)
	if not ok then V.clear(tool) return true end
	-- Use the measured phase timing; Length=0 is not a reliable end signal.
	task.delay(.1,function()
		if info.serial~=serial then return end
		if not current() then V.clear(tool) return end
		local played=pcall(function() first:Stop(.1) second:Play(.1,1,1) second.TimePosition=0 end)
		if not played then V.clear(tool) return end
		task.delay(.1,function()
			if info.serial==serial then pcall(function() second:Stop(.1) end) end
		end)
	end)
	return true
end
function V.equipped(tool,name)
	V.clear(tool)
	if mode=="create" and tool.Parent==LocalPlayer.Character then play(tool,"equip") end
	task.defer(function() if not unloaded and mode=="create" and tool.Parent==LocalPlayer.Character and activeTool==name then play(tool,"idle") end end)
end
function V.activated(tool)
	if mode~="create" or blocked() or not tool.Parent or tool.Parent~=LocalPlayer.Character then return end
	local info=data[tool] if not info or os.clock()-info.lastAction<.04 then return end info.lastAction=os.clock()
	if not playVerified(tool) then play(tool,"action") end
end
function V.clear(only)
	for tool,info in pairs(data) do if not only or only==tool then info.serial+=1 end end
	for tool,owned in pairs(tracks) do
		if not only or only==tool then
			for _,entry in pairs(owned) do pcall(function() entry.track:Stop(.1) entry.track:Destroy() end) end
			tracks[tool]=nil
		end
	end
end
return V

	end)()
	local function installTools()
		local backpack=LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack then return end
		for _,name in ipairs(toolNames) do
			if not tools[name] or not tools[name].Parent then
				local tool=create("Tool",{Name=name,ToolTip="Мнимый bkit · "..toolLabels[name],RequiresHandle=true,CanBeDropped=false,Enabled=mode=="create"})
				tools[name]=tool
				ToolView.decorate(tool,name) tool.Parent=backpack
				trackConn(tool.Activated:Connect(function() ToolView.activated(tool) end))
				trackConn(tool.Equipped:Connect(function() setTool(name,false) ToolView.equipped(tool,name) end))
				trackConn(tool.Unequipped:Connect(function() ToolView.clear(tool) if activeTool==name then activeTool=nil held=false end end))
			end
		end
	end
	installTools()
	trackConn(LocalPlayer.CharacterAdded:Connect(function()
		releaseTool()
		task.defer(function() if not unloaded then installTools() end end)
	end))
	trackConn(LocalPlayer.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then task.defer(function() if not unloaded then installTools() end end) end
	end))
	for name,b in pairs(toolButtons) do trackConn(b.MouseButton1Click:Connect(function() setTool(name,true) end)) end
	local ghost=create("Part",{Name="ImaginaryPlacementPreview",Size=Vector3.new(4,4,4),Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,Transparency=1,Color=Color3.fromRGB(202,163,255),Material=Enum.Material.ForceField,Parent=scene})
	local function hit()
		local camera=workspace.CurrentCamera
		if not camera then return nil end
		local point=UserInputService:GetMouseLocation()
		local ray=mouse.UnitRay
		local params=RaycastParams.new()
		params.FilterType=Enum.RaycastFilterType.Exclude
		local exclude={ghost}
		if LocalPlayer.Character then exclude[#exclude+1]=LocalPlayer.Character end
		if visualFolder then exclude[#exclude+1]=visualFolder end
		params.FilterDescendantsInstances=exclude
		params.IgnoreWater=true
		local result=workspace:Raycast(ray.Origin,ray.Direction*2000,params)
		if not result then return nil end
		local normal=result.Normal
		local x,y,z=math.abs(normal.X),math.abs(normal.Y),math.abs(normal.Z)
		local face
		if x>=y and x>=z then face=normal.X>0 and Enum.NormalId.Right or Enum.NormalId.Left
		elseif y>=z then face=normal.Y>0 and Enum.NormalId.Top or Enum.NormalId.Bottom
		else face=normal.Z>0 and Enum.NormalId.Back or Enum.NormalId.Front end
		return result,face,Vector3.FromNormalId(face)
	end
	local function candidate(result,face,normal)
		local source=parts[result.Instance]
		if copyStyle and source then return Model.clone(source,face) end
		local step=small and 1 or 4
		return {centerPos=Model.place(result.Position,normal,step),size=Vector3.new(step,step,step),color=paintColor,material=paintMaterial,canCollide=paintCollide,sprays={}}
	end
	local function fits(b,ignore)
		if not Model.valid(b) then return false,"Границы детали должны быть целыми; размер от 1 до 4096" end
		if not allowOverlap then
			for part,data in pairs(parts) do if part~=ignore and part.Parent and Model.overlaps(b,data) then return false,"Детали пересекаются. Разреши пересечения, если это задумано" end end
		end
		return true
	end
	local function eligible(part)
		if parts[part] then return true end
		local bricks=workspace:FindFirstChild("Bricks")
		return bricks and part:IsA("BasePart") and part:IsDescendantOf(bricks)
	end
	local function act()
		if blocked() or sceneInvalid or mode~="create" or not activeTool or codeOpen then return end
		local result,face,normal=hit()
		if not result then return end
		local part=result.Instance
		if activeTool=="mchoose" then
			if eligible(part) and not visited[part] then
				visited[part]=true
				selectPart(part,UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl))
			end
			return
		end
		if activeTool=="mbuild" then
			local b=candidate(result,face,normal)
			local ok,reason=fits(b)
			if not ok then setStatus(reason,true) return end
			addPart(b) commit() return
		end
		if not parts[part] then setStatus("Этот инструмент изменяет только мнимые детали",true) return end
		if activeTool=="mdelete" then
			parts[part]=nil selected[part]=nil
			if highlights[part] then highlights[part]:Destroy() highlights[part]=nil end
			part:Destroy() commit()
		elseif activeTool=="msize" then
			local step=(UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) and 4 or 1
			local b=Model.resize(parts[part],face,sizeDecrease and -step or step)
			if not b then setStatus("Размер не может быть меньше 1 стада",true) return end
			local ok,reason=fits(b,part)
			if not ok then setStatus(reason,true) return end
			updatePart(part,b) commit()
		elseif activeTool=="mpaint" then
			local targets={part}
			if selected[part] then targets={} for p in pairs(selected) do if parts[p] then targets[#targets+1]=p end end end
			for _,p in ipairs(targets) do
				local b=Model.copy(parts[p])
				if paintMode=="both" or paintMode=="color" then b.color=paintColor end
				if paintMode=="both" or paintMode=="material" then b.material=paintMaterial end
				if paintMode=="spray" then
					local next={}
					for _,s in ipairs(b.sprays) do if s.face~=face then next[#next+1]=s end end
					if paintText~="" then next[#next+1]={face=face,text=paintText,colorHex=paintTextHex} end
					b.sprays=next
				else b.canCollide=paintCollide end
				updatePart(p,b)
			end
			commit()
		end
	end
	local marquee=create("Frame",{Parent=gui,BackgroundColor3=Color3.fromRGB(168,116,255),BackgroundTransparency=.85,BorderSizePixel=0,Visible=false,ZIndex=100})
	marquee:SetAttribute("StudioFixedColor",true) addStroke(marquee,1,Color3.fromRGB(205,161,255))
	local function finishRectangle(point)
		if not pressPoint or (point-pressPoint).Magnitude<8 then return end
		local camera=workspace.CurrentCamera
		if not camera then return end
		local lo=Vector2.new(math.min(point.X,pressPoint.X),math.min(point.Y,pressPoint.Y))
		local hi=Vector2.new(math.max(point.X,pressPoint.X),math.max(point.Y,pressPoint.Y))
		local remove=UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		local candidates={}
		for part in pairs(parts) do candidates[#candidates+1]=part end
		local bricks=workspace:FindFirstChild("Bricks")
		if bricks then for _,part in ipairs(bricks:GetDescendants()) do if part:IsA("BasePart") then candidates[#candidates+1]=part end end end
		for _,part in ipairs(candidates) do
			local projected,visible=camera:WorldToViewportPoint(part.Position)
			if visible and projected.Z>0 and projected.X>=lo.X and projected.X<=hi.X and projected.Y>=lo.Y and projected.Y<=hi.Y then selectPart(part,remove,true) end
		end
		refreshSelection()
	end
	trackConn(UserInputService.InputBegan:Connect(function(input,processed)
		if unloaded then return end
		if input.UserInputType==Enum.UserInputType.Keyboard and not UserInputService:GetFocusedTextBox() then
			local ctrl=UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			if ctrl and input.KeyCode==Enum.KeyCode.Z then
				local shift=UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
				restore(shift and "redo" or "undo") return
			elseif ctrl and input.KeyCode==Enum.KeyCode.Y then restore("redo") return end
			if blocked() or sceneInvalid or mode~="create" then return end
			if input.KeyCode==Enum.KeyCode.R then
				if activeTool=="mbuild" then small=not small buildToggle.Text=small and "Куб 1 × 1 × 1 · R" or "Куб 4 × 4 × 4 · R"
				elseif activeTool=="msize" then sizeDecrease=not sizeDecrease sizeToggle.Text=sizeDecrease and "Уменьшить грань · R" or "Увеличить грань · R" end
			elseif input.KeyCode==Enum.KeyCode.Delete then
				local removed=false
				for part in pairs(selected) do if parts[part] then parts[part]=nil part:Destroy() removed=true end end
				clearSelection() if removed then commit() end
			end
		end
		if processed or input.UserInputType~=Enum.UserInputType.MouseButton1 or uiHit(UserInputService:GetMouseLocation()) or blocked() or mode~="create" then return end
		held=true visited={}
		if activeTool=="mchoose" then
			pressPoint=UserInputService:GetMouseLocation()
			if not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and not UserInputService:IsKeyDown(Enum.KeyCode.RightShift) and not UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) and not UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then clearSelection() end
		end
		act()
	end))
	trackConn(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType~=Enum.UserInputType.MouseButton1 then return end
		if held and mode=="create" and activeTool=="mchoose" and not blocked() then finishRectangle(UserInputService:GetMouseLocation()) end
		held=false pressPoint=nil marquee.Visible=false
	end))
	trackConn(UserInputService.WindowFocusReleased:Connect(function() held=false pressPoint=nil marquee.Visible=false end))
	local cursorUpdateAt=0
	trackConn(RunService.RenderStepped:Connect(function()
		if os.clock()<cursorUpdateAt then return end
		cursorUpdateAt=os.clock()+.04
		ghost.Transparency=1
		if blocked() or mode~="create" or codeOpen or uiHit(UserInputService:GetMouseLocation()) then return end
		if activeTool=="mbuild" then
			local result,face,normal=hit()
			if result then
				local b=candidate(result,face,normal)
				ghost.Size=b.size ghost.Position=b.centerPos ghost.Transparency=.65
				ghost.Color=fits(b) and Color3.fromRGB(192,144,255) or Color3.fromRGB(255,95,116)
			end
		elseif activeTool=="mchoose" and held then
			act()
			if pressPoint then
				local point=UserInputService:GetMouseLocation()
				-- This ScreenGui ignores the inset; mouse and viewport positions
				-- therefore use the same origin, including the selection frame.
				marquee.Position=UDim2.fromOffset(math.min(point.X,pressPoint.X),math.min(point.Y,pressPoint.Y))
				marquee.Size=UDim2.fromOffset(math.abs(point.X-pressPoint.X),math.abs(point.Y-pressPoint.Y))
				marquee.Visible=(point-pressPoint).Magnitude>8
			end
		end
	end))
	StudioHooks.close=function()
		sceneRevision+=1 pendingContent=nil held=false pressPoint=nil
		local errors={}
		local function closeStep(fn) local ok,err=pcall(fn) if not ok then errors[#errors+1]=tostring(err) end end
		closeStep(function() ToolView.clear() end)
		closeStep(persistHistory)
		for _,tool in pairs(tools) do closeStep(function() tool:Destroy() end) end
		closeStep(function() scene:Destroy() end)
		if #errors>0 then error(table.concat(errors,"; "),0) end
	end
	syncVisibility()
	setStatus("Выбери режим: локальная мастерская или загрузка постройки")
end)()
end

-- Performance Tracker & Progress Display Loop
local lastTime = tick()
local lastPerfUpdate = 0
trackConn(RunService.RenderStepped:Connect(function()
	local now = tick()
	local fps = math.round(1 / math.max(now - lastTime, .0001))
	lastTime = now
	if now-lastPerfUpdate<.25 then return end
	lastPerfUpdate=now
	if StudioHooks.timingDisplay then StudioHooks.timingDisplay() end
	local ping = math.round(getSafePing() * 2000)
	perfDisplay.Text = string.format("FPS: %d | RTT: %dms | ×%.1f", math.round(1/StudioHooks.timing.frame), ping,StudioHooks.timing.multiplier)

	if _G.autobuildRunning and _G.autobuildTotal and _G.autobuildTotal > 0 then
		local total = _G.autobuildTotal
		local placed = _G.autobuildPlaced or 0
		local remaining = math.max(0, total - placed)
		local remainPercent = math.clamp(math.round((remaining / total) * 100), 0, 100)
		local donePercent = 100 - remainPercent

		statDisplay.Text = string.format(
			"Осталось: %d бл. (%d%%) | Готово: %d%%",
			remaining,
			remainPercent,
			donePercent
		)
	end
end))

-- ============================================================================
-- FULL UNLOAD LOGIC
-- ============================================================================
unloadScript = function()
	if StudioHooks.unloadComplete then return true,{} end
	-- Cancellation must precede persistence: failed saves cannot leave jobs alive.
	unloaded=true _G.stopautobuild=true _G.autobuildRunning=false
	_G.autobuildPreparing=false isBuilding=false
	if StudioHooks.documents then StudioHooks.documents.pendingUI=nil end
	local errors={}
	local function step(name,fn)
		local ok,err=pcall(fn)
		if not ok then errors[#errors+1]=name..": "..tostring(err) end
	end
	step("Stairwell",function() if StudioHooks.stairwell then StudioHooks.stairwell.close() end end)
	step("Двойник",function() if StudioHooks.extras then StudioHooks.extras.close() end end)
	step("Защита",function() if StudioHooks.guard then StudioHooks.guard.close() end end)
	local sessions={} local seen={}
	local function include(session)
		if type(session)=="table" and not seen[session] then seen[session]=true sessions[#sessions+1]=session end
	end
	include(resumeSession)
	if StudioHooks.documents then
		for _,session in pairs(StudioHooks.documents.jobs) do include(session) end
		for _,session in pairs(StudioHooks.documents.orphans) do include(session) end
	end
	for _,session in ipairs(sessions) do
		step("Состояние работы",function() if StudioHooks.recovery then local saved,message=StudioHooks.recovery.capture(session,"flush") if saved==false then error(message,0) end end end)
		local function closeHolder(holder)
			local function disconnect(request)
				if request and request.connection then step("Ответ создания",function() request.connection:Disconnect() end) end
			end
			disconnect(holder.creation)
			for _,request in ipairs(holder.retired or {}) do disconnect(request) end
		end
		for _,block in ipairs(session.blocks or {}) do
			closeHolder(block)
			for _,helper in ipairs(block.work and block.work.helpers or {}) do closeHolder(helper) end
		end
	end
	if resumeSession and not resumeSession.transient then _G.AUTOBUILD_RESUME={version=2,job=game.JobId,session=resumeSession} end
	step("Кэш мира",function() if StudioHooks.liveWorld then StudioHooks.liveWorld.close() end end)
	step("Наблюдение ответов",function() if StudioHooks.recovery then StudioHooks.recovery.close() end end)
	step("Сохранение вкладок",function() saveData() if storageError then error(storageError,0) end end)
	step("Мастерская",function() if StudioHooks.close then StudioHooks.close() end end)
	for _,conn in ipairs(connections) do step("Обработчик",function() conn:Disconnect() end) end
	table.clear(connections)
	step("Удержание позиции",unlockPosition)
	step("Экипировка",stopToolForcing)
	step("Столкновения персонажа",disableNoclip)
	step("Предпросмотр",function() cleanupVisuals(false) end)
	step("Интерфейс",function() gui:Destroy() end)
	_G.visualsEnabled=false
	StudioHooks.unloadComplete=#errors==0
	-- Keep the callback on failure so a second invocation can retry cleanup.
	if StudioHooks.unloadComplete and _G.AUTOBUILD_UNLOAD==unloadScript then _G.AUTOBUILD_UNLOAD=nil end
	for _,err in ipairs(errors) do warn("ORBIT UNLOAD: "..err) end
	return StudioHooks.unloadComplete,errors
end

_G.AUTOBUILD_UNLOAD = unloadScript
setStatus("ORBIT stairwell-20: открытый вход у ног, подъём по этажам и быстрые шаблоны")
