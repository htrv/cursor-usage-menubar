# Cursor Usage Menubar

Иконка в строке меню macOS, которая показывает, как быстро вы расходуете лимит подписки Cursor: кольцо — расход за **сегодня** относительно дневного бюджета, точка внутри — лимит **other models / API**, тонкий красный ободок — темп выше графика по биллинг‑циклу.

Никакой регистрации и ключей: приложение использует сессию уже залогиненного Cursor IDE на этом же Mac.

![Состояния иконки: спокойное утро → середина дня → бюджет дня почти выбран → выше графика](docs/icon-states.png)

## Требования

- macOS 14+
- Swift toolchain: `xcode-select --install` (полный Xcode не нужен)
- Установленный и залогиненный Cursor IDE

## Запуск

```bash
git clone https://github.com/htrv/cursor-usage-menubar.git
cd cursor-usage-menubar
chmod +x run.sh scripts/*.sh
./run.sh status   # проверить, что токен читается и API отвечает (без GUI)
./run.sh          # собрать и запустить в menu bar
```

Пример вывода `./run.sh status`:

```
OK  mode=auto via=direct  plan=pro  total=16.1%  auto=14.1%  api/other=62.8%
    expected≈38.0%  cycle 2026-10-08 → 2026-11-08
    pace: ниже графика
```

### Как .app и автозапуск

```bash
./scripts/make-app.sh                   # → build/Cursor Usage.app
cp -R "build/Cursor Usage.app" ~/Applications/
open ~/Applications/"Cursor Usage.app"
```

Автозапуск: Системные настройки → Основные → Объекты входа → добавить `Cursor Usage.app`.

Приложение подписано ad‑hoc; при первом запуске может понадобиться разрешить его в Системных настройках → Конфиденциальность и безопасность.

## Как приложение подключается к вашему usage

1. Cursor IDE после логина хранит OAuth‑токен в своей локальной базе:
   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, таблица `ItemTable`, ключ `cursorAuth/accessToken` (JWT).
2. Приложение открывает базу **только на чтение**, достаёт токен и `sub` из его payload.
3. Из них собирается cookie `WorkosCursorSessionToken=<sub>::<jwt>` — та же, что ставит браузер на cursor.com.
4. С этой cookie делается `GET https://cursor.com/api/usage-summary` (тот же endpoint, которым пользуется страница Dashboard → Usage).

Токен нигде не сохраняется и никуда, кроме `cursor.com`, не отправляется; на каждое обновление (старт + каждые 5 минут + кнопка «Обновить») он перечитывается из базы. Если вы перелогинитесь в Cursor — приложение подхватит новый токен само.

Если вы видите `cursorAuth/accessToken не найден` — откройте Cursor и войдите в аккаунт. Если `HTTP 401/403` — сессия Cursor протухла, перелогиньтесь в IDE.

Endpoint неофициальный: Cursor может его поменять, тогда приложение покажет ошибку парсинга до обновления кода.

## Иконка

| Элемент | Смысл |
|--------|--------|
| Внешнее кольцо (заполнение) | расход **сегодня** / дневной бюджет; сброс в локальную полночь |
| Цвет кольца | зелёный → жёлтый → красный по заполнению дня |
| Точка внутри | `apiPercentUsed` (other models): чем ближе к 100%, тем краснее |
| Тонкий красный ободок | темп **выше графика** по биллинг‑циклу |

Дневной бюджет: `(100 − total%) / дней_осталось_включая_сегодня`.
Темп: сравниваем `totalPercentUsed` с долей прошедшего биллинг‑цикла (±5 п.п.).

История дня: `~/Library/Application Support/cursor-usage-menubar/history.json`.

## Прокси

Если `cursor.com` недоступен из вашей сети напрямую, в меню → **Прокси**:

| Режим | Поведение |
|-------|-----------|
| **Авто** | Cursor `http.proxy` → `HTTPS_PROXY`/`HTTP_PROXY` из окружения → напрямую |
| **Вручную** | свой HTTP CONNECT‑прокси (`http://127.0.0.1:8080` или `host:port`) |
| **Напрямую** | без прокси |

Настройки: `~/Library/Application Support/cursor-usage-menubar/settings.json`.

## Как добавить проверку usage другого сервиса (например, Claude)

Код разбит так, что провайдер данных — это два файла. Чтобы показать usage другого сервиса:

1. **Токен** — новый `enum XxxTokenProvider` по образцу `Sources/TokenProvider.swift`: откуда взять учётку локально (SQLite, Keychain, файл) и как превратить её в заголовок/cookie.
2. **API** — новый `enum XxxAPI` по образцу `Sources/CursorAPI.swift`: `Codable`‑модель ответа и `fetch…()`. Перебор прокси (`ProxySettings.shared.candidates()`) можно переиспользовать как есть.
3. **Отображение** — в `UsageStore.refresh()` вызвать новый fetch и положить результат в свою `@Published`‑модель; в `App.swift` (`MenuPanel`) добавить секцию, в `IconRenderer` — при желании второй слой иконки.

Конкретно для **Claude Code** (подписка, OAuth‑логин на этом Mac):

- Учётка лежит в Keychain: `kSecClassGenericPassword`, `kSecAttrService = "Claude Code-credentials"`. Значение — JSON вида `{"claudeAiOauth": {"accessToken": "...", "refreshToken": "...", "expiresAt": ..., "subscriptionType": "..."}}`. На Linux то же самое в `~/.claude/.credentials.json`.
- Запрос: `GET https://api.anthropic.com/api/oauth/usage` с `Authorization: Bearer <accessToken>`, `anthropic-version: 2023-06-01`, `anthropic-client-name: claude-code`, `anthropic-client-version: <версия claude>`. Ответ содержит `five_hour` и `seven_day` с полями `utilization` (0–100) и `resets_at`.
- Для иконки логично: кольцо = окно 5 часов, точка = окно 7 дней; `Pace`/`HistoryStore` (месячный темп) для Claude не нужны.
- Токен живёт несколько часов; проще не рефрешить его самостоятельно (это перезапишет Keychain и может сбить CLI), а при истечении показывать «запустите `claude`».
- При первом чтении Keychain macOS спросит разрешение для приложения; чтобы не спрашивала при каждой пересборке, подпишите .app постоянным сертификатом.

Если Claude Code настроен через сторонний прокси (`ANTHROPIC_BASE_URL` в `~/.claude/settings.json`), usage‑endpoint у прокси обычно отсутствует — проверяйте заранее.

## Структура

```
Sources/
  App.swift            # MenuBarExtra, панель меню, настройки прокси
  UsageStore.swift     # таймер обновления, состояние, иконка
  TokenProvider.swift  # чтение токена Cursor из state.vscdb
  CursorAPI.swift      # usage-summary + перебор прокси
  Pace.swift           # дневной бюджет и темп по циклу
  HistoryStore.swift   # снимки по дням (history.json)
  IconRenderer.swift   # отрисовка кольца/точки
  ProxyResolver.swift, ProxySettings.swift
scripts/
  status.py            # headless-проверка API
  make-app.sh          # сборка .app
```

## Лицензия

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/) — см. `LICENSE`.

- **Бесплатно**: личное использование, учёба, исследования, некоммерческие организации, образование, госорганы.
- **Коммерческое использование** (в компании, в составе продукта, перепродажа, переработка на продажу) требует отдельной коммерческой лицензии. Для её получения откройте [issue](https://github.com/htrv/cursor-usage-menubar/issues) с меткой `commercial`.

Отправляя pull request, вы соглашаетесь, что автор проекта вправе распространять ваш вклад на условиях этой и коммерческой лицензии.

## Благодарность

Если проект пригодился, можно отправить биткоин сюда:

`bc1q8dtk9sar0862ckav0hacmvllwkhy00rvzn6puv`
