"""Fail on missing build capabilities. Does not replace playback tests."""
import argparse
import json
import re
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--build', required=True, type=Path)
a = p.parse_args()
headers = list((a.build / 'subprojects' / 'ffmpeg').rglob('config*.h'))
if not headers:
    raise SystemExit('No generated FFmpeg config headers found')
values = {}
for header in headers:
    values.update(dict(re.findall(r'^\s*#define\s+(CONFIG_\w+)\s+([01])\b', header.read_text(errors='replace'), re.M)))
required = ['LIBDAV1D', 'LIBXML2', 'LIBDAV1D_DECODER', 'H264_DECODER',
            'HEVC_DECODER', 'VP9_DECODER', 'MPEG4_DECODER', 'H263_DECODER', 'DASH_DEMUXER',
            'HLS_DEMUXER', 'MATROSKA_DEMUXER', 'MOV_DEMUXER',
            'PNG_ENCODER', 'MJPEG_ENCODER', 'HTTP_PROTOCOL', 'HTTPS_PROTOCOL',
            'SCHANNEL']
forbidden = ['GPL', 'VERSION3', 'NONFREE', 'VULKAN']
missing = [x for x in required if values.get('CONFIG_' + x) != '1']
unexpected = [x for x in forbidden if values.get('CONFIG_' + x) != '0']
report = {'required_missing': missing, 'forbidden_enabled_or_unknown': unexpected,
          'headers': [str(x.relative_to(a.build)) for x in headers],
          'status': 'failed' if missing or unexpected else 'configuration-pass',
          'playback_tested': False}
(a.build / 'safeer-capabilities.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
raise SystemExit(1 if missing or unexpected else 0)
