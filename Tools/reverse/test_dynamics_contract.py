import copy
import math
import unittest

from dynamics_contract import distribution, validate_topology, vector


def key(time, value):
    return dict(time=time, value=value, inSlope=0, outSlope=0)


class DynamicsContractTests(unittest.TestCase):
    def test_distribution_clamps_and_uses_zero_tangent_hermite(self):
        curve = {'m_Curve': [key(.25, 1), key(1.25, 0)]}
        self.assertEqual(distribution({}, .5), 1)
        self.assertEqual(distribution(curve, 0), 1)
        self.assertEqual(distribution(curve, 2), 0)
        self.assertEqual(distribution(curve, .75), .5)
        self.assertEqual(distribution(curve, .5), .84375)
        self.assertEqual(distribution({'m_Curve': [key(.3, .6)]}, 1), .6)

    def test_distribution_rejects_unsupported_or_malformed_curves(self):
        curve = {'m_Curve': [key(0, 1), key(1, 0)]}
        for field, value in [('inSlope', math.nan), ('outSlope', math.inf), ('time', math.nan), ('value', math.inf)]:
            changed = copy.deepcopy(curve)
            changed['m_Curve'][0][field] = value
            with self.assertRaises(ValueError):
                distribution(changed, .5)
        for times in [(1, 1), (2, 1)]:
            with self.assertRaises(ValueError):
                distribution({'m_Curve': [key(times[0], 1), key(times[1], 0)]}, .5)

    def test_nonzero_tangents_match_linear_and_cubic_polynomials(self):
        # y=t and y=t^3 have independent exact polynomial expectations.
        linear = {'m_Curve': [dict(time=0,value=0,inSlope=1,outSlope=1),dict(time=1,value=1,inSlope=1,outSlope=1)]}
        cubic = {'m_Curve': [dict(time=0,value=0,inSlope=0,outSlope=0),dict(time=1,value=1,inSlope=3,outSlope=3)]}
        for i in range(17):
            t=i/16
            self.assertAlmostEqual(distribution(linear,t),t,places=7)
            self.assertAlmostEqual(distribution(cubic,t),t**3,places=7)
        with self.assertRaises(ValueError):distribution(linear,math.nan)

    def test_exporter_rejects_topology_it_cannot_simulate(self):
        tree = dict(m_EndLength=0, m_EndOffset=dict(x=0, y=0, z=0), m_Exclusions=[], m_notRolls=[], m_DistantDisable=False)
        validate_topology(tree)
        for field, value in [('m_EndLength', .1), ('m_EndOffset', dict(x=0, y=0, z=1)),
                             ('m_Exclusions', [1]), ('m_notRolls', [1]), ('m_DistantDisable', True)]:
            changed = copy.deepcopy(tree)
            changed[field] = value
            with self.assertRaises(ValueError):
                validate_topology(changed)

    def test_vector_conversion_reflects_only_z(self):
        self.assertEqual(vector(dict(x=1, y=2, z=3)), [1, 2, -3])


if __name__ == '__main__':
    unittest.main()
