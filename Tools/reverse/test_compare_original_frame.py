import unittest
import numpy as np
from compare_original_frame import geometry_metrics,depth_metrics,color_metrics,family_metrics

class FrameComparisonTests(unittest.TestCase):
 def test_family_metrics_only_compare_frontmost_pixels(self):
  # A 1×4 strip. Pixels 0/1: family-only equals the full translated render (both
  # render the family color 20) but not the source frame (source 100).
  # Pixel 2: another family occludes the family, so full 50 ≠ family-only 20: excluded.
  # Pixel 3: nothing renders there: transparent in both native renders: excluded.
  source=np.full((1,4,4),100,np.uint8)
  full=np.full((1,4,4),100,np.uint8);full[:,0:2,:]=20;full[:,2,:]=50;full[:,3,:]=0
  only=np.full((1,4,4),100,np.uint8);only[:,0:2,:]=20;only[:,3,:]=0
  result=family_metrics(source,full,only)
  self.assertEqual(result['comparedPixels'],2)
  self.assertAlmostEqual(result['meanAbsoluteChannelBytes'],80.0)
  self.assertEqual(result['p99ChannelBytes'],80.0)
  self.assertEqual(result['maximumChannelBytes'],80)
  self.assertNotIn('silhouetteDifferingPixels',result)
 def test_family_without_frontmost_pixels_reports_nothing(self):
  source=np.full((1,2,4),100,np.uint8)
  full=np.full((1,2,4),100,np.uint8);full[:,:,:3]=40
  result=family_metrics(source,full,source*0+60)
  self.assertEqual(result['comparedPixels'],0)
  self.assertNotIn('meanAbsoluteChannelBytes',result)
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
