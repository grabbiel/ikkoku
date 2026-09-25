import unittest
import numpy as np
from analysis.trigonometric_ik_contract import MatrixSolver, fixtures, look, rotation, interpolate_rotation, matrix_quaternion


class TrigonometricIKContractTests(unittest.TestCase):
    def test_reachable_target_and_rigid_link_lengths(self):
        p=np.array([[0.,0,0],[0,1,0],[0,2,0]]);r=np.array([np.eye(3)]*3)
        solved,_=MatrixSolver(p,r,[1,0,0]).solve(p,r,np.array([0,1,1.]),np.eye(3),1,0)
        np.testing.assert_allclose(solved[2],[0,1,1],atol=1e-12)
        np.testing.assert_allclose(np.linalg.norm(np.diff(solved,axis=0),axis=1),[1,1],atol=1e-12)

    def test_weight_zero_preserves_positions(self):
        p=np.array([[0.,0,0],[0,1,0],[0,2,0]]);r=np.array([np.eye(3)]*3)
        solved,_=MatrixSolver(p,r,[1,0,0]).solve(p,r,np.array([0,1,1.]),rotation([1,0,0],.5),0,1)
        np.testing.assert_array_equal(solved,p)

    def test_matrix_slerp_halfway(self):
        result=interpolate_rotation(np.eye(3),rotation([0,1,0],1),.5)
        np.testing.assert_allclose(result,rotation([0,1,0],.5),atol=1e-12)

    def test_degenerate_look_is_explicitly_rejected(self):
        with self.assertRaises(ValueError):look(np.array([0.,1,0]),np.array([0.,2,0]))

    def test_eigen_quaternion_conversion_matches_known_axis(self):
        q=matrix_quaternion(rotation([0,1,0],.8))
        np.testing.assert_allclose(q,[0,np.sin(.4),0,np.cos(.4)],atol=1e-12)

    def test_fixtures_include_partial_weights_animated_pose_and_reach_limits(self):
        cases=fixtures();self.assertEqual(len(cases),60)
        names={c["name"] for c in cases}
        self.assertIn("target-at-root",names);self.assertIn("updated-plane",names)
        self.assertIn("animated-0.5-0.4",names);self.assertIn("unreachable-1-1",names)


if __name__=="__main__":unittest.main()
