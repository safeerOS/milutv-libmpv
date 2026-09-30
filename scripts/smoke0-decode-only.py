"""Decode-level probe (no window): vo=null, hwdec=no. Verifies demux/decode/PNG, NOT rendering."""
import argparse, json, os, struct, sys, time, threading, faulthandler
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--dll-dir', required=True, type=Path); p.add_argument('--source', required=True)
p.add_argument('--av1', action='store_true'); p.add_argument('--png', type=Path)
p.add_argument('--seconds', type=float, default=5); p.add_argument('--report', type=Path, required=True)
a = p.parse_args()
faulthandler.dump_traceback_later(50, exit=True)
folder = a.dll_dir.resolve(strict=True)
os.add_dll_directory(str(folder)); os.environ['PATH'] = str(folder) + os.pathsep + os.environ['PATH']
import mpv
rep = {'status': 'failed', 'mode': 'vo=null (decode only)', 'source': a.source}
logs = []
def lh(l, pre, txt): logs.append(f'[{l}] {pre}: {txt.strip()}')
player = None
try:
    opts = dict(config=False, hwdec='no', vo='null', idle=True, log_handler=lh, msg_level='all=warn,vd=v,demux=v')
    if a.av1: opts['vd'] = 'lavc:libdav1d'
    player = mpv.MPV(**opts)
    rep['version'] = player.mpv_version
    dl = player.decoder_list
    rep['has_libdav1d'] = any(x.get('driver') == 'libdav1d' for x in dl)
    if a.av1 and not rep['has_libdav1d']: raise RuntimeError('libdav1d absent')
    player.play(a.source)
    player.wait_until_playing(timeout=30)
    player.wait_for_property('video-params', lambda v: isinstance(v, dict) and v.get('w', 0) > 0, timeout=30)
    t0 = player.time_pos or 0
    time.sleep(a.seconds)
    t1 = player.time_pos
    if t1 is None or t1 <= t0: raise RuntimeError(f'no progress {t0}->{t1}')
    rep.update(video_params=player.video_params, video_codec=player.video_codec, demuxer=player.current_demuxer,
               position=t1, progress=t1 - t0, hwdec_current=player.hwdec_current)
    if a.png:
        tgt = a.png.resolve()
        if tgt.exists(): tgt.unlink()
        player.screenshot_format = 'png'
        player.command('screenshot-to-file', str(tgt), 'video')
        d = tgt.read_bytes()
        if d[:8] != b'\x89PNG\r\n\x1a\n': raise RuntimeError('not PNG')
        rep['png_dimensions'] = list(struct.unpack('>II', d[16:24])); rep['png_bytes'] = len(d)
    rep['status'] = 'decode-pass'
except Exception as e:
    rep['error'] = repr(e)
finally:
    rep['log_tail'] = [l for l in logs if any(k in l.lower() for k in ('dav1d','decoder','demuxer','error','fail','warn'))][-15:]
    a.report.write_text(json.dumps(rep, indent=2), encoding='utf-8')
    if player is not None:
        threading.Thread(target=player.terminate, daemon=True).start(); time.sleep(2)
print(rep['status']); os._exit(0)
