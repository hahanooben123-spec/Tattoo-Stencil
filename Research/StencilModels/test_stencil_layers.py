"""Synthetic geometry checks, not a substitute for tattoo artist review."""
import unittest

import cv2
import numpy as np

from stencil_layers import (checked, curves, dash_segments, process, render,
                            sampled, shadow_mask, structure_mask, trace)


class StencilLayersTests(unittest.TestCase):
    def test_rejects_invalid_images_and_coordinate_mismatch(self):
        for bad in (np.full((16, 16), np.nan), np.ones((16, 16)) * 1.01,
                    np.zeros((16, 16, 3)), np.zeros((2, 2))):
            with self.assertRaises(ValueError):
                checked(bad)
        with self.assertRaises(ValueError):
            process(np.zeros((20, 20)), np.zeros((24, 24)))

    def test_faint_eye_ring_survives_without_face_annotations(self):
        ink = np.zeros((96, 96), np.float32)
        cv2.ellipse(ink, (48, 48), (26, 12), 0, 0, 360, 0.12, 2)
        cv2.circle(ink, (48, 48), 7, 0.17, 2)
        mask = structure_mask(ink)
        count, _, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
        self.assertGreaterEqual(sum(stats[1:, cv2.CC_STAT_AREA] > 25), 2)
        self.assertGreater(mask[44:53, 39:58].sum(), 12)

    def test_supported_faint_section_is_connected(self):
        ink = np.zeros((40, 100), np.float32)
        ink[19:22, 10:90] = 0.25
        ink[19:22, 40:60] = 0.055
        mask = structure_mask(ink)
        count, labels = cv2.connectedComponents(mask, 8)
        left = set(labels[18:24, 15:25].ravel()) - {0}
        right = set(labels[18:24, 75:85].ravel()) - {0}
        self.assertTrue(left & right)

    def test_does_not_bridge_unsupported_gap(self):
        ink = np.zeros((40, 100), np.float32)
        ink[19:22, 10:43] = ink[19:22, 57:90] = 0.3
        mask = structure_mask(ink)
        self.assertEqual(int(mask[:, 46:54].sum()), 0)
        _, labels = cv2.connectedComponents(mask, 8)
        self.assertFalse((set(labels[:, :43].ravel()) - {0}) &
                         (set(labels[:, 57:].ravel()) - {0}))

    def test_parallel_strokes_stay_separate(self):
        ink = np.zeros((64, 100), np.float32)
        ink[20:23, 10:90] = 0.2
        ink[29:32, 10:90] = 0.12
        mask = structure_mask(ink)
        self.assertEqual(int(mask[24:28].sum()), 0)
        _, labels = cv2.connectedComponents(mask, 8)
        self.assertFalse((set(labels[19:24].ravel()) - {0}) &
                         (set(labels[28:33].ravel()) - {0}))

    def test_short_connection_between_junctions_is_retained(self):
        mask = np.zeros((20, 20), np.uint8)
        mask[4:16, 7] = mask[4:16, 9] = 1
        mask[10, 7:10] = 1
        paths = curves(mask, 3, preserve_junctions=True)
        self.assertTrue(any(path['points'][0] == [7.5, 10.5] and
                            path['points'][-1] == [9.5, 10.5] for path in paths))

    def test_loop_trace_closes_and_open_endpoints_stay_fixed(self):
        mask = np.zeros((32, 32), np.uint8)
        cv2.rectangle(mask, (5, 5), (25, 25), 1, 1)
        paths = trace(mask)
        self.assertEqual(len(paths), 1)
        self.assertTrue(paths[0][1])
        path = {"points": [[1, 2], [10, 12], [20, 2]], "closed": False}
        points = sampled(path)
        np.testing.assert_allclose(points[0], [1, 2])
        np.testing.assert_allclose(points[-1], [20, 2])
        # Rounded corner remains within the declared radius of the vertex.
        self.assertLess(np.linalg.norm(points - [10, 12], axis=1).min(), 0.65)

    def test_blank_source_creates_no_guides_or_ink(self):
        structure, guides, _ = process(np.zeros((96, 96)), np.ones((96, 96)))
        self.assertEqual((structure, guides), ([], []))

    def test_guides_do_not_duplicate_structural_edge(self):
        source = np.zeros((96, 96), np.float32) + 0.2
        source[:, 48:] = 0.7
        mask = np.zeros((96, 96), np.uint8)
        mask[:, 47:50] = 1
        result = shadow_mask(source, mask)
        self.assertEqual(int(result[:, 43:54].sum()), 0)

    def test_output_is_binary_and_dashes_have_real_gaps(self):
        path = {"points": [[5, 20], [90, 20]], "closed": False}
        image = np.array(render(100, 40, [], [path]))
        self.assertEqual(set(np.unique(image)), {0, 255})
        row = image[60]
        self.assertLess(row[17], 255)
        self.assertEqual(row[30], 255)
        segments = list(dash_segments(np.array([[0., 0.], [30., 0.]])))
        self.assertEqual(len(segments), 4)


if __name__ == "__main__":
    unittest.main()
