#!/bin/bash
# Grok Build (xAI) - мнение, разбор кода, делегирование работы.
# По умолчанию РЕЖИМ ЧТЕНИЯ. Флаг -w разрешает правки в рабочем каталоге.
#
#   ask-grok.sh [-e УСИЛИЕ] [-m МОДЕЛЬ] [-t СЕК] [-d DIR] [-f ПУТЬ]... [-s СКИЛЛ]... [-w] "промпт"
#   echo "длинный промпт" | ask-grok.sh -e high -f ~/Documents/проект -
#
# -e  усилие: none/minimal/low/medium/high/xhigh/max. Не указан - дефолт модели.
# -m  модель, по умолчанию grok-4.6 (есть ещё grok-4.5). Список: grok models.
# -f  файл или папка с материалами, можно несколько. Копировать никуда не надо:
#     Grok читает ~/Documents и сетевые тома напрямую.
# -s  наш скилл как инструкция: имя из ~/.claude/skills или путь к SKILL.md.
#     Можно несколько. Текст подмешивается в начало промпта, папка скилла
#     указывается - модель дочитает справочные файлы сама.
# -d  рабочий каталог. По умолчанию - папка первого материала, иначе временная.
# -j  файл JSON-схемы: ответ придёт строго по ней. Годится schemas/review-schema.json.
# -w  разрешить менять файлы. Правки возможны ТОЛЬКО внутри рабочего каталога.
# -t  таймаут в секундах, по умолчанию 600.
#
# Коды возврата: 0 - ответ получен, 1 - ошибка запуска, 124 - таймаут.
#
# --- Почему именно такие флаги (док: ~/.grok/docs/user-guide/) ---
# Режим чтения держат три независимых слоя:
#   1. --sandbox read-only  - ядро (Seatbelt на macOS) не даёт писать никуда, кроме
#      ~/.grok и /tmp. Это настоящая граница: её не обойти ни шеллом, ни субагентом.
#   2. --disallowed-tools search_replace,write - инструменты правки просто убраны из
#      набора, модель не тратит ходы на попытки.
#   3. --permission-mode default - из шелла сами исполняются только команды из
#      встроенного read-only списка (git log/diff/status, ls, cat, grep); всё
#      остальное в headless некому подтвердить, и оно падает.
# Режим -w: --sandbox workspace ограничивает запись рабочим каталогом (+/tmp),
# остальной диск ядро защищает; --always-approve - документированный способ для
# автоматики (auto в headless произвольно блокирует вызовы, acceptEdits и dontAsk
# запись не пропускают вовсе); deny-правила на rm -rf и git push - жёсткий предел,
# deny выигрывает у всего, включая always-approve.

set -uo pipefail

export PATH="$HOME/.grok/bin:$HOME/.local/bin:$PATH"

EFFORT=""
MODEL=""
TIMEOUT=600
SCHEMA=""
WORKDIR=""
WORKDIR_EXPLICIT=0
WRITE=0
MATERIALS=()
SKILLS=()

while getopts "e:m:t:d:f:s:j:wh" opt; do
  case "$opt" in
    e) EFFORT="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    d) WORKDIR="$OPTARG"; WORKDIR_EXPLICIT=1 ;;
    f) MATERIALS[${#MATERIALS[@]}]="$OPTARG" ;;
    s) SKILLS[${#SKILLS[@]}]="$OPTARG" ;;
    j) SCHEMA="$OPTARG" ;;
    w) WRITE=1 ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "ask-grok: неизвестный флаг" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

PROMPT="${1:-}"
if [ -z "$PROMPT" ] || [ "$PROMPT" = "-" ]; then
  PROMPT="$(cat)"
fi
if [ -z "${PROMPT// }" ]; then
  echo "ask-grok: пустой промпт" >&2
  exit 1
fi

if [ -n "$SCHEMA" ] && [ ! -f "$SCHEMA" ]; then
  echo "ask-grok: файл схемы не найден: $SCHEMA" >&2
  exit 1
fi

if ! command -v grok >/dev/null 2>&1; then
  echo "ask-grok: grok CLI не установлен (curl -fsSL https://x.ai/cli/install.sh | bash)" >&2
  exit 1
fi

# У Grok нет флага для дополнительных каталогов: он работает от --cwd, поэтому пути
# материалов перечисляем в промпте абсолютными, а рабочим каталогом берём первый.
FIRSTDIR=""
if [ ${#MATERIALS[@]} -gt 0 ]; then
  LIST=""
  for m in "${MATERIALS[@]}"; do
    if [ ! -e "$m" ]; then
      echo "ask-grok: не найдено: $m" >&2
      exit 1
    fi
    abs="$(cd "$(dirname "$m")" >/dev/null 2>&1 && pwd)/$(basename "$m")"
    if [ -d "$abs" ]; then dir="$abs"; else dir="$(dirname "$abs")"; fi
    [ -z "$FIRSTDIR" ] && FIRSTDIR="$dir"
    LIST="$LIST
- $abs"
  done
  PROMPT="$PROMPT

Материалы для разбора (читай их по этим путям):$LIST"
fi

# Скиллы: подмешиваем наши инструкции в начало промпта. Тело SKILL.md без
# frontmatter плюс путь к папке - справочные файлы модель дочитает сама.
if [ ${#SKILLS[@]} -gt 0 ]; then
  GUIDE=""
  for s in "${SKILLS[@]}"; do
    if [ -f "$s" ]; then
      sf="$s"; sdir="$(cd "$(dirname "$s")" && pwd)"
    elif [ -f "$HOME/.claude/skills/$s/SKILL.md" ]; then
      sf="$HOME/.claude/skills/$s/SKILL.md"; sdir="$HOME/.claude/skills/$s"
    else
      echo "ask-grok: скилл не найден: $s" >&2; exit 1
    fi
    if [ "$(head -1 "$sf")" = "---" ]; then body="$(sed '1,/^---$/d' "$sf")"; else body="$(cat "$sf")"; fi
    GUIDE="$GUIDE
=== ИНСТРУКЦИЯ «${s}» ===
$body

(справочные файлы этой инструкции лежат в $sdir - читай их при необходимости)
"
  done
  PROMPT="Работай строго по приложенным ниже инструкциям - это наши внутренние правила.
$GUIDE
=== ЗАДАЧА ===
$PROMPT"
fi

# -w без -d запрещён: рабочий каталог - это граница правок, и подставлять её молча
# (папкой первого материала) значит открыть на запись всё дерево проекта.
if [ "$WRITE" -eq 1 ] && [ "$WORKDIR_EXPLICIT" -eq 0 ]; then
  echo "ask-grok: с -w нужно явно задать -d - рабочий каталог это граница правок" >&2
  exit 1
fi

SANDBOX=""
if [ -z "$WORKDIR" ]; then
  if [ -n "$FIRSTDIR" ]; then
    WORKDIR="$FIRSTDIR"
  else
    SANDBOX="$(mktemp -d -t ask-grok)" || exit 1
    WORKDIR="$SANDBOX"
  fi
fi
if [ ! -d "$WORKDIR" ]; then
  echo "ask-grok: каталог не найден: $WORKDIR" >&2
  exit 1
fi

OUT="$(mktemp -t ask-grok-out)" || exit 1
ERR="$(mktemp -t ask-grok-err)" || exit 1
PFILE="$(mktemp -t ask-grok-prompt)" || exit 1
TMARK="$(mktemp -t ask-grok-tmark)" || exit 1
rm -f "$TMARK"
cleanup() { rm -f "$OUT" "$ERR" "$PFILE" "$TMARK"; [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; return 0; }
trap cleanup EXIT

# Промпт передаём файлом: headless не читает stdin, а длинный аргумент упирается
# в лимит длины команды и мучается с кавычками.
printf '%s' "$PROMPT" > "$PFILE"

set -- grok --prompt-file "$PFILE" \
  --cwd "$WORKDIR" \
  --output-format plain \
  --no-auto-update
# Усилие передаём только если попросили явно - иначе действует дефолт модели.
[ -n "$EFFORT" ] && set -- "$@" --reasoning-effort "$EFFORT"
if [ "$WRITE" -eq 1 ]; then
  set -- "$@" --sandbox workspace --always-approve \
    --deny 'Bash(rm -rf *)' \
    --deny 'Bash(git push*)' \
    --rules 'Не удаляй файлы без явной необходимости. Ничего не публикуй наружу: не пушь в git, не отправляй письма и сообщения.'
else
  set -- "$@" --sandbox read-only \
    --permission-mode default \
    --disallowed-tools 'search_replace,write'
fi
[ -n "$MODEL" ] && set -- "$@" -m "$MODEL"
[ -n "$SCHEMA" ] && set -- "$@" --json-schema "$(cat "$SCHEMA")"

cd "$WORKDIR" || exit 1

"$@" >"$OUT" 2>"$ERR" </dev/null &
pid=$!
# Если убьют саму обёртку, дочерний процесс модели не должен остаться сиротой.
trap 'kill -TERM "$pid" 2>/dev/null; exit 143' TERM INT
{ sleep "$TIMEOUT"; : > "$TMARK"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null; } >/dev/null 2>&1 &
watcher=$!
wait "$pid"; rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

if [ ! -s "$OUT" ]; then
  # 143 - SIGTERM от сторожа, 130 - SIGINT (док: 14-headless-mode.md).
  if [ -f "$TMARK" ]; then
    echo "ask-grok: Grok не уложился в ${TIMEOUT}с" >&2
    exit 124
  fi
  echo "ask-grok: Grok не вернул ответ (код $rc). Последние строки вывода:" >&2
  tail -15 "$ERR" >&2
  exit 1
fi

cat "$OUT"
