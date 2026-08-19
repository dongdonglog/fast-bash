import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("smon_web", ROOT / "web.py")
WEB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEB)


class WebContractTests(unittest.TestCase):
    def test_monitor_pids_are_filtered_at_api_boundary(self):
        payload = {
            "processes": [{"pid": 1}, {"pid": 20}],
            "network_entities": [{"pid": None}, {"pid": 20}],
        }
        WEB.filter_monitoring(payload, {20})
        self.assertEqual(payload["processes"], [{"pid": 1}])
        self.assertEqual(payload["network_entities"], [{"pid": None}])

    def test_ui_contract_for_container_diagnostics(self):
        self.assertNotIn("仅宿主机进程归属", WEB.HTML)
        self.assertIn('id="hotspotSection" hidden', WEB.HTML)
        self.assertIn("network_entities", WEB.HTML)
        self.assertIn('data-filter="host"', WEB.HTML)
        self.assertIn('data-filter="pod"', WEB.HTML)
        self.assertIn('data-filter="container"', WEB.HTML)
        self.assertIn("const containerized=Boolean(item.container||item.container_id||item.pod)", WEB.HTML)
        self.assertIn("if(scopeFilter==='container')return item.containerized", WEB.HTML)
        self.assertIn("entity.runtime||'container'", WEB.HTML)
        self.assertIn('class="copy"', WEB.HTML)
        self.assertIn("cache_age_ms", WEB.HTML)

    def test_copy_commands_support_plain_http(self):
        self.assertIn("window.isSecureContext", WEB.HTML)
        self.assertIn("document.execCommand('copy')", WEB.HTML)
        self.assertIn("浏览器禁止自动复制", WEB.HTML)

    def test_dynamic_fields_use_html_escape(self):
        escaped_templates = (
            "${esc(item.summary)}",
            "${esc(action.command)}",
            "${esc(item.cmd)}",
            "${esc(item.workload_label)}",
        )
        for template in escaped_templates:
            self.assertIn(template, WEB.HTML)


if __name__ == "__main__":
    unittest.main()
