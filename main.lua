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
local resumeSession = nil
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


local loadWarning=nil
if isfile and readfile then
	local ok, decoded=pcall(function()
		if not isfile(SAVE_FILE) then return nil end
		return HttpService:JSONDecode(readfile(SAVE_FILE))
	end)
	if ok and decoded~=nil and type(decoded)=="table" then
		local clean, rejected={},0
		for _, tab in ipairs(decoded) do
			if type(tab)=="table" and type(tab.content)=="string" then
				clean[#clean+1]={name=type(tab.name)=="string" and tab.name or "Build",content=tab.content}
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
	if StudioHooks.save then StudioHooks.save() end
	if not writefile then storageError="Нет writefile; вкладки доступны только в этом запуске" return end
	local ok,err=pcall(function() local payload=HttpService:JSONEncode(tabsData)
		writefile(SAVE_FILE..".pending",payload)
		if readfile and isfile and isfile(SAVE_FILE) then
			local old=readfile(SAVE_FILE)
			local valid=pcall(function() HttpService:JSONDecode(old) end)
			if valid then writefile(SAVE_FILE..".backup",old) end
		end
		writefile(SAVE_FILE,payload)
		if readfile and readfile(SAVE_FILE)~=payload then error("Проверка сохранения не пройдена") end end)
	storageError=not ok and tostring(err) or nil
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
local FONT_BOLD = Font.new([[rbxasset://fonts/families/Montserrat.json]], Enum.FontWeight.Bold, Enum.FontStyle.Normal)

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

local normalSize = UDim2.new(0, 800, 0, 610)
local fullSize = UDim2.new(0, 1040, 0, 720)
local minimizedSize = UDim2.new(0, 800, 0, 44)
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
	
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = hoverBg or C_LIGHT_GRAY, TextColor3 = C_WHITE}):Play()
		TweenService:Create(stroke, TweenInfo.new(0.2), {Color = defaultColor or C_GREEN}):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = C_GRAY, TextColor3 = defaultColor or C_GREEN}):Play()
		TweenService:Create(stroke, TweenInfo.new(0.2), {Color = strokeColor or C_DARK_GREEN}):Play()
	end)
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

btnClose.MouseButton1Click:Connect(function()
	bodyFrame.Visible = false
	local tween = TweenService:Create(mainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {Size = UDim2.new(0, 0, 0, 0)})
	tween:Play()
	tween.Completed:Connect(function()
		unloadScript()
	end)
end)

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
	updatingEditor = true
	editorDisplayText = value
	textBox.Text = value
	updatingEditor = false
end

local function setBuildContent(value, keepRotationPivot)
	if not keepRotationPivot then rotationPivot = nil end
	_G.fullBuildString = value
	tabsData[activeTabIndex].content = value
	if StudioHooks.content then StudioHooks.content(value) end
	invalidatePreparedPlan()
	setEditorDisplay(#value <= 60000 and value or ("[Loaded " .. #value .. " characters; COPY exports the full build]"))
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
	
	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = C_LIGHT_GRAY}):Play()
		TweenService:Create(stroke, TweenInfo.new(0.2), {Color = C_GREEN}):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = C_GRAY}):Play()
		TweenService:Create(stroke, TweenInfo.new(0.2), {Color = C_DARK_GREEN}):Play()
	end)
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
	if unloaded then return end
	message=tostring(message or "")
	if storageError then message=message.." · вкладки не записаны в файл" end
	statusLabel.Text=message
	statusLabel.TextColor3=failure and C_RED or C_WHITE
	diagnosticLog[#diagnosticLog+1]=os.date("%H:%M:%S").." "..message
	if #diagnosticLog>100 then table.remove(diagnosticLog,1) end
	if failure then warn("AUTOBUILD: "..message) end
end
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
	for _ in text:gmatch("|[^|]+|") do blockCount = blockCount + 1 end
	statDisplay.Text = "Blocks: " .. blockCount .. "  |  Chars: " .. #text
end

btnLog.MouseButton1Click:Connect(function()
	local text="Autobuild Studio v4\n"..table.concat(diagnosticLog,"\n")
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
			Size = UDim2.new(0, 115, 1, -6),
			BackgroundColor3 = isCurrent and C_BLACK or C_GRAY,
			LayoutOrder = i
		})
		addCorner(tFrame, 6)
		local stroke = addStroke(tFrame, 1, isCurrent and C_GREEN or C_DARK_GREEN)
		
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
			Text = "✕",
			TextColor3 = isCurrent and C_GREEN or Color3.fromRGB(150, 150, 150),
			FontFace = FONT_BOLD,
			TextSize = 10
		})
		
		tBtn.MouseButton1Click:Connect(function()
			if _G.autobuildRunning or busySaving then return end
	activeTabIndex = i
			setBuildContent(tab.content)
			renderTabs()
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
			if _G.autobuildRunning or busySaving then return end
	if #tabsData <= 1 then
				tabsData[1] = {name = "Build 1", content = ""}
				activeTabIndex = 1
			else
				table.remove(tabsData, i)
				if activeTabIndex >= i then
					activeTabIndex = math.max(1, activeTabIndex - 1)
				end
			end
			setBuildContent(tabsData[activeTabIndex].content)
			saveData()
			renderTabs()
		end)
		
		table.insert(tabElements, tFrame)
	end
	tabScroll.CanvasSize = UDim2.new(0, #tabsData * 123 + 6, 0, 0)
end

addTabBtn.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	table.insert(tabsData, {name = "Build " .. (#tabsData + 1), content = ""})
	activeTabIndex = #tabsData
	setBuildContent("")
	saveData()
	renderTabs()
end)

textBox:GetPropertyChangedSignal("Text"):Connect(function()
	if updatingEditor or textBox.Text == editorDisplayText then return end
	if _G.autobuildRunning or busySaving then setEditorDisplay(tabsData[activeTabIndex].content) return end
	editorDisplayText = nil
	rotationPivot = nil
	tabsData[activeTabIndex].content = textBox.Text
	if StudioHooks.content then StudioHooks.content(textBox.Text) end
	_G.fullBuildString = textBox.Text
	invalidatePreparedPlan()
	saveRevision = saveRevision + 1
	local revision = saveRevision
	task.delay(.4, function() if not unloaded and revision == saveRevision then saveData() end end)
	
	local params = Instance.new("GetTextBoundsParams")
	params.Text = textBox.Text == "" and "A" or textBox.Text
	params.Font = FONT_BOLD
	params.Size = 12
	params.Width = textScroll.AbsoluteSize.X > 0 and textScroll.AbsoluteSize.X or 300
	
	local success, result = pcall(function() return TextService:GetTextBoundsAsync(params) end)
	if success then
		textScroll.CanvasSize = UDim2.new(0, 0, 0, math.max(result.Y + 15, editorFrame.AbsoluteSize.Y - 10))
		textBox.Size = UDim2.new(1, 0, 0, math.max(result.Y + 15, editorFrame.AbsoluteSize.Y - 10))
	end
	
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
	if not ok or not ping or ping <= 0 then ping = 0.05 end
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
local function parseBlocks(text, offset)
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
	if visualFolder then visualFolder:Destroy() visualFolder = nil end
	if handles then handles:Destroy() handles = nil end
	centerPart = nil
	visualsShowing = false
	_G.visualsEnabled = false
	if not preserveOffset then
		_G.buildOffset = Vector3.zero
	end
	btnImport.Text = "ПРЕДПРОСМОТР"
end

local function showVisuals()
	local buildString = (_G.fullBuildString and _G.fullBuildString ~= "") and _G.fullBuildString or textBox.Text
	if buildString == "" then return end

	local blocks, invalid = parseBlocks(buildString, Vector3.zero)
	if #blocks == 0 or invalid > 0 then setStatus("Некорректное сохранение: " .. invalid, true) return end

	local savedOffset = snapBuildOffset(_G.buildOffset or Vector3.zero)
	cleanupVisuals(true)
	visualFolder = create("Folder", {Name = "BuildVisuals", Parent = workspace})

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
		isDragging = true
		startPositions = {}
		for _, child in pairs(visualFolder:GetChildren()) do
			if child:IsA("BasePart") then
				startPositions[child] = child.Position
			end
		end
	end)

	handles.MouseDrag:Connect(function(face, distance)
		if not isDragging then return end
		local direction = Vector3.FromNormalId(face)
		local snappedDistance = math.round(distance / CONFIG.GRID_STEP) * CONFIG.GRID_STEP
		local offset = direction * snappedDistance
		for part, startPos in pairs(startPositions) do
			if part and part.Parent then
				part.Position = startPos + offset
			end
		end
		_G.buildOffset = centerPart.Position - originalCenterPos
	invalidatePreparedPlan()
	end)

	handles.MouseButton1Up:Connect(function()
		isDragging = false
		startPositions = {}
	end)

	visualsShowing = true
	_G.visualsEnabled = true
	_G.buildOffset = savedOffset
	btnImport.Text = "REMOVE"
end

btnImport.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	if visualsShowing then
		cleanupVisuals(false)
	else
		showVisuals()
	end
end)

btnToMe.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	if not visualsShowing or not centerPart or not visualFolder then return end
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
	invalidatePreparedPlan()
end)

btnSnap.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	_G.buildOffset = snapBuildOffset(_G.buildOffset or Vector3.zero)
	showVisuals()
end)

-- ============================================================================
-- БРОНЕБОЙНАЯ МАТЕМАТИКА ПОВОРОТА ПО ВОКСЕЛЬНОЙ СЕТКЕ
-- ============================================================================
local function rotateBuild(angle)
	local buildString = (_G.fullBuildString and _G.fullBuildString ~= "") and _G.fullBuildString or textBox.Text
	if buildString == "" or _G.autobuildRunning or busySaving then return end

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
	local newBuildStr = ""
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

		newBuildStr = newBuildStr .. string.format("|%s%s%s%.0f,%.0f,%.0f.%.6f,%.6f,%.6f%s.|",
			colorHex, matSym, canColMarker, nSize.X, nSize.Y, nSize.Z, nCenterX, nCenterY, nCenterZ, spraysStr)
	end

	setBuildContent(newBuildStr, true)
	updateDefaultStats()

	if visualsShowing then
		showVisuals()
	end
end

btnRot90.MouseButton1Click:Connect(function() rotateBuild(90) end)
btnRot180.MouseButton1Click:Connect(function() rotateBuild(180) end)
btnRotNeg90.MouseButton1Click:Connect(function() rotateBuild(-90) end)

btnPaste.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	local getClip = getclipboard or (syn and syn.get_clipboard) or (Clipboard and Clipboard.get)
	local text = ""
	if getClip then
		local s, res = pcall(getClip)
		if s and type(res) == "string" then text = res end
	end
	if text == "" then
		btnPaste.Text = "EMPTY!"
		task.wait(0.7)
		btnPaste.Text = "ВСТАВИТЬ"
		return
	end

	setBuildContent(text)
	updateDefaultStats()
	btnPaste.Text = "PASTED!"
	task.wait(0.7)
	btnPaste.Text = "ВСТАВИТЬ"
end)

btnCopy.MouseButton1Click:Connect(function()
	if not exportToClipboard(_G.fullBuildString or textBox.Text) then setStatus("Буфер обмена недоступен", true) return end
	btnCopy.Text = "COPIED!"
	task.wait(1)
	btnCopy.Text = "КОПИРОВАТЬ"
end)

btnClear.MouseButton1Click:Connect(function()
	if _G.autobuildRunning or busySaving then return end
	setBuildContent("")
	_G.buildChunks = nil
	_G.totalChunks = nil
	_G.currentChunk = nil
	btnNextChunk.Visible = false
	cleanupVisuals(false)
	updateDefaultStats()
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
	setEditorDisplay("[Chunk " .. _G.currentChunk .. "/" .. _G.totalChunks .. " copied!]")
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
	if not source or not colorEqual(source.color,target.color) or source.material~=target.material then cost=cost+1 end
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
	local ops,count={},0
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
local function makeRecipe(initial,target,source,kind,face,helpers)
	local _,steps=changes(initial,target,true)
	if not steps or steps>20000 then return nil end
	local styling=styleCost(source,target)
	if not styling then return nil end
	local helperCount=helpers and #helpers or 0
	return {kind=kind,initial=initial,target=target,source=source,face=face,helpers=helpers or {},shapeSteps=steps,styleSteps=styling,operations=(kind=="reuse" and 0 or 1)+steps+styling+helperCount*2}
end
P.recipe=makeRecipe
function P.baselines(target)
	local result={}
	local lo,hi=bounds(target)
	-- Every detailed corner has the same step count; different corners can
	-- avoid obstructions during intermediate growth.
	for x=0,1 do for y=0,1 do for z=0,1 do
		local position=Vector3.new(x==0 and lo.X+.5 or hi.X-.5,y==0 and lo.Y+.5 or hi.Y-.5,z==0 and lo.Z+.5 or hi.Z-.5)
		if math.abs(position.X%1-.5)<.005 and math.abs(position.Y%1-.5)<.005 and math.abs(position.Z%1-.5)<.005 then
			local r=makeRecipe({pos=position,size=Vector3.new(1,1,1)},target,nil,"detailed")
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
		local r=makeRecipe({pos=Vector3.new(x,y,z),size=Vector3.new(4,4,4)},target,nil,"normal")
		if r then result[#result+1]=r end
	end end end
	table.sort(result,function(a,b) return a.operations<b.operations end)
	return result
end
function P.copies(source,target,bridges)
	local result={}
	if source.eligible==false then return result end
	if not styleCost(source,target) then return result end
	for _,d in ipairs(dirs) do
		-- Conservative approach envelope: both the block centre and the hit
		-- point must be reachable without relying on an unverified range bypass.
		if source.size[d.axis]/2>39.8 then continue end
		local initial={pos=source.pos+d.unit*source.size[d.axis],size=source.size}
		local recipe=makeRecipe(initial,target,source,"clone",d.face)
		if recipe then result[#result+1]=recipe end
		if bridges then
			local helpers={}
			for extra=1,2 do
				helpers[#helpers+1]={pos=initial.pos,size=initial.size}
				initial={pos=initial.pos+d.unit*source.size[d.axis],size=source.size}
				local r=makeRecipe(initial,target,source,"bridge",d.face,table.clone(helpers))
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
local function safeBox(box,target,obstacles,exclude,strict)
	local tlo,thi=bounds(target)
	local lo,hi=bounds(box)
	for _,other in ipairs(obstacles) do
		if other.id~=exclude and intersects(box,other) then
			if strict then return false end
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
function P.compile(recipe,obstacles,allTargets,exclude,checkpoint)
	if recipe.kind=="bridge" then
		for _,helper in ipairs(recipe.helpers) do
			if not safeBox(helper,recipe.target,obstacles,nil,true) or not safeBox(helper,recipe.target,allTargets,nil,true) then return nil end
		end
	end
	local ilo,ihi=bounds(recipe.initial) local tlo,thi=bounds(recipe.target)
	local lo=Vector3.new(math.min(ilo.X,tlo.X),math.min(ilo.Y,tlo.Y),math.min(ilo.Z,tlo.Z))
	local hi=Vector3.new(math.max(ihi.X,thi.X),math.max(ihi.Y,thi.Y),math.max(ihi.Z,thi.Z))
	local envelope={pos=(lo+hi)/2,size=hi-lo}
	local relevant={} for _,other in ipairs(obstacles) do if intersects(envelope,other) then relevant[#relevant+1]=other end end
	obstacles=relevant
	if not safeBox(recipe.initial,recipe.target,obstacles,exclude,false) then return nil end
	if recipe.kind=="reuse" then
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
			local value={model=m,distance=distance(m)}
			if #heap<maximum then
				heap[#heap+1]=value local i=#heap
				while i>1 do local parent=math.floor(i/2) if heap[parent].distance>=heap[i].distance then break end heap[parent],heap[i]=heap[i],heap[parent] i=parent end
			elseif value.distance<heap[1].distance then
				heap[1]=value local i=1
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
function P.prepare(targets,world,options)
	options=options or {}
	local function checkpoint(text,fraction)
		if options.cancelled and options.cancelled() then error("Подготовка остановлена",0) end
		if options.progress then options.progress(text,fraction) end
	end
	local models={} local byId={}
	for _,m in ipairs(world) do if m.eligible~=false then models[#models+1]=m end byId[m.id]=m end
	for _,m in ipairs(targets) do models[#models+1]=m byId[m.id]=m end
	local recipes,lowerCosts={},{ }
	for i,target in ipairs(targets) do
		local usedFaces={} for _,sp in ipairs(target.sprays) do if usedFaces[sp.face] then error("Блок "..i..": несколько надписей на одной грани",0) end usedFaces[sp.face]=true end
		local baseline=P.baselines(target)
		if #baseline==0 then error("Блок "..i..": границы не совместимы с целыми шагами граней",0) end
		local list={} for _,r in ipairs(baseline) do list[#list+1]=r end
		local bestCost=baseline[1].operations
		for _,source in ipairs(world) do
			if source.id==target.id and source.eligible~=false and geometry(source,target) then
				local r=makeRecipe({pos=source.pos,size=source.size},target,source,"reuse") if r then list[#list+1]=r end
			end
		end
		for _,source in ipairs(nearestModels(target,models,64)) do
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
		if i%8==0 or i==#targets then checkpoint("Анализ способов: "..i.."/"..#targets,.45*i/#targets) end
	end
	local futureSavings={} local outgoing={}
	for j,list in ipairs(recipes) do
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
	local function evaluate(name,spatial,lookahead,planNumber)
		local available={} local obstacles={} local done={} local plan={name=name,items={},operations=0,shapeSteps=0,helpers=0,score=0}
		for _,m in ipairs(world) do available[m.id]=true obstacles[#obstacles+1]=m end
		local ready={}
		local function refresh(i)
			ready[i]=nil
			for _,r in ipairs(recipes[i]) do if not r.source or available[r.source.id] then ready[i]=r break end end
		end
		for i in ipairs(targets) do refresh(i) end
		local position=options.position or targets[1].pos
		for step=1,#targets do
			local best,bestIndex,bestScore=nil,nil,math.huge
			local evaluations={}
			for i,target in ipairs(targets) do
				if not done[i] then
					local r=ready[i]
					if r and r.source and not available[r.source.id] then refresh(i) r=ready[i] end
					if r then
						local distance=math.sqrt(distanceSquared(target.pos,position))
						local travel=distance>20 and 2+.002*distance or .001*distance
						local score=spatial and distance or r.operations+travel
						if lookahead then
							local counted=0
							for _,saving in ipairs(futureList[target.id] or {}) do
								if not done[saving.index] and saving.index~=i then score=score-.2*saving.saving counted=counted+1 if counted==3 then break end end
							end
						end
						local reuseId=r.kind=="reuse" and r.source.id or nil
						evaluations[#evaluations+1]={index=i,score=score,recipe=r,reuseId=reuseId}
					end
				end
			end
			table.sort(evaluations,function(a,b) return a.score<b.score end)
			for _,choice in ipairs(evaluations) do
				if best and choice.score>bestScore then break end
				for _,candidate in ipairs(recipes[choice.index]) do
					if not candidate.source or available[candidate.source.id] then
						local compiled=P.compile(candidate,obstacles,targets,candidate.kind=="reuse" and candidate.source.id or nil,function() checkpoint(name..": проверка промежуточных объёмов",.45+.55*(planNumber-1+step/#targets)/3) end)
						if compiled then
							local score=choice.score+(spatial and 0 or compiled.operations-choice.recipe.operations)
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
			if step%8==0 or step==#targets then checkpoint(name..": "..step.."/"..#targets,.45+.55*(planNumber-1+step/#targets)/3) end
		end
		return plan
	end
	local candidates={}
	for number,setting in ipairs({{"Пространственный",true,false},{"Стоимость операций",false,false},{"Выгодные шаблоны",false,true}}) do
		local plan,err=evaluate(setting[1],setting[2],setting[3],number)
		if plan then candidates[#candidates+1]=plan elseif options.progress then options.progress(setting[1]..": "..err,.9) end
	end
	if #candidates==0 then error("Безопасный план не найден; проверьте перекрытия и геометрию",0) end
	table.sort(candidates,function(a,b) return a.score<b.score end)
	local best=candidates[1] best.alternatives=candidates
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
return P

end)()
-- A build request is never retried automatically: the server has no request IDs.
local positionLock, positionPhysics, noclipConnection, toolEquipConnection
local isBuilding = false
local collisionState, toolState = {}, {}
local equippedCharacter=nil
local function cancelled() return unloaded or _G.stopautobuild == true end
local function roundTripPing() return getSafePing()*2 end
local function responseTimeout(minimum) return math.max(minimum,roundTripPing()*4+.1) end
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
	if not visualFolder or not (session.visiblePlanIndices and session.visiblePlanIndices[index]) then return end
	local m=session.models[index]
	local part=visualFolder:FindFirstChild("Plan_State_"..index)
	if not part then
		part=create("Part",{Name="Plan_State_"..index,Parent=visualFolder,Size=m.size,Position=m.pos,Anchored=true,CanCollide=false,CanQuery=false,CanTouch=false,Transparency=1})
		create("SelectionBox",{Name="StateOutline",Parent=part,Adornee=part,LineThickness=.02,SurfaceTransparency=1})
	end
	local partial=session.blocks[index].placedBrick
	local color=session.done[index] and Color3.fromRGB(107,231,150) or (partial and partial.Parent and Color3.fromRGB(255,196,95) or Color3.fromRGB(162,136,234))
	part.StateOutline.Color3=color
end
local function refreshPlanProgress(session)
	local first
	for rank,item in ipairs(session.plan.items) do if not session.done[item.index] then first=rank break end end
	if first and (first<(session.routeWindowStart or 1) or first>=(session.routeWindowStart or 1)+192) then
		session.routeWindowStart=first session.renderedText=nil
	end
	for index in pairs(session.visiblePlanIndices or {}) do markPlanProgress(session,index) end
end
local function drawPreparedPlan(session)
	if unloaded then return end
	-- Reuse the same drawings when resuming. A hidden/destroyed preview is rebuilt.
	if session.renderedText==session.text and session.renderedOffset==session.offset and visualFolder and visualFolder:FindFirstChild("Plan_Start") then return end
	if not visualFolder then showVisuals() end
	clearPlanPreview()
	if not visualFolder then return end
	local colors={route=Color3.fromRGB(92,178,255),source=Color3.fromRGB(105,233,161),helper=Color3.fromRGB(255,184,82)}
	local function segment(a,b,color,name,width)
		local length=(b-a).Magnitude
		if length<.01 then return end
		create("Part",{Name="Plan_"..name,Parent=visualFolder,Anchored=true,CanCollide=false,CanQuery=false,CanTouch=false,Size=Vector3.new(width,width,length),CFrame=CFrame.lookAt((a+b)/2,b),Material=Enum.Material.Neon,Color=color,Transparency=.3})
	end
	local function cross(point,color,name)
		segment(point-Vector3.new(.7,0,.7),point+Vector3.new(.7,0,.7),color,name.."_a",.08)
		segment(point-Vector3.new(.7,0,-.7),point+Vector3.new(.7,0,-.7),color,name.."_b",.08)
	end
	local previous
	session.visiblePlanIndices={}
	-- A bounded moving window avoids thousands of UI objects or line segments.
	local first=session.routeWindowStart or 1
	local last=math.min(#session.plan.items,first+191)
	for rank=first,last do
		local item=session.plan.items[rank]
		session.visiblePlanIndices[item.index]=true
		local target=session.models[item.index]
		local point=target.pos+Vector3.new(0,target.size.Y/2+.7,0)
		if previous then segment(previous,point,colors.route,"Route_"..rank,.06) end
		if rank==first then
			create("Part",{Name="Plan_Start",Parent=visualFolder,Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,Shape=Enum.PartType.Ball,Size=Vector3.new(.55,.55,.55),Position=point,Material=Enum.Material.Neon,Color=colors.route,Transparency=.2})
		end
		if item.source then segment(item.source.pos,target.pos,colors.source,"Source_"..rank,.03) end
		for n,h in ipairs(item.helpers or {}) do
			local ghost=create("Part",{Name="Plan_Helper_"..rank.."_"..n,Parent=visualFolder,Anchored=true,CanCollide=false,CanQuery=false,CanTouch=false,Size=h.size,CFrame=CFrame.new(h.pos),Transparency=1})
			create("SelectionBox",{Name="Plan_HelperOutline",Parent=ghost,Adornee=ghost,Color3=colors.helper,LineThickness=.035,SurfaceTransparency=1})
			cross(h.pos+Vector3.new(0,h.size.Y/2+.7,0),colors.helper,"HelperMark_"..rank.."_"..n)
		end
		previous=point
		markPlanProgress(session,item.index)
	end
	session.renderedOffset=session.offset session.renderedText=session.text session.previewInvalid=false
end
local function advancePlanPreview(session,rank)
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
local function snapshotWorld(session)
	local result,sources={},{}
	local unfinished={}
	for i,data in ipairs(session.blocks) do if not session.done[i] and data.placedBrick then unfinished[data.placedBrick]=true end end
	local own=getPlayerBricksFolder()
	local root=workspace:FindFirstChild("Bricks")
	if not root then return result,sources end
	for _,brick in ipairs(root:GetDescendants()) do
		if brick:IsA("BasePart") and brick.Name=="Brick" then
			local cf,size=brick.CFrame,brick.Size
			local identity=(cf.RightVector-Vector3.new(1,0,0)).Magnitude<.001 and (cf.UpVector-Vector3.new(0,1,0)).Magnitude<.001
			local worldSize=Vector3.new(math.abs(cf.RightVector.X)*size.X+math.abs(cf.UpVector.X)*size.Y+math.abs(cf.LookVector.X)*size.Z,math.abs(cf.RightVector.Y)*size.X+math.abs(cf.UpVector.Y)*size.Y+math.abs(cf.LookVector.Y)*size.Z,math.abs(cf.RightVector.Z)*size.X+math.abs(cf.UpVector.Z)*size.Y+math.abs(cf.LookVector.Z)*size.Z)
			local id=session.ids[brick]
			if not id then session.nextWorld=session.nextWorld+1 id="w:"..session.nextWorld session.ids[brick]=id end
			local opaque=brick.Transparency<.001 or (brick.Material==Enum.Material.Glass and math.abs(brick.Transparency-.5)<.001)
			local eligible=own and brick:IsDescendantOf(own) and identity and brick.Anchored and opaque and brick:IsA("Part") and brick.Shape==Enum.PartType.Block and SymbolToMaterial[MaterialSymbols[brick.Material]]~=nil
			local model={id=id,pos=brick.Position,size=worldSize,color=brick.Color,material=brick.Material,collide=brick.CanCollide,sprays=readSprays(brick),instance=brick,external=true,eligible=eligible==true and not session.helpers[brick] and not unfinished[brick]}
			result[#result+1]=model
			if model.eligible and not session.helpers[brick] then sources[#sources+1]=model end
			session.instances[id]=brick
		end
	end
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
	local stored={version=4,planner="bounds-v3-studio-2",text=session.text,offset=planVector(session.offset),world=planWorldKey(scene,clearance),clearance={pos=planVector(clearance.pos),size=planVector(clearance.size)},bridges=bridges,name=plan.name,operations=plan.operations,shapeSteps=plan.shapeSteps,helpers=plan.helpers,items={}}
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
		if stored.version~=4 or stored.planner~="bounds-v3-studio-2" or stored.text~=session.text or readPlanVector(stored.offset)~=session.offset or stored.bridges~=bridges or type(stored.clearance)~="table" then return nil end
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
			local item={index=i,kind=entry.kind,operations=entry.operations,shapeSteps=entry.shapeSteps,helpers={}}
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

local function instanceModel(brick,id)
	return {id=id,pos=brick.Position,size=brick.Size,color=brick.Color,material=brick.Material,collide=brick.CanCollide,sprays=readSprays(brick),instance=brick,eligible=true}
end
local function matchesAll(brick,data)
	if not geometryMatches(brick,data) or not brick.Anchored or not sameColor(brick.Color,data.color) or brick.Material~=data.material or brick.CanCollide~=data.canCollide then return false end
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
		if data.placedBrick and matchesAll(data.placedBrick,data) and not data.pendingResize and not data.pendingCollision and not data.creation and not cleanup then
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

local function ensureNear(position,sourcePosition)
	local hrp=getValidHRP()
	if not hrp or cancelled() then return false end
	if positionLock and (hrp.Position-position).Magnitude<=20 and (not sourcePosition or (hrp.Position-sourcePosition).Magnitude<=20) then return true end
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
	local readyAt=os.clock()+math.clamp(roundTripPing(),.06,.3)
	return waitUntil(function()
		local c=LocalPlayer.Character
		local r=c and c:FindFirstChild("HumanoidRootPart")
		return os.clock()>=readyAt and r and (r.Position-target).Magnitude<.1
	end,2)
end
local function facePoint(model,face)
	for _,d in ipairs(Planner.directions) do
		if d.face==face then return model.pos+d.unit*(model.size[d.axis]/2) end
	end
	return model.pos
end
local function createOnce(holder,source,face,initial,mode,session,label)
	if holder.brick and holder.brick.Parent then return holder.brick end
	local folder=getPlayerBricksFolder()
	local tool=not holder.creation and awaitTool("Build") or nil
	if not folder or (not holder.creation and not tool) then return nil,"Нет Build или вашей папки блоков" end
	if not holder.creation then
		if source and (not source.Parent or not source.Anchored) then return nil,"Источник копии удалён или изменён" end
		if source then
			local prediction
			for _,d in ipairs(Planner.directions) do if d.face==face then prediction=source.Position+d.unit*source.Size[d.axis] break end end
			if not prediction or (prediction-initial.pos).Magnitude>.03 or (source.Size-initial.size).Magnitude>.03 then return nil,"Источник копии изменил положение или размер" end
		end
		local input=source and facePoint(instanceModel(source,"input"),face) or initial.pos
		if not source and mode=="detailed" then input=input+CONFIG.DETAILED_INPUT_OFFSET end
		if not ensureNear(input,source and source.Position or nil) then return nil,"Не удалось подойти к точке создания и источнику" end
		local obstacles=snapshotWorld(session)
		if not Planner.safeBox(initial,holder.finalModel or initial,obstacles,nil,holder.temporary==true) then return nil,"Промежуточный объём занят; создание остановлено" end
		holder.creation={candidates={},before={},folder=folder}
		for _,existing in ipairs(folder:GetChildren()) do holder.creation.before[existing]=true end
		local creation=holder.creation
		creation.connection=trackConn(folder.ChildAdded:Connect(function(child)
			if child:IsA("BasePart") and child.Name=="Brick" then creation.candidates[#creation.candidates+1]=child end
		end))
		if cancelled() then creation.connection:Disconnect() holder.creation=nil return nil,"Пауза" end
		session.actual.creates=session.actual.creates+1
		local ok,err=pcall(function() tool.event:FireServer(source or workspace.Terrain,face or Enum.NormalId.Top,input,mode) end)
		if not ok then creation.connection:Disconnect() holder.creation=nil return nil,tostring(err) end
	end
	local creation=holder.creation
	if creation.folder~=folder then
		creation.connection:Disconnect() creation.folder=folder
		creation.connection=trackConn(folder.ChildAdded:Connect(function(child)
			if child:IsA("BasePart") and child.Name=="Brick" then creation.candidates[#creation.candidates+1]=child end
		end))
	end
	-- A reset can replace the owner folder between the request and its response.
	-- Reconcile late candidates by identity, without ever repeating the request.
	local seen={}
	for _,candidate in ipairs(creation.candidates) do seen[candidate]=true end
	for _,candidate in ipairs(folder:GetChildren()) do
		if not creation.before[candidate] and not seen[candidate] and candidate:IsA("BasePart") and candidate.Name=="Brick" then
			creation.candidates[#creation.candidates+1]=candidate seen[candidate]=true
		end
	end
	local selected,ambiguous
	local ok=waitUntil(function()
		local candidates={}
		for _,brick in ipairs(holder.creation.candidates) do
			if brick.Parent and (brick.Position-initial.pos).Magnitude<.03 and (brick.Size-initial.size).Magnitude<.03 then candidates[#candidates+1]=brick end
		end
		if #candidates>1 then ambiguous=true return true end
		if #candidates==1 then selected=candidates[1] return true end
		return false
	end,responseTimeout(5))
	if ambiguous then return nil,"Получены несколько подходящих новых блоков; автоматический выбор остановлен" end
	if not ok or not selected then
		local detail="Создание не подтверждено; новых блоков: "..#holder.creation.candidates
		for _,b in ipairs(holder.creation.candidates) do if b.Parent then detail=detail.."; факт "..tostring(b.Position).." / "..tostring(b.Size) break end end
		return nil,detail.."; ожидалось "..tostring(initial.pos).." / "..tostring(initial.size)..". Запрос не повторён."
	end
	holder.creation.connection:Disconnect() holder.creation=nil holder.brick=selected
	return selected
end
local function boundaryEdit(brick,target,session,data)
	if data.pendingResize then
		local pending=data.pendingResize
		if pending.brick~=brick then return false,"Изменился блок ожидающего ресайза" end
		if not waitUntil(function() return brick.Parent and (brick.Size-pending.step.after.size).Magnitude<.03 and (brick.Position-pending.step.after.pos).Magnitude<.03 end,responseTimeout(2)) then return false,"Ожидаю подтверждение ранее отправленного шага грани; повтор не отправлен" end
		data.pendingResize=nil
	end
	local partial=instanceModel(brick,session.ids[brick] or "partial")
	local obstacles=snapshotWorld(session)
	local recipe=Planner.chooseLive(target,{},obstacles,session.models,false,partial)
	if not recipe then return false,"Нельзя безопасно изменить границы текущего блока" end
	for _,step in ipairs(recipe.steps) do
		if cancelled() then return false,"Пауза" end
		if (brick.Position-step.before.pos).Magnitude>.03 or (brick.Size-step.before.size).Magnitude>.03 then return false,"Блок изменился до шага ресайза" end
		local scene=snapshotWorld(session)
		if not Planner.safeBox(step.after,target,scene,session.ids[brick],false) then return false,"Путь изменения грани занят другим блоком" end
		if not ensureNear(brick.Position) then return false,"Персонаж недоступен для ресайза" end
		local tool=awaitTool("Shape")
		local hrp=LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not tool or not hrp or cancelled() then return false,"Нет Shape или персонажа" end
		session.actual.shapes=session.actual.shapes+1
		data.pendingResize={brick=brick,step=step}
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
		local obstacles,sources=snapshotWorld(session)
		local reviewed=session.planByIndex[index]
		local recipe=Planner.chooseLive(target,sources,obstacles,session.models,reviewed.kind=="bridge" and findTool("Delete")~=nil)
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
	if not ensureNear(brick.Position) then return false,"Не удалось подойти для проверки свойств" end
	if not paintBlock(brick,data) then return false,"Цвет или материал не подтверждён" end
	if not collisionConfirmed(brick,data) then return false,"Столкновения не подтверждены; повтор переключения не отправлен" end
	for _,sp in ipairs(data.sprays) do if not sprayBlock(brick,sp) then return false,"Надпись не подтверждена" end end
	if not matchesAll(brick,data) then return false,"Итоговая проверка геометрии или свойств не пройдена" end
	for n=#work.helpers,1,-1 do local removed,message=deleteHelper(work.helpers[n],session) if not removed then return false,message end end
	if not matchesAll(brick,data) then return false,"Целевой блок изменился после удаления временных деталей" end
	return true
end
local function runBuilderEngine(buildString,offset,prepareOnly)
	if not resumeSession or resumeSession.text~=buildString or resumeSession.offset~=offset then
		if resumeSession then
			for helper in pairs(resumeSession.helpers or {}) do if helper.Parent then return false,"Остались временные блоки предыдущей стройки. Продолжите её для удаления." end end
			for _,old in ipairs(resumeSession.blocks) do
				if old.pendingResize or old.pendingCollision or old.creation then return false,"Есть неподтверждённый запрос предыдущей стройки. Продолжите её перед сменой данных." end
				for _,holder in ipairs(old.work and old.work.helpers or {}) do if holder.creation then return false,"Есть неподтверждённый временный блок. Продолжите предыдущую стройку." end end
			end
			for _,old in ipairs(resumeSession.blocks) do if old.creation then old.creation.connection:Disconnect() end end
		end
		local blocks,invalid=parseBlocks(buildString,offset)
		if invalid>0 or #blocks==0 then return false,"Некорректные данные постройки" end
		resumeSession={text=buildString,offset=offset,blocks=blocks,done={},models={},ids={},instances={},nextWorld=0,helpers={},actual={creates=0,shapes=0,deletes=0}}
		for i,data in ipairs(blocks) do resumeSession.models[i]=targetModel(data,i) end
	end
	local session=resumeSession
	reconcileBuild(session)
	_G.autobuildTotal=#session.blocks _G.autobuildPlaced=0
	for i,data in ipairs(session.blocks) do
		if session.done[i] and not matchesAll(data.placedBrick,data) then session.done[i]=nil end
		if session.done[i] then _G.autobuildPlaced=_G.autobuildPlaced+1 end
	end
	if not session.plan then
		local scene=snapshotWorld(session)
		local char=LocalPlayer.Character local root=char and char:FindFirstChild("HumanoidRootPart")
		local started=os.clock()
		btnStart.Text="ГОТОВЛЮ ПЛАН"
		local cached=loadPreparedPlan(session,scene,findTool("Delete")~=nil)
		session.plan=cached or Planner.prepare(session.models,scene,{bridges=findTool("Delete")~=nil,position=root and root.Position or session.models[1].pos,cancelled=cancelled,progress=function(text,fraction)
			setStatus(string.format("Подготовка %d%% · %s",math.round(fraction*100),text))
			statDisplay.Text="Подготовка · "..#session.blocks.." блоков"
			task.wait()
		end})
		local plan=session.plan
		if not cached then savePreparedPlan(session,scene,findTool("Delete")~=nil) end
		session.planByIndex={}
		for _,item in ipairs(plan.items) do session.planByIndex[item.index]=item end
		setStatus(string.format("План: %s · операций ~%d · грани %d · временных %d · подготовка %.1fс",plan.name,plan.operations,plan.shapeSteps,plan.helpers,os.clock()-started))
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
	if handles then handles:Destroy() handles=nil end
	task.wait()
	enableNoclip() startToolForcing()
	for rank,item in ipairs(session.plan.items) do
		advancePlanPreview(session,rank)
		local i=item.index local data=session.blocks[i]
		if cancelled() then return false,"Пауза. План и временные детали сохранены для продолжения." end
		if not session.done[i] then
			local ok,err=executeBlock(data,i,session)
			if not ok then return false,err end
			session.done[i]=true _G.autobuildPlaced=_G.autobuildPlaced+1
			markPlanProgress(session,i)
			if visualFolder then local visual=visualFolder:FindFirstChild("Visual_"..i) if visual then visual:Destroy() end end
		end
	end
	return true,string.format("Готово: %d блоков · созданий %d · изменений граней %d · удалений временных %d",#session.blocks,session.actual.creates,session.actual.shapes,session.actual.deletes)
end
local function launchAction(forcePreparation)
	if busySaving then setStatus("Дождитесь сохранения") return end
	if isBuilding then _G.stopautobuild=true btnStart.Text="ОСТАНОВКА…" setStatus("Останавливаю; отправленный запрос может завершиться") return end
	local text=_G.fullBuildString or textBox.Text
	local blocks,invalid=parseBlocks(text,Vector3.zero)
	if #blocks==0 or invalid>0 then setStatus("Некорректная постройка",true) return end
	local offset=snapBuildOffset(_G.buildOffset or Vector3.zero)
	local prepared=resumeSession and resumeSession.text==text and resumeSession.offset==offset and resumeSession.plan~=nil and not resumeSession.previewInvalid
	local prepareOnly=false
	if forcePreparation and prepared then resumeSession.plan=nil end
	_G.buildOffset=offset _G.stopautobuild=false _G.autobuildRunning=true
	_G.autobuildTotal=#blocks _G.autobuildPlaced=0
	isBuilding=true textBox.TextEditable=false btnStart.Text="ГОТОВЛЮ ПЛАН" btnStart.TextColor3=C_RED
	if handles then handles:Destroy() handles=nil end
	task.spawn(function()
		local ok,finished,message=pcall(runBuilderEngine,text,offset,prepareOnly)
		unlockPosition() stopToolForcing() disableNoclip() isBuilding=false
		if unloaded then return end
		_G.autobuildRunning=false textBox.TextEditable=true btnStart.TextColor3=C_GREEN
		btnStart.Text=ok and finished and (prepareOnly and "СТРОИТЬ ПО ПЛАНУ" or "СТРОИТЬ") or "ПРОДОЛЖИТЬ"
		if ok and finished and not prepareOnly then cleanupVisuals(true) end
		setStatus(ok and message or tostring(finished),not ok or not finished and not _G.stopautobuild)
		statDisplay.Text=prepareOnly and ok and finished and ("План · действий ~"..resumeSession.plan.operations) or string.format("Готово: %d/%d",_G.autobuildPlaced or 0,#blocks)
	end)
end
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
	end
	return true
end
function H.clone(s)
	local next={tabs={},active=s.active}
	for i,t in ipairs(s.tabs) do next.tabs[i]={name=t.name,content=t.content} end
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
	local mutedHistory=false
	local historyFile="AutobuildStudioHistory-v4.json"
	local function snapshot()
		return History.clone({tabs=tabsData,active=activeTabIndex})
	end
	local baseline=snapshot()
	if isfile and readfile then
		pcall(function()
			if isfile(historyFile) then History.load(HttpService:JSONDecode(readfile(historyFile)),baseline) end
		end)
	end
	local function persistHistory()
		if not writefile then return end
		local ok=pcall(function()
			writefile(historyFile,HttpService:JSONEncode({version=4,current=snapshot(),undo=History.undo,redo=History.redo}))
		end)
		if not ok then setStatus("Вкладки сохранены; история отмены не записана",true) end
	end
	local function remember()
		local current=snapshot()
		if not mutedHistory and History.record(baseline,current) then persistHistory() end
		baseline=current
	end
	StudioHooks.save=remember
	local palette={}
	local palettes={
		load={base=Color3.fromRGB(250,247,235),panel=Color3.fromRGB(240,235,216),hover=Color3.fromRGB(231,222,194),accent=Color3.fromRGB(126,86,13),line=Color3.fromRGB(204,183,130),text=Color3.fromRGB(45,39,25)},
		create={base=Color3.fromRGB(17,13,34),panel=Color3.fromRGB(31,24,54),hover=Color3.fromRGB(49,36,78),accent=Color3.fromRGB(202,163,255),line=Color3.fromRGB(91,64,137),text=Color3.fromRGB(241,233,255)}
	}
	local roles=setmetatable({},{__mode="k"})
	local function style(object)
		if not object:IsDescendantOf(gui) then return end
		if object:GetAttribute("StudioFixedColor") then return end
		if object:IsA("GuiObject") then
			local r=roles[object]
			if not r then
				r={}
				local c=object.BackgroundColor3
				r.bg=(c==C_BLACK and "base") or (c==C_GRAY and "panel") or (c==C_LIGHT_GRAY and "hover")
				if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
					r.text=object.TextColor3==C_RED and "danger" or "text"
				end
				roles[object]=r
			end
			if r.bg then object.BackgroundColor3=palette[r.bg] end
			if r.text then object.TextColor3=r.text=="danger" and C_RED or palette.text end
			if object:IsA("TextBox") then object.PlaceholderColor3=palette.accent end
			if object:IsA("ScrollingFrame") then object.ScrollBarImageColor3=palette.accent end
		elseif object:IsA("UIStroke") then object.Color=palette.line object.Thickness=1 end
	end
	local function applyTheme(which)
		palette=palettes[which]
		for _,v in ipairs(gui:GetDescendants()) do style(v) end
		C_BLACK=palette.base C_GRAY=palette.panel C_LIGHT_GRAY=palette.hover
		C_GREEN=palette.accent C_DARK_GREEN=palette.line C_WHITE=palette.text
		borderGradient.Color=ColorSequence.new(palette.line)
	end
	-- Assign roles against the original palette before replacing its variables.
	palette=palettes.load
	for _,v in ipairs(gui:GetDescendants()) do style(v) end
	applyTheme("load")
	StudioHooks.style=style
	mainStroke.Thickness=1
	header.Size=UDim2.new(1,0,0,44)
	bodyFrame.Position=UDim2.fromOffset(0,44)
	bodyFrame.Size=UDim2.new(1,0,1,-44)
	title.Text="AUTOBUILD / STUDIO"
	title.TextSize=17
	title.Position=UDim2.fromOffset(18,0)
	local scale=create("UIScale",{Parent=mainFrame,Scale=1})
	gui.IgnoreGuiInset=true
	local function fit()
		local camera=workspace.CurrentCamera
		if not camera then return end
		local size=isMaximized and fullSize or normalSize
		scale.Scale=math.min(1,(camera.ViewportSize.X-24)/size.X.Offset,(camera.ViewportSize.Y-24)/size.Y.Offset)
	end
	local fitClock=0
	trackConn(RunService.RenderStepped:Connect(function(dt)
		fitClock+=dt
		if fitClock>.5 then fitClock=0 fit() end
	end))
	fit()
	local function label(parent,text,pos,size,textSize)
		return create("TextLabel",{Parent=parent,Text=text,Position=pos,Size=size,BackgroundTransparency=1,TextColor3=C_WHITE,FontFace=FONT_BOLD,TextSize=textSize or 13,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left})
	end
	local function button(parent,text,pos,size,callback)
		local b=create("TextButton",{Parent=parent,Text=text,Position=pos,Size=size,BackgroundColor3=C_GRAY,TextColor3=C_WHITE,FontFace=FONT_BOLD,TextSize=12,TextWrapped=true,AutoButtonColor=true})
		addCorner(b,9) addStroke(b,1,C_DARK_GREEN)
		if callback then trackConn(b.MouseButton1Click:Connect(callback)) end
		return b
	end
	local function field(parent,text,pos,size)
		local f=create("TextBox",{Parent=parent,Text=text,Position=pos,Size=size,BackgroundColor3=C_BLACK,TextColor3=C_WHITE,ClearTextOnFocus=false,FontFace=FONT_BOLD,TextSize=12})
		addCorner(f,7) addStroke(f,1,C_DARK_GREEN)
		return f
	end
	local modeBar=create("Frame",{Parent=bodyFrame,BackgroundTransparency=1,Position=UDim2.fromOffset(14,5),Size=UDim2.new(1,-28,0,36)})
	local createModeBtn=button(modeBar,"✦ Творить",UDim2.fromOffset(0,0),UDim2.fromOffset(128,34))
	local loadModeBtn=button(modeBar,"↑ Грузить",UDim2.fromOffset(136,0),UDim2.fromOffset(128,34))
	local undoBtn=button(modeBar,"↶",UDim2.new(1,-148,0,0),UDim2.fromOffset(34,34))
	local redoBtn=button(modeBar,"↷",UDim2.new(1,-108,0,0),UDim2.fromOffset(34,34))
	local codeBtn=button(modeBar,"Код",UDim2.new(1,-68,0,0),UDim2.fromOffset(68,34))
	tabSection.Position=UDim2.fromOffset(14,48)
	tabSection.Size=UDim2.new(1,-28,0,34)
	editorFrame.Position=UDim2.fromOffset(14,90)
	editorFrame.Size=UDim2.new(1,-224,1,-156)
	sideContainer.Position=UDim2.new(1,-196,0,90)
	sideContainer.Size=UDim2.new(0,182,1,-156)
	footerFrame.Position=UDim2.new(0,14,1,-62)
	footerFrame.Size=UDim2.new(1,-28,0,58)
	textScroll.Position=UDim2.fromOffset(12,12)
	textScroll.Size=UDim2.new(1,-24,1,-24)
	textBox.PlaceholderText="Вставь код постройки и нажми «Строить». План рассчитывается автоматически перед строительством."
	textBox.TextSize=13
	local primary={btnStart,btnImport,btnToMe,btnSave,btnMode}
	local extra={btnRot90,btnRot180,btnRotNeg90,btnPaste,btnCopy,btnClear,btnSnap,btnLog}
	local captions={
		[btnStart]="Строить",[btnImport]="Предпросмотр",[btnToMe]="Ко мне",[btnSave]="Снять постройку",[btnMode]="Выбрать игроков",
		[btnRot90]="Повернуть +90°",[btnRot180]="Повернуть 180°",[btnRotNeg90]="Повернуть −90°",[btnPaste]="Вставить код",[btnCopy]="Скопировать код",[btnClear]="Очистить код",[btnSnap]="На сетку",[btnLog]="Диагностика"
	}
	for i,b in ipairs(primary) do b.LayoutOrder=i b.Size=UDim2.new(1,-4,0,38) b.TextSize=12 b.Text=captions[b] end
	for i,b in ipairs(extra) do b.LayoutOrder=20+i b.Size=UDim2.new(1,-4,0,34) b.TextSize=12 b.Text=captions[b] end
	local moreBtn=button(sideContainer,"Ещё действия ▾",UDim2.new(),UDim2.new(1,-4,0,34))
	moreBtn.LayoutOrder=10
	local creator=create("ScrollingFrame",{Parent=bodyFrame,Position=editorFrame.Position,Size=editorFrame.Size,BackgroundColor3=C_GRAY,ScrollBarThickness=3,CanvasSize=UDim2.fromOffset(0,630),Visible=false})
	addCorner(creator,12) addStroke(creator,1,C_DARK_GREEN)
	label(creator,"Твоя мастерская",UDim2.fromOffset(18,16),UDim2.new(1,-36,0,30),22)
	label(creator,"Локальные детали · доступны без bkit",UDim2.fromOffset(18,50),UDim2.new(1,-36,0,22),12)
	local sceneStats=label(creator,"0 деталей",UDim2.fromOffset(18,82),UDim2.new(1,-36,0,28),14)
	local toolHint=label(creator,"Выбери инструмент справа или в инвентаре.",UDim2.fromOffset(18,118),UDim2.new(1,-36,0,56),14)
	local editorTools=create("Frame",{Parent=sideContainer,BackgroundTransparency=1,Size=UDim2.new(1,-4,0,300),LayoutOrder=0,Visible=false})
	local toolButtons={}
	local toolNames={"mbuild","mpaint","mdelete","msize","mchoose"}
	local toolLabels={mbuild="▧  Построить",mpaint="◈  Покрасить",mdelete="×  Удалить",msize="↔  Размер",mchoose="□  Выделить"}
	for i,name in ipairs(toolNames) do toolButtons[name]=button(editorTools,toolLabels[name],UDim2.fromOffset(0,(i-1)*43),UDim2.new(1,0,0,38)) end
	local selectionStats=label(editorTools,"Выбрано: 0",UDim2.fromOffset(4,218),UDim2.new(1,-8,0,22),12)
	local toCodeBtn=button(editorTools,"Выделенное → вкладка",UDim2.fromOffset(0,245),UDim2.new(1,0,0,36))
	local toolOptions=create("Frame",{Parent=creator,Position=UDim2.fromOffset(18,190),Size=UDim2.new(1,-36,0,390),BackgroundTransparency=1})
	local buildToggle=button(toolOptions,"Куб 4 × 4 × 4 · R",UDim2.fromOffset(0,0),UDim2.new(.5,-4,0,34))
	local sizeToggle=button(toolOptions,"Увеличить грань · R",UDim2.new(.5,4,0,0),UDim2.new(.5,-4,0,34))
	local copyToggle=button(toolOptions,"Копировать деталь: да",UDim2.fromOffset(0,42),UDim2.new(.5,-4,0,34))
	local overlapToggle=button(toolOptions,"Пересечения: нет",UDim2.new(.5,4,0,42),UDim2.new(.5,-4,0,34))
	label(toolOptions,"Цвет HEX",UDim2.fromOffset(0,90),UDim2.fromOffset(90,24))
	local hexField=field(toolOptions,"C0C0C0",UDim2.fromOffset(96,86),UDim2.fromOffset(100,32))
	local swatch=create("Frame",{Parent=toolOptions,BackgroundColor3=paintColor,Position=UDim2.fromOffset(204,86),Size=UDim2.fromOffset(32,32)})
	swatch:SetAttribute("StudioFixedColor",true) addCorner(swatch,8)
	local materialButton=button(toolOptions,"Материал: Plastic ▾",UDim2.fromOffset(0,126),UDim2.new(1,0,0,34))
	local materialList=create("ScrollingFrame",{Parent=creator,Position=UDim2.fromOffset(18,190),Size=UDim2.new(1,-36,0,330),BackgroundColor3=C_BLACK,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollBarThickness=4,Visible=false,ZIndex=8})
	addCorner(materialList,10)
	create("UIListLayout",{Parent=materialList,Padding=UDim.new(0,4)})
	local materials={}
	for material in pairs(MaterialSymbols) do materials[#materials+1]=material end
	table.sort(materials,function(a,b) return a.Name<b.Name end)
	for _,material in ipairs(materials) do
		local b=button(materialList,material.Name,UDim2.new(),UDim2.new(1,-6,0,32),function()
			paintMaterial=material materialButton.Text="Материал: "..material.Name.." ▾" materialList.Visible=false
		end)
		b.ZIndex=9
	end
	local paintModeButton=button(toolOptions,"Покраска: цвет + материал",UDim2.fromOffset(0,168),UDim2.new(1,0,0,34))
	local collideToggle=button(toolOptions,"Collide в коде: включён",UDim2.fromOffset(0,210),UDim2.new(1,0,0,34))
	local sprayField=field(toolOptions,"",UDim2.fromOffset(0,252),UDim2.new(.72,-4,0,34))
	sprayField.PlaceholderText="Текст на выбранной грани"
	local sprayColorField=field(toolOptions,"FFFFFF",UDim2.new(.72,4,0,252),UDim2.new(.28,-4,0,34))
	label(toolOptions,"Все детали закреплены. Collide хранится для настоящей постройки; локальные детали не мешают персонажу.",UDim2.fromOffset(0,296),UDim2.new(1,0,0,58),11)
	local selectionCopy=button(creator,"Копировать выделение",UDim2.fromOffset(18,586),UDim2.new(.5,-22,0,32))
	local selectionClear=button(creator,"Снять выделение",UDim2.new(.5,4,0,586),UDim2.new(.5,-22,0,32))
	local welcome=create("Frame",{Parent=bodyFrame,Size=UDim2.new(1,0,1,0),BackgroundColor3=C_BLACK,ZIndex=30})
	local welcomeTitle=label(welcome,"Что будем делать?",UDim2.fromOffset(28,38),UDim2.new(1,-56,0,45),28)
	welcomeTitle.ZIndex=31
	local welcomeSub=label(welcome,"Создай свою постройку или загрузи готовую",UDim2.fromOffset(28,91),UDim2.new(1,-56,0,28),14)
	welcomeSub.ZIndex=31
	local cards={}
	for i,which in ipairs({"create","load"}) do
		local card=button(welcome,"",UDim2.new((i-1)*.5,24,0,153),UDim2.new(.5,-36,1,-208))
		card.ZIndex=31
		card:SetAttribute("StudioFixedColor",true)
		card.BackgroundColor3=which=="create" and Color3.fromRGB(35,25,66) or Color3.fromRGB(239,226,183)
		local ink=which=="create" and Color3.fromRGB(224,200,255) or Color3.fromRGB(109,76,17)
		local heading=label(card,which=="create" and "Творить" or "Грузить",UDim2.new(0,22,1,-96),UDim2.new(1,-44,0,34),24)
		heading:SetAttribute("StudioFixedColor",true) heading.TextColor3=ink heading.ZIndex=32
		local description=label(card,which=="create" and "Мнимый bkit · локальная мастерская" or "Код → план → настоящая постройка",UDim2.new(0,22,1,-55),UDim2.new(1,-44,0,35),12)
		description:SetAttribute("StudioFixedColor",true) description.TextColor3=ink description.ZIndex=32
		local art=create("Frame",{Parent=card,Position=UDim2.new(.5,-70,.4,-52),Size=UDim2.fromOffset(140,110),BackgroundTransparency=1,ZIndex=32})
		local function shape(pos,size,rotation)
			local item=create("Frame",{Parent=art,Position=pos,Size=size,BackgroundColor3=ink,BorderSizePixel=0,Rotation=rotation or 0,ZIndex=33})
			item:SetAttribute("StudioFixedColor",true) addCorner(item,4) return item
		end
		if which=="create" then
			shape(UDim2.fromOffset(25,26),UDim2.fromOffset(56,56),-12)
			shape(UDim2.fromOffset(91,16),UDim2.fromOffset(10,78),28)
			shape(UDim2.fromOffset(77,3),UDim2.fromOffset(34,20),28)
			for star=1,7 do shape(UDim2.fromOffset((star*41)%134,(star*29)%106),UDim2.fromOffset(3,3),45) end
		else
			shape(UDim2.fromOffset(21,80),UDim2.fromOffset(98,10))
			shape(UDim2.fromOffset(21,66),UDim2.fromOffset(10,20))
			shape(UDim2.fromOffset(109,66),UDim2.fromOffset(10,20))
			shape(UDim2.fromOffset(65,21),UDim2.fromOffset(10,50))
			shape(UDim2.fromOffset(51,13),UDim2.fromOffset(27,10),-45)
			shape(UDim2.fromOffset(62,13),UDim2.fromOffset(27,10),45)
		end
		cards[which]=card
	end
	local function blocked() return unloaded or _G.autobuildRunning or busySaving or sceneLoading or pendingContent~=nil end
	local function uiHit(point)
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
		sceneStats.Text=string.format("%d деталей · сохраняется автоматически",#collect(false))
		refreshSelection()
	end
	local function commit()
		local code=codeFor(collect(false))
		updatingScene=true
		_G.buildOffset=Vector3.zero
		setBuildContent(code)
		updatingScene=false
		loadedContent=code lastContentTab=activeTabIndex loadedOffset=Vector3.zero sceneInvalid=false
		updateDefaultStats() updateSceneStats()
	end
	local loadScene
	loadScene=function(code)
		if sceneLoading then pendingContent=code return false end
		pendingContent=nil
		if loadedContent==code and lastContentTab==activeTabIndex and loadedOffset==(_G.buildOffset or Vector3.zero) then return true end
		local blocks,invalid=parseBlocks(code,_G.buildOffset or Vector3.zero)
		if invalid>0 then sceneInvalid=true setStatus("Код содержит ошибки; мастерская не заменена",true) return false end
		sceneLoading=true sceneInvalid=false
		local tab=activeTabIndex
		local offset=_G.buildOffset or Vector3.zero
		clearSelection()
		for part in pairs(parts) do part:Destroy() end
		table.clear(parts) table.clear(order)
		for i,b in ipairs(blocks) do
			addPart(b)
			if i%200==0 then task.wait() if unloaded then sceneLoading=false return false end end
		end
		loadedContent=code lastContentTab=tab loadedOffset=offset
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
		if mode=="create" then
			pendingContent=value
			task.defer(function()
				if revision~=sceneRevision or unloaded or mode~="create" then return end
				loadScene(value)
			end)
		end
	end
	local function syncVisibility()
		local creating=mode=="create"
		welcome.Visible=mode=="welcome"
		creator.Visible=creating and not codeOpen
		editorFrame.Visible=mode=="load" or (creating and codeOpen)
		editorTools.Visible=creating
		moreBtn.Visible=not creating
		for _,b in ipairs(primary) do b.Visible=not creating end
		for _,b in ipairs(extra) do b.Visible=(not creating and moreOpen) end
		btnNextChunk.Visible=not creating and _G.totalChunks~=nil and _G.totalChunks>1
		moreBtn.Text=moreOpen and "Скрыть действия ▴" or "Ещё действия ▾"
		codeBtn.Text=creating and (codeOpen and "Свойства" or "Код") or "Вставить"
		createModeBtn.Text=creating and "✦ Творить •" or "✦ Творить"
		loadModeBtn.Text=mode=="load" and "↑ Грузить •" or "↑ Грузить"
		for _,part in ipairs(order) do
			if part.Parent then
				part.LocalTransparencyModifier=creating and 0 or 1 part.CanQuery=creating
				for _,child in ipairs(part:GetChildren()) do if child:IsA("SurfaceGui") then child.Enabled=creating end end
			end
		end
		for _,h in pairs(highlights) do h.Visible=creating end
	end
	local setMode
	local function releaseTool()
		activeTool=nil held=false pressPoint=nil
		local backpack=LocalPlayer:FindFirstChildOfClass("Backpack")
		for _,tool in pairs(tools) do if tool.Parent and tool.Parent==LocalPlayer.Character and backpack then tool.Parent=backpack end end
	end
	setMode=function(nextMode)
		if blocked() then setStatus("Сначала поставь строительство на паузу",true) return end
		if nextMode=="create" and mode~="create" then
			cleanupVisuals(true)
			if not loadScene(_G.fullBuildString or textBox.Text) then return end
		elseif mode=="create" and nextMode~="create" then
			if not sceneInvalid then commit() end
			releaseTool() clearSelection()
		end
		mode=nextMode codeOpen=false materialList.Visible=false
		for _,tool in pairs(tools) do tool.Enabled=nextMode=="create" end
		applyTheme(nextMode=="create" and "create" or "load")
		syncVisibility() renderTabs()
		setStatus(nextMode=="create" and "Мастерская · R меняет режим инструмента · Ctrl+Z отменяет действие" or "Загрузи код → рассчитай план → проверь → строй")
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
		setBuildContent(tabsData[activeTabIndex].content) renderTabs() updateDefaultStats()
		baseline=snapshot() mutedHistory=false persistHistory()
		setStatus(direction=="undo" and "Действие отменено" or "Действие повторено")
	end
	trackConn(undoBtn.MouseButton1Click:Connect(function() restore("undo") end))
	trackConn(redoBtn.MouseButton1Click:Connect(function() restore("redo") end))
	trackConn(createModeBtn.MouseButton1Click:Connect(function() setMode("create") end))
	trackConn(loadModeBtn.MouseButton1Click:Connect(function() setMode("load") end))
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
		toolHint.Text=hints[name]
		for n,b in pairs(toolButtons) do b.Text=(n==name and "• " or "")..toolLabels[n] end
		if equip then
			local hum=LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum and tools[name] then hum:EquipTool(tools[name]) end
		end
	end
	local function installTools()
		local backpack=LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack then return end
		for _,name in ipairs(toolNames) do
			if not tools[name] or not tools[name].Parent then
				local tool=create("Tool",{Name=name,ToolTip="Мнимый bkit · "..toolLabels[name],RequiresHandle=false,CanBeDropped=false,Enabled=mode=="create",Parent=backpack})
				tools[name]=tool
				trackConn(tool.Equipped:Connect(function() setTool(name,false) end))
				trackConn(tool.Unequipped:Connect(function() if activeTool==name then activeTool=nil held=false end end))
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
		sceneRevision+=1
		persistHistory()
		for _,tool in pairs(tools) do tool:Destroy() end
		scene:Destroy()
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
	local ping = math.round(getSafePing() * 2000)
	perfDisplay.Text = string.format("FPS: %d  |  Ping×2: %dms", fps, ping)

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
	saveData()
	if StudioHooks.close then StudioHooks.close() end
	unloaded = true
	_G.stopautobuild = true
	_G.autobuildRunning = false
	isBuilding = false

	for _, conn in ipairs(connections) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(connections)

	unlockPosition()
	stopToolForcing()
	disableNoclip()
	cleanupVisuals(false)

	pcall(function() gui:Destroy() end)
	-- Destroy only this instance; a reloaded script owns its own GUI.

	_G.AUTOBUILD_UNLOAD = nil
end

_G.AUTOBUILD_UNLOAD = unloadScript