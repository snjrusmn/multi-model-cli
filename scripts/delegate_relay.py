#!/usr/bin/env python3
"""Ретранслятор делегирования: читает события `codex exec --json` со stdin, сжимает до
шагов и показывает ход одним сообщением в Telegram (редактируется по мере работы).

Оркестратор этот поток не читает — он ждёт только файл итога. Без настроек Telegram ход
пишется в progress.md папки прогона.

    codex exec --json ... | delegate_relay.py --run-dir DIR --name ИМЯ

Окружение: DELEGATE_TG_TOKEN, DELEGATE_TG_CHAT, DELEGATE_TG_THREAD (топик, по желанию).
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

MAX_STEPS = 15
_SHELL_WRAP = re.compile(r"^(?:/bin/)?(?:ba|z)?sh -lc ['\"](.*)['\"]$", re.S)


def _short_cmd(cmd):
    m = _SHELL_WRAP.match(cmd or "")
    cmd = m.group(1) if m else (cmd or "")
    cmd = " ".join(cmd.split())
    return cmd if len(cmd) <= 80 else cmd[:77] + "…"


class State:
    def __init__(self):
        self.steps = []
        self.done = False
        self.failed = False

    def feed(self, line):
        try:
            e = json.loads(line)
        except (ValueError, TypeError):
            return
        if not isinstance(e, dict):
            return
        t, it = e.get("type"), e.get("item") or {}
        kind = it.get("type")
        if t == "item.started" and kind == "command_execution":
            self.steps.append("▶ " + _short_cmd(it.get("command")))
        elif t == "item.completed" and kind == "command_execution":
            code = it.get("exit_code")
            cmd = _short_cmd(it.get("command"))
            self.steps.append("✓ " + cmd if code == 0 else "✗ %s (код %s)" % (cmd, code))
        elif t == "item.completed" and kind == "file_change":
            for ch in it.get("changes") or []:
                self.steps.append("✎ " + os.path.basename(ch.get("path", "?")))
        elif t == "item.completed" and kind == "agent_message":
            text = " ".join((it.get("text") or "").split())
            self.steps.append("💬 " + (text if len(text) <= 120 else text[:117] + "…"))
        elif t == "turn.completed":
            self.done = True
        elif t in ("turn.failed", "error"):
            self.done = self.failed = True
            msg = (e.get("error") or {}).get("message") if isinstance(e.get("error"), dict) else e.get("message")
            self.steps.append("⛔ " + str(msg or "ошибка")[:200])


def render(state, name, elapsed):
    head = "⇢ %s · %d:%02d · %s" % (name, elapsed // 60, elapsed % 60,
                                    "ошибка" if state.failed else ("готово" if state.done else "работает"))
    shown = state.steps[-MAX_STEPS:]
    skipped = len(state.steps) - len(shown)
    body = ([("… ещё %d шагов выше" % skipped)] if skipped else []) + shown
    return (head + "\n" + "\n".join(body))[:3900]


def _post(token):
    def post(method, data):
        req = urllib.request.Request("https://api.telegram.org/bot%s/%s" % (token, method),
                                     data=urllib.parse.urlencode(data).encode())
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    return post


class Publisher:
    def __init__(self, env, run_dir, post=None):
        self.token, self.chat = env.get("DELEGATE_TG_TOKEN"), env.get("DELEGATE_TG_CHAT")
        self.thread = env.get("DELEGATE_TG_THREAD")
        self.run_dir = run_dir
        self.post = post or (_post(self.token) if self.token else None)
        self.message_id = None
        self.last = None

    def publish(self, text):
        with open(os.path.join(self.run_dir, "progress.md"), "w") as f:
            f.write(text)
        if not (self.token and self.chat) or text == self.last:
            return
        try:
            if self.message_id is None:
                data = {"chat_id": self.chat, "text": text}
                if self.thread:
                    data["message_thread_id"] = self.thread
                r = self.post("sendMessage", data)
                self.message_id = (r.get("result") or {}).get("message_id")
            else:
                self.post("editMessageText", {"chat_id": self.chat, "message_id": self.message_id, "text": text})
            self.last = text
        except Exception as e:  # сеть не должна ронять прогон
            with open(os.path.join(self.run_dir, "relay-errors.log"), "a") as f:
                f.write("%s %r\n" % (time.strftime("%H:%M:%S"), e))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--name", default="делегирование")
    ap.add_argument("--every", type=float, default=12.0, help="секунд между обновлениями сообщения")
    a = ap.parse_args()
    st, pub, t0, last_pub = State(), Publisher(os.environ, a.run_dir), time.time(), 0.0
    with open(os.path.join(a.run_dir, "events.jsonl"), "a") as log:
        for line in sys.stdin:
            log.write(line)
            st.feed(line)
            now = time.time()
            if now - last_pub >= a.every:
                pub.publish(render(st, a.name, int(now - t0)))
                last_pub = now
    st.done = True
    pub.publish(render(st, a.name, int(time.time() - t0)))


if __name__ == "__main__":
    main()
