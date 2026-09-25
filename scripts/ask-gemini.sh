#!/bin/bash
# Gemini (Google) - мнение, большой контекст, делегирование работы.
# По умолчанию РЕЖИМ ЧТЕНИЯ. Флаг -w разрешает правки в рабочем каталоге.
#
#   ask-gemini.sh [-e УСИЛИЕ] [-m МОДЕЛЬ] [-t СЕК] [-d DIR] [-f ПУТЬ]... [-s СКИЛЛ]... [-w] "промпт"
#   echo "длинный промпт" | ask-gemini.sh -f ~/Documents/проект -
#
# -e  усилие: low / medium / high. Не указан - его несёт суффикс модели.
# -m  модель, по умолчанию gemini-3.8-flash-high. Под чистый reasoning -
#     gemini-3.1-pro-high. Есть также claude-sonnet-4-6, claude-opus-4-6-thinking,
#     gpt-oss-120b-medium - у них ОТДЕЛЬНАЯ квота от Gemini. Список: agy models.
# -f  файл или папка с материалами, можно несколько. Копировать никуда не надо:
#     agy читает ~/Documents и сетевые тома напрямую.
# -s  наш скилл как инструкция: имя из ~/.claude/skills или путь к SKILL.md.
#     Можно несколько. Текст подмешивается в начало промпта, а папка скилла
#     открывается через --add-dir - модель дочитает справочные файлы сама.
# -d  рабочий каталог. По умолчанию - папка первого материала, иначе временная.
# -j  файл JSON-схемы: ответ придёт строго по ней. Годится schemas/review-schema.json.
# -w  разрешить менять файлы. Правки возможны ТОЛЬКО внутри рабочего каталога.
# -t  таймаут в секундах, по умолчанию 600.
#
# Коды возврата: 0 - ответ получен, 1 - ошибка запуска, 124 - таймаут.
#
# --- Почему agy, а не gemini CLI ---
# Gemini CLI для частных аккаунтов Google выключен 18.06.2026 («This client is no
# longer supported for Gemini Code Assist for individuals»), включая платные AI Pro.
# Официальная замена - Antigravity CLI (`agy`), те же модели Gemini 3 плюс Claude и
# GPT-OSS. Имя скрипта оставлено прежним: для нас это по-прежнему «спросить Gemini».
#
# --- Почему именно такие флаги (док: antigravity.google/docs/cli) ---
# --add-dir ОБЯЗАТЕЛЕН: без него agy не видит рабочий каталог вообще и пишет в свою
#   служебную папку scratch. Проверено - это не подсказка, а условие работы.
# Инструменты не урезаем ни в одном режиме: раньше тут стоял --mode plan, и agy в режиме
#   чтения не мог даже обойти каталог - вызов шелла отклонялся, а отклонённый инструмент
#   обрывал весь ответ. Границу держит только ядро.
# Режим -w: --dangerously-skip-permissions. Своей файловой границы у agy НЕТ -
#   ни --add-dir, ни --sandbox её не дают (--sandbox ограничивает только шелл),
#   поэтому границу ставим снаружи через sandbox-exec с профилем agy-sandbox.sb.
#   Он же используется и в режиме чтения - как второй слой поверх отказа в правах.

set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

PROFILE="$(cd "$(dirname "$0")" && pwd)/agy-sandbox.sb"

EFFORT=""
# Дефолт задан явно: agy свою модель нигде не раскрывает. Выбран свежий Flash (3.8 с
# 25.09.2026), а не Pro 3.1: ещё Flash 3.7 обходил Pro по замерам Artificial Analysis
# (индекс 56 против 48, первый токен 12с против 29с, на 60% дешевле, контекст у обоих 1M). Pro выигрывает лишь на
# отдельных reasoning-бенчмарках - под них переключай: -m gemini-3.1-pro-high.
MODEL="gemini-3.8-flash-high"
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
    *) echo "ask-gemini: неизвестный флаг" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

PROMPT="${1:-}"
if [ -z "$PROMPT" ] || [ "$PROMPT" = "-" ]; then
  PROMPT="$(cat)"
fi
if [ -z "${PROMPT// }" ]; then
  echo "ask-gemini: пустой промпт" >&2
  exit 1
fi

if [ -n "$SCHEMA" ] && [ ! -f "$SCHEMA" ]; then
  echo "ask-gemini: файл схемы не найден: $SCHEMA" >&2
  exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
  echo "ask-gemini: agy не установлен (curl -fsSL https://antigravity.google/cli/install.sh | bash)" >&2
  exit 1
fi
if [ ! -f "$PROFILE" ]; then
  echo "ask-gemini: не найден профиль песочницы: $PROFILE" >&2
  exit 1
fi

# Материалы: каждый каталог отдаём через --add-dir, пути дописываем в промпт.
ADDDIRS=()
FIRSTDIR=""
if [ ${#MATERIALS[@]} -gt 0 ]; then
  LIST=""
  SEEN=""
  for m in "${MATERIALS[@]}"; do
    if [ ! -e "$m" ]; then
      echo "ask-gemini: не найдено: $m" >&2
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

# Скиллы: подмешиваем наши инструкции в начало промпта. Папку скилла добавляем в
# --add-dir - без этого agy её просто не увидит и справочные файлы не прочитает.
if [ ${#SKILLS[@]} -gt 0 ]; then
  GUIDE=""
  for s in "${SKILLS[@]}"; do
    if [ -f "$s" ]; then
      sf="$s"; sdir="$(cd "$(dirname "$s")" && pwd)"
    elif [ -f "$HOME/.claude/skills/$s/SKILL.md" ]; then
      sf="$HOME/.claude/skills/$s/SKILL.md"; sdir="$HOME/.claude/skills/$s"
    else
      echo "ask-gemini: скилл не найден: $s" >&2; exit 1
    fi
    if [ "$(head -1 "$sf")" = "---" ]; then body="$(sed '1,/^---$/d' "$sf")"; else body="$(cat "$sf")"; fi
    ADDDIRS[${#ADDDIRS[@]}]="$sdir"
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
  echo "ask-gemini: с -w нужно явно задать -d - рабочий каталог это граница правок" >&2
  exit 1
fi

TMPWORK=""
if [ -z "$WORKDIR" ]; then
  if [ -n "$FIRSTDIR" ]; then
    WORKDIR="$FIRSTDIR"
  else
    TMPWORK="$(mktemp -d -t ask-gemini)" || exit 1
    WORKDIR="$TMPWORK"
  fi
fi
if [ ! -d "$WORKDIR" ]; then
  echo "ask-gemini: каталог не найден: $WORKDIR" >&2
  exit 1
fi
WORKDIR="$(cd "$WORKDIR" && pwd)"

OUT="$(mktemp -t ask-gemini-out)" || exit 1
ERR="$(mktemp -t ask-gemini-err)" || exit 1
TMARK="$(mktemp -t ask-gemini-tmark)" || exit 1
rm -f "$TMARK"
cleanup() { rm -f "$OUT" "$ERR" "$TMARK"; [ -n "$TMPWORK" ] && rm -rf "$TMPWORK"; return 0; }
trap cleanup EXIT

# В режиме чтения рабочей папкой песочницы делаем временный каталог: тогда запись
# невозможна вообще нигде, даже если права почему-то пропустят.
SBWORK="$WORKDIR"
RO_TMP=""
if [ "$WRITE" -eq 0 ]; then
  RO_TMP="$(mktemp -d -t ask-gemini-ro)" || exit 1
  SBWORK="$RO_TMP"
  cleanup() { rm -f "$OUT" "$ERR" "$TMARK"; [ -n "$TMPWORK" ] && rm -rf "$TMPWORK"; rm -rf "$RO_TMP"; return 0; }
fi

# Усилие у agy зашито в ИМЯ модели (…-high / …-medium / …-low), и отдельный флаг
# --effort с таким именем конфликтует: «--model … conflicts with --effort=…».
# Поэтому -e подменяет суффикс. Учти: у gemini-3.1-pro суффикса -medium не бывает.
if [ -n "$EFFORT" ]; then
  case "$MODEL" in
    *-high|*-medium|*-low) MODEL="${MODEL%-*}-$EFFORT"; EFFORT="" ;;
  esac
fi

set -- sandbox-exec -f "$PROFILE" \
  -D WORKDIR="$SBWORK" \
  -D AGYSTATE="$HOME/.gemini" \
  -D CACHE="$HOME/.cache" \
  -D LAUNCHAGENTS="$HOME/Library/LaunchAgents" \
  -D LAUNCHDAEMONS="$HOME/Library/LaunchDaemons" \
  -D SSHDIR="$HOME/.ssh" \
  -D AWSDIR="$HOME/.aws" \
  -D GPGDIR="$HOME/.gnupg" \
  -D CONFIGDIR="$HOME/.config" \
  -D CODEXDIR="$HOME/.codex" \
  -D GROKDIR="$HOME/.grok" \
  -D SECRETSFILE="${ASK_SECRETS_FILE:-$HOME/.no-such-secrets-file}" \
  agy -p "$PROMPT" --print-timeout "${TIMEOUT}s"
# Усилие у agy зашито в ИМЯ модели (…-high / …-medium / …-low), и отдельный --effort
# с таким именем конфликтует: «--model … conflicts with --effort=…». Поэтому -e меняет
# суффикс, а не добавляет флаг. Учти: у gemini-3.1-pro суффикса -medium не существует.
[ -n "$EFFORT" ] && set -- "$@" --effort "$EFFORT"
set -- "$@" --add-dir "$WORKDIR"
if [ ${#ADDDIRS[@]} -gt 0 ]; then
  for d in "${ADDDIRS[@]}"; do
    [ "$d" = "$WORKDIR" ] || set -- "$@" --add-dir "$d"
  done
fi
# Инструменты не ограничиваем ни в одном режиме: границу держит ядро (см. профиль
# Seatbelt выше). В режиме чтения рабочим каталогом песочницы стоит временная папка,
# поэтому писать в файлы владельца физически нельзя, а читать, искать и обходить папки -
# можно. Раньше здесь стоял --mode plan, и agy в режиме чтения не мог даже обойти
# каталог: любой вызов шелла отклонялся, а отклонённый инструмент обрывал весь ответ.
set -- "$@" --dangerously-skip-permissions
[ -n "$MODEL" ] && set -- "$@" --model "$MODEL"
# agy требует json-формат вместе со схемой, иначе отказывается запускаться
[ -n "$SCHEMA" ] && set -- "$@" --json-schema "$SCHEMA" --output-format json

# Снимаем ВСЕ переменные ANTIGRAVITY_*: если обёртку случайно запустят изнутри
# работающего агента Antigravity, унаследованное окружение даёт рекурсию и взаимную
# блокировку. Снимаем по префиксу, а не списком, чтобы новые переменные не всплыли.
unset ${!ANTIGRAVITY_@}

cd "$WORKDIR" || exit 1

"$@" >"$OUT" 2>"$ERR" </dev/null &
pid=$!
# Если убьют саму обёртку, дочерний процесс модели не должен остаться сиротой.
trap 'kill -TERM "$pid" 2>/dev/null; exit 143' TERM INT
# Сторож на 30с длиннее собственного --print-timeout: даём agy выйти самому.
{ sleep $((TIMEOUT + 30)); : > "$TMARK"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null; } >/dev/null 2>&1 &
watcher=$!
wait "$pid"; rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null

if [ ! -s "$OUT" ]; then
  if [ -f "$TMARK" ]; then
    echo "ask-gemini: Gemini не уложился в ${TIMEOUT}с" >&2
    exit 124
  fi
  echo "ask-gemini: Gemini не вернул ответ (код $rc). Последние строки вывода:" >&2
  tail -15 "$ERR" >&2
  exit 1
fi

# agy заворачивает результат схемы в служебный конверт. Разворачиваем, чтобы вывод
# со схемой выглядел одинаково у всех трёх обёрток: голый объект по схеме.
if [ -n "$SCHEMA" ]; then
  python3 -c 'import json,sys
d=json.load(sys.stdin)
print(json.dumps(d.get("structured_output", d), ensure_ascii=False, indent=2))' < "$OUT" 2>/dev/null || cat "$OUT"
else
  cat "$OUT"
fi
