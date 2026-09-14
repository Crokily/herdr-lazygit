#!/usr/bin/env python3
"""Regressions for the real-client smoke test's terminal screen adapter."""
from pathlib import Path
import runpy
import unittest

import pyte

ClientScreen = runpy.run_path(str(Path(__file__).with_name('herdr-smoke-test.py')))['ClientScreen']


class ClientScreenTest(unittest.TestCase):
    def test_wide_character_partial_repaint(self):
        screen = ClientScreen(8, 1)
        stream = pyte.Stream(screen)
        stream.feed('中\x1b[1Ga')
        # The second cell is still a wide-character continuation in pyte.
        self.assertEqual(screen.buffer[0][1].data, '')
        self.assertEqual(screen.display, ['a       '])
        stream.feed('b')
        self.assertEqual(screen.display, ['ab      '])

    def test_intact_wide_and_combining_characters(self):
        screen = ClientScreen(10, 1)
        pyte.Stream(screen).feed('中文e\u0301!')
        self.assertEqual(screen.display, ['中文é!    '])

    def test_cleared_diff_is_absent_from_current_screen(self):
        screen = ClientScreen(32, 2)
        stream = pyte.Stream(screen)
        stream.feed('+HLG_VISIBLE_DIFF_LINE')
        self.assertIn('+HLG_VISIBLE_DIFF_LINE', '\n'.join(screen.display))
        stream.feed('\x1b[2J\x1b[Hsource tab')
        self.assertNotIn('HLG_VISIBLE_DIFF_LINE', '\n'.join(screen.display))
        self.assertTrue(screen.display[0].startswith('source tab'))


if __name__ == '__main__':
    unittest.main()
