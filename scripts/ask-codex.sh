#!/bin/bash
# Codex (GPT, OpenAI) - мнение, строгий разбор кода, делегирование работы.
# По умолчанию РЕЖИМ ЧТЕНИЯ. Флаг -w разрешает правки в рабочем каталоге.
#
#   ask-codex.sh [-e УСИЛИЕ] [-m МОДЕЛЬ] [-t СЕК] [-d DIR] [-f ПУТЬ]... [-s СКИЛЛ]... [-w] "промпт"
#   echo "длинный промпт" | ask-codex.sh -e high -f ~/Documents/проект -
#
# -e  усилие: low / medium / high / xhigh. Не указан - берётся из
#     ~/.codex/config.toml (там xhigh). Ставь low/medium на рутину, чтобы не ждать.
# -f  файл или папка с материалами, можно несколько.
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
# --- Про доступ к ~/Documents ---
# Раньше Codex туда не пускали, и материалы приходилось копировать в /tmp. На
# codex-cli 0.146.0 это ПРОШЛО: проверено чтение и запись в ~/Documents, и запуск
# прямо из неё. Копирование убрано - пути передаются как есть.
#
# --- Почему именно такие флаги ---
# --sandbox read-only / workspace-write - собственная песочница Codex уровня ОС.
#   read-only: читать можно везде, писать нельзя нигде. workspace-write: запись
#   только в рабочий каталог и то, что добавлено через --add-dir.
# --ephemeral - не засорять историю Codex разовыми вызовами.
# -o ФАЙЛ - финальный ответ отдельно от служебного лога, чтобы вернуть чистый текст.

set -uo pipefail

export PATH="$HOME/.npm-global/bin:$PATH"

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
    h) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "ask-codex: неизвестный флаг" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

PROMPT="${1:-}"
if [ -z "$PROMPT" ] || [ "$PROMPT" = "-" ]; then
  PROMPT="$(cat)"
fi
if [ -z "${PROMPT// }" ]; then
  echo "ask-codex: пустой промпт" >&2
  exit 1
fi

if [ -n "$SCHEMA" ] && [ ! -f "$SCHEMA" ]; then
  echo "ask-codex: файл схемы не найден: $SCHEMA" >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "ask-codex: codex CLI не установлен (npm i -g @openai/codex)" >&2
  exit 1
fi

# Материалы: пути дописываем в промпт. В режиме -w их каталоги ещё и открываем
# на запись через --add-dir, иначе песочница пустит только в рабочий каталог.
ADDDIRS=()
FIRSTDIR=""
if [ ${#MATERIALS[@]} -gt 0 ]; then
  LIST=""
  SEEN=""
  for m in "${MATERIALS[@]}"; do
    if [ ! -e "$m" ]; then
      echo "ask-codex: не найдено: $m" >&2
      exit 1
    fi
    abs="$(cd "$(dirname "$m")" >/dev/null 2>&1 && pwd)/$(basename "$m")"
    if [ -d "$abs" ]; then dir="$abs"; else dir="$(dirname "$abs")"; fi
    case ",$SEEN," in
      *",$dir,"*) ;;
      *) SEEN="${SEEN:+$SEEN,}$dir"; ADDDIRS[${#ADDDIRS[@]}]="$dir" ;;
    esac
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
      echo "ask-codex: скилл не найден: $s" >&2; exit 1
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
  echo "ask-codex: с -w нужно явно задать -d - рабочий каталог это граница правок" >&2
  exit 1
fi

TMPWORK=""
if [ -z "$WORKDIR" ]; then
  if [ -n "$FIRSTDIR" ]; then
    WORKDIR="$FIRSTDIR"
  else
    TMPWORK="$(mktemp -d -t ask-codex)" || exit 1
    WORKDIR="$TMPWORK"
  fi
fi
if [ ! -d "$WORKDIR" ]; then
  echo "ask-codex: каталог не найден: $WORKDIR" >&2
  exit 1
fi
WORKDIR="$(cd "$WORKDIR" && pwd)"

OUT="$(mktemp -t ask-codex-out)" || exit 1
ERR="$(mktemp -t ask-codex-err)" || exit 1
TMARK="$(mktemp -t ask-codex-tmark)" || exit 1
rm -f "$TMARK"
cleanup() { rm -f "$OUT" "$ERR" "$TMARK"; [ -n "$TMPWORK" ] && rm -rf "$TMPWORK"; return 0; }
trap cleanup EXIT

set -- codex exec \
  --skip-git-repo-check \
  --ephemeral \
  --color never \
  -C "$WORKDIR" \
  -o "$OUT"
# Усилие передаём ТОЛЬКО если попросили явно. Иначе действует model_reasoning_effort
# из ~/.codex/config.toml - там осознанно выставлен xhigh, и молча понижать его нельзя.
[ -n "$EFFORT" ] && set -- "$@" -c model_reasoning_effort="\"$EFFORT\""
if [ "$WRITE" -eq 1 ]; then
  # Папки материалов на запись НЕ открываем: у Grok и Gemini их нет в writable,
  # и одинаковый вызов должен давать одинаковый радиус правок у всех трёх.
  set -- "$@" --sandbox workspace-write
else
  set -- "$@" --sandbox read-only
fi
[ -n "$MODEL" ] && set -- "$@" -m "$MODEL"
[ -n "$SCHEMA" ] && set -- "$@" --output-schema "$SCHEMA"
set -- "$@" "$PROMPT"

cd "$WORKDIR" || exit 1

# </dev/null обязателен: при stdin-пайпе без писателя `codex exec` виснет навсегда -
# без логов, без кода возврата (openai/codex#20919). Ретраи и таймауты симптом усугубляют.
"$@" >"$ERR" 2>&1 </dev/null &
pid=$!
{ sleep "$TIMEOUT"; : > "$TMARK"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null; } >/dev/null 2>&1 &
watcher=$!
wait "$pid"; rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

if [ ! -s "$OUT" ]; then
  if [ -f "$TMARK" ]; then
    echo "ask-codex: Codex не уложился в ${TIMEOUT}с" >&2
    exit 124
  fi
  echo "ask-codex: Codex не вернул ответ (код $rc). Последние строки вывода:" >&2
  tail -15 "$ERR" >&2
  exit 1
fi

cat "$OUT"
