# Private Autobuild Studio

Репозиторий закрыт. `main.lua` — текущая версия; `loader.lua` — постоянный загрузчик. Основной файл обновляется в ветке `main`.

## Первый запуск

1. [Создай fine-grained token](https://github.com/settings/personal-access-tokens/new?name=Autobuild+read+only&description=r-3a6a7779c88c35a335eedf76cec69dd2&target_name=nikkon-lol&expires_in=90&contents=read).
2. В Repository access выбери **Only select repositories** и только **r-3a6a7779c88c35a335eedf76cec69dd2**.
3. В Repository permissions оставь **Contents → Read-only**. Metadata → Read-only добавляется GitHub автоматически.
4. Нажми Generate token. Ключ вставляй только в локальное окно загрузчика, не в чат и не в файлы репозитория.
5. Один раз сохрани `loader.lua` в исполнителе как отдельный запускаемый элемент. При первом запуске он запросит ключ. Затем этот же загрузчик будет скачивать обновлённый `main.lua` при каждом запуске.

Если исполнитель поддерживает `readfile`, можно положить загрузчик в его workspace под именем `Autobuild-private-loader.lua` и сохранить одну команду:

```lua
loadstring(readfile("Autobuild-private-loader.lua"))()
```

Личный ключ хранится в `AutobuildGithubKey-r-3a6a7779c88c35a335eedf76cec69dd2.txt` в workspace исполнителя. Не добавляй его в Git. При истечении срока ключа загрузчик снова попросит действующий ключ. Без записи файлов ключ сохраняется только на текущий запуск.

Закрытый файл нельзя загрузить обычным анонимным `game:HttpGet` по Raw-ссылке. Загрузчик использует GitHub Contents API с заголовком Authorization, поэтому в исполнителе требуется `request`, `http_request` или аналог с поддержкой заголовков.

Управление и возможности: [GUIDE.md](GUIDE.md).

Документация: [Fine-grained tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [Contents API](https://docs.github.com/en/rest/repos/contents).
