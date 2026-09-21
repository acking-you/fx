#!/usr/bin/env python3
"""Measure native fx peak RSS while a parent repeatedly inspects a blocked child.

Linux only; uses a local Responses fixture, isolated profiles, and no credentials.
GNU time records fx's kernel RSS high-water mark, not sampled RSS or cumulative
allocation traffic. Each binary/run gets a fresh process and identical workload.
"""

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import threading
import time


CHILD_PROMPT = "INSPECT_BENCH_CHILD: read the evidence, then wait for completion."
CHILD_DONE = "INSPECT_BENCH_CHILD_COMPLETE"
PARENT_DONE = "INSPECT_BENCH_PARENT_COMPLETE"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def content_text(content):
    if isinstance(content, str):
        return content
    return "".join(item.get("text", "") for item in content)


def tool_call(call_id, name, arguments, text=""):
    events = []
    if text:
        events.append({"type": "response.output_text.delta", "item_id": "text",
                       "output_index": 0, "content_index": 0, "delta": text})
    events.extend([
        {"type": "response.output_item.added", "output_index": 1, "item": {
            "type": "function_call", "id": call_id + "_item", "call_id": call_id,
            "name": name, "arguments": ""}},
        {"type": "response.function_call_arguments.done", "output_index": 1,
         "item_id": call_id + "_item", "call_id": call_id,
         "arguments": json.dumps(arguments)},
    ])
    return events


def final_text(text):
    return [{"type": "response.output_text.delta", "item_id": "answer",
             "output_index": 0, "content_index": 0, "delta": text}]


def rss_status(pid):
    fields = {}
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith(("VmRSS:", "VmHWM:")):
                key, value = line.split(":", 1)
                fields[key] = int(value.split()[0])
    except FileNotFoundError:
        pass
    return fields


def run_once(binary, root, args):
    root.mkdir(mode=0o700, parents=True)
    home, workspace = root / "home", root / "workspace"
    (home / ".fx").mkdir(parents=True, mode=0o700)
    workspace.mkdir()
    (home / ".fx/settings.json").write_text(json.dumps({
        "provider": "gateway", "model": "fixture-model", "max_agent_steps": 0,
    }))
    (workspace / "evidence.txt").write_text("benchmark evidence\n")
    child_ready, release_child = threading.Event(), threading.Event()
    observations, errors = [], []
    child_id = ""
    inspect_started = 0.0
    fixture = {}
    proc = None
    fx_pid = None

    def inspect(call_id, wait=False):
        command = {"id": child_id, "sections": ["status", "messages"], "limit": 5}
        if wait:
            command["wait"] = {"until": "settled", "timeout_ms": 10000}
        return tool_call(call_id, "subagent", {"command": {"inspect": command}})

    def respond(body):
        nonlocal child_id, inspect_started
        results = {item["call_id"]: content_text(item["output"])
                   for item in body["input"] if item.get("type") == "function_call_output"}
        # Parent results take precedence: its history also contains the child's
        # prompt in create arguments, but never the child's internal tool calls.
        if "collect_child" in results:
            outcome = json.loads(results["collect_child"])
            require(outcome["ok"] and outcome["status"] == "idle", "child did not settle")
            require(outcome["requested"]["history_len"] == 1, "missing committed child turn")
            require(CHILD_DONE in json.dumps(outcome), "missing completed child history")
            fixture["completed_history_verified"] = True
            return final_text(PARENT_DONE)
        if "create_child" in results:
            created = json.loads(results["create_child"])
            require(created["ok"], f"create failed: {created}")
            child_id = created["child_id"]
            require(child_ready.wait(args.timeout), "child never reached its blocked request")
            completed = sum(f"inspect_{index}" in results for index in range(args.inspections))
            if completed:
                raw_output = results[f"inspect_{completed - 1}"]
                try:
                    outcome = json.loads(raw_output)
                    require(outcome["ok"] and outcome["status"] == "running", "inspect failed")
                    require(outcome["requested"]["history_len"] == 0, "child completed too early")
                    require(outcome["requested"].get("history_error") is None, "history load failed")
                except Exception:
                    fixture["failed_inspection"] = {"number": completed, "output": raw_output[:65536]}
                    raise
                observations.append({"inspection": completed, "output_bytes": len(results[f"inspect_{completed - 1}"].encode()),
                                     "seconds": time.monotonic() - inspect_started,
                                     **rss_status(fx_pid)})
            else:
                log = home / ".fx/sessions" / child_id / "events.jsonl"
                sizes = []
                for line in log.open():
                    if "recovery_checkpoint_set" in line:
                        sizes.append(len(line.encode()))
                require(len(sizes) >= args.child_steps * 2, "fixture did not persist checkpoints")
                fixture.update(checkpoint_events=len(sizes), checkpoint_frame_bytes=sizes,
                               event_log_bytes=log.stat().st_size,
                               before_inspections=rss_status(fx_pid))
                inspect_started = time.monotonic()
            if completed < args.inspections:
                return inspect(f"inspect_{completed}")
            fixture["inspection_seconds"] = time.monotonic() - inspect_started
            release_child.set()
            return inspect("collect_child", wait=True)
        reads = sum(f"child_read_{index}" in results for index in range(args.child_steps))
        is_child = reads or any(CHILD_PROMPT == content_text(item.get("content", []))
                                for item in body["input"] if item.get("role") == "user")
        if is_child:
            if reads == args.child_steps:
                child_ready.set()
                require(release_child.wait(args.timeout), "parent did not release child")
                return final_text(CHILD_DONE)
            return tool_call(f"child_read_{reads}", "read_file", {"path": "evidence.txt"},
                             f"checkpoint step {reads}: " + "x" * args.text_bytes)
        return tool_call("create_child", "subagent", {"command": {"create": {
            "name": "inspection-benchmark", "mode": "persistent", "prompt": CHILD_PROMPT}}})

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, data, content_type, status=200):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(json.dumps({"object": "list", "data": [{"id": "fixture-model",
                       "object": "model", "context_window": 1000000}]}).encode(), "application/json")

        def do_POST(self):
            try:
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                events = respond(body)
                events.append({"type": "response.completed", "response": {"status": "completed",
                               "usage": {"input_tokens": 3, "output_tokens": 5, "total_tokens": 8}}})
                self.reply(("".join("data: " + json.dumps(event) + "\n\n" for event in events)
                            + "data: [DONE]\n\n").encode(), "text/event-stream")
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                errors.append(str(error))
                self.reply(json.dumps({"error": str(error)}).encode(), "application/json", 500)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("FX_", "OPENAI_", "GROK_", "XAI_"))}
    env.update(HOME=str(home), OPENAI_API_KEY="fixture-key", FX_MODEL="fixture-model",
               FX_RESPONSES_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1", FX_MAX_AGENT_STEPS="0")

    started = time.monotonic()
    samples = []
    usage_path = root / "resource-usage.txt"
    with (root / "stdout.json").open("w") as out, (root / "stderr.log").open("w") as err:
        # Measuring Popen directly with wait4 includes Python's pre-exec RSS.
        # GNU time forks from its small, freshly exec'd process, then measures
        # only the prlimit -> fx child. prlimit execs fx in the same PID.
        proc = subprocess.Popen(["/usr/bin/time", "--quiet", "--format=%M %U %S %x",
                                 "--output", str(usage_path), "--", "prlimit",
                                 f"--as={args.limit_mib * 1024**2}", "--core=0:0", "--",
                                 str(binary), "ask", "--json", "--yolo",
                                 "Inspect the child repeatedly, then collect its completed history."],
                                cwd=workspace, env=env, stdout=out, stderr=err,
                                start_new_session=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            children_path = Path(f"/proc/{proc.pid}/task/{proc.pid}/children")
            while fx_pid is None:
                children = children_path.read_text().split() if children_path.exists() else []
                if children:
                    fx_pid = int(children[0])
                    break
                require(proc.poll() is None and time.monotonic() - started < 5,
                        "GNU time did not start the measured process")
                time.sleep(0.01)
            while True:
                if proc.poll() is not None:
                    break
                samples.append({"seconds": time.monotonic() - started, **rss_status(fx_pid)})
                if time.monotonic() - started > args.timeout or errors:
                    if not errors:
                        errors.append("benchmark deadline exceeded")
                    # Leave GNU time alive so even a failed/OOM workload has
                    # a kernel peak measurement. This fixture starts no shell
                    # descendants: both agents live in the measured process.
                    try:
                        os.kill(fx_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
                    break
                time.sleep(0.01)
        finally:
            release_child.set()
            if proc.returncode is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            server.shutdown()
            server.server_close()
    stderr = (root / "stderr.log").read_text()
    stdout = (root / "stdout.json").read_text()
    usage = usage_path.read_text().split() if usage_path.exists() else []
    if len(usage) != 4:
        errors.append("missing kernel peak RSS: measured process did not exit normally")
    report = {"binary": str(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "code": proc.returncode, "peak_rss_kib": int(usage[0]) if len(usage) == 4 else None,
              "elapsed_seconds": time.monotonic() - started,
              "user_seconds": float(usage[1]) if len(usage) == 4 else None,
              "system_seconds": float(usage[2]) if len(usage) == 4 else None, "fixture": fixture,
              "observations": observations, "errors": errors, "samples": samples}
    report["completed_inspections"] = len(observations)
    try:
        report["product_error"] = json.loads(stdout).get("error")
    except (json.JSONDecodeError, AttributeError):
        report["product_error"] = None
    report["oom_detected"] = bool(re.search(r"OutOfMemory|out.of.memory|memory allocation failed",
                                            stderr + stdout + json.dumps(fixture.get("failed_inspection")),
                                            re.IGNORECASE))
    report["passed"] = (proc.returncode == 0 and not errors
                        and not re.search(r"error:|panic|segmentation fault|OutOfMemory", stderr, re.IGNORECASE)
                        and len(observations) == args.inspections
                        and fixture.get("completed_history_verified", False)
                        and PARENT_DONE in stdout)
    (root / "measurements.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", action="append", help="LABEL=PATH; repeat to compare binaries")
    parser.add_argument("--output", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--inspections", type=int, default=12)
    parser.add_argument("--child-steps", type=int, default=4)
    parser.add_argument("--text-bytes", type=int, default=64 * 1024)
    parser.add_argument("--limit-mib", type=int, default=2048)
    parser.add_argument("--max-peak-mib", type=float, help="optional peak RSS regression budget")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("this benchmark uses Linux /proc and GNU time RSS units")
    if not Path("/usr/bin/time").exists() or not shutil.which("prlimit"):
        parser.error("GNU time and util-linux prlimit are required")
    if min(args.runs, args.inspections, args.child_steps, args.text_bytes, args.limit_mib, args.timeout) <= 0:
        parser.error("workload sizes, limits and runs must be positive")
    if args.max_peak_mib is not None and args.max_peak_mib <= 0:
        parser.error("peak RSS budget must be positive")
    binaries = []
    for value in args.binary or ["current=./zig-out/bin/fx"]:
        label, path = value.split("=", 1)
        if not label or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in label):
            parser.error("binary labels must use letters, digits, hyphens or underscores")
        binaries.append((label, Path(path).resolve(strict=True)))
    if len({label for label, _ in binaries}) != len(binaries):
        parser.error("binary labels must be unique")
    root = Path(args.output).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    reports = {label: [] for label, _ in binaries}
    # Rotate order to reduce systematic warm-cache bias between variants.
    for run in range(args.runs):
        offset = run % len(binaries)
        for label, binary in binaries[offset:] + binaries[:offset]:
            report = run_once(binary, root / label / str(run + 1), args)
            if args.max_peak_mib is not None:
                report["passed"] &= (report["peak_rss_kib"] is not None
                                     and report["peak_rss_kib"] <= args.max_peak_mib * 1024)
                (root / label / str(run + 1) / "measurements.json").write_text(json.dumps(report, indent=2) + "\n")
            reports[label].append(report)
            print(json.dumps({"label": label, "run": run + 1, "peak_rss_kib": report["peak_rss_kib"],
                              "inspection_seconds": report["fixture"].get("inspection_seconds"),
                              "passed": report["passed"]}), flush=True)
    summary = {"platform": platform.platform(), "machine": platform.machine(), "workload": vars(args),
               "variants": {label: {"binary_sha256": runs[0]["binary_sha256"],
                   "peak_rss_mib_median": (statistics.median(item["peak_rss_kib"] for item in runs) / 1024
                                           if all(item["peak_rss_kib"] is not None for item in runs) else None),
                   "peak_rss_kib_runs": [item["peak_rss_kib"] for item in runs],
                   "completed_inspections_runs": [item["completed_inspections"] for item in runs],
                   "exit_codes": [item["code"] for item in runs],
                   "oom_detected_runs": [item["oom_detected"] for item in runs],
                   "product_errors": [item["product_error"] for item in runs],
                   "inspection_seconds_runs": [item["fixture"].get("inspection_seconds") for item in runs],
                   "passed": all(item["passed"] for item in runs)} for label, runs in reports.items()}}
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if all(item["passed"] for item in summary["variants"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
