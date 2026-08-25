#!/bin/bash
# Проверяет готовность обвязки: CLI, авторизация, песочница, права на файлы.
#
#   ./doctor.sh          быстрая проверка, без обращений к моделям
#   ./doctor.sh --live   дополнительно дёргает каждую модель одним коротким запросом
#
# Коды возврата: 0 — всё готово, 1 — есть проблемы.

set -uo pipefail

export PATH="$HOME/.npm-global/bin:$HOME/.grok/bin:$HOME/.local/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1
FAILED=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s: %s\n" "$1" "$2"; FAILED=1; }
warn() { printf "  \033[33m!\033[0m %s: %s\n" "$1" "$2"; }

echo "Система"
if [ "$(uname)" = "Darwin" ]; then
  ok "macOS $(sw_vers -productVersion 2>/dev/null)"
else
  bad "не macOS" "профиль Seatbelt не сработает, ask-gemini.sh не запустится"
fi
command -v sandbox-exec >/dev/null 2>&1 && ok "sandbox-exec на месте" \
  || bad "sandbox-exec не найден" "границы для Antigravity держать нечем"
ok "bash $(/bin/bash --version | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')"

echo
echo "Файлы обвязки"
for f in ask-codex.sh ask-grok.sh ask-gemini.sh doctor.sh; do
  if [ -x "$DIR/$f" ]; then ok "$f"
  elif [ -f "$DIR/$f" ]; then bad "$f" "нет флага исполнения: chmod +x"
  else bad "$f" "не найден"; fi
done
for f in agy-sandbox.sb review-schema.json adversarial-review.md; do
  [ -f "$DIR/$f" ] && ok "$f" || bad "$f" "не найден"
done

echo
echo "Профиль песочницы"
if [ -f "$DIR/agy-sandbox.sb" ]; then
  T="$(mktemp -d)"
  if sandbox-exec -f "$DIR/agy-sandbox.sb" \
      -D WORKDIR="$T" -D AGYSTATE="$HOME/.gemini" -D CACHE="$HOME/.cache" \
      -D LAUNCHAGENTS="$HOME/Library/LaunchAgents" -D LAUNCHDAEMONS="$HOME/Library/LaunchDaemons" \
      -D SSHDIR="$HOME/.ssh" -D AWSDIR="$HOME/.aws" -D GPGDIR="$HOME/.gnupg" \
      -D CONFIGDIR="$HOME/.config" -D CODEXDIR="$HOME/.codex" -D GROKDIR="$HOME/.grok" \
      -D SECRETSFILE="${ASK_SECRETS_FILE:-$HOME/.no-such-secrets-file}" \
      /bin/bash -c "touch '$T/ok' 2>/dev/null" >/dev/null 2>&1; then
    ok "профиль загружается, запись в рабочий каталог проходит"
  else
    bad "профиль не загрузился" "запусти с RUST_LOG или смотри log stream"
  fi
  if sandbox-exec -f "$DIR/agy-sandbox.sb" \
      -D WORKDIR="$T" -D AGYSTATE="$HOME/.gemini" -D CACHE="$HOME/.cache" \
      -D LAUNCHAGENTS="$HOME/Library/LaunchAgents" -D LAUNCHDAEMONS="$HOME/Library/LaunchDaemons" \
      -D SSHDIR="$HOME/.ssh" -D AWSDIR="$HOME/.aws" -D GPGDIR="$HOME/.gnupg" \
      -D CONFIGDIR="$HOME/.config" -D CODEXDIR="$HOME/.codex" -D GROKDIR="$HOME/.grok" \
      -D SECRETSFILE="${ASK_SECRETS_FILE:-$HOME/.no-such-secrets-file}" \
      /bin/bash -c "touch '$HOME/Library/LaunchAgents/.doctor-probe' 2>/dev/null" >/dev/null 2>&1; then
    bad "автозапуск открыт на запись" "профиль пропускает ~/Library/LaunchAgents"
    rm -f "$HOME/Library/LaunchAgents/.doctor-probe"
  else
    ok "запись в автозапуск заблокирована"
  fi
  rm -rf "$T"
fi
if [ -n "${ASK_SECRETS_FILE:-}" ]; then
  [ -f "$ASK_SECRETS_FILE" ] && ok "ASK_SECRETS_FILE указывает на существующий файл" \
    || warn "ASK_SECRETS_FILE" "файла нет: $ASK_SECRETS_FILE"
else
  warn "ASK_SECRETS_FILE не задан" "файл с доступами не закрыт от чтения"
fi

echo
echo "CLI и авторизация"
check_cli() {
  bin="$1"; label="$2"; probe="$3"
  if ! command -v "$bin" >/dev/null 2>&1; then
    warn "$label" "не установлен, обёртка работать не будет"
    return
  fi
  if eval "$probe" >/dev/null 2>&1; then ok "$label: установлен, авторизован"
  else warn "$label" "установлен, но авторизация не подтверждена"; fi
}
check_cli codex "Codex"       "codex --version"
check_cli grok  "Grok Build"  "grok models"
check_cli agy   "Antigravity" "agy models"

if [ "$LIVE" -eq 1 ]; then
  echo
  echo "Живые вызовы"
  for pair in "codex:ask-codex.sh" "grok:ask-grok.sh" "agy:ask-gemini.sh"; do
    bin="${pair%%:*}"; scr="${pair##*:}"
    command -v "$bin" >/dev/null 2>&1 || continue
    if out=$("$DIR/$scr" -t 120 -e low "Ответь одним словом: ок" 2>&1 | tail -1) && [ -n "$out" ]; then
      ok "$scr → $out"
    else
      bad "$scr" "ответа нет: $out"
    fi
  done
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "Готово к работе."
else
  echo "Есть проблемы, отмеченные ✗."
fi
exit "$FAILED"
