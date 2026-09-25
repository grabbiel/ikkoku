import unittest
import zlib
from studio_animation import low_detail_paths


class LowDetailBindingTests(unittest.TestCase):
    def test_exact_avatar_identity_prevents_heuristic_retargeting(self):
        names=['root/joint','root/low','root/present-in-rig']
        keys=[zlib.crc32(x.encode()) for x in names]
        high={'m_Name':'cf_body_00Avatar','m_TOS':[(keys[0],names[0])]}
        low={'m_Name':'cf_body_lowAvatar','m_TOS':list(zip(keys,names))}
        self.assertEqual(low_detail_paths([high,low],{keys[2]:{}}),{keys[1]:names[1]})
        low['m_TOS'][0]=(keys[0],'renamed')
        with self.assertRaises(ValueError):low_detail_paths([high,low],{})


if __name__=='__main__':unittest.main()
