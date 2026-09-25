from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location('source_translation', HERE / 'translate.py')
translation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(translation)


class TranslationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = ROOT / '.local/reverse/api-substitution'
        cls.evidence.mkdir(parents=True, exist_ok=True)
        cls.scratch = tempfile.TemporaryDirectory(prefix='tests-', dir=cls.evidence)
        cls.work = Path(cls.scratch.name)
        cls.frontend = cls.evidence / 'frontend'
        translation.build_frontend(cls.frontend)
        cls.module = cls.work / 'module'
        cls.module.mkdir()
        cls.command(['swiftc', '-swift-version', '6', '-emit-library', '-emit-module', '-module-name', 'Gameplay', str(ROOT / 'Packages/Engine/Sources/Gameplay/SourceTranslatedBehaviour.swift'), '-emit-module-path', str(cls.module / 'Gameplay.swiftmodule'), '-o', str(cls.module / 'libGameplay.dylib')])

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    @staticmethod
    def command(command, **kwargs):
        result = subprocess.run(command, text=True, capture_output=True, **kwargs)
        if result.returncode:
            raise AssertionError(f"Command failed: {command}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def compile_and_run(self, ir, output, main):
        (output / 'main.swift').write_text(main)
        binary = output / 'native-reference'
        self.command(['swiftc', '-swift-version', '6', '-I', str(self.module), '-L', str(self.module), '-lGameplay', str(output / 'Translated.swift'), str(output / 'main.swift'), '-o', str(binary)])
        return self.command([str(binary)], env={**os.environ, 'DYLD_LIBRARY_PATH': str(self.module)})

    def translate(self, text, type_name='Fixture.Component', **kwargs):
        output = Path(tempfile.mkdtemp(dir=self.work))
        source = output / 'Input.cs'
        source.write_text(text)
        result = translation.translate(source, type_name, output, build_dir=self.frontend, **kwargs)
        return result, output

    def test_bepinex_identity_dependencies_lifecycle_and_serialized_clone_fields(self):
        text = '''using UnityEngine; using BepInEx;
namespace Fixture;
[BepInPlugin("Creator.Mixed_é", "Original name", "1.2.3")]
[BepInProcess("CharaStudio")]
[BepInDependency("Hard.ID", "1.2")]
[BepInDependency("Soft.ID", BepInDependency.DependencyFlags.SoftDependency)]
[BepInIncompatibility("Other.ID")]
public class Component : BaseUnityPlugin {
 public float publicField = 1f;
 [SerializeField] private float serializedField = 2f;
 [System.NonSerialized] public float transientField = 3f;
 private float privateField = 4f;
 void Awake() {} void OnEnable() {} void Start() {} void FixedUpdate() {}
 void Update() {} void LateUpdate() {} void OnDisable() {} void OnDestroy() {}
}'''
        ir, _ = self.translate(text, component=True)
        self.assertEqual(ir['status'], 'ready', ir['diagnostics'])
        self.assertEqual(ir['identity']['pluginGUID'], 'Creator.Mixed_é')
        self.assertEqual(ir['plugin'], {'guid':'Creator.Mixed_é', 'name':'Original name', 'version':'1.2.3',
            'processes':['CharaStudio'], 'dependencies':[{'guid':'Hard.ID','minimumVersion':'1.2','required':True},
                {'guid':'Soft.ID','minimumVersion':None,'required':False}], 'incompatibilities':['Other.ID']})
        self.assertEqual({f['name']:f['serialized'] for f in ir['fields']},
            {'publicField':True, 'serializedField':True, 'transientField':False, 'privateField':False})
        self.assertEqual(len([m for m in ir['methods'] if m['lifecycle']]), 8)
        bad, output = self.translate(text, component=True, plugin_guid='creator.mixed_é')
        self.assertEqual(bad['status'], 'rejected')
        self.assertFalse((output/'Translated.swift').exists())

    def test_plugin_packaging_preserves_declared_metadata_and_rejects_unmapped_source(self):
        import sys
        sys.path.insert(0, str(HERE))
        import plugin
        source = self.work/'Package.cs'
        source.write_text('''using UnityEngine; using BepInEx;
[BepInPlugin("Creator.Package", "Package", "1.0")]
public class Package : BaseUnityPlugin { void Update() { transform.Translate(Vector3.one); } }''')
        target = self.work/'packaged'
        result = plugin.package(source, 'Package', target, build_dir=self.frontend)
        self.assertEqual(result['status'], 'ready')
        manifest = json.loads((target/'manifest.json').read_text())
        self.assertEqual(manifest['identity'], {'guid':'Creator.Package','name':'Package','version':'1.0'})
        ref = manifest['components'][0]['program']
        self.assertEqual(ref['sha256'], hashlib.sha256((target/ref['file']).read_bytes()).hexdigest())
        with self.assertRaises(ValueError): plugin.package(source, 'Package', target, build_dir=self.frontend)
        with self.assertRaises(ValueError): plugin.package(source, 'Package', self.work/'wrong-version', version='2.0', build_dir=self.frontend)
        source.write_text('using UnityEngine; public class Package : MonoBehaviour { void Update() { while(true) {} } }')
        rejected = self.work/'rejected'
        result = plugin.package(source, 'Package', rejected, guid='Original.ID', name='Original', version='1.0', build_dir=self.frontend)
        self.assertEqual(result['status'], 'rejected')
        self.assertFalse((rejected/'manifest.json').exists())
        self.assertFalse(list(self.work.glob('.plugin-stage-*')))

    def test_lifecycle_transform_objects_and_opaque_identity(self):
        guid = 'Example.Creator.MixedCase_é.01'
        ir, output = self.translate('''using UnityEngine;
namespace Fixture;
public class Component : MonoBehaviour {
    public float speed = 2f;
    public float ticks;
    public float starts;
    public float constructedFixed = Time.fixedDeltaTime;
    public float awakeFixed;
    public float startFixed;
    public float firstUpdateFixed;
    private bool updated;
    public Vector3 axis = new Vector3(1f, 0f, 0f);
    public string identity = "Example.Creator.MixedCase_é.01";
    void Awake() { transform.localPosition = Vector3.zero; awakeFixed = Time.fixedDeltaTime; }
    void Start() { starts += 1f; transform.localScale = Vector3.one; startFixed = Time.fixedDeltaTime; }
    void Update() {
        if (!updated) { firstUpdateFixed = Time.fixedDeltaTime; updated = true; }
        transform.Translate(axis * (speed * Time.deltaTime), Space.World);
        ticks += Time.deltaTime;
        GameObject copy = GameObject.Instantiate(gameObject);
        copy.SetActive(false);
        GameObject.Destroy(copy);
    }
    void FixedUpdate() { transform.Translate(new Vector3(0f, Time.deltaTime + Time.fixedDeltaTime, 0f)); }
    public float Clock(float context) { return Time.deltaTime + context; }
}''', component=True, plugin_guid=guid)
        self.assertEqual(ir['status'], 'ready', ir['diagnostics'])
        self.assertEqual(ir['identity']['pluginGUID'], guid)
        self.assertEqual({m['lifecycle'] for m in ir['methods'] if m['lifecycle']}, {'Awake', 'Start', 'Update', 'FixedUpdate'})
        result = json.loads(self.compile_and_run(ir, output, '''import Foundation
import Gameplay
final class Transform: SourceAPITransform {
    var position = SIMD3<Float>(9, 9, 9)
    var localPosition: SIMD3<Float> { get { position } set { position = newValue } }
    var localScale = SIMD3<Float>(repeating: 7)
    func translate(_ delta: SIMD3<Float>, relativeTo: SourceAPISpace) {
        // Fixture object is rotated +90 degrees about Z; scale must not affect Translate.
        position += relativeTo == .world ? delta : SIMD3<Float>(-delta.y, delta.x, delta.z)
    }
}
final class Object: SourceAPIObject {
    let sourceIdentity: String
    let transform: any SourceAPITransform = Transform()
    var active = true
    init(_ id: String) { sourceIdentity = id }
    func setActive(_ active: Bool) { self.active = active }
}
final class World: SourceAPIWorld {
    var clones: [Object] = []
    var destroyed: [String] = []
    func instantiate(_ original: any SourceAPIObject) -> any SourceAPIObject {
        let clone = Object(original.sourceIdentity + ".copy.\\(clones.count)")
        clones.append(clone)
        return clone
    }
    func destroy(_ object: any SourceAPIObject) { destroyed.append(object.sourceIdentity) }
}
let world = World(), original = Object("Source.Card.GUID/unchanged")
let context = try SourceAPIContext(world: world, fixedDeltaTime: 0.02)
try context.configureClocks(deltaTime: 0.01, fixedDeltaTime: 0.03)
let component = TYPE(context: context, gameObject: original)
let driver = SourceBehaviourDriver(component)
driver.awake(); driver.awake()
try driver.update(deltaTime: 0.25)
try driver.fixedUpdate(fixedDeltaTime: 0.02)
try driver.update(deltaTime: 0.5)
var rejected = false
do { try driver.update(deltaTime: .nan) } catch { rejected = true }
let result: [String: Any] = ["position": [original.transform.position.x, original.transform.position.y, original.transform.position.z], "ticks": component.ticks, "clock": component.Clock(2), "initialFixed": [component.constructedFixed, component.awakeFixed, component.startFixed, component.firstUpdateFixed], "starts": component.starts, "identity": component.identity, "original": original.sourceIdentity, "cloneIDs": world.clones.map(\\.sourceIdentity), "active": world.clones.map(\\.active), "destroyed": world.destroyed, "badClockRejected": rejected, "source": TYPE.sourceIdentityJSON]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
'''.replace('TYPE', ir['swiftName'])))
        self.assertAlmostEqual(result['position'][0], 1.46, places=6)
        self.assertEqual(result['position'][1:], [0, 0])
        self.assertEqual(result['ticks'], .75)
        self.assertEqual(result['clock'], 2.5)
        for value in result['initialFixed']:
            self.assertAlmostEqual(value, 0.03, places=7)
        self.assertEqual(result['starts'], 1)
        self.assertEqual(result['identity'], guid)
        self.assertEqual(result['original'], 'Source.Card.GUID/unchanged')
        self.assertEqual(result['cloneIDs'], ['Source.Card.GUID/unchanged.copy.0', 'Source.Card.GUID/unchanged.copy.1'])
        self.assertEqual(result['destroyed'], result['cloneIDs'])
        self.assertEqual(result['active'], [False, False])
        self.assertTrue(result['badClockRejected'])
        self.assertEqual(json.loads(result['source'])['pluginGUID'], guid)
        (self.evidence / 'lifecycle-report.json').write_text(json.dumps({'sourceSHA256': ir['source']['sha256'], 'swiftSHA256': ir['swiftSHA256'], 'substitutions': len(ir['substitutions']), 'result': result}, indent=2) + '\n')

    def test_unsupported_statements_reject_whole_component_with_location(self):
        for body in ['for (int i = 0; i < 4; i++) {}', 'try {} catch {}', 'yield return null;']:
            with self.subTest(body=body):
                ir, output = self.translate('using UnityEngine; namespace Fixture; public class Component : MonoBehaviour { void Update() { ' + body + ' } }', component=True)
                self.assertEqual(ir['status'], 'rejected')
                self.assertFalse((output / 'Translated.swift').exists())
                self.assertGreater(ir['diagnostics'][0]['line'], 0)
                self.assertTrue(any(d['code'] == 'UNSUPPORTED' for d in ir['diagnostics']))

    def test_unmapped_lifecycle_and_spoofed_api_rejected(self):
        for source in [
            'using UnityEngine; namespace Fixture; public class Component : MonoBehaviour { void OnCollisionEnter() {} }',
            'using UnityEngine; namespace Fixture; public class Component : MonoBehaviour { void sourceAwake() {} }',
            'using UnityEngine; namespace Fixture { public class Component : MonoBehaviour { void Update() { Fake.Translate(new Vector3()); } } public static class Fake { public static void Translate(Vector3 value) {} } }',
            'namespace UnityEngine { public class MonoBehaviour {} } namespace Fixture { public class Component : UnityEngine.MonoBehaviour {} }',
        ]:
            ir, output = self.translate(source, component=True)
            self.assertEqual(ir['status'], 'rejected')
            self.assertFalse((output / 'Translated.swift').exists())

    def test_properties_coroutines_and_integer_arithmetic_not_silently_omitted(self):
        for member in ['public float value { get; set; }', 'System.Collections.IEnumerator Start() { yield return null; }', 'int value; void Update() { value += 1; }']:
            ir, _ = self.translate('using UnityEngine; namespace Fixture; public class Component : MonoBehaviour {' + member + '}', component=True)
            self.assertEqual(ir['status'], 'rejected')

    def test_numeric_conversion_mutable_parameters_and_nested_scopes(self):
        ir, output = self.translate('''namespace Fixture;
public static class Utility {
    public static float Compute(float value, bool enabled) {
        value += 2;
        float extra = value * 3;
        if (enabled) { float extra2 = extra + 1f; value = extra2; }
        return value;
    }
}''', type_name='Fixture.Utility', methods=['Compute'])
        self.assertEqual(ir['status'], 'ready', ir['diagnostics'])
        result = self.compile_and_run(ir, output, f'import Foundation\nprint({ir["swiftName"]}.Compute(2, true))\nprint({ir["swiftName"]}.Compute(2, false))\n')
        self.assertEqual([float(v) for v in result.splitlines()], [13, 4])

    def test_rejection_removes_previous_emission_and_identity_affects_symbol(self):
        ir, output = self.translate('namespace Fixture; public static class Utility { public static float Value() { return 2f; } }', type_name='Fixture.Utility', methods=['Value'], plugin_guid='Author.A')
        other = translation.translate(output / 'Input.cs', 'Fixture.Utility', output, methods=['Value'], plugin_guid='Author.B', build_dir=self.frontend)
        self.assertNotEqual(ir['swiftName'], other['swiftName'])
        (output / 'Input.cs').write_text('namespace Fixture; public static class Utility { public static float Value() { throw new System.Exception(); } }')
        rejected = translation.translate(output / 'Input.cs', 'Fixture.Utility', output, methods=['Value'], build_dir=self.frontend)
        self.assertEqual(rejected['status'], 'rejected')
        self.assertFalse((output / 'Translated.swift').exists())

    def test_clock_configuration_requires_valid_explicit_timestep_and_is_atomic(self):
        ir, output = self.translate('namespace Fixture; public static class Utility { public static float Value() { return 1f; } }', type_name='Fixture.Utility', methods=['Value'])
        result = json.loads(self.compile_and_run(ir, output, """import Foundation
import Gameplay
final class World: SourceAPIWorld {
    func instantiate(_ original: any SourceAPIObject) -> any SourceAPIObject { original }
    func destroy(_ object: any SourceAPIObject) {}
}
let world = World()
var rejected = 0
for duration: Float in [0, -1, .nan, .infinity] {
    do { _ = try SourceAPIContext(world: world, fixedDeltaTime: duration) } catch { rejected += 1 }
}
let context = try SourceAPIContext(world: world, deltaTime: 0.25, fixedDeltaTime: 0.02)
for clocks: (Float, Float) in [(-1, 0.1), (.nan, 0.1), (0.5, 0), (0.5, .infinity)] {
    do { try context.configureClocks(deltaTime: clocks.0, fixedDeltaTime: clocks.1) } catch { rejected += 1 }
}
let result: [String: Any] = ["rejected": rejected, "delta": context.deltaTime, "fixed": context.fixedDeltaTime]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
"""))
        self.assertEqual(result['rejected'], 8)
        self.assertEqual(result['delta'], 0.25)
        self.assertAlmostEqual(result['fixed'], 0.02, places=7)

    def test_recovered_methods_match_original_unmodified_dll(self):
        source = Path(os.environ.get('IKKOKU_TRANSLATION_MATHF_SOURCE', ROOT / '.local/reverse/decompiled/Expressions/MathfEx.cs'))
        managed = Path(os.environ.get('IKKOKU_TRANSLATION_MANAGED', ROOT / '.local/reverse/source/Koikatu_Data/Managed'))
        if not source.is_file() or not (managed / 'Assembly-CSharp.dll').is_file() or not (managed / 'UnityEngine.dll').is_file():
            self.skipTest('Private original source and managed DLLs are not installed')
        output = self.evidence / 'mathfex'
        ir = translation.translate(source, 'MathfEx', output, methods=['LerpAccel', 'LerpBrake'], assembly=managed / 'Assembly-CSharp.dll', build_dir=self.frontend)
        self.assertEqual(ir['status'], 'ready', ir['diagnostics'])
        reference = self.work / 'reference'
        reference.mkdir()
        (reference / 'Reference.csproj').write_text(f'''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup><ItemGroup><Reference Include="Assembly-CSharp"><HintPath>{managed / 'Assembly-CSharp.dll'}</HintPath></Reference><Reference Include="UnityEngine"><HintPath>{managed / 'UnityEngine.dll'}</HintPath></Reference></ItemGroup></Project>''')
        (reference / 'Program.cs').write_text('''using System.Globalization;
for (int i = 0; i < 2001; i++) {
    float t = (i - 500) / 500f;
    float from = (i % 17) - 8.25f, to = (i % 29) + 2.75f;
    Console.WriteLine(MathfEx.LerpAccel(from, to, t).ToString("R", CultureInfo.InvariantCulture) + "," + MathfEx.LerpBrake(from, to, t).ToString("R", CultureInfo.InvariantCulture));
}
''')
        expected = self.command(['dotnet', 'run', '--project', str(reference / 'Reference.csproj'), '-v:q'])
        actual = self.compile_and_run(ir, output, f'''import Foundation
for i in 0..<2001 {{
    let t = Float(i - 500) / 500
    let from = Float(i % 17) - 8.25, to = Float(i % 29) + 2.75
    print("\\({ir['swiftName']}.LerpAccel(from, to, t)),\\({ir['swiftName']}.LerpBrake(from, to, t))")
}}
''')
        pairs = list(zip(expected.splitlines(), actual.splitlines(), strict=True))
        error = 0.0
        nan_count = 0
        for a, b in pairs:
            for left, right in zip(map(float, a.split(',')), map(float, b.split(',')), strict=True):
                if math.isnan(left):
                    self.assertTrue(math.isnan(right))
                    nan_count += 1
                else:
                    error = max(error, abs(left - right))
                    self.assertAlmostEqual(left, right, delta=4e-6)
        report = {'cases': len(pairs), 'methodComparisons': len(pairs) * 2, 'maxAbsoluteDifferenceFromDecimalOutput': error, 'nanComparisons': nan_count, 'identity': ir['identity'], 'unityEngineSHA256': hashlib.sha256((managed / 'UnityEngine.dll').read_bytes()).hexdigest(), 'swiftSHA256': ir['swiftSHA256'], 'oracle': 'Unmodified original Assembly-CSharp.dll + UnityEngine.dll executed by .NET'}
        (self.evidence / 'original-math-parity.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    unittest.main()
