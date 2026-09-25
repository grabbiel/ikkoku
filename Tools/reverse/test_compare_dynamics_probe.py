import copy
import math
import unittest
from compare_dynamics_probe import compare


class DynamicsProbeTests(unittest.TestCase):
    def fixture(self):
        particle=dict(name='tip',parent=-1,damping=.1,elasticity=.2,stiffness=.3,inert=.4,radius=.01)
        source={k:v for k,v in particle.items() if k not in ['name','parent']};source.update(nodeName='tip',parent=None)
        component=dict(rootName='tip',particles=[source],sourceAsset=dict(category=102,id=2,modGUID=None),colliders=[],updateRate=60)
        actual=dict(rootName='tip',particles=[particle],colliders=0,updateRate=60,curves={})
        return dict(hairIDs=[0,2],components=[actual]),dict(components=[component])

    def test_exact_setup_passes_and_preserves_count(self):
        p,c=self.fixture();r=compare(p,c)
        self.assertEqual(r['parameters'],5)
        self.assertEqual(r['maximumParameterError'],0)

    def test_identity_order_duplicates_and_nonfinite_fail(self):
        p,c=self.fixture()
        variants=[]
        changed=copy.deepcopy(p);changed['components']*=2;variants.append(changed)
        changed=copy.deepcopy(p);changed['components'][0]['particles'][0]['name']='other';variants.append(changed)
        changed=copy.deepcopy(p);changed['components'][0]['particles'][0]['radius']=math.nan;variants.append(changed)
        changed=copy.deepcopy(p);changed['components'][0]['particles'][0]['radius']=.2;variants.append(changed)
        for changed in variants:
            with self.assertRaises(ValueError):compare(changed,c)


if __name__=='__main__':unittest.main()
