# multi-model-cli

Подключает CLI трёх вендоров к Claude Code как субагентов: **Codex** (OpenAI),
**Grok Build** (xAI), **Antigravity** (Google). Единый интерфейс, режим чтения по
умолчанию, правки только внутри указанного каталога.

> Содержимое на русском: комментарии в коде, скиллы, документация.
> *Content is in Russian - code comments, skills and docs.*

## Состав

```
scripts/     три обёртки + Seatbelt-профиль для Antigravity
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

## Использование

```bash
~/.claude/scripts/ask-codex.sh  [-e УСИЛИЕ] [-m МОДЕЛЬ] [-t СЕК] [-d DIR] [-f ПУТЬ]... [-s СКИЛЛ]... [-w] "промпт"
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
| `-m` | модель | Codex `gpt-5.6-terra`, Grok `grok-4.6`, Antigravity `gemini-3.7-flash-high` |
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
```

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

## Лицензия

MIT, см. [LICENSE](LICENSE).
