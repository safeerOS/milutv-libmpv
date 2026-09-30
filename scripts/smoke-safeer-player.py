"""Windows playback probe. Requires python-mpv==1.0.8 and a trusted media sample.
This opens a real video window. It does NOT certify HDR or GUI embedding.
"""
import argparse
import json
import os
import struct
import sys
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--dll-dir', required=True, type=Path)
p.add_argument('--source', required=True)
p.add_argument('--av1', action='store_true')
p.add_argument('--png', type=Path)
p.add_argument('--seconds', type=float, default=10)
p.add_argument('--report', type=Path, default=Path('safeer-smoke.json'))
p.add_argument('--runtime-dir', type=Path, help='app-local MSVC runtime (msvcp140/vcruntime140/vcruntime140_1); preloaded only if not already in process')
a = p.parse_args()
if os.name != 'nt' or struct.calcsize('P') != 8:
    raise SystemExit('Run in 64-bit Python on Windows')
folder = a.dll_dir.resolve(strict=True)
if not (folder / 'libmpv-2.dll').is_file():
    raise SystemExit('libmpv-2.dll missing')
handle = os.add_dll_directory(str(folder))
os.environ['PATH'] = str(folder) + os.pathsep + os.environ.get('PATH', '')
import ctypes
from ctypes import wintypes
_k32 = ctypes.WinDLL('kernel32', use_last_error=True)
_k32.GetModuleHandleW.restype = wintypes.HMODULE; _k32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
runtime_info = {}
def _preload_runtime(rt):
    for name in ('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll'):
        if _k32.GetModuleHandleW(name):
            runtime_info[name] = 'already-loaded'; continue
        f = rt / name
        if f.is_file():
            ctypes.WinDLL(str(f)); runtime_info[name] = 'preloaded:' + str(f)
        else:
            runtime_info[name] = 'missing-in-runtime-dir'
if a.runtime_dir:
    _preload_runtime(a.runtime_dir.resolve(strict=True))
import mpv

def _loaded_path(name):
    h = _k32.GetModuleHandleW(name)
    if not h: return None
    buf = ctypes.create_unicode_buffer(1024); _k32.GetModuleFileNameW(wintypes.HMODULE(h), buf, 1024); return buf.value

player = None
report = {'status': 'failed', 'hdr_verified': False, 'hardware_decoding_tested': False, 'runtime_preload': runtime_info}
try:
    opts = dict(config=False, hwdec='no', vo='gpu-next', gpu_api='opengl',
                gpu_context='angle', idle=True, force_window=True)
    if a.av1:
        opts['vd'] = 'lavc:libdav1d'
    player = mpv.MPV(**opts)
    report['version'] = player.mpv_version
    report['msvcp140_loaded_from'] = _loaded_path('msvcp140.dll'); report['vcruntime140_loaded_from'] = _loaded_path('vcruntime140.dll')
    report['decoders'] = player.decoder_list
    if a.av1 and not any(x.get('driver') == 'libdav1d' for x in player.decoder_list):
        raise RuntimeError('libdav1d absent from loaded DLL')
    player.play(a.source)
    player.wait_until_playing(timeout=30)
    player.wait_for_property('video-params', lambda v: isinstance(v, dict) and v.get('w', 0) > 0, timeout=30)
    initial = player.time_pos or 0
    time.sleep(max(1, a.seconds))
    position = player.time_pos
    if position is None or position <= initial:
        raise RuntimeError('Playback did not advance; use a sample longer than the test')
    report.update(video_params=player.video_params, video_codec=player.video_codec,
                  position=position, elapsed_progress=position-initial)
    if a.png:
        target = a.png.resolve()
        if target.exists():
            raise RuntimeError('Choose a new PNG filename; refusing to overwrite')
        target.parent.mkdir(parents=True, exist_ok=True)
        player.screenshot_format = 'png'
        player.command('screenshot-to-file', str(target), 'video')
        data = target.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 33:
            raise RuntimeError('Screenshot is not a valid PNG header')
        report['png_dimensions'] = list(struct.unpack('>II', data[16:24]))
    report['status'] = 'playback-smoke-pass'
except Exception as exc:
    report['error'] = str(exc)
finally:
    if player is not None:
        player.terminate()
    a.report.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
    handle.close()
print(report['status'])
sys.exit(0 if report['status'] == 'playback-smoke-pass' else 1)
