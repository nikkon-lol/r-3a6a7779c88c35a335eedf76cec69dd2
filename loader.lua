-- Save this launcher once in your executor. It downloads main.lua on each run.
-- The repository is private. A read-only key is entered locally on first run.
local OWNER="nikkon-lol"
local REPO="r-3a6a7779c88c35a335eedf76cec69dd2"
local KEY_FILE="AutobuildGithubKey-"..REPO..".txt"
local ENDPOINT="https://api.github.com/repos/"..OWNER.."/"..REPO.."/contents/main.lua?ref=main"
local sender=request or http_request or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)
assert(type(sender)=="function","Исполнитель не поддерживает HTTP-запросы с заголовками авторизации")
assert(type(loadstring)=="function","В исполнителе отсутствует loadstring")
local function fetch(key)
	key=key:gsub("^%s+",""):gsub("%s+$","")
	if key=="" or key:find("%s") then return nil,"Нужен GitHub fine-grained token" end
	local ok,reply=pcall(sender,{
		Url=ENDPOINT,Method="GET",Headers={
			Authorization="Bearer "..key,
			Accept="application/vnd.github.raw+json",
			["X-GitHub-Api-Version"]="2026-03-10",
			["Cache-Control"]="no-cache",
		},
	})
	-- Never include request headers, the key, or response bodies in errors.
	if not ok or type(reply)~="table" then return nil,"Не удалось подключиться к GitHub" end
	local status=tonumber(reply.StatusCode or reply.Status or reply.status_code)
	if status~=200 then
		if status==401 or status==404 then return nil,"Ключ недействителен или нет доступа к этому репозиторию (HTTP "..status..")" end
		if status==403 or status==429 then return nil,"GitHub отклонил запрос или достигнут лимит (HTTP "..status..")" end
		return nil,"GitHub вернул HTTP "..tostring(status)
	end
	local source=reply.Body or reply.body
	if type(source)~="string" or source=="" then return nil,"GitHub вернул пустой файл" end
	local run=loadstring(source,"@github/"..REPO.."/main.lua")
	if not run then return nil,"Загруженный main.lua содержит ошибку Luau; запуск отменён" end
	return run,nil,key
end
_G.AUTOBUILD_GITHUB_KEYS=_G.AUTOBUILD_GITHUB_KEYS or {}
local key=_G.AUTOBUILD_GITHUB_KEYS[REPO]
if not key and readfile and isfile then
	local ok,value=pcall(function() if isfile(KEY_FILE) then return readfile(KEY_FILE) end end)
	if ok and type(value)=="string" then key=value end
end
local problem
if key then
	local run,message=fetch(key)
	if run then run() return end
	problem=message
end
if _G.AUTOBUILD_GITHUB_KEY_UI then pcall(function() _G.AUTOBUILD_GITHUB_KEY_UI:Destroy() end) end
local gui=Instance.new("ScreenGui")
gui.Name="AutobuildPrivateLoader" gui.ResetOnSpawn=false gui.DisplayOrder=1001
local parent=(gethui and gethui()) or game:GetService("CoreGui")
local parented=pcall(function() gui.Parent=parent end)
if not parented then gui.Parent=game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end
_G.AUTOBUILD_GITHUB_KEY_UI=gui
local frame=Instance.new("Frame") frame.Parent=gui frame.AnchorPoint=Vector2.new(.5,.5) frame.Position=UDim2.fromScale(.5,.5) frame.Size=UDim2.fromOffset(480,280) frame.BackgroundColor3=Color3.fromRGB(24,18,40)
local corner=Instance.new("UICorner") corner.CornerRadius=UDim.new(0,14) corner.Parent=frame
local function text(message,y,height,size)
	local t=Instance.new("TextLabel") t.Parent=frame t.Position=UDim2.fromOffset(18,y) t.Size=UDim2.new(1,-36,0,height) t.BackgroundTransparency=1 t.Text=message t.Font=Enum.Font.Gotham t.TextSize=size or 13 t.TextColor3=Color3.fromRGB(239,230,255) t.TextWrapped=true
	return t
end
text("Приватный Autobuild",15,32,21)
text("Вставь ключ только для этого репозитория: Contents → Read-only. Он сохранится локально. Пароль от GitHub сюда не нужен.",56,54)
local box=Instance.new("TextBox") box.Parent=frame box.Position=UDim2.fromOffset(18,120) box.Size=UDim2.new(1,-36,0,38) box.BackgroundColor3=Color3.fromRGB(40,28,62) box.TextColor3=Color3.fromRGB(241,235,255) box.PlaceholderText="github_pat_…" box.Text="" box.ClearTextOnFocus=false box.Font=Enum.Font.Code box.TextSize=12
local status=text(problem or "Первое подключение. Следующие запуски автоматически загрузят текущую версию.",168,42,12)
local function button(caption,x,width)
	local b=Instance.new("TextButton") b.Parent=frame b.Position=UDim2.fromOffset(x,226) b.Size=UDim2.fromOffset(width,34) b.Text=caption b.Font=Enum.Font.Gotham b.TextSize=13 b.BackgroundColor3=Color3.fromRGB(97,65,144) b.TextColor3=Color3.new(1,1,1)
	local c=Instance.new("UICorner") c.Parent=b c.CornerRadius=UDim.new(0,8)
	return b
end
local connect=button("Подключить и запустить",18,308)
local close=button("Закрыть",336,126)
local busy=false
connect.MouseButton1Click:Connect(function()
	if busy then return end
	busy=true status.Text="Загружаю с GitHub…"
	local run,message,clean=fetch(box.Text)
	if not run then status.Text=message busy=false return end
	_G.AUTOBUILD_GITHUB_KEYS[REPO]=clean
	if writefile then
		local saved=pcall(writefile,KEY_FILE,clean)
		if not saved then warn("Autobuild: ключ сохранён только на текущий запуск") end
	else warn("Autobuild: нет writefile; ключ сохранён только на текущий запуск") end
	box.Text="" gui:Destroy()
	if _G.AUTOBUILD_GITHUB_KEY_UI==gui then _G.AUTOBUILD_GITHUB_KEY_UI=nil end
	run()
end)
close.MouseButton1Click:Connect(function() gui:Destroy() if _G.AUTOBUILD_GITHUB_KEY_UI==gui then _G.AUTOBUILD_GITHUB_KEY_UI=nil end end)
