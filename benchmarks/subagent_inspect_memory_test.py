import unittest

from subagent_inspect_memory import inspection_latencies, latency_summary


def event(timestamp, phase, call_id="inspect_0", turn=1, step=3, name="subagent"):
    return (f"{timestamp} [tool] event={phase}_tool_execution turn_id={turn} "
            f"step_id={step} call_id={call_id} name={name}")


class InspectionLatencyTests(unittest.TestCase):
    def test_interleaved_child_and_final_wait_do_not_enter_inspection_samples(self):
        trace = "\n".join([
            event(100, "before"),
            event(101, "before", "child_read_0", turn=2, name="read_file"),
            event(104, "after", "child_read_0", turn=2, name="read_file"),
            event(108, "after"),
            event(110, "before", "inspect_1", step=4),
            event(125, "after", "inspect_1", step=4),
            event(126, "before", "collect_child", step=5),
            event(999, "after", "collect_child", step=5),
        ])
        self.assertEqual(inspection_latencies(trace, 2), [8, 15])

    def test_incomplete_duplicate_or_mismatched_spans_fail_closed(self):
        cases = [
            [event(10, "before")],
            [event(10, "after")],
            [event(10, "before"), event(20, "before"), event(30, "after")],
            [event(10, "before"), event(20, "after", turn=2)],
            [event(10, "before"), event(20, "after", step=4)],
            [event(10, "before"), event(9, "after")],
            [event(10, "before"), event(20, "after"), event(30, "before"), event(40, "after")],
            [event(10, "before", "inspect_1"), event(20, "after", "inspect_1")],
        ]
        for lines in cases:
            with self.subTest(lines=lines), self.assertRaises(RuntimeError):
                inspection_latencies("\n".join(lines), 1)

    def test_summary_uses_nearest_rank_p95_and_keeps_zero_ms_samples(self):
        result = latency_summary(list(range(20)))
        self.assertEqual(result, {"count": 20, "total_ms": 190, "mean_ms": 9.5,
                                  "p50_ms": 9.5, "p95_ms": 18, "max_ms": 19})


if __name__ == "__main__":
    unittest.main()
