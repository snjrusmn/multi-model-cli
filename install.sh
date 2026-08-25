#!/bin/bash
# Ставит обвязку в ~/.claude симлинками. Ничего не перезаписывает молча:
# если файл уже есть — говорит и пропускает.
#
#   ./install.sh            поставить
#   ./install.sh --dry-run  показать, что будет сделано
#   ./install.sh --force    заменить существующие файлы (сделает .bak)

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/.claude"
DRY=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "неизвестный флаг: $a" >&2; exit 1 ;;
  esac
done

if [ "$(uname)" != "Darwin" ]; then
  echo "Внимание: границы для Antigravity сделаны на Seatbelt (sandbox-exec) и работают" >&2
  echo "только на macOS. На этой системе обёртка ask-gemini.sh не запустится." >&2
  echo >&2
fi

link() {
  s="$SRC/$1"; d="$DST/$1"
  mkdir -p "$(dirname "$d")"
  if [ -e "$d" ] || [ -L "$d" ]; then
    if [ "$(readlink "$d" 2>/dev/null)" = "$s" ]; then
      printf "  =  уже стоит: %s\n" "$1"; return 0
    fi
    if [ "$FORCE" -eq 1 ]; then
      [ "$DRY" -eq 1 ] || mv "$d" "$d.bak"
      printf "  ~  заменено (старое в %s.bak): %s\n" "$1" "$1"
    else
      printf "  !  уже существует, пропущено: %s\n" "$1"
      printf "     заменить — ./install.sh --force\n"
      return 0
    fi
  fi
  [ "$DRY" -eq 1 ] || ln -s "$s" "$d"
  printf "  +  %s\n" "$1"
}

[ "$DRY" -eq 1 ] && echo "= пробный прогон, ничего не меняется =" && echo

echo "Обёртки:"
for f in scripts/ask-codex.sh scripts/ask-grok.sh scripts/ask-gemini.sh scripts/agy-sandbox.sb; do
  link "$f"
done
[ "$DRY" -eq 1 ] || chmod +x "$SRC"/scripts/ask-*.sh

echo "Субагенты:"
for f in agents/codex.md agents/grok.md agents/gemini.md; do link "$f"; done

echo "Скиллы:"
for f in skills/delegate skills/second-opinion; do link "$f"; done

echo
echo "Готово. Дальше:"
echo "  1. Убедись, что нужные CLI установлены и авторизованы: codex / grok / agy"
echo "  2. Проверь вызов:  ~/.claude/scripts/ask-codex.sh -e low \"ответь одним словом: работает\""
echo "  3. Хочешь закрыть свой файл с доступами от чтения — задай переменную:"
echo "     export ASK_SECRETS_FILE=\"\$HOME/путь/к/файлу\""
