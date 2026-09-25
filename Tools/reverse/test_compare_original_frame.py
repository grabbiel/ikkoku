import unittest
import numpy as np
from compare_original_frame import geometry_metrics,depth_metrics,color_metrics

class FrameComparisonTests(unittest.TestCase):
 def test_geometry_displacement_cannot_pass_as_color_or_pose_parity(self):
  a=np.zeros((100,100),bool);a[20:80,20:80]=True;b=np.roll(a,1,axis=1)
  self.assertFalse(geometry_metrics(a,b)['passes'])
  self.assertTrue(geometry_metrics(a,a)['passes'])
 def test_empty_and_unmatched_frames_are_rejected(self):
  with self.assertRaises(ValueError):geometry_metrics(np.zeros((1,1),bool),np.zeros((1,1),bool))
  with self.assertRaises(ValueError):geometry_metrics(np.ones((1,1),bool),np.ones((2,2),bool))
 def test_depth_threshold_is_explicitly_quantization_scaled(self):
  a=np.zeros((10,10,4),np.uint8);b=a.copy();b[:,:,3]=1;mask=np.ones((10,10),bool)
  result=depth_metrics(a,b,mask,100)
  self.assertTrue(result['passes']);self.assertAlmostEqual(result['meanMetres'],100/65025)
  b[:,:,3]=5;self.assertFalse(depth_metrics(a,b,mask,100)['passes'])
 def test_color_gate_does_not_accept_global_recoloring(self):
  a=np.full((10,10,4),100,np.uint8);b=a.copy();b[:,:,:3]+=30
  self.assertFalse(color_metrics(a,b,np.ones((10,10),bool))['passes'])

if __name__=='__main__':unittest.main()
