"""Bounded probe request format; values are canonical IEEE Float32 rates."""
import math
import re
import struct


def parse(data):
    if not 0 < len(data) <= 16_384:
        raise ValueError('Model shape input must contain 1...16384 bytes')
    rows = {}
    for line in data.decode('ascii').splitlines():
        fields = line.split('\t')
        if len(fields) != 3 or fields[0] not in ('body', 'face') or not re.fullmatch(r'0|[1-9][0-9]*', fields[1]):
            raise ValueError('Model shape rows need body/face, index and rate separated by tabs')
        domain, index = fields[0], int(fields[1])
        if not 0 <= index < (44 if domain == 'body' else 52) or (domain, index) in rows:
            raise ValueError('Duplicate or out-of-range model shape index')
        try:
            value = float(fields[2])
        except ValueError:
            raise ValueError('Model shape rate must be finite and within 0...1')
        if not math.isfinite(value) or not 0 <= value <= 1:
            raise ValueError('Model shape rate must be finite and within 0...1')
        rows[domain, index] = struct.unpack('<f', struct.pack('<f', value))[0]
    if not rows:
        raise ValueError('Model shape input has no rows')
    return [dict(domain=domain, index=index, value=value) for (domain, index), value in sorted(rows.items())]


def canonical(data):
    return ''.join('{domain}\t{index}\t{value:.9g}\n'.format(**row) for row in parse(data)).encode('ascii')
