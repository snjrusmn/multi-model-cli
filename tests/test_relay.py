import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import delegate_relay as R  # noqa: E402


def ev(t, item=None):
    d = {"type": t}
    if item is not None:
        d["item"] = item
    return json.dumps(d)


class Steps(unittest.TestCase):
    def test_command_file_change_and_message_become_steps(self):
        st = R.State()
        for line in [ev("thread.started"),
                     ev("item.started", {"type": "command_execution", "command": "/bin/zsh -lc 'wc -l a.txt'"}),
                     ev("item.completed", {"type": "command_execution", "command": "/bin/zsh -lc 'wc -l a.txt'", "exit_code": 0}),
                     ev("item.completed", {"type": "file_change", "changes": [{"path": "/w/app.py", "kind": "update"}]}),
                     ev("item.completed", {"type": "agent_message", "text": "Готово: 1 строка"}),
                     ev("turn.completed")]:
            st.feed(line)
        self.assertEqual(st.steps, ["▶ wc -l a.txt", "✓ wc -l a.txt", "✎ app.py", "💬 Готово: 1 строка"])
        self.assertTrue(st.done)

    def test_failed_command_marked(self):
        st = R.State()
        st.feed(ev("item.completed", {"type": "command_execution", "command": "pytest", "exit_code": 1}))
        self.assertEqual(st.steps, ["✗ pytest (код 1)"])

    def test_garbage_lines_ignored(self):
        st = R.State()
        st.feed("не json")
        st.feed("")
        self.assertEqual(st.steps, [])

    def test_render_keeps_last_steps_and_header(self):
        st = R.State()
        for i in range(30):
            st.steps.append("шаг %d" % i)
        text = R.render(st, name="ревью", elapsed=65)
        self.assertIn("ревью", text)
        self.assertIn("шаг 29", text)
        self.assertNotIn("шаг 0\n", text)
        self.assertLess(len(text), 4000)


class Telegram(unittest.TestCase):
    def test_no_send_without_config_but_progress_file_written(self):
        d = tempfile.mkdtemp()
        calls = []
        out = R.Publisher(env={}, run_dir=d, post=lambda m, data: calls.append(m))
        out.publish("текст")
        self.assertEqual(calls, [])
        self.assertFalse(os.path.exists(os.path.join(d, "relay-errors.log")))
        with open(os.path.join(d, "progress.md")) as f:
            self.assertEqual(f.read(), "текст")
        self.assertIsNone(out.message_id)

    def test_first_publish_sends_then_edits(self):
        calls = []

        def post(method, data):
            calls.append((method, data))
            return {"ok": True, "result": {"message_id": 42}}

        d = tempfile.mkdtemp()
        out = R.Publisher(env={"DELEGATE_TG_TOKEN": "T", "DELEGATE_TG_CHAT": "-1", "DELEGATE_TG_THREAD": "7"},
                          run_dir=d, post=post)
        out.publish("a")
        out.publish("b")
        self.assertEqual([c[0] for c in calls], ["sendMessage", "editMessageText"])
        self.assertEqual(calls[0][1]["message_thread_id"], "7")
        self.assertEqual(calls[1][1]["message_id"], 42)


if __name__ == "__main__":
    unittest.main()
