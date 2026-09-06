#!/usr/bin/env python3
"""Cancel a silent HTTP stream through the real native ABI, then reuse its session."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"gpt-5","object":"model","owned_by":"openai"}]}')

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(b'data: {"type":"response.output_text.delta","item_id":"answer","output_index":0,"content_index":0,"delta":"STREAM_STARTED"}\n\n')
            self.wfile.flush()
            if not self.server.release.is_set():
                self.server.release.wait(30)
            self.wfile.write(b'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}\n\ndata: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


def verify(binary, revision):
    server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
    server.daemon_threads = True
    server.release = threading.Event()
    serving = threading.Thread(target=server.serve_forever)
    serving.start()
    try:
        with tempfile.TemporaryDirectory(prefix="fx-native-cancel-") as temporary:
            root = Path(temporary)
            (root / "home").mkdir()
            (root / "workspace").mkdir()
            configuration = root / "config.json"
            configuration.write_text(json.dumps({"home": str(root / "home"), "workspace_root": str(root / "workspace"),
                "native_tools": False, "model": "openai/gpt-5", "api_key": "synthetic-fixture-key",
                "responses_base_url": f"http://127.0.0.1:{server.server_port}/v1"}))
            process = subprocess.Popen([str(binary), str(configuration), revision, "--bridge"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            messages = queue.Queue()

            def read():
                for line in process.stdout:
                    messages.put(json.loads(line))
                messages.put(None)

            reader = threading.Thread(target=read)
            reader.start()

            def send(number, method, params):
                value = {"jsonrpc": "2.0", "method": method, "params": params}
                if number is not None:
                    value["id"] = number
                process.stdin.write(json.dumps(value) + "\n")
                process.stdin.flush()

            def receive(predicate):
                while True:
                    value = messages.get(timeout=10)
                    assert value is not None, "Native stream closed unexpectedly"
                    assert "error" not in value, value
                    if predicate(value):
                        return value

            try:
                send(1, "initialize", {"protocolVersion": 1})
                receive(lambda value: value.get("id") == 1)
                send(2, "session/new", {"cwd": str(root / "workspace"), "mcpServers": []})
                session = receive(lambda value: value.get("id") == 2)["result"]["sessionId"]
                send(3, "session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "Start streaming"}]})
                receive(lambda value: "STREAM_STARTED" in json.dumps(value))
                send(None, "session/cancel", {"sessionId": session})
                assert receive(lambda value: value.get("id") == 3)["result"]["stopReason"] == "cancelled"
                # Only release the provider after cancellation has settled. An
                # implementation that waits for another provider byte must fail.
                server.release.set()
                send(4, "session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "Continue"}]})
                assert receive(lambda value: value.get("id") == 4)["result"]["stopReason"] == "end_turn"
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                assert not process.stderr.read()
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                reader.join(timeout=10)
    finally:
        server.release.set()
        server.shutdown()
        server.server_close()
        serving.join()
    print("Native silent-stream cancellation and session reuse passed.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(), sys.argv[2])
