"""HTTP contract checks for the synthetic fixture, not iOS performance tests."""
import base64
import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from urllib.parse import urlencode

import lab


class LabContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.log_path = Path(self.temporary.name) / "requests.jsonl"
        self.state = lab.LabState(text_bytes=64, tool_bytes=128, log_path=self.log_path)
        self.server = lab.make_server(state=self.state, password="contract-test-only")
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        self.thread.start()
        self.connections = []
        token = base64.b64encode(b"opencode:contract-test-only").decode()
        self.authorization = "Basic " + token

    def tearDown(self):
        for connection in self.connections:
            connection.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def connect(self):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        self.connections.append(connection)
        return connection

    def request(self, path, *, body=None, authorized=True):
        connection = self.connect()
        headers = {"Authorization": self.authorization} if authorized else {}
        if body is not None:
            headers["Content-Type"] = "application/json"
        connection.request("GET" if body is None else "POST", path,
                           None if body is None else json.dumps(body), headers)
        response = connection.getresponse()
        raw = response.read()
        return response.status, dict(response.getheaders()), json.loads(raw) if raw else None, raw

    def open_stream(self, path="/global/event", last_id=None):
        connection = self.connect()
        headers = {"Authorization": self.authorization}
        if last_id is not None:
            headers["Last-Event-ID"] = str(last_id)
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertIn("text/event-stream", response.getheader("Content-Type"))
        return connection, response

    @staticmethod
    def read_event(response):
        event_id = None
        payload = []
        while True:
            line = response.readline()
            if not line:
                raise AssertionError("SSE ended before the expected event")
            line = line.decode().rstrip("\r\n")
            if line.startswith("id:"):
                event_id = line[3:].strip()
            elif line.startswith("data:"):
                payload.append(line[5:].lstrip())
            elif not line and payload:
                data = json.loads("\n".join(payload))
                return event_id, data.get("payload", data)

    def test_bootstrap_and_v1_probe_identity(self):
        status, _, health, _ = self.request("/global/health")
        self.assertEqual(status, 200)
        self.assertTrue(health["healthy"])
        self.assertTrue(health["version"].startswith("1."))
        self.assertEqual(self.request("/api/info")[0], 404)
        self.assertEqual(self.request("/api/health")[0], 404)
        self.assertEqual(self.request("/path")[2]["directory"], "/openclient-performance-lab")
        sessions = self.request("/session")[2]
        self.assertEqual({item["id"] for item in sessions}, {"ses_20", "ses_200", "ses_2000"})
        self.assertEqual(self.request("/permission")[2], [])
        self.assertEqual(self.request("/question")[2], [])
        self.assertEqual(self.request("/session/status")[2], {})
        providers = self.request("/provider")[2]
        self.assertIsInstance(providers["all"], list)
        self.assertEqual(providers["connected"], ["lab"])
        self.assertEqual(providers["default"], {"lab": "synthetic"})
        self.assertEqual(self.request("/project")[2][0]["worktree"], "/openclient-performance-lab")
        self.assertEqual(self.request("/agent")[2][0]["mode"], "primary")
        snapshot = self.request("/_lab/status")[2]
        self.assertIsInstance(snapshot["recent_requests"], list)
        self.assertEqual(snapshot["sse_connections"], 0)

    def test_authentication_unknown_routes_and_bad_queries(self):
        self.assertEqual(self.request("/session", authorized=False)[0], 401)
        self.assertEqual(self.request("/unknown")[0], 404)
        self.assertEqual(self.request("/session/not-a-session/message")[0], 404)
        for query in ("limit=0", "limit=-1", "limit=abc", "before=unknown"):
            with self.subTest(query=query):
                self.assertEqual(self.request("/session/ses_200/message?" + query)[0], 400)

    def test_initial_limit_is_honored_and_all_pages_have_no_gaps(self):
        path = "/session/ses_2000/message"
        _, headers, page, _ = self.request(path + "?limit=20")
        self.assertEqual(len(page), 20)
        ids = [message["info"]["id"] for message in page]
        self.assertEqual(ids[-1], "msg_ses_2000_001999")
        cursor = {key.lower(): value for key, value in headers.items()}.get("x-next-cursor")
        while cursor:
            _, headers, page, _ = self.request(path + "?" + urlencode({"limit": 200, "before": cursor}))
            self.assertLessEqual(len(page), 200)
            ids = [message["info"]["id"] for message in page] + ids
            cursor = {key.lower(): value for key, value in headers.items()}.get("x-next-cursor")
        self.assertEqual(ids, [f"msg_ses_2000_{index:06d}" for index in range(2000)])

    def test_larger_retained_limit_increases_body_and_detail_matches_page(self):
        _, _, small, small_raw = self.request("/session/ses_200/message?limit=20")
        _, _, large, large_raw = self.request("/session/ses_200/message?limit=200")
        self.assertEqual(len(small), 20)
        self.assertEqual(len(large), 200)
        self.assertGreater(len(large_raw), len(small_raw))
        message = next(item for item in small if any(p["type"] == "tool" for p in item["parts"]))
        _, _, detail, _ = self.request("/session/ses_200/message/" + message["info"]["id"])
        self.assertEqual(detail, message)
        tool = next(part for part in detail["parts"] if part["type"] == "tool")
        self.assertEqual(len(tool["state"]["output"].encode()), 128)

    def test_sse_broadcast_and_canonical_text_agree(self):
        _, first = self.open_stream()
        _, second = self.open_stream()
        self.assertEqual(self.read_event(first)[1]["type"], "server.connected")
        self.assertEqual(self.read_event(second)[1]["type"], "server.connected")
        status, _, _, _ = self.request("/_lab/stream", body={
            "sessionID": "ses_20", "chunks": 3, "interval_ms": 5, "chunk_bytes": 11,
        })
        self.assertIn(status, (200, 202))
        traces = []
        for response in (first, second):
            trace = []
            for _ in range(30):
                event_id, event = self.read_event(response)
                trace.append((event_id, event))
                if event["type"] == "session.status" and event["properties"]["status"]["type"] == "idle":
                    break
            else:
                self.fail("Stream did not reach idle")
            traces.append(trace)
        self.assertEqual(traces[0], traces[1], "Each subscriber must receive the same changes")
        deltas = [event["properties"]["delta"] for _, event in traces[0]
                  if event["type"] == "message.part.delta" and event["properties"]["field"] == "text"]
        self.assertEqual(len(deltas), 3)
        latest = self.request("/session/ses_20/message?limit=2")[2][-1]
        text = next(part["text"] for part in latest["parts"] if part["type"] == "text")
        self.assertEqual(text, "".join(deltas))
        self.assertEqual(len(text.encode()), 33)
        self.assertEqual(self.request("/session/status")[2], {})

    def test_invalid_stream_cannot_mutate_fixture(self):
        before = self.request("/session/ses_20/message?limit=100")[2]
        status, _, _, _ = self.request("/_lab/stream", body={"sessionID": "ses_20", "chunks": -1})
        self.assertEqual(status, 400)
        self.assertEqual(self.request("/session/ses_20/message?limit=100")[2], before)

    def test_request_log_records_bytes_without_credentials_or_payload(self):
        for _ in range(2):
            self.request("/session/ses_20/message/msg_ses_20_000019")
        deadline = time.monotonic() + 2
        rows = []
        while time.monotonic() < deadline:
            rows = [json.loads(line) for line in self.log_path.read_text().splitlines()] if self.log_path.exists() else []
            if len(rows) == 2:
                break
            time.sleep(0.005)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["path"], rows[1]["path"])
        for row in rows:
            self.assertEqual(row["status"], 200)
            self.assertGreater(row["response_bytes"], 0)
            self.assertGreaterEqual(row["ended_ns"], row["started_ns"])
            self.assertIsInstance(row["query"], dict)
        raw = self.log_path.read_text()
        self.assertNotIn("contract-test-only", raw)
        self.assertNotIn(self.authorization, raw)
        self.assertNotIn('"parts"', raw)
        self.assertEqual(lab.summary(self.log_path)["total_requests"], 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
