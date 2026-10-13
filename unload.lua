-- ORBIT: stop the current client instance without leaving the server.
-- Built world objects, save files and recovery data are retained.
local callback=_G.AUTOBUILD_UNLOAD
_G.stopautobuild=true
if type(callback)~="function" then
	print("ORBIT UNLOAD: активный экземпляр не найден; выгружать нечего.")
	return
end
local ok,complete,errors=pcall(callback)
if not ok then
	warn("ORBIT UNLOAD: выгрузка прервана: "..tostring(complete)..". Повтори запуск; подробности в F9.")
	return
end
if complete==false then
	warn("ORBIT UNLOAD: работа остановлена, но часть очистки не завершилась. Повтори запуск; подробности в F9.")
	return
end
_G.autobuildRunning=false
_G.autobuildPreparing=false
_G.visualsEnabled=false
print("ORBIT UNLOAD: выключен. Сохранения и построенные блоки сохранены. ORBIT можно запустить снова без перезахода.")
