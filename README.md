# DeepAI Code TPS

Счётчик скорости генерации токенов для [DeepAI Code](https://deepai.code) (Windows):
маленькое окно поверх всех окон с живым **tok/s**, TTFT и средней скоростью,
плюс локальный дашборд с журналом последних ответов.

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

- Windows 10/11 (окно — WPF, PowerShell 5.1+);
- Node.js 18+ в `PATH` (нужен хабу);
- DeepAI Code 0.3.x.

## Установка

```powershell
git clone https://github.com/michael-korotaev/deepai-code-tps.git C:\AI\deepai-code-tps
cd C:\AI\deepai-code-tps
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` делает три вещи и сразу запускает счётчик:

1. кладёт dsh-плагин в `%USERPROFILE%\.deepai-code\userdata\deepai\dsh\tps-push.mjs`
   и включает его через машинный слой `cordis.patch.yml` в той же папке;
2. кладёт pi-расширение в `<agent-dir>\extensions\tps-push.js` (для старых чатов);
3. поднимает хаб метрик и окно.

Цифры появятся **в новом чате**: плагин читается движком при старте чата.
Чат, начатый до установки, метрик не даёт.

Автозапуска по умолчанию нет. Вернуть его можно так:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WithTask
```

## Каждый день

```cmd
start.cmd     :: включить (хаб + окно)
stop.cmd      :: выключить
```

Оба идемпотентны: повторный запуск ничего не дублирует.

Дашборд: <http://127.0.0.1:57451/__tps/>

## Как это работает

```
 dsh (движок DeepAI Code)
   └─ плагин tps-push: оборачивает llm/stream, считает прирост символов
        └─ POST /__ingest → tps-hub.mjs (127.0.0.1:57451)
             ├─ GET /__tps/state → окно overlay.ps1 (каждые 150 мс)
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

## Диагностика

Окно пустое (idle, «—») — это нормально, пока нет генерации.

1. Проверьте, что хаб и окно запущены: `start.cmd`.
2. Откройте новый чат и отправьте сообщение.
3. Посмотрите состояние: <http://127.0.0.1:57451/__tps/state> — при генерации
   `lastIngest` обновляется, `active` становится `true`.
4. Логи: `logs/hub.log.err`, `logs/overlay.log.err`.

Если после крупного обновления DeepAI Code счётчик замолчал — запустите
`install.ps1` ещё раз: он заново положит плагин и запись слоя.

## Удаление

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Убирает dsh-плагин и запись слоя, pi-расширение, задачу Планировщика и
процессы. Модели при этом не затрагиваются.

## Структура репозитория

| Файл | Роль |
| --- | --- |
| `dsh/tps-push.mjs` | плагин движка dsh: слушает `llm/stream`, шлёт метрики в хаб |
| `extension/tps-push.js` | pi-расширение для старых чатов (тот же протокол) |
| `tps-hub.mjs` | приёмник метрик и дашборд, только loopback |
| `overlay.ps1` | окно-виджет (WPF), опрашивает хаб |
| `install.ps1` / `uninstall.ps1` | установка и полный откат |
| `start.ps1` / `stop.ps1` (+ `.cmd`) | включение и выключение хаба с окном |

## English

Live tokens-per-second meter for DeepAI Code on Windows. A dsh plugin wraps the
`llm/stream` hook, a local hub (127.0.0.1) aggregates the numbers, and a
small always-on-top WPF window plus an HTML dashboard display them. Models stay
connected directly; no proxy, no `models.json` edits. Run
`install.ps1`, then open a new chat.
