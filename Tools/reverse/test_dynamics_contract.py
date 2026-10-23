import copy
import math
import unittest

from dynamics_contract import (REJECTION_REASONS, Rejected, append_particles, child_lists, clothes_component,
                               distribution, migrate, validate_topology, vector, world_matrices)


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


def node(name, parent, y=0.0, active=True):
    return dict(name=name, parent=parent, sourceID='CAB-body:' + name, translation=[0, y, 0],
                rotation=[0, 0, 0, 1], scale=[1, 1, 1], active=active)


def body_rig():
    """hips -> sk_top -> cf_j_sk_00_00..05 chain, plus a spinesk chain without group 13 names."""
    nodes = [node('cf_j_hips', None), node('cf_d_sk_top', 0)]
    nodes.append(node('cf_j_sk_00_00', 1, -.1))
    for i in range(1, 6):
        nodes.append(node(f'cf_j_sk_00_{i:02d}', len(nodes) - 1, -.1))
    nodes.append(node('cf_j_spinesk_00', 0, -.2))
    for i in range(1, 4):
        nodes.append(node(f'cf_j_spinesk_{i:02d}', len(nodes) - 1, -.1))
    names = [n['name'] for n in nodes]
    return dict(nodes=nodes, children=child_lists(nodes), worlds=world_matrices(nodes), byName={n: i for i, n in enumerate(names)})


SKIRT_NAMES = frozenset(f'cf_j_sk_{c:02d}_{j:02d}' for c in range(8) for j in range(6))


def garment():
    """A clothes prefab: its root owns the component; its own skeleton copy carries the referenced names."""
    names = ['p_o_bot_skirt', 'cf_j_root', 'cf_j_sk_00_00', 'cf_j_sk_00_03', 'cf_j_sk_00_04', 'cf_j_sk_00_05',
             'cf_j_spinesk_00', 'n_bot_b', 'cf_j_unknown']
    return [dict(name=n, parent=None if i == 0 else 0, sourceID=f'CAB-cloth:{i + 100}', active=True)
            for i, n in enumerate(names)]


def ref(path_id, file_id=0):
    return {'m_FileID': file_id, 'm_PathID': path_id}


def component(**changes):
    data = dict(m_Enabled=1, m_Root=ref(102), m_notRolls=[ref(104), ref(105)], m_Exclusions=[], m_DistantDisable=0,
                m_EndLength=0.0, m_EndOffset=dict(x=0.0, y=0.0, z=0.0), m_Colliders=[ref(0)] * 8,
                m_Damping=.1, m_Elasticity=.1, m_Stiffness=.8, m_Inert=1.0, m_Radius=.02,
                m_DampingDistrib={}, m_ElasticityDistrib={}, m_StiffnessDistrib={}, m_InertDistrib={},
                m_RadiusDistrib={'m_Curve': [key(0, 1), key(1, .5)]})
    data.update(changes)
    return data


class ClothesDynamicsTests(unittest.TestCase):
    def test_migration_marks_schema_1_components_as_hair_and_keeps_their_data(self):
        old = dict(schemaVersion=1, coordinateSpace='native-right-handed-y-up',
                   components=[dict(sourceID='a', ownerID='hair-1/x', particles=[dict(nodeID='hair-1/x', parent=None)])])
        upgraded = migrate(copy.deepcopy(old))
        self.assertEqual(upgraded['schemaVersion'], 2)
        self.assertEqual(upgraded['rejected'], [])
        self.assertEqual([c.pop('group') for c in upgraded['components']], ['hair'])
        self.assertEqual(upgraded['components'], old['components'])
        self.assertIs(migrate(upgraded), upgraded)
        with self.assertRaises(ValueError):
            migrate(dict(schemaVersion=3, components=[]))

    def test_append_particles_follows_source_notroll_truncation_and_order(self):
        body = body_rig(); index = body['byName']
        chain = [index[f'cf_j_sk_00_{i:02d}'] for i in range(6)]
        self.assertEqual(append_particles(chain[0], body['children']), [(chain[i], None if i == 0 else i - 1) for i in range(6)])
        self.assertEqual(append_particles(chain[0], body['children'], frozenset(chain[4:6])),
                         [(chain[0], None), (chain[1], 0), (chain[2], 1), (chain[3], 2)])
        self.assertEqual(len(append_particles(chain[0], body['children'], frozenset([chain[4], chain[5], chain[3]]))), 3)
        # Branches keep transform child order (pre-order, as AppendParticles recurses).
        children = [[1, 3], [2], [], []]
        self.assertEqual(append_particles(0, children), [(0, None), (1, 0), (2, 1), (3, 0)])

    def test_append_particles_rejects_reparenting_notrolls_and_real_virtual_ends(self):
        body = body_rig(); chain = [body['byName'][f'cf_j_sk_00_{i:02d}'] for i in range(6)]
        with self.assertRaises(Rejected) as raised:
            append_particles(chain[0], body['children'], frozenset([chain[4]]))
        self.assertEqual(raised.exception.reason, 'notroll-reparent')
        with self.assertRaises(Rejected) as raised:
            append_particles(chain[0], body['children'], virtual_end=True)
        self.assertEqual(raised.exception.reason, 'virtual-end')
        # A truncated chain never reaches a childless transform, so m_EndLength has no particle.
        self.assertEqual(len(append_particles(chain[0], body['children'], frozenset(chain[4:6]), virtual_end=True)), 4)

    def test_clothes_component_remaps_to_body_bones_and_classifies_groups(self):
        body = body_rig()
        result = clothes_component(component(), 'DynamicBone', 0, garment(), body, SKIRT_NAMES, 'CAB-cloth')
        self.assertEqual(result['group'], 'skirt')
        self.assertEqual(result['rootName'], 'cf_j_sk_00_00')
        self.assertEqual(result['notRolls'], ['cf_j_sk_00_04', 'cf_j_sk_00_05'])
        self.assertEqual([p['nodeID'] for p in result['particles']], [f'body-master/CAB-body:cf_j_sk_00_{i:02d}' for i in range(4)])
        self.assertEqual([p['parent'] for p in result['particles']], [None, 0, 1, 2])
        for particle, rate in zip(result['particles'], [0, 1/3, 2/3, 1]):
            self.assertAlmostEqual(particle['lengthRate'], rate, places=6)
        self.assertAlmostEqual(result['particles'][-1]['radius'], .01)
        self.assertEqual(result['particles'][0]['stiffness'], .800000011920929)
        self.assertTrue(result['colliderSlots'])
        self.assertFalse(clothes_component(component(m_Colliders=None), 'DynamicBone', 0, garment(), body, SKIRT_NAMES, 'CAB-cloth')['colliderSlots'])
        spine = clothes_component(component(m_Root=ref(106), m_notRolls=[]), 'DynamicBone', 0, garment(), body, SKIRT_NAMES, 'CAB-cloth')
        self.assertEqual((spine['group'], len(spine['particles'])), ('clothes', 4))
        # notRoll names without a body bone keep a prefab transform that never matches a body child.
        kept = clothes_component(component(m_notRolls=[ref(108), ref(0)]), 'DynamicBone', 0, garment(), body, SKIRT_NAMES, 'CAB-cloth')
        self.assertEqual(len(kept['particles']), 6)

    def test_clothes_component_rejects_each_unsupported_variant_by_name(self):
        body = body_rig(); inactive = garment(); inactive[0]['active'] = False
        cases = [
            ('unsupported-version', dict(), 'DynamicBone_Ver02', 0, garment()),
            ('unsupported-version', dict(), 'DynamicBone_Ver01', 0, garment()),
            ('invalid-configuration', dict(m_EndLength=math.nan), 'DynamicBone', 0, garment()),
            ('invalid-configuration', dict(m_Radius=math.inf), 'DynamicBone', 0, garment()),
            ('prefab-disabled', dict(m_Enabled=0), 'DynamicBone', 0, garment()),
            ('inactive-object', dict(), 'DynamicBone', 0, inactive),
            ('owner-below-prefab-root', dict(), 'DynamicBone', 7, garment()),
            ('external-reference', dict(m_Root=ref(5, 1)), 'DynamicBone', 0, garment()),
            ('external-reference', dict(m_notRolls=[ref(999)]), 'DynamicBone', 0, garment()),
            ('root-not-in-body', dict(m_Root=ref(108)), 'DynamicBone', 0, garment()),
            ('root-not-in-body', dict(m_Root=ref(0)), 'DynamicBone', 0, garment()),
            ('exclusions', dict(m_Exclusions=[ref(0)]), 'DynamicBone', 0, garment()),
            ('distant-disable', dict(m_DistantDisable=1), 'DynamicBone', 0, garment()),
            ('virtual-end', dict(m_notRolls=[], m_EndLength=.5), 'DynamicBone', 0, garment()),
            ('virtual-end', dict(m_notRolls=[], m_EndOffset=dict(x=0, y=-.1, z=0)), 'DynamicBone', 0, garment()),
            ('notroll-reparent', dict(m_notRolls=[ref(104)]), 'DynamicBone', 0, garment()),
            ('unsupported-curve', dict(m_DampingDistrib={'m_Curve': [dict(key(0, 1), weightedMode=1), key(1, 0)]}), 'DynamicBone', 0, garment()),
        ]
        self.assertEqual({c[0] for c in cases}, set(REJECTION_REASONS))
        for reason, changes, class_name, owner, nodes in cases:
            with self.subTest(reason=reason, changes=changes):
                with self.assertRaises(Rejected) as raised:
                    clothes_component(component(**changes), class_name, owner, nodes, body, SKIRT_NAMES, 'CAB-cloth')
                self.assertEqual(raised.exception.reason, reason)
        with self.assertRaises(ValueError):
            Rejected('approximated', 'unnamed reasons are refused')


if __name__ == '__main__':
    unittest.main()
