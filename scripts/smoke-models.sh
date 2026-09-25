#!/bin/zsh
# Проверка всех моделей: один вопрос, замер времени
cd "${TMPDIR:-/tmp}"
LOG="${TMPDIR:-/tmp}/smoke-models.tsv"; : > "$LOG"
Q='Reply in Russian with ONE short sentence: which model are you and who made you?'
t() { # label, command...
  local label=$1; shift
  printf '\n\033[1;36m▶ %s\033[0m\n' "$label"
  local s=$(date +%s)
  local out=$( perl -e 'alarm 180; exec @ARGV' "$@" 2>&1 | grep -v '^\s*$' | tail -3 | tr '\n' ' ' | cut -c1-220 )
  local rc=$?; local e=$(( $(date +%s) - s ))
  printf '  %ss │ %s\n' "$e" "$out"
  printf '%s\t%s\t%s\n' "$label" "$e" "$out" >> "$LOG"
}
# Claude (подписка $100)
for m in fable opus sonnet haiku; do t "claude:$m" claude -p --model $m --effort low "$Q"; done
# Codex (ChatGPT $100)
for m in gpt-6-astra gpt-6-sol gpt-6-luna gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5.5; do
  t "codex:$m" codex exec --skip-git-repo-check -s read-only -m $m -c model_reasoning_effort=low "$Q"; done
# Grok (закомментирован: баланс подписки кончился 25.09.2026)
# for m in grok-4.7 grok-4.7-build-fast grok-4.6; do t "grok:$m" grok -p "$Q" -m $m; done
# Google ($20) — Gemini и Claude/GPT-OSS в отдельной квоте
for m in gemini-3.8-flash-low gemini-3.1-pro-low claude-opus-4-6-thinking claude-sonnet-4-6 gpt-oss-120b-medium; do
  t "agy:$m" agy -p "$Q" --model $m --print-timeout 170s; done
printf '\n\033[1;32m✔ Готово. Итог: %s\033[0m\n' "$LOG"
