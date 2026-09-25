#!/bin/bash
# Делегирование без терминала: Codex работает в отдельной сессии tmux, ход показывается
# ретранслятором (Telegram или progress.md), оркестратор ждёт только файл итога.
#
#   server-delegate.sh [-m МОДЕЛЬ] [-e УСИЛИЕ] [-w DIR] [-n ИМЯ] [-t СЕК] ЗАДАНИЕ.md
#
# -w  разрешить правки только в DIR (иначе только чтение).
# -t  предел времени, по умолчанию 1800 секунд.
# Печатает: RUN=<папка прогона>, RESULT=<файл итога>, SESSION=<сессия tmux>. Готовность —
# в папке прогона появился файл exit_code. Итог — result.md (последнее сообщение Codex).
# Telegram: DELEGATE_TG_TOKEN, DELEGATE_TG_CHAT, DELEGATE_TG_THREAD — в окружении или в
# ~/.config/delegate/env (chmod 600).
set -euo pipefail

MODEL=""; EFFORT=""; WDIR=""; NAME="делегирование"; TIMEOUT=1800
while getopts "m:e:w:n:t:h" o; do
  case "$o" in
    m) MODEL="$OPTARG" ;; e) EFFORT="$OPTARG" ;; w) WDIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;; t) TIMEOUT="$OPTARG" ;; h) sed -n "2,14p" "$0"; exit 0 ;; *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))
BRIEF="${1:?нужен файл задания}"
[ -f "$BRIEF" ] || { echo "нет файла задания: $BRIEF" >&2; exit 1; }
command -v tmux >/dev/null || { echo "нужен tmux" >&2; exit 1; }
CODEX="${DELEGATE_BIN_CODEX:-$(command -v codex)}"
[ -x "$CODEX" ] || { echo "не найден codex" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

ROOT="${DELEGATE_RUNS:-$HOME/.delegate-runs}"; mkdir -p "$ROOT"
RUN="$(mktemp -d "$ROOT/$(date +%m%d-%H%M%S).XXXX")"
cp "$BRIEF" "$RUN/brief.md"
if [ -n "$WDIR" ]; then
  WDIR="$(cd "$WDIR" && pwd)"; CWD="$WDIR"; SANDBOX="workspace-write"
else
  CWD="$RUN"; SANDBOX="read-only"
fi

ARGS=(exec --skip-git-repo-check --ephemeral -s "$SANDBOX" -C "$CWD" --json -o "$RUN/result.md")
[ -n "$MODEL" ] && ARGS+=(-m "$MODEL")
[ -n "$EFFORT" ] && ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
printf '%q ' "$CODEX" "${ARGS[@]}" - > "$RUN/cmd.txt"

SESSION="deleg-$(basename "$RUN" | tr '.' '-')"
ENVFILE="$HOME/.config/delegate/env"
cat > "$RUN/run.sh" <<RUNSH
#!/bin/bash
set -a; [ -f "$ENVFILE" ] && . "$ENVFILE"; set +a
cd "$CWD"
timeout $TIMEOUT $(cat "$RUN/cmd.txt") < "$RUN/brief.md" 2> "$RUN/stderr.txt" \
  | python3 "$HERE/delegate_relay.py" --run-dir "$RUN" --name $(printf '%q' "$NAME")
echo "\${PIPESTATUS[0]}" > "$RUN/exit_code"
RUNSH
chmod +x "$RUN/run.sh"
tmux new-session -d -s "$SESSION" "$RUN/run.sh"
echo "RUN=$RUN"
echo "RESULT=$RUN/result.md"
echo "SESSION=$SESSION"
