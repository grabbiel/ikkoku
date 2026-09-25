import unittest
from source_shader_translation import translate,emit_stage,read

class ShaderTranslationTests(unittest.TestCase):
 def test_unknown_opcodes_and_dynamic_buffers_fail_closed(self):
  for body in ['ps_4_0\ndcl_temps 1\nsample_c r0.xyzw, v1.xyxx, t0.xyzw, s0, v2.x\n','ps_4_0\ndcl_constantbuffer CB0[2], dynamicIndexed\n','ps_4_0\nloop\n']:
   with self.subTest(body=body),self.assertRaises(ValueError):translate(body,'fragment')
 def test_dxbc_boolean_bit_masks_are_preserved_through_movc(self):
  result=translate('ps_4_0\ndcl_input_ps linear v1.xy\ndcl_output o0.xyzw\ndcl_temps 1\nlt r0.x, v1.x, l(0.500000)\nmovc o0.xyzw, r0.xxxx, l(1,0,0,1), l(0,1,0,1)\nret\n','fragment')
  text=emit_stage(result)
  self.assertIn('uint4(0xffffffffu)',text);self.assertIn('as_type<uint4>(r0.xxxx) != uint4(0)',text)
  self.assertNotIn('r0.xxxx != float4(0)',text)
 def test_destination_masks_keep_dxbc_source_lane_positions(self):
  result=translate('ps_4_0\ndcl_output o0.xyzw\ndcl_temps 1\nmov r0.xz, l(1,2,3,4)\nmov o0.xyzw, r0.xyzw\n','fragment')
  self.assertIn('r0.xz = (float4(1.0f,2.0f,3.0f,4.0f)).xz;',result['body'])
 def test_sampling_converts_source_uv_orientation_once_and_keeps_swizzle(self):
  result=translate('ps_4_0\ndcl_input_ps linear v1.xy\ndcl_output o0.xyzw\ndcl_sampler s2, mode_default\ndcl_resource_texture2d (float,float,float,float) t3\nsample o0.xyzw, v1.xyxx, t3.wxyz, s2\n','fragment')
  self.assertEqual(result['textures'],{3:'float'});self.assertEqual(result['samplers'],{2:'default'})
  self.assertIn('1.0 - (v1.xyxx).y',result['body'][0]);self.assertIn(').wxyz',result['body'][0])
 def test_absolute_and_hex_literals_do_not_become_decimal_float_values(self):
  self.assertEqual(read('|r1.xxxx|'),'abs(r1.xxxx)')
  self.assertIn('as_type<float>(uint(0x3f800000))',read('l(0x3f800000)'))
 def test_sincos_aliases_snapshot_the_input_before_either_destination(self):
  body=translate('ps_4_0\ndcl_temps 2\nsincos r0.x, r1.y, r0.x\nsincos null, r1.z, r0.x\n','fragment')['body']
  self.assertEqual(body[0],'float4 sincosInput0 = float4(r0.x);')
  self.assertIn('sin(sincosInput0)',body[1]);self.assertIn('cos(sincosInput0)',body[2])
  self.assertEqual(len(body),5);self.assertIn('cos(sincosInput3)',body[4])

if __name__=='__main__':unittest.main()
