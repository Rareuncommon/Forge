"""Exercise the real newline-JSON transport, including OCCT file translators."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class MCPWorkflowTests(unittest.TestCase):
    def test_step_interference_history_and_persistence(self):
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        with tempfile.TemporaryDirectory() as temporary:
            source = str(Path(temporary) / "source.step")
            saved = str(Path(temporary) / "saved.forgepart")
            calls = [
                ("new_document", {}),
                ("execute", {"command": "body.create_box", "params": {"width": 10, "height": 10, "depth": 10}}),
                ("export_step", {"path": source}),
                ("new_document", {}),
                ("import_step", {"path": source}),
                ("execute", {"command": "body.create_box", "params": {"width": 10, "height": 10, "depth": 10, "origin": [5, 0, 0]}}),
                ("check_interference", {}),
                ("execute", {"command": "body.transform", "params": {"body": "body-1", "translate": [0, 0, 1]}}),
                ("get_feature_dependencies", {"feature": "feature-2"}),
                ("reorder_feature", {"feature": "feature-1"}),
                ("get_feature", {"feature": "feature-2"}),
                ("save", {"path": saved}),
                ("import_step", {"path": str(Path(temporary) / "missing.step")}),
            ]
            responses = self.run_calls(executable, calls)
            for response in responses[:-1]:
                self.assertFalse(response["result"]["isError"], response)
            overlap = responses[6]["result"]["structuredContent"]
            self.assertEqual(overlap["interference_count"], 1)
            self.assertAlmostEqual(overlap["interferences"][0]["volume_mm3"], 500)
            self.assertTrue(responses[-1]["result"]["isError"])
            Path(source).unlink()
            reopened = self.run_calls(executable, [
                ("open", {"path": saved}), ("rebuild", {}),
                ("compare_to_spec", {"spec": {"body_count": 2, "bodies": [
                    {"body": "body-1", "volume_mm3": {"value": 1000, "tol": 1e-8}},
                    {"body": "body-2", "volume_mm3": {"value": 1000, "tol": 1e-8}},
                ]}}),
            ])
            self.assertTrue(reopened[-1]["result"]["structuredContent"]["passed"])

    def test_invalid_step_keeps_stdout_valid_json(self):
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "invalid.step"
            source.write_text("not a STEP document\n")
            responses = self.run_calls(executable, [
                ("new_document", {}), ("import_step", {"path": str(source)}),
                ("check_interference", {}),
            ])
            self.assertTrue(responses[1]["result"]["isError"])
            self.assertFalse(responses[2]["result"]["isError"])
            self.assertEqual(responses[2]["result"]["structuredContent"]["bodies"], [])

    def run_calls(self, executable, calls):
        messages = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}]
        messages.extend({"jsonrpc": "2.0", "id": index + 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
                        for index, (name, arguments) in enumerate(calls))
        process = subprocess.run([executable, "mcp"], input="".join(json.dumps(m) + "\n" for m in messages),
                                 text=True, capture_output=True, timeout=60, check=True)
        # Any OCCT progress text on stdout breaks this parse, as it would a real MCP client.
        responses = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([r["id"] for r in responses], list(range(len(messages))))
        return responses[1:]


if __name__ == "__main__":
    unittest.main()
