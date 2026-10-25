import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from make_smoke_pairs import create
from register_pair import checked_similarity, overlaps, register_target
from training_data import validate


class RegistrationTests(unittest.TestCase):
    def test_rejects_anatomy_distortion_and_implausible_rotation(self):
        for matrix in ([[1, 0.2, 0], [0, 1, 0]], [[0, -1, 0], [1, 0, 0]],
                       [[-1, 0, 0], [0, -1, 0]], [[np.nan, 0, 0], [0, 1, 0]]):
            with self.assertRaises(ValueError):
                checked_similarity(matrix)

    def test_identity_preserves_pixel_centers(self):
        target = np.full((32, 32), 255, np.uint8)
        target[4:28, 16] = 0
        actual = register_target(target, [[1, 0, 0], [0, 1, 0]], 32, 32)
        np.testing.assert_array_equal(actual, target)

    def test_thin_downscaled_line_survives_without_filling_white_gap(self):
        target = np.full((64, 64), 255, np.uint8)
        target[5:25, 21] = target[40:59, 21] = 0
        actual = register_target(target, [[0.4, 0, 2], [0, 0.4, 2]], 32, 32)
        self.assertGreater(int((actual == 0).sum()), 8)
        self.assertTrue((actual[14:17] == 255).all())
        self.assertEqual(set(np.unique(actual)), {0, 255})

    def test_crop_overlap_detection(self):
        self.assertTrue(overlaps([0, 0, 100, 100], [90, 90, 200, 200]))
        self.assertFalse(overlaps([0, 0, 100, 100], [100, 0, 200, 100]))

    def test_provisional_pairs_require_opt_in_and_remain_ineligible(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = create(Path(temp) / "pairs")
            data = json.loads(manifest.read_text())
            data["scope"] = "provisional-registered-collages"
            for pair in data["pairs"]:
                pair.update(aligned=False, artistApproved=False, targetProvidedAsExample=True,
                            alignmentEstimate={"method": "reviewed-similarity", "reviewed": True})
            manifest.write_text(json.dumps(data))
            self.assertFalse(validate(manifest)[1]["ready"])
            _, report = validate(manifest, allow_provisional=True)
            self.assertTrue(report["ready"], report)
            self.assertFalse(report["qualityEligible"])
            self.assertTrue(report["provisionalAlignment"])


if __name__ == "__main__":
    unittest.main()
