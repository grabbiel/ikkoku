"""Exact installed-assembly registry for behavior adapters verified by source oracles."""
import hashlib, json
from pathlib import Path

REGISTRY = {
 'e494f24b73fed491d056c3c6a00ee73baf257409877ce8e5b44da1b0494ca96d': {
  'adapterID':'bepinex-mute-in-background-v1','type':'BepInEx.MuteInBackground',
  'identity':{'guid':'BepInEx.MuteInBackground','name':'Mute In Background','version':'1.1'},'processes':[]},
 'c60d740ee1037040e97bcb0ae8037f8f7a1e4350322bc7ed44699fd0dc9662bd': {
  'adapterID':'kk-studio-accessory-names-v1','type':'KK_StudioAccessoryNames.KK_StudioAccessoryNames',
  'identity':{'guid':'KK_StudioAccessoryNames','name':'KK_StudioAccessoryNames','version':'1.1.0'},'processes':['CharaStudio']}
}

def identify(source: Path):
 if source.suffix.lower()!='.dll':return None
 digest=hashlib.sha256(source.read_bytes()).hexdigest()
 value=REGISTRY.get(digest)
 return (digest,value) if value else None

def publish(source: Path, stage: Path, entry, config: Path | None):
 digest, row = entry
 data=source.read_bytes()
 if hashlib.sha256(data).hexdigest()!=digest:raise ValueError('Original assembly changed during adapter packaging')
 (stage/'Original.dll').write_bytes(data)
 manifest={'schemaVersion':1,'kind':'ikkoku-native-plugin-adapter',**row,'source':{'file':'Original.dll','sha256':digest}}
 if config is not None:
  if row['adapterID']!='bepinex-mute-in-background-v1':raise ValueError('This installed adapter has no original configuration file')
  if not config.is_file() or config.stat().st_size>1024*1024:raise ValueError('Configuration exceeds its limit')
  data=config.read_bytes();(stage/'Original.cfg').write_bytes(data)
  manifest['configuration']={'file':'Original.cfg','sha256':hashlib.sha256(data).hexdigest()}
 (stage/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
 return {'status':'ready','execution':'verified-native-adapter','identity':row['identity'],'adapterID':row['adapterID'],'sourceSHA256':digest}
