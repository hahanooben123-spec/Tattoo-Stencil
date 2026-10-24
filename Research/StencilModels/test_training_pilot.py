"""Checks for pair integrity, leakage and loss/measurement failure modes."""
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from make_smoke_pairs import create
from train_pilot import balanced_loss, crop_pair, metrics, regressions
from training_data import tensors, validate


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manifest = create(self.root / "pairs")

    def tearDown(self):
        self.temporary.cleanup()

    def edit(self, edit):
        content = json.loads(self.manifest.read_text())
        edit(content)
        self.manifest.write_text(json.dumps(content))

    def test_smoke_requires_explicit_opt_in(self):
        self.assertFalse(validate(self.manifest)[1]["ready"])
        pairs, report = validate(self.manifest, True)
        self.assertTrue(report["ready"], report)
        source, targets = tensors(pairs[0])
        self.assertEqual(source.shape, (3, 128, 128))
        self.assertEqual(targets.shape, (2, 128, 128))
        self.assertEqual(set(np.unique(targets)), {0., 1.})

    def test_unapproved_artist_data_is_refused(self):
        self.edit(lambda c: c.update(scope="artist-pairs"))
        self.assertFalse(validate(self.manifest)[1]["ready"])

    def test_unknown_guides_are_not_treated_as_blank_labels(self):
        self.edit(lambda c: c["pairs"][0].update(guides=None))
        pairs, report = validate(self.manifest, True)
        self.assertTrue(report["ready"])
        self.assertNotIn("guides", pairs[0]["files"])
        prediction = torch.full((1, 2, 32, 32), 0.2, requires_grad=True)
        loss = balanced_loss(prediction, torch.zeros_like(prediction), torch.tensor([1., 0.]))
        loss.backward()
        self.assertEqual(float(prediction.grad[:, 1].abs().sum()), 0)

    def test_transparent_targets_are_refused(self):
        Image.new("RGBA", (128, 128), (0, 0, 0, 0)).save(self.manifest.parent / "sample-0/guides.png")
        self.assertTrue(any("opaque" in e for e in validate(self.manifest, True)[1]["errors"]))

    def test_unaligned_and_mismatched_targets_are_refused(self):
        self.edit(lambda c: c["pairs"][0].update(aligned=False))
        self.assertFalse(validate(self.manifest, True)[1]["ready"])
        Image.new("L", (96, 96), 255).save(self.manifest.parent / "sample-0/guides.png")
        self.assertTrue(any("dimensions differ" in e for e in validate(self.manifest, True)[1]["errors"]))

    def test_gray_targets_are_refused(self):
        Image.new("L", (128, 128), 127).save(self.manifest.parent / "sample-0/guides.png")
        self.assertTrue(any("without gray" in e for e in validate(self.manifest, True)[1]["errors"]))

    def test_group_leakage_is_refused(self):
        self.edit(lambda c: c["pairs"][2].update(group="procedural-family-0"))
        self.assertTrue(any("family occurs" in e for e in validate(self.manifest, True)[1]["errors"]))

    def test_reencoded_source_leakage_is_refused(self):
        original = Image.open(self.manifest.parent / "sample-0/source.png")
        original.save(self.manifest.parent / "sample-2/source.png", compress_level=0)
        self.assertTrue(any("decoded source" in e for e in validate(self.manifest, True)[1]["errors"]))

    def test_unsafe_name_is_refused(self):
        self.edit(lambda c: c["pairs"][0].update(name="../other"))
        self.assertFalse(validate(self.manifest, True)[1]["ready"])

    def test_loss_is_finite_and_empty_prediction_does_not_win(self):
        target = torch.zeros(1, 2, 32, 32)
        target[:, 0, 8:24, 16] = 1
        blank = torch.full_like(target, 0.001, requires_grad=True)
        good = (target * 0.998 + 0.001).requires_grad_()
        bad_loss, good_loss = balanced_loss(blank, target), balanced_loss(good, target)
        self.assertLess(float(good_loss.detach()), float(bad_loss.detach()))
        good_loss.backward()
        self.assertTrue(torch.isfinite(good.grad).all())

    def test_metrics_expose_missing_eye_and_empty_guide_layer(self):
        target = np.zeros((32, 32), np.float32)
        target[8:24, 16] = 1
        self.assertEqual(metrics(np.zeros_like(target), target)["recall"], 0)
        self.assertEqual(metrics(target, target)["f1"], 1)
        extra = np.zeros_like(target)
        extra[:, 8] = 1
        self.assertEqual(metrics(extra, np.zeros_like(target))["precision"], 0)
        self.assertIsNone(metrics(extra, np.zeros_like(target))["f1"])

    def test_lost_eye_is_flagged_even_when_full_image_improves(self):
        good = {"targetInkPixels": 10, "predictedInkPixels": 10, "precision": 1., "recall": 1., "f1": 1.}
        absent = {"targetInkPixels": 10, "predictedInkPixels": 0, "precision": 0., "recall": 0., "f1": 0.}
        before = [{"name": "portrait", "layers": {"structure": {"supervised": True,
                  "fullImage": absent, "regions": {"eye": good}}}}]
        after = [{"name": "portrait", "layers": {"structure": {"supervised": True,
                 "fullImage": good, "regions": {"eye": absent}}}}]
        self.assertTrue(any("eye" in problem for problem in regressions(before, after)))

    def test_crop_has_white_source_and_blank_target_padding(self):
        import random
        source, targets = np.zeros((3, 30, 40), np.float32), np.ones((2, 30, 40), np.float32)
        s, t = crop_pair(source, targets, 64, random.Random(1), [])
        self.assertEqual(s.shape, (3, 64, 64))
        self.assertEqual(t.shape, (2, 64, 64))
        self.assertTrue((s[:, 30:] == 1).all())
        self.assertTrue((t[:, 30:] == 0).all())


if __name__ == "__main__":
    unittest.main()
