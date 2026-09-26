#!/bin/bash
# Видимое делегирование: модель запускается в ИНТЕРАКТИВНОМ режиме в панели agterm,
# чтобы владелец видел работу и мог вмешаться. Скрытые ask-*.sh остаются для случаев,
# когда agterm нет (сервер, cron) или нужен короткий ответ без показа.
#
#   delegate-tab.sh -c codex|gemini|grok [-m МОДЕЛЬ] [-e УСИЛИЕ] [-w DIR | -k DIR] [-n ИМЯ]
#                   [-p auto|split|tab] [-W СЕК] ЗАДАНИЕ.md
#
# -c  кому: codex (Codex CLI), gemini (Antigravity agy, любая его модель), grok.
# -m  модель; по умолчанию дефолт инструмента (gemini: gemini-3.8-flash-high).
# -e  усилие (codex, grok). У gemini усилие в суффиксе имени модели.
# -w  разрешить правки ТОЛЬКО в этом каталоге. Без -w модель пишет лишь в папку прогона.
# -k  безопасная правка: каталог копируется в RUN/work, модель правит только копию,
#     оригинал физически недоступен для записи. Что изменилось: diff -ru DIR RUN/work;
#     переносит правки в оригинал вызывающий, после проверки. Предпочтительнее -w.
# -n  подпись вкладки.
# -p  куда: split - правая панель вызывающей сессии, tab - новая вкладка рядом,
#     auto (по умолчанию) - правая панель, если она свободна, иначе новая вкладка.
# -W  ждать итог N секунд и напечатать его; без -W скрипт сразу печатает путь к итогу.
#
# Итог модель кладёт в RUN/result.md. Готовность = файл появился и не пустой.
set -uo pipefail

TOOL=""; MODEL=""; EFFORT=""; WDIR=""; KDIR=""; NAME=""; PLACE="auto"; WAIT=0
while getopts "c:m:e:w:k:n:p:W:h" o; do
  case "$o" in
    c) TOOL="$OPTARG" ;; m) MODEL="$OPTARG" ;; e) EFFORT="$OPTARG" ;;
    w) WDIR="$OPTARG" ;; k) KDIR="$OPTARG" ;; n) NAME="$OPTARG" ;; p) PLACE="$OPTARG" ;; W) WAIT="$OPTARG" ;;
    h) sed -n "2,22p" "$0"; exit 0 ;; *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))
BRIEF="${1:-}"
[ -n "$TOOL" ] && [ -f "$BRIEF" ] || { echo "нужно: -c ИНСТРУМЕНТ и файл задания" >&2; exit 1; }
[ "${AGTERM_ENABLED:-}" = "1" ] || { echo "не внутри agterm - используй ask-$TOOL.sh" >&2; exit 2; }
command -v agtermctl >/dev/null || { echo "нет agtermctl" >&2; exit 2; }
[ -n "$WDIR" ] && [ -n "$KDIR" ] && { echo "-w и -k вместе нельзя" >&2; exit 1; }
[ -n "$WDIR" ] && { WDIR="$(cd "$WDIR" && pwd)" || exit 1; }
[ -n "$KDIR" ] && { KDIR="$(cd "$KDIR" && pwd)" || exit 1; }

BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
# Корень прогонов постоянный: Codex и agy спрашивают доверие к каждой НОВОЙ папке, а эту
# достаточно подтвердить один раз. Лежит в $TMPDIR (/private/var/...) - туда разрешает
# запись и Seatbelt-профиль agy. Модель без -w пишет только сюда.
ROOT="${TMPDIR:-/tmp}/delegate-runs"; mkdir -p "$ROOT"
RUN="$(mktemp -d "$ROOT/$(date +%m%d-%H%M%S).XXXX")"
RESULT="$RUN/result.md"
if [ -n "$KDIR" ]; then
  # копия, а не оригинал: папка прогона разрешена на запись всем трём моделям
  SIZE_MB=$(du -sm "$KDIR" | cut -f1)
  [ "$SIZE_MB" -le 500 ] || { echo "каталог $KDIR — ${SIZE_MB} МБ, больше 500: дай папку поуже" >&2; exit 1; }
  rsync -a --exclude node_modules --exclude .venv "$KDIR/" "$RUN/work/" || exit 1
  echo "$KDIR" > "$RUN/source.txt"
  # канонический путь (/private/var/…): по нему Codex сверяет доверие к папке
  WDIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RUN/work")"
fi
# Окно доверия Codex читает только свой config.toml (параметр -c не помогает): новую копию
# вносим в доверенные, а записи об уже удалённых копиях вычищаем, чтобы файл не рос.
if [ -n "$KDIR" ] && [ "$TOOL" = codex ]; then
  python3 - "$WDIR" "${CODEX_HOME:-$HOME/.codex}/config.toml" <<'PY'
import os, re, sys
work, cfg = sys.argv[1], sys.argv[2]
s = open(cfg).read() if os.path.exists(cfg) else ""
pat = re.compile(r'\[projects\."(/[^"]*/delegate-runs/[^"]+/work)"\]\ntrust_level = "trusted"\n\n?')
s = pat.sub(lambda m: m.group(0) if os.path.isdir(m.group(1)) else "", s)
if f'[projects."{work}"]' not in s:
    s = s.rstrip("\n") + f'\n\n[projects."{work}"]\ntrust_level = "trusted"\n'
open(cfg, "w").write(s)
PY
fi
CWD="${WDIR:-$ROOT}"
PROMPT="Прочитай файл $BRIEF и выполни задание оттуда полностью. Итоговый ответ целиком запиши в файл $RESULT командой в терминале, проверь, что файл существует и не пустой, и только после этого напиши ГОТОВО. Написать ГОТОВО без файла - ошибка."
[ -z "$WDIR" ] && PROMPT="$PROMPT Файлы владельца не меняй."
[ -n "$KDIR" ] && PROMPT="$PROMPT Рабочая папка — $RUN/work (копия папки $KDIR): все правки делай только в ней, пути из задания, указывающие в $KDIR, понимай как соответствующие пути внутри $RUN/work."

# Текст задания и запуск кладём в файлы прогона: так кириллица и кавычки не ломаются
# при передаче через agterm, а бинарники зовём по полному пути (у GUI-сессий урезан PATH).
printf '%s' "$PROMPT" > "$RUN/prompt.txt"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
BIN="$(command -v "$( [ "$TOOL" = gemini ] && echo agy || echo "$TOOL" )")" || { echo "не найден CLI для $TOOL" >&2; exit 1; }
{
  echo '#!/bin/bash'
  echo "export PATH=\"$PATH\" LANG=\"${LANG:-en_US.UTF-8}\""
  echo "cd \"$CWD\" || exit 1"
  echo "PROMPT=\"\$(cat \"$RUN/prompt.txt\")\""
  case "$TOOL" in
    codex)
      # workspace-write от cwd: писать можно только в CWD (корень прогонов или -w), читать везде.
      printf '%s' "exec \"$BIN\" -s workspace-write -a never -C \"$CWD\""
      [ -n "$MODEL" ] && printf '%s' " -m \"$MODEL\""
      [ -n "$EFFORT" ] && printf '%s' " -c 'model_reasoning_effort=\"$EFFORT\"'"
      echo ' "$PROMPT"' ;;
    gemini)
      MODEL="${MODEL:-gemini-3.8-flash-high}"
      echo 'unset ${!ANTIGRAVITY_@}'
      echo "exec sandbox-exec -f \"$SCRIPTS/agy-sandbox.sb\" -D WORKDIR=\"$CWD\" \\"
      echo "  -D AGYSTATE=\"$HOME/.gemini\" -D CACHE=\"$HOME/.cache\" \\"
      echo "  -D LAUNCHAGENTS=\"$HOME/Library/LaunchAgents\" -D LAUNCHDAEMONS=\"$HOME/Library/LaunchDaemons\" \\"
      echo "  -D SSHDIR=\"$HOME/.ssh\" -D AWSDIR=\"$HOME/.aws\" -D GPGDIR=\"$HOME/.gnupg\" \\"
      echo "  -D CONFIGDIR=\"$HOME/.config\" -D CODEXDIR=\"$HOME/.codex\" -D GROKDIR=\"$HOME/.grok\" \\"
      echo "  -D SECRETSFILE=\"${ASK_SECRETS_FILE:-$HOME/.no-such-secrets-file}\" \\"
      echo "  \"$BIN\" --model \"$MODEL\" --add-dir \"$CWD\" --dangerously-skip-permissions -i \"\$PROMPT\"" ;;
    grok)
      printf '%s' "exec \"$BIN\" --cwd \"$CWD\" --sandbox workspace --always-approve"
      [ -n "$MODEL" ] && printf '%s' " -m \"$MODEL\""
      [ -n "$EFFORT" ] && printf '%s' " --reasoning-effort \"$EFFORT\""
      echo ' "$PROMPT"' ;;
    *) echo "неизвестный инструмент: $TOOL" >&2; exit 1 ;;
  esac
} > "$RUN/launch.sh"
chmod +x "$RUN/launch.sh"
CMD="$RUN/launch.sh"

LABEL="⇢ ${NAME:-$TOOL${MODEL:+ $MODEL}}"
SELF="${AGTERM_SESSION_ID:?}"
# Свободна ли правая панель: сплита нет, либо в нём шелл без запущенной программы.
split_state() {
  agtermctl tree --json | python3 -c '
import json,sys
t=json.load(sys.stdin); me=sys.argv[1]
def walk(o):
    if isinstance(o,dict):
        if o.get("id")==me: print("busy" if o.get("split") and o.get("splitForeground") else ("free" if o.get("split") else "none")); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(t)' "$SELF"
}
[ "$PLACE" = "auto" ] && { [ "$(split_state)" = "busy" ] && PLACE="tab" || PLACE="split"; }

if [ "$PLACE" = "split" ]; then
  # Интерактивная модель после ГОТОВО остаётся открытой и держит панель. Прошлого агента
  # делегирования закрываем; чужую программу не трогаем — иначе команда уйдёт ей в ввод.
  if [ "$(split_state)" = "busy" ]; then
    PREV="$(agtermctl tree --json | python3 -c '
import json,re,sys
t=json.load(sys.stdin); me=sys.argv[1]
def walk(o):
    if isinstance(o,dict):
        if o.get("id")==me:
            m=re.search(r"delegate-runs/+([0-9-]+\.[A-Za-z0-9]+)", " ".join(o.get("splitForeground") or []))
            print(m.group(1) if m else ""); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(t)' "$SELF")"
    [ -n "$PREV" ] || { echo "правая панель занята не агентом делегирования — не трогаю; освободи её или -p tab" >&2; exit 3; }
    pkill -f "delegate-runs/+$PREV" ; for _ in 1 2 3 4 5 6; do [ "$(split_state)" = "busy" ] || break; sleep 1; done
    [ "$(split_state)" = "busy" ] && { echo "прошлый агент ($PREV) не закрылся" >&2; exit 3; }
  fi
  [ "$(split_state)" = "none" ] && agtermctl session split on --target "$SELF" >/dev/null
  agtermctl session type --target "$SELF" --pane right "clear; $CMD
" >/dev/null
  WHERE="правая панель"
else
  agtermctl session new --after "$SELF" --no-select --name "$LABEL" --cwd "$CWD" --wait \
    --command "$CMD" >/dev/null
  WHERE="новая вкладка «${LABEL}»"
fi
echo "запущено: $TOOL → $WHERE"
echo "итог: $RESULT"
[ -n "$KDIR" ] && echo "копия: $RUN/work  (что изменилось: diff -ru \"$KDIR\" \"$RUN/work\")"

[ "$WAIT" -gt 0 ] 2>/dev/null || exit 0
for ((i=0; i<WAIT; i+=5)); do
  if [ -s "$RESULT" ]; then sleep 3; cat "$RESULT"; exit 0; fi
  sleep 5
done
echo "таймаут: итога нет за ${WAIT}с, модель ещё работает (см. $WHERE)" >&2
exit 124
