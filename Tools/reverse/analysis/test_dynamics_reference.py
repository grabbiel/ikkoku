import copy
import json
import unittest

import numpy as np

from dynamics_reference import REPO, ParticleReference, collider, collide, node, synthetic_document, v


class DynamicsReferenceTests(unittest.TestCase):
    def test_sphere_inside_adds_particle_radius_and_zero_stays(self):
        c = collider(); c.update(center=[0, 0, 0], radius=1)
        matrix = np.eye(4, dtype=np.float32)
        np.testing.assert_array_equal(collide([0, 0, 0], .2, c, matrix), [0, 0, 0])
        np.testing.assert_allclose(collide([.5, 0, 0], .2, c, matrix), [1.2, 0, 0], rtol=0, atol=1e-7)
        c['bound'] = 1
        np.testing.assert_allclose(collide([2, 0, 0], .2, c, matrix), [1.2, 0, 0], rtol=0, atol=1e-7)

    def test_capsule_endpoint_uses_height_minus_one_radius(self):
        c = collider(1, 0, 2); c.update(center=[0, 0, 0], radius=.5)
        np.testing.assert_array_equal(collide([0, 1, 0], 0, c, np.eye(4, dtype=np.float32)), [0, 1.25, 0])

    def test_capsule_interior_and_z_scale(self):
        c = collider(1, 0, 2); c.update(center=[0, 0, 0], radius=.5)
        m = np.diag(v([2, 3, 4, 1]))
        np.testing.assert_array_equal(collide([.25, 0, 0], .5, c, m), [2.5, 0, 0])

    def test_exact_capsule_axis_retains_source_zero_radial_offset(self):
        c = collider(1, 0, 1.6); c.update(center=[0, .1, 0], radius=.35)
        np.testing.assert_array_equal(collide(c['center'], 0, c, np.eye(4, dtype=np.float32)), v(c['center']))

    def test_collider_order_changes_result(self):
        a = collider(); a.update(center=[0, 0, 0], radius=1)
        b = copy.deepcopy(a); b['center'] = [1, 0, 0]
        m = np.eye(4, dtype=np.float32)
        ab = collide(collide([.4, .2, 0], 0, a, m), 0, b, m)
        ba = collide(collide([.4, .2, 0], 0, b, m), 0, a, m)
        self.assertGreater(float(np.linalg.norm(ab - ba)), .1)

    def test_source_force_is_per_step_and_catchup_caps(self):
        nodes = [node('owner'), node('tip', 0, (0, -1, 0))]
        config = dict(ownerID='owner', updateRate=60, gravity=[0,0,0], force=[.1,0,0], freezeAxis=0, colliders=[],
            particles=[dict(nodeID='owner', parent=None), dict(nodeID='tip', parent=0, damping=0, elasticity=0, stiffness=0, inert=0, radius=0)])
        solver = ParticleReference(nodes, config)
        first = solver.advance(nodes, 1/60)
        expected = v([.1,-1,0]); expected /= np.linalg.norm(expected)
        np.testing.assert_allclose(first['positions'][1], expected, rtol=0, atol=1e-7)
        state = solver.advance(nodes, 10)
        self.assertEqual(state['lastStepCount'], 3)
        self.assertEqual(state['remainder'], 0)
        self.assertEqual(solver.advance(nodes, 0)['lastStepCount'], 0)

    def test_fixture_is_deterministic_finite_and_covers_steps(self):
        first = synthetic_document()
        self.assertEqual(first, synthetic_document())
        self.assertEqual(len(first['collisions']), 252)
        self.assertEqual(len(first['scenarios']), 5)
        counts = {f['expected']['lastStepCount'] for s in first['scenarios'] for f in s['frames']}
        self.assertEqual(counts, {0, 1, 2, 3})
        for scenario in first['scenarios']:
            for frame in scenario['frames']:
                self.assertTrue(np.isfinite(frame['expected']['positions']).all())

    def test_checked_in_fixture_matches_generator(self):
        fixture = json.loads((REPO / 'Tools/reverse/fixtures/dynamics-reference.json').read_text())
        self.assertEqual(fixture, synthetic_document())


if __name__ == '__main__':
    unittest.main()
