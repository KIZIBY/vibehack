"""Unit tests for Hermes designer browser tool contract & spike (Spike T003 / R6).

Tests verify that:
1. Viewport dimensions 1440x900 (desktop) and 390x844 (mobile) are supported and validated.
2. Console logs / errors are extracted and formatted cleanly (detecting JS errors, unhandled rejections).
3. Browser artifacts (screenshots) are isolated strictly to runs/<run_id>/browser/.
4. Concurrent browser sessions (2-3 sessions) keep state and log buffers separate.
"""
import unittest
from pathlib import Path
import sys

HERMES_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERMES_DIR / "plugins" / "ai-judge"))

try:
    import browser
except ImportError:
    browser = None


class DesignerBrowserSpikeTest(unittest.TestCase):
    def setUp(self):
        if browser is None:
            self.fail("browser module is not implemented yet (RED phase)")

    def test_supported_viewports(self):
        self.assertTrue(browser.is_supported_viewport(1440, 900))
        self.assertTrue(browser.is_supported_viewport(390, 844))
        self.assertFalse(browser.is_supported_viewport(800, 600))
        self.assertFalse(browser.is_supported_viewport(-1, 900))

    def test_format_console_errors(self):
        raw_logs = [
            {"type": "info", "text": "Application initialized"},
            {"type": "error", "text": "Uncaught TypeError: Cannot read property 'map' of undefined at app.js:42"},
            {"type": "warning", "text": "Devtools warning"},
            {"type": "error", "text": "Failed to load resource: the server responded with a status of 404"},
        ]
        errors = browser.extract_console_errors(raw_logs)
        self.assertEqual(len(errors), 2)
        self.assertIn("TypeError", errors[0])
        self.assertIn("404", errors[1])

    def test_screenshot_path_isolation(self):
        session_id = "run_spike_1:design:project"
        out_path = browser.get_screenshot_destination(session_id, viewport=(1440, 900), name="home")
        self.assertTrue(out_path.startswith("runs/run_spike_1/browser/"))
        self.assertTrue(out_path.endswith("home_1440x900.png"))

    def test_concurrent_sessions_isolation(self):
        s1 = browser.BrowserSessionContext(session_id="run_1:design:project")
        s2 = browser.BrowserSessionContext(session_id="run_2:design:project")

        s1.record_console_error("Error in run 1")
        s2.record_console_error("Error in run 2")

        self.assertEqual(s1.get_errors(), ["Error in run 1"])
        self.assertEqual(s2.get_errors(), ["Error in run 2"])


if __name__ == "__main__":
    unittest.main()
