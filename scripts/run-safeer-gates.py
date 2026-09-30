"""Safeer release gates for a freshly built libmpv-2.dll (Windows x64, Python 3.14, python-mpv 1.0.8).

Runs scripts/smoke-safeer-player.py once per case, verifies the PNG really holds a picture, records DLL
provenance and writes <out-dir>/summary.json. Exit code 0 ONLY when milestone 1 holds:
av1_mp4, av1_webm, dash, png and BOTH h264 baseline runs pass. MPEG-4 Part 2 is reported (with the
actual decoder/error from an inline probe) but does not gate milestone 1.
Standard library only. Never overwrites existing PNGs.
"""
import argparse, hashlib, json, os, struct, subprocess, sys, threading, time, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
SMOKE = HERE / 'smoke-safeer-player.py'

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()

def png_has_picture(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 1000:
        return False, 'not a PNG or too small (%d B)' % len(data)
    pos, idat, w, h = 8, b'', 0, 0
    while pos + 8 <= len(data):
        ln, typ = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h = struct.unpack('>II', body[:8])
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
        pos += 12 + ln
    if not (w > 0 and h > 0):
        return False, 'IHDR without size'
    try:
        raw = zlib.decompress(idat)
    except Exception as e:
        return False, 'IDAT decompress failed: %r' % e
    distinct = len(set(raw[:2_000_000]))
    return (distinct >= 8), 'size=%dx%d distinct_bytes=%d' % (w, h, distinct)

def run_smoke(dll_dir, source, report, av1=False, png=None, seconds=8):
    cmd = [sys.executable, str(SMOKE), '--dll-dir', str(dll_dir), '--source', str(source),
           '--seconds', str(seconds), '--report', str(report)]
    if av1: cmd.append('--av1')
    if png: cmd += ['--png', str(png)]
    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    rep = {}
    try: rep = json.loads(Path(report).read_text(encoding='utf-8'))
    except Exception: pass
    return {'ok': proc.returncode == 0 and rep.get('status') == 'playback-smoke-pass',
            'status': rep.get('status'), 'error': rep.get('error'), 'video_codec': rep.get('video_codec'),
            'seconds': round(time.time() - t0, 1), 'stdout_tail': proc.stdout[-300:], 'stderr_tail': proc.stderr[-300:]}

def mpeg4_probe(dll_dir, source):
    """Inline probe: which decoder mpv actually picked for MPEG-4 Part 2, and why it failed if it did."""
    code = r'''
import os, sys, time, json
d = sys.argv[1]; os.environ["PATH"] = d + os.pathsep + os.environ.get("PATH", ""); os.add_dll_directory(d)
import mpv
lines = []
p = mpv.MPV(vo="null", ao="null", hwdec="no", log_handler=lambda l, c, m: lines.append(f"[{l}] {c}: {m.strip()}"), msg_level="all=v")
try:
    p.play(sys.argv[2]); time.sleep(2.5)
    out = {"video_codec": p.video_codec, "dwidth": p.dwidth}
except Exception as e:
    out = {"exception": repr(e)}
out["log"] = [x for x in lines if ("vd" in x.lower() or "decoder" in x.lower() or "error" in x.lower())][:25]
p.terminate(); print(json.dumps(out))
'''
    proc = subprocess.run([sys.executable, '-c', code, str(dll_dir), str(source)], capture_output=True, text=True, timeout=90)
    try: return json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception: return {'probe_error': proc.stderr[-400:]}

def main():
    a = argparse.ArgumentParser()
    a.add_argument('--dll-dir', required=True, type=Path)
    a.add_argument('--media-dir', required=True, type=Path)
    a.add_argument('--out-dir', required=True, type=Path)
    a.add_argument('--dash-dir', type=Path)
    a.add_argument('--seconds', type=float, default=8)
    args = a.parse_args()
    dll, media, out = args.dll_dir.resolve(), args.media_dir.resolve(), args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S')
    S = {'timestamp': stamp, 'dll_dir': str(dll), 'gates': {}, 'diagnostics': {}}

    S['dll_sha256'] = {n: (sha256(dll / n) if (dll / n).is_file() else 'MISSING') for n in ('libmpv-2.dll', 'libEGL.dll', 'libGLESv2.dll')}
    cap = None
    for c in (dll / 'safeer-capabilities.json', dll.parent / 'safeer-capabilities.json'):
        if c.is_file(): cap = json.loads(c.read_text()); break
    S['safeer_capabilities'] = cap if cap else 'MISSING'

    server = None
    dash_url = None
    if args.dash_dir:
        import http.server, socketserver, functools
        H = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(args.dash_dir.resolve()))
        server = socketserver.TCPServer(('127.0.0.1', 0), H)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        dash_url = 'http://127.0.0.1:%d/index.mpd' % server.server_address[1]

    def gate(name, source, av1=False, png=None):
        r = run_smoke(dll, source, out / f'{name}-{stamp}.json', av1=av1, png=png, seconds=args.seconds)
        S['gates'][name] = r
        print('%-14s %s  %s' % (name, 'PREHOD' if r['ok'] else 'PADEC ', r.get('video_codec') or r.get('error') or ''))
        return r

    png_path = out / f'av1-frame-{stamp}.png'
    gate('h264_pred', media / 'h264_24s.mp4')
    gate('av1_mp4', media / 'av1_24s.mp4', av1=True, png=png_path)
    gate('av1_webm', media / 'av1_24s.webm', av1=True)
    if dash_url:
        gate('dash', dash_url)
    else:
        S['gates']['dash'] = {'ok': False, 'status': 'skipped-no-dash-dir'}; print('%-14s PADEC  (brez --dash-dir)' % 'dash')
    if png_path.is_file():
        ok, why = png_has_picture(png_path)
        S['gates']['png'] = {'ok': ok, 'detail': why, 'path': str(png_path)}
    else:
        S['gates']['png'] = {'ok': False, 'detail': 'PNG ni nastal'}
    print('%-14s %s  %s' % ('png', 'PREHOD' if S['gates']['png']['ok'] else 'PADEC ', S['gates']['png'].get('detail', '')))
    gate('h264_po', media / 'h264_24s.mp4')

    for name, f in (('mpeg4p2_mp4', 'mpeg4p2_24s.mp4'), ('mpeg4p2_avi', 'mpeg4p2_24s.avi')):
        r = run_smoke(dll, media / f, out / f'{name}-{stamp}.json', seconds=args.seconds)
        if not r['ok']:
            r['probe'] = mpeg4_probe(dll, media / f)
        S['diagnostics'][name] = r
        print('%-14s %s  %s' % (name, 'PREHOD' if r['ok'] else 'PADEC ', r.get('video_codec') or r.get('error') or ''))

    if server: server.shutdown()
    need = ('h264_pred', 'av1_mp4', 'av1_webm', 'dash', 'png', 'h264_po')
    S['milestone1'] = all(S['gates'].get(n, {}).get('ok') for n in need)
    (out / f'summary-{stamp}.json').write_text(json.dumps(S, indent=2, ensure_ascii=False), encoding='utf-8')
    print('\nMEJNIK 1:', 'PREHOD' if S['milestone1'] else 'PADEC', '->', out / f'summary-{stamp}.json')
    sys.exit(0 if S['milestone1'] else 1)

if __name__ == '__main__':
    main()
