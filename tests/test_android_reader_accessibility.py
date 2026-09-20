from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
READER_SCREEN = (
    ROOT / "app" / "src" / "main" / "java" / "com" / "aaris"
    / "quran" / "ui" / "ReaderScreen.kt"
)


class AndroidReaderAccessibilityContractTests(unittest.TestCase):
    def setUp(self):
        self.reader = READER_SCREEN.read_text(encoding="utf-8")

    def test_text_heavy_reader_exposes_heading_semantics(self):
        self.assertGreaterEqual(self.reader.count(".semantics { heading() }"), 2)

    def test_async_statuses_are_exposed_without_assertive_chatter(self):
        self.assertIn('contentDescription = "Loading Quran"', self.reader)
        self.assertIn('contentDescription = "Searching Quran"', self.reader)
        self.assertIn("liveRegion = LiveRegionMode.Polite", self.reader)
        self.assertNotIn("LiveRegionMode.Assertive", self.reader)
        self.assertIn("error(errorText)", self.reader)

    def test_approximate_search_status_is_not_color_only(self):
        self.assertIn('text = "Approximate spelling match"', self.reader)
        self.assertIn(
            'stateDescription = "Approximate spelling match"',
            self.reader,
        )

    def test_reader_keeps_scalable_rtl_text_and_large_controls(self):
        self.assertIn("TextDirection.ContentOrRtl", self.reader)
        self.assertIn("fontSize = 32.sp", self.reader)
        self.assertIn("fontSize = 26.sp", self.reader)
        self.assertNotIn("fontSize = 32.dp", self.reader)
        self.assertNotIn("fontSize = 26.dp", self.reader)
        self.assertGreaterEqual(self.reader.count(".heightIn(min = 48.dp)"), 6)

    def test_accessibility_work_does_not_restore_unverified_word_tap(self):
        self.assertNotIn("detectTapGestures", self.reader)
        self.assertNotIn("SurfaceTapAnchorResolver", self.reader)
        self.assertNotIn("Verified word details are not installed yet.", self.reader)


if __name__ == "__main__":
    unittest.main()
