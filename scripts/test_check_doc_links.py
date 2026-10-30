import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("check_doc_links", Path(__file__).with_name("check-doc-links.py"))
check_doc_links = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_doc_links)


class DocLinkTests(unittest.TestCase):
    def repository(self, files):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        subprocess.check_call(["git", "init", "-q", str(root)])
        for name, text in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(text, encoding="utf-8")
        return root

    def test_slug_matches_github_style(self):
        self.assertEqual(check_doc_links.slug(" iPhone and iPad "), "iphone-and-ipad")
        self.assertEqual(check_doc_links.slug("Check `your` download"), "check-your-download")

    def test_good_links_pass(self):
        root = self.repository({
            "README.md": "[a](docs/a.md#first-part) [b](#top) ![i](pic.png) [web](https://example.com/x)\n# Top\n",
            "docs/a.md": "# First part\n",
            "pic.png": "x",
        })
        self.assertEqual(check_doc_links.check(root), [])

    def test_missing_file_and_heading_are_reported(self):
        root = self.repository({
            "README.md": "[gone](docs/gone.md) [bad](docs/a.md#nope)\n",
            "docs/a.md": "# Real\n",
        })
        errors = check_doc_links.check(root)
        self.assertEqual(len(errors), 2)
        self.assertIn("missing target docs/gone.md", errors[0])
        self.assertIn("missing heading docs/a.md#nope", errors[1])

    def test_links_in_code_are_ignored(self):
        root = self.repository({"README.md": "`[x](nope.md)`\n```\n[y](nope.md)\n```\n"})
        self.assertEqual(check_doc_links.check(root), [])


if __name__ == "__main__":
    unittest.main()
