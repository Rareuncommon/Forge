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

    def test_angle_measurement_and_structured_errors(self):
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        responses = self.run_calls(executable, [
            ("new_document", {}),
            ("execute", {"command": "body.create_box", "params": {"width": 10, "height": 20, "depth": 30}}),
            ("measure", {"from": "body-1/face@feature-1:+x", "to": "body-1/face@feature-1:+z", "mode": "angle"}),
            ("measure", {"from": "body-1/face@feature-1:+x", "to": "body-1/face@feature-1:+z"}),
            ("measure", {"from": "body-1", "to": "body-1/face@feature-1:+z", "mode": "angle"}),
            ("measure", {"from": "body-1/face@feature-1:+x", "mode": "angle"}),
        ])
        for response in responses[:4]:
            self.assertFalse(response["result"]["isError"], response)
        angle = responses[2]["result"]["structuredContent"]
        self.assertAlmostEqual(angle["angle_degrees"], 90)
        self.assertNotIn("distance_mm", angle)
        self.assertIn("distance_mm", responses[3]["result"]["structuredContent"])
        for response in responses[4:]:
            self.assertTrue(response["result"]["isError"], response)

    def test_selection_framing_is_read_only_and_respects_visibility(self):
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        responses = self.run_calls(executable, [
            ("new_document", {}),
            ("execute", {"command": "body.create_box", "params": {"width": 10, "height": 20, "depth": 30}}),
            ("execute", {"command": "body.create_box", "params": {"width": 10, "height": 20, "depth": 30, "origin": [1000, 0, 0]}}),
            ("execute", {"command": "selection.set", "params": {"entities": ["body-1"]}}),
            ("get_document_state", {}),
            ("zoom_to_selection", {}),
            ("get_document_state", {}),
            ("execute", {"command": "view.set_visibility", "params": {"bodies": ["body-1"], "visible": False}}),
            ("zoom_to_selection", {"entities": ["body-1", "plane-front"]}),
        ])
        for response in responses:
            self.assertFalse(response["result"]["isError"], response)
        state = lambda i: responses[i]["result"]["structuredContent"]
        self.assertEqual(state(4), state(6))
        self.assertEqual(state(5)["framed"], ["body-1"])
        self.assertAlmostEqual(state(5)["bounds"]["max"][0], 10, places=6)
        self.assertEqual(state(8)["framed"], [])
        self.assertNotIn("bounds", state(8))

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

    def test_face_sketch_conversion_builds_an_analytic_boss(self):
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        responses = self.run_calls(executable, [
            ("new_document", {}),
            ("execute", {"command": "body.create_box", "params": {"width": 10, "height": 20, "depth": 30}}),
            ("execute", {"command": "sketch.create", "params": {"face": "body-1/face-5"}}),
            ("convert_entities", {"entities": ["body-1/face-5"]}),
            ("execute", {"command": "sketch.exit", "params": {}}),
            ("execute", {"command": "body.extrude", "params": {"sketch": "sketch-1", "depth": 2}}),
            ("compare_to_spec", {"spec": {"body_count": 2, "bodies": [
                {"body": "body-1", "volume_mm3": {"value": 6000, "tol": 1e-6}},
                {"body": "body-2", "volume_mm3": {"value": 400, "tol": 1e-6}},
            ]}}),
        ])
        for response in responses:
            self.assertFalse(response["result"]["isError"], response)
        self.assertTrue(responses[-1]["result"]["structuredContent"]["passed"])

    def test_curved_slot_measurement_and_body_visibility(self):
        import math
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        with tempfile.TemporaryDirectory() as temporary:
            saved = str(Path(temporary) / "curved-slot.forgepart")
            responses = self.run_calls(executable, [
                ("new_document", {}),
                ("execute", {"command": "sketch.create", "params": {"plane": "front"}}),
                ("execute", {"command": "sketch.add_arc_slot", "params": {
                    "center": [0, 0], "start": [10, 0], "end": [0, 10], "width": 4}}),
                ("execute", {"command": "sketch.exit", "params": {}}),
                ("execute", {"command": "body.extrude", "params": {"sketch": "sketch-1", "depth": 3}}),
                ("measure", {"from": "body-1"}),
                ("execute", {"command": "view.set_visibility", "params": {"bodies": ["body-1"], "visible": False}}),
                ("execute", {"command": "view.isolate", "params": {"bodies": ["body-1"]}}),
                ("save", {"path": saved}),
            ])
            for response in responses:
                self.assertFalse(response["result"]["isError"], response)
            measured = responses[5]["result"]["structuredContent"]["from_entity"]
            self.assertAlmostEqual(measured["volume_mm3"], 72 * math.pi, places=6)
            self.assertEqual(responses[6]["result"]["structuredContent"]["result"]["visible_bodies"], [])
            self.assertEqual(responses[7]["result"]["structuredContent"]["result"]["visible_bodies"], ["body-1"])
            reopened = self.run_calls(executable, [
                ("open", {"path": saved}), ("rebuild", {}),
                ("execute", {"command": "document.state", "params": {}}),
                ("execute", {"command": "view.show_all", "params": {}}),
                ("measure", {"from": "body-1"}),
            ])
            for response in reopened:
                self.assertFalse(response["result"]["isError"], response)
            visibility = reopened[2]["result"]["structuredContent"]["result"]["visibility"]
            self.assertEqual(visibility["hidden_bodies"], ["body-1"])
            self.assertEqual(visibility["visible_bodies"], [])
            self.assertIsNone(visibility.get("isolated_bodies"))
            self.assertEqual(reopened[3]["result"]["structuredContent"]["result"]["visible_bodies"], ["body-1"])
            self.assertAlmostEqual(reopened[4]["result"]["structuredContent"]["from_entity"]["volume_mm3"], 72 * math.pi, places=6)

    def test_selected_contour_surface_limit_and_selection_filters(self):
        import math
        executable = os.environ.get("FORGE_CLI", ".build/debug/forge-cli")
        with tempfile.TemporaryDirectory() as temporary:
            saved = str(Path(temporary) / "selected-region.forgepart")
            responses = self.run_calls(executable, [
                ("new_document", {}),
                ("execute", {"command": "plane.create", "params": {"reference": "front", "offset": 10}}),
                ("execute", {"command": "sketch.create", "params": {"plane": "front"}}),
                ("execute", {"command": "sketch.add_circle", "params": {"center": [0, 0], "radius": 5}}),
                ("execute", {"command": "sketch.add_circle", "params": {"center": [0, 0], "radius": 2}}),
                ("execute", {"command": "sketch.add_circle", "params": {"center": [20, 0], "radius": 3}}),
                ("execute", {"command": "sketch.regions", "params": {"sketch": "sketch-1", "at": [4, 0]}}),
                ("execute", {"command": "sketch.exit", "params": {}}),
                ("execute", {"command": "body.extrude", "params": {"sketch": "sketch-1", "contours": [["circle-1"]],
                    "end_condition": "offset_from_surface", "surface": "plane-1", "offset": 2}}),
                ("measure", {"from": "body-1"}),
                ("execute", {"command": "selection.set_filter", "params": {"filter": "faces"}}),
                ("execute", {"command": "document.state", "params": {}}),
                ("save", {"path": saved}),
            ])
            for response in responses:
                self.assertFalse(response["result"]["isError"], response)
            regions = responses[6]["result"]["structuredContent"]["result"]["regions"]
            self.assertEqual(len(regions), 1)
            self.assertEqual(regions[0]["selector"], ["circle-1"])
            self.assertEqual(regions[0]["holes"], [["circle-3"]])
            self.assertAlmostEqual(responses[9]["result"]["structuredContent"]["from_entity"]["volume_mm3"], 168 * math.pi, places=6)
            self.assertEqual(responses[11]["result"]["structuredContent"]["result"]["selection_filter"], "faces")
            reopened = self.run_calls(executable, [
                ("open", {"path": saved}), ("rebuild", {}), ("measure", {"from": "body-1"}),
                ("execute", {"command": "document.state", "params": {}}),
            ])
            for response in reopened:
                self.assertFalse(response["result"]["isError"], response)
            self.assertAlmostEqual(reopened[2]["result"]["structuredContent"]["from_entity"]["volume_mm3"], 168 * math.pi, places=6)
            self.assertEqual(reopened[3]["result"]["structuredContent"]["result"]["selection_filter"], "all")

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
