#!/usr/bin/env python3
"""Convert Studio voice metadata and explicitly selected AudioClip bundles.

No audio is played. Default operation exports catalog metadata only.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import wave
import xml.etree.ElementTree as ET

REPO=Path(__file__).resolve().parents[2]


def catalog_rows(tables):
    rows=[]
    for table in sorted(tables,key=lambda t:t.get('m_Name','')):
        if not re.fullmatch(r'Voice_\d+_\d+_\d+',table.get('m_Name','')):continue
        for entry in table['list'][2:]:
            row=entry['list']
            if not row or not re.fullmatch(r'-?\d+',row[0]):continue
            if len(row)<6:raise ValueError('Truncated voice catalog row')
            rows.append(dict(group=int(row[1]),category=int(row[2]),no=int(row[0]),bundle=row[4],asset=row[5]))
    if len(rows)!=len({(r['group'],r['category'],r['no']) for r in rows}):raise ValueError('Ambiguous source voice identities')
    return rows


def voice_volumes(personality_tables, xml_data=None):
    personalities={}
    for table in personality_tables:
        for row in table.get('param',[]):
            if 'No' in row and 'FileName' in row:personalities[int(row['No'])]=row['FileName']
    volume_node=ET.fromstring(xml_data).find('Volume') if xml_data else None
    def value(name):
        node=volume_node.find(name) if volume_node is not None else None
        if node is None or not node.text:return 1.0
        match=re.fullmatch(r'Volume\[([0-9]+)\] : Switch\[(true|false)\]',node.text.strip(),re.I)
        if not match:return 1.0
        return min(int(match[1])*0.01,1.0) if match[2].lower()=='true' else 0.0
    return value('PCM'),[dict(no=no,file=file,volume=value(file)) for no,file in sorted(personalities.items())]


def convert(info_bundle, output, bundle=None, source_bundle=None, personality_bundles=(), volume_xml=None):
    import UnityPy
    output=output.resolve()
    if not output.is_relative_to(REPO/'.local'):raise ValueError('Original audio and metadata must remain in .local')
    output.mkdir(parents=True,exist_ok=True)
    tables=[o.read_typetree() for o in UnityPy.load(str(info_bundle)).objects if o.type.name=='MonoBehaviour']
    rows=catalog_rows(tables);converted={}
    if bundle is not None:
        if not source_bundle:raise ValueError('Explicit original bundle identity is required')
        if not bundle.is_file() or bundle.stat().st_size>256*1024*1024:raise ValueError('Unbounded AudioClip source bundle')
        wanted={r['asset'] for r in rows if r['bundle']==source_bundle}
        if not wanted:raise ValueError('Bundle does not match an original catalog identity')
        objects={}
        for obj in UnityPy.load(str(bundle)).objects:
            if obj.type.name=='AudioClip' and obj.peek_name() in wanted:
                name=obj.peek_name()
                if name in objects:raise ValueError('Ambiguous source AudioClip name')
                objects[name]=obj
        for name,obj in objects.items():
            samples=obj.read().samples
            if len(samples)!=1:raise ValueError('Expected one decoded waveform per source AudioClip')
            data=next(iter(samples.values()))
            if len(data)>128*1024*1024 or data[:4]!=b'RIFF':raise ValueError('Expected bounded WAV conversion')
            with wave.open(io.BytesIO(data)) as audio:
                frames,rate,channels=audio.getnframes(),audio.getframerate(),audio.getnchannels()
                if not 0<frames<=48_000*60*20 or channels not in (1,2) or not 8_000<=rate<=192_000:raise ValueError('Unsupported voice waveform bounds')
            digest=hashlib.sha256(data).hexdigest();filename=digest+'.wav';(output/filename).write_bytes(data)
            converted[name]=dict(file=filename,sha256=digest,frames=frames,sampleRate=rate,channels=channels)
        for row in rows:
            if row['bundle']==source_bundle and row['asset'] in converted:row.update(converted[row['asset']])
    tables=[]
    for path in personality_bundles:
        tables += [o.read_typetree() for o in UnityPy.load(str(path)).objects if o.type.name=='MonoBehaviour']
    xml=volume_xml.read_bytes() if volume_xml else None
    if xml and (len(xml)>2*1024*1024 or b'<!DOCTYPE' in xml):raise ValueError('Unsupported voice configuration XML')
    voice_volume,personalities=voice_volumes(tables,xml)
    manifest=dict(schemaVersion=1,kind='ikkoku-studio-voice-catalog',sourceSHA256=hashlib.sha256(info_bundle.read_bytes()).hexdigest(),
        voiceVolume=voice_volume,personalities=personalities,entries=rows)
    (output/'catalog.json').write_text(json.dumps(manifest,indent=2)+'\n')
    report=dict(catalogRows=len(rows),convertedRows=sum('file' in r for r in rows),decodedClips=len(converted),playedAudio=False)
    (output/'coverage.json').write_text(json.dumps(report,indent=2)+'\n');return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--info-bundle',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--bundle',type=Path);p.add_argument('--source-bundle')
    p.add_argument('--personality-bundle',type=Path,action='append',default=[]);p.add_argument('--volume-xml',type=Path)
    a=p.parse_args();print(json.dumps(convert(a.info_bundle,a.output,a.bundle,a.source_bundle,a.personality_bundle,a.volume_xml),indent=2))
