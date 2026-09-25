import unittest
from maker_assembly_variants import row, replace_face_channels


class MakerAssemblyVariantTests(unittest.TestCase):
    def test_exact_normal_head_identity(self):
        table = dict(categoryNo=100, lstKey=['ID', 'MainData'], dictList={'200': ['200', 'head02']})
        self.assertEqual(row(table, 200)['MainData'], 'head02')
        with self.assertRaises(ValueError): row(table, 0)
        table['dictList']['duplicate'] = ['200', 'head03']
        with self.assertRaises(ValueError): row(table, 200)
        table['categoryNo'] = 501
        with self.assertRaises(ValueError): row(table, 200)

    def test_channels_replace_only_matching_head_domain(self):
        contract = dict(domains=[dict(id='body', channels=['untouched']), dict(id='face', channels=['old'],
            slots=[dict(bindings=[dict(sourceName='jaw')])], provenance=[dict(path='cf_anmShapeHead_00.bytes'), dict(path='controller.cs')])])
        result = replace_face_channels(contract, [dict(name='jaw', samples=[])], dict(path='head02.bytes'))
        self.assertEqual(result['domains'][0], contract['domains'][0])
        self.assertEqual(result['domains'][1]['provenance'], [dict(path='controller.cs'), dict(path='head02.bytes')])
        self.assertEqual(contract['domains'][1]['channels'], ['old'])
        with self.assertRaises(ValueError): replace_face_channels(contract, [dict(name='other')], {})
        with self.assertRaises(ValueError): replace_face_channels(contract, [dict(name='jaw'), dict(name='jaw')], {})


if __name__ == '__main__': unittest.main()
