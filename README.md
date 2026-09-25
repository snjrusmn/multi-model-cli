# multi-model-cli

Подключает CLI трёх вендоров к Claude Code как субагентов: **Codex** (OpenAI),
**Grok Build** (xAI), **Antigravity** (Google). Единый интерфейс, режим чтения по
умолчанию, правки только внутри указанного каталога.

> Содержимое на русском: комментарии в коде, скиллы, документация.
> *Content is in Russian - code comments, skills and docs.*

## Состав

```
scripts/     три обёртки, диагностика, Seatbelt-профиль, схема и промпт для ревью
agents/      определения субагентов Claude Code
skills/      delegate (делегирование работы), second-opinion (второе мнение)
docs/        pitfalls.md - собранные грабли
```

## Требования

- macOS. Границы для Antigravity держатся на `sandbox-exec`.
- bash 3.2 (штатный). Синтаксис bash 4+ не используется.
- Минимум один из CLI, установленный и авторизованный:

| CLI | Установка |
|---|---|
| [Codex](https://developers.openai.com/codex) | `npm i -g @openai/codex` |
| [Grok Build](https://x.ai/news/grok-build-cli) | `curl -fsSL https://x.ai/cli/install.sh \| bash` |
| [Antigravity](https://antigravity.google/docs/cli/overview/) | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` |

## Установка

```bash
git clone https://github.com/snjrusmn/multi-model-cli.git
cd multi-model-cli
./install.sh
```

Ставит симлинки в `~/.claude/{scripts,agents,skills}`. Существующие файлы не трогает,
выводит список пропущенных. Замена - `./install.sh --force`, старое уходит в `.bak`.

Проверка готовности:

```bash
~/.claude/scripts/doctor.sh          # CLI, авторизация, границы песочницы
~/.claude/scripts/doctor.sh --live   # плюс по одному живому вызову на каждую модель
```

## Использование

```bash
~/.claude/scripts/ask-codex.sh  [-e УСИЛИЕ] [-m МОДЕЛЬ] [-t СЕК] [-d DIR] [-f ПУТЬ]... [-s СКИЛЛ]... [-j СХЕМА] [-w] "промпт"
~/.claude/scripts/ask-grok.sh   ...
~/.claude/scripts/ask-gemini.sh ...
```

| Флаг | Значение | По умолчанию |
|---|---|---|
| `-f` | файл или папка с материалами, повторяемый | нет |
| `-s` | скилл Claude Code как инструкция в промпт, повторяемый | нет |
| `-d` | рабочий каталог, граница правок | папка первого материала |
| `-w` | разрешить запись, требует явного `-d` | выключено |
| `-e` | усилие рассуждения | настройка CLI |
| `-m` | модель | Codex и Grok - настройка CLI (сейчас `gpt-6-sol` и `grok-4.7`), Antigravity `gemini-3.8-flash-high` |
| `-j` | файл JSON-схемы, ответ приходит строго по ней | нет |
| `-t` | таймаут, секунды | 600 |

Промпт передаётся аргументом или через stdin (`-`). Коды возврата: `0` ответ получен,
`1` ошибка, `124` таймаут.

```bash
# чтение
ask-codex.sh -e high "Найди, где функция сломается на пустом вводе: ..."

# разбор папки
ask-gemini.sh -f ~/Documents/проект -t 900 "Выпиши файлы, где встречается X"

# правка внутри указанного каталога
ask-grok.sh -w -d ~/Documents/проект/src -e high "Перепиши модуль на async"

# свой скилл как правила работы
ask-gemini.sh -s writing-style "Перепиши текст: ..."

# ревью со структурированным ответом
ask-codex.sh -f src/auth.py -j scripts/review-schema.json \
  "$(cat scripts/adversarial-review.md)"
```

Со схемой все три обёртки возвращают голый объект по ней. Схема `review-schema.json`
задаёт вердикт `approve` / `needs-attention`, находки с файлом, диапазоном строк,
серьёзностью, уверенностью и рекомендацией. Это делает претензию модели проверяемой:
есть координаты, по которым можно пойти и посмотреть.

## Границы доступа

Без `-w` запись невозможна. Проверено тремя способами обхода: инструмент правки, шелл
с перенаправлением, `open()` в Python. Все три возвращают `operation not permitted`.

С `-w` запись разрешена только внутри каталога из `-d`. Соседние каталоги, включая
родительский, закрыты.

| | Codex | Grok | Antigravity |
|---|---|---|---|
| своя песочница ОС | есть | есть | нет |
| механизм | `--sandbox read-only` / `workspace-write` | `--sandbox read-only` / `workspace` | внешний профиль `scripts/agy-sandbox.sb` |

У Antigravity файловой границы нет: `--add-dir` задаёт контекст, `--sandbox` ограничивает
шелл и отключается флагом `--dangerously-skip-permissions`. Профиль `sandbox-exec` -
единственная граница.

Профиль дополнительно закрывает:

- монтирование файловых систем;
- запись в `~/Library/LaunchAgents` и `~/Library/LaunchDaemons`;
- чтение `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`, `~/.codex`, `~/.grok`.

Свой файл с доступами:

```bash
export ASK_SECRETS_FILE="$HOME/путь/к/файлу"
```

**Сеть не ограничена.** От утечки через внедрённую в материалы инструкцию файловая
граница не защищает. Для сетевого allowlist - [`sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime).

## Ограничения

- Качество кода делегирование не повышает. На SWE-bench Pro впереди модели Claude:
  Fable 5 - 80,3%, Opus 4.8 - 69,2%, GPT-5.6 Sol - 64,6%.
- На задачах короче 15 минут запуск и проверка результата съедают выигрыш.
- Отчёт модели об успехе не доказывает его. Пример: Codex сообщил о записи `файл.txt`,
  фактически создал `file.txt` латиницей. Проверять диффом и списком файлов.
- Матрица «задача - модель» в `skills/delegate/` собрана на бенчмарках, практикой
  проверены отдельные клетки. Замеры от 25.08.2026, цены и модели меняются.

## Грабли

[docs/pitfalls.md](docs/pitfalls.md): зависания headless-режимов, ложные коды успеха,
побеги из allow-default песочницы, пределы моделей, не указанные в документации.

## Похожие проекты

| Проект | Кто | Что делает |
|---|---|---|
| [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) | OpenAI, официальный | плагин Claude Code: слэш-команды ревью и делегирования, перенос сессии, субагент |
| [xai-org/grok-build-plugin-cc](https://github.com/xai-org/grok-build-plugin-cc) | xAI, официальный | то же для Grok Build, по умолчанию режим чтения |
| [yuting0624/antigravity-for-claude-code](https://github.com/yuting0624/antigravity-for-claude-code) | сообщество | плагин для Antigravity, маршрутизация моделей и учёт расхода |
| [anthropic-experimental/sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) | Anthropic | песочница с сетевым allowlist, macOS и Linux |
| [umputun/ralphex](https://github.com/umputun/ralphex) | сообщество | автономный цикл по плану: свежая сессия на задачу, конвейер ревью из пяти агентов |

Плагины удобнее по части UX: слэш-команды, перенос сессии, управление фоновыми задачами.
Их поддерживают сами вендоры.

Чем отличается этот репозиторий:

- единый интерфейс на три вендора вместо трёх разных наборов команд;
- Seatbelt-профиль для Antigravity, у которого своей файловой границы нет. Community-плагин
  работает через `--yolo` и прямо пишет, что режим записи не в песочнице, предлагая
  страховаться ветками git;
- передача скиллов Claude Code внешней модели флагом `-s`.

Что заимствовано: схема структурированного вывода ревью и промпт состязательного ревью
из плагина OpenAI (Apache-2.0), диагностика окружения из плагина Antigravity, а из
ralphex (MIT) - цикл сходимости при ревью, правило проверять поиском утверждения вида
«не используется», снятие переменных `ANTIGRAVITY_*` против рекурсии и проброс сигнала
дочернему процессу.

## Лицензия

MIT, см. [LICENSE](LICENSE).
