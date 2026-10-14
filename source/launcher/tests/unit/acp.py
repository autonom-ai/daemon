import io
import queue
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "acp"))
import server


class AdapterTests(unittest.TestCase):
    def test_frames_are_bounded_and_validated(self):
        self.assertEqual(server.read_frame(io.BytesIO(b'\n{"jsonrpc":"2.0","id":1}\n')),
                         b'{"jsonrpc":"2.0","id":1}\n')
        self.assertRaises(server.ProtocolError, server.decode_frame, b'{"jsonrpc":"1.0"}')
        with patch.object(server, "MAX_FRAME_BYTES", 8):
            self.assertRaises(server.ProtocolError, server.read_frame, io.BytesIO(b"123456789\n"))

    def test_shutdown_attempts_every_relay_even_when_one_stop_fails(self):
        agent = server.Agent(Mock(), "/workspace")
        relays = [Mock(), Mock()]
        for relay in relays:
            relay.close.side_effect = server.DaemonError("Stop unavailable")
        agent.relays.update(relays)
        with patch.object(sys, "stdin", Mock(buffer=io.BytesIO())):
            self.assertRaises(server.DaemonError, agent.serve)
        for relay in relays:
            relay.close.assert_called_once()
        self.assertTrue(agent.stopping.is_set())

    def test_close_unblocks_pending_requests_and_rejects_late_frames(self):
        agent = server.Agent(Mock(), "/workspace")
        agent.launcher.request.return_value = {"status": "stopped"}
        relay = server.Relay.__new__(server.Relay)
        relay.agent = agent
        relay.execution = "execution"
        relay.waiter_lock = threading.Lock()
        response = queue.Queue(maxsize=1)
        relay.waiters = {1: response}
        relay.closed = threading.Event()
        relay.close_lock = threading.Lock()
        relay.finished = False
        relay.thread = Mock()
        agent.relays.add(relay)
        agent.responses["forwarded"] = (relay, 2)
        relay.close()
        self.assertIsInstance(response.get_nowait(), server.DaemonError)
        self.assertRaises(server.DaemonError, relay.send, {"jsonrpc": "2.0"})
        self.assertFalse(agent.relays)
        self.assertFalse(agent.responses)
        count = agent.launcher.request.call_count
        relay.close()
        self.assertEqual(agent.launcher.request.call_count, count)

    def test_transcript_poll_emits_new_messages_once_and_tracks_title(self):
        daemon = Mock()
        daemon.request.return_value = {
            "session": {"title": "Autonom wake test"},
            "messages": [
                {"nodeId": 1, "role": "user", "content": [{"type": "text", "text": "Clock fired"}]},
                {"nodeId": 2, "role": "assistant", "content": "Wake displayed"},
                {"nodeId": 3, "role": "system", "content": "not visible"},
            ],
        }
        agent = server.Agent(daemon, "/workspace")
        sent = []
        agent.send = sent.append
        session = server.Session({"cwd": "/workspace"})
        agent.sync_transcript("session-one", session)
        self.assertEqual([frame["params"]["update"]["sessionUpdate"] for frame in sent],
                         ["session_info_update", "user_message_chunk", "agent_message_chunk"])
        self.assertEqual(sent[1]["params"]["update"]["content"]["text"], "Clock fired")
        self.assertEqual(session.last_node_id, 3)
        agent.sync_transcript("session-one", session)
        self.assertEqual(len(sent), 3)

    def test_session_load_seeds_transcript_without_duplicate_replay(self):
        daemon = Mock()
        daemon.request.return_value = {
            "session": {"title": "Existing session"},
            "messages": [{"nodeId": 17, "role": "assistant", "content": "Already replayed"}],
        }
        agent = server.Agent(daemon, "/workspace")
        sent = []
        agent.send = sent.append
        session = server.Session({"cwd": "/workspace"})
        agent.sync_transcript("session-one", session, seed=True)
        self.assertEqual(sent, [])
        self.assertEqual(session.last_node_id, 17)
        self.assertEqual(session.title, "Existing session")

    def test_open_after_shutdown_does_not_create_a_process(self):
        agent = server.Agent(Mock(), "/workspace")
        agent.stopping.set()
        with patch.object(server, "Relay") as relay:
            self.assertRaises(server.DaemonError, agent.open)
            relay.assert_not_called()


if __name__ == "__main__":
    unittest.main()
