from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from check_cli_update import ANNOTATION, release_patch


class UpdateTests(unittest.TestCase):
    def test_same_release_does_not_restart(self):
        self.assertIsNone(release_patch('2.1.266', '2.1.266'))

    def test_new_release_changes_only_pilot_template_annotation(self):
        self.assertEqual(release_patch('2.1.265', '2.1.266'),
                         {'spec': {'template': {'metadata': {'annotations': {ANNOTATION: '2.1.266'}}}}})

    def test_invalid_registry_value_is_rejected(self):
        with self.assertRaises(ValueError): release_patch('2.1.266', 'invalid/value')


if __name__ == '__main__': unittest.main()
