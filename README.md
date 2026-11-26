# DeepAI Code TPS

Счётчик скорости генерации токенов для [DeepAI Code](https://deepai.code) на
**macOS и Windows**: маленькое окно поверх всех окон с живым **tok/s**, TTFT и
средней скоростью, плюс локальный дашборд с журналом последних ответов.

Токены считаются по потоку чанков внутри движка **dsh** — модели подключены
напрямую, `models.json` не меняется, прокси нет.

## Возможности

- живой tok/s в окне поверх всех окон: перетаскивается мышью, двойной клик — закрыть;
- TTFT и средняя скорость по последнему ответу;
- дашборд `http://127.0.0.1:57451/__tps/` с журналом последних 40 ответов
  (точные `input`/`output` из usage API);
- работает в новых чатах DeepAI Code (движок dsh, 0.3.x) и в старых pi-чатах;
- ноль изменений в конфигурации моделей и провайдера.

## Требования

- macOS 13+ (окно — AppKit/Swift; нужен `swiftc` из Xcode Command Line Tools:
  `xcode-select --install`) **или** Windows 10/11 (окно — WPF, PowerShell 5.1+);
- Node.js 18+ в `PATH` (нужен хабу);
- DeepAI Code 0.3.x.

## Установка

### macOS

```bash
git clone https://github.com/michael-korotaev/deepai-code-tps.git ~/AI/deepai-code-tps
cd ~/AI/deepai-code-tps
./install.sh
```

`install.sh` делает три вещи и сразу запускает счётчик:

1. кладёт dsh-плагин в `~/.deepai-code/userdata/deepai/dsh/tps-push.mjs`
   и включает его через машинный слой `cordis.patch.yml` в той же папке;
2. кладёт pi-расширение в `<agent-dir>/extensions/tps-push.js` (для старых чатов);
3. собирает нативное окно (`swiftc`) и поднимает хаб метрик с окном.

Цифры появятся **в новом чате**: плагин читается движком при старте чата.
Чат, начатый до установки, метрик не даёт.

Автозапуска по умолчанию нет. Включить LaunchAgent на вход в систему:

```bash
./install.sh --with-agent
```

Ключи: `--port 57451`, `--no-start` (только установка), `--quiet`.

### Windows

```powershell
git clone https://github.com/michael-korotaev/deepai-code-tps.git C:\AI\deepai-code-tps
cd C:\AI\deepai-code-tps
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` делает то же самое: dsh-плагин и машинный слой, pi-расширение,
хаб и окно. Автозапуск — `-WithTask`, без запуска — `-NoStart`.

## Каждый день

```bash
# macOS
./start.sh     # включить (хаб + окно)
./stop.sh      # выключить
```

```cmd
:: Windows
start.cmd     :: включить (хаб + окно)
stop.cmd      :: выключить
```

Все команды идемпотентны: повторный запуск ничего не дублирует.

Дашборд: <http://127.0.0.1:57451/__tps/>

## Как это работает

```
 dsh (движок DeepAI Code)
   └─ плагин tps-push: оборачивает llm/stream, считает прирост символов
        └─ POST /__ingest → tps-hub.mjs (127.0.0.1:57451)
             ├─ GET /__tps/state → окно overlay (Swift/AppKit или WPF, каждые 150 мс)
             └─ GET /__tps/       → HTML-дашборд
```

tok/s — оценка по символам: латиница ~3.8 симв./токен, кириллица и CJK
~1.6 симв./токен, окно усреднения 1.2 с. Точные значения токенов приходят из
`usage` в конце ответа и видны в журнале дашборда.

## Важно: почему плагин в «машинном слое»

Приложение при каждом старте удаляет всю папку `$DSH_HOME/profiles` и
создаёт её заново, поэтому плагин, положенный в `profiles/acp`,
исчезает при следующем запуске. Плагин живёт в домашней папке dsh, а
подключается через машинный слой `$DSH_HOME/cordis.patch.yml`:

```yaml
- insert:
    - id: tps-push
      name: ./tps-push.mjs
```

Порядок слоёв dsh: бандлы профиля → `profiles/<name>/cordis.patch.yml` →
`$DSH_HOME/cordis.patch.yml` → `--patch` приложения. Приложение этот
файл не трогает, поэтому счётчик переживает перезапуски.

Если в `cordis.patch.yml` уже есть `- insert:` (например, MCP-серверы),
установщик macOS дописывает запись **в конец существующего блока**: второй
`- insert:` перекрыл бы первый. Перед правкой файл сохраняется рядом как
`cordis.patch.yml.bak-<дата>`.

## Диагностика

Окно пустое (idle, «—») — это нормально, пока нет генерации.

1. Проверьте, что хаб и окно запущены: `./start.sh` (macOS) или `start.cmd`.
2. Откройте новый чат и отправьте сообщение.
3. Посмотрите состояние: <http://127.0.0.1:57451/__tps/state> — при генерации
   `lastIngest` обновляется, `active` становится `true`.
4. Логи: `logs/hub.log.err`, `logs/overlay.log.err`.

Проверить, что движок видит плагин (macOS):

```bash
"/Applications/DeepAI Code.app/Contents/Frameworks/DeepAI Code Helper.app/Contents/MacOS/DeepAI Code Helper" \
  "/Applications/DeepAI Code.app/Contents/Resources/app.asar/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile acp --patch ~/.deepai-code/userdata/deepai/dsh/deepai.patch.yml --dump-config \
  | grep -A1 tps-push
```

В выводе будет `name: file:///.../dsh/tps-push.mjs`.

Если после крупного обновления DeepAI Code счётчик замолчал — запустите
`install.sh` (macOS) или `install.ps1` ещё раз: он заново положит плагин и запись слоя.

## Удаление

```bash
./uninstall.sh          # macOS
```

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1   # Windows
```

Убирает dsh-плагин и запись слоя, pi-расширение, автозапуск (LaunchAgent или
задачу Планировщика) и процессы. Модели при этом не затрагиваются.

## Структура репозитория

| Файл | Роль |
| --- | --- |
| `dsh/tps-push.mjs` | плагин движка dsh: слушает `llm/stream`, шлёт метрики в хаб |
| `extension/tps-push.js` | pi-расширение для старых чатов (тот же протокол) |
| `tps-hub.mjs` | приёмник метрик и дашборд, только loopback |
| `overlay.swift` | окно-виджет macOS (AppKit), опрашивает хаб |
| `overlay.ps1` | окно-виджет Windows (WPF), опрашивает хаб |
| `install.sh` / `uninstall.sh` | установка и полный откат в macOS |
| `start.sh` / `stop.sh` | включение и выключение хаба с окном в macOS |
| `scripts/build-overlay.sh` | сборка окна macOS через `swiftc` |
| `scripts/patch-yaml.mjs` | аккуратная правка машинного слоя dsh |
| `install.ps1` / `uninstall.ps1` | установка и полный откат в Windows |
| `start.ps1` / `stop.ps1` (+ `.cmd`) | включение и выключение хаба с окном в Windows |

## English

Live tokens-per-second meter for DeepAI Code on macOS and Windows. A dsh plugin
wraps the `llm/stream` hook, a local hub (127.0.0.1) aggregates the numbers, and
a small always-on-top window (AppKit on macOS, WPF on Windows) plus an HTML
dashboard display them. Models stay connected directly; no proxy, no
`models.json` edits. Run `./install.sh` (macOS) or `install.ps1` (Windows), then
open a new chat.
