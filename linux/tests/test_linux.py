"""End-to-end checks for the Linux build, run in CI on a real Linux machine.

A fake home folder with a Steam library, a fake Discord (a Unix socket speaking the IPC protocol)
and a real running process named like the game. Checks the scanner finds and matches the game and
that the engine shows it on the right Discord app, then clears it when the game closes."""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix='rp-test-'))
HOME = TMP / 'home'
RUN = TMP / 'run'
os.environ['HOME'] = str(HOME)
os.environ['RICHPRESENCE_DATA'] = str(TMP / 'data')
os.environ['XDG_RUNTIME_DIR'] = str(RUN)
os.environ.pop('DISPLAY', None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

bad = 0


def check(label, ok, detail=''):
    global bad
    print(('PASS' if ok else 'FAIL') + '  ' + label + ('  ' + str(detail) if detail and not ok else ''))
    if not ok:
        bad += 1
        print(f'::error title=test::{label} {str(detail)[:900]}'.replace(chr(10), ' '))


# ---- a fake Steam library with one game, whose binary is a real ELF (a copy of /bin/sleep)
steam = HOME / '.local/share/Steam'
game_dir = steam / 'steamapps/common/Duck Quest'
game_dir.mkdir(parents=True)
shutil.copy('/bin/sleep', game_dir / 'duckquest')
(game_dir / 'uninstall').write_bytes(open('/bin/sleep', 'rb').read())
os.chmod(game_dir / 'uninstall', 0o755)
(steam / 'steamapps/appmanifest_4242.acf').write_text('"AppState"\n{\n "appid" "4242"\n "name" "Duck Quest"\n "installdir" "Duck Quest"\n}\n')
(steam / 'steamapps/appmanifest_1.acf').write_text('"AppState"\n{\n "appid" "1"\n "name" "Proton 9.0"\n "installdir" "Proton 9.0"\n}\n')
# a Windows game run through Proton, and one in ~/Games
win_dir = steam / 'steamapps/common/Goose Game'
win_dir.mkdir(parents=True)
(win_dir / 'Goose.exe').write_bytes(b'MZ' + b'\0' * 5000)
(steam / 'steamapps/appmanifest_77.acf').write_text('"AppState"\n{\n "appid" "77"\n "name" "Goose Game"\n "installdir" "Goose Game"\n}\n')
(HOME / 'Games/Pond Racer').mkdir(parents=True)
shutil.copy('/bin/sleep', HOME / 'Games/Pond Racer/pondracer')

# Discord's detectable list (cached, so no network is needed)
data = Path(os.environ['RICHPRESENCE_DATA'])
data.mkdir(parents=True)
(data / 'detectable.json').write_text(json.dumps([
    {'id': '111111111111111111', 'name': 'Duck Quest', 'executables': [{'os': 'linux', 'name': 'duckquest'}]},
    {'id': '222222222222222222', 'name': 'Untitled Goose Game', 'executables': [{'os': 'win32', 'name': 'goose.exe'}]},
]))

import traceback  # noqa: E402


def _hook(tp, v, tb):
    print('::error title=crash::' + ' | '.join(traceback.format_exception(tp, v, tb)).replace(chr(10), ' ')[:3000])
    sys.__excepthook__(tp, v, tb)


sys.excepthook = _hook
from richpresence import discord_ipc, engine as E, scanner, settings as S, system  # noqa: E402

games = scanner.scan(S.load(), log=lambda m: None)
by = {g['name']: g for g in games}
check('finds the native Steam game', 'Duck Quest' in by, list(by))
check('skips Proton/runtime entries', not any('Proton' in n for n in by))
check('matches it to its official Discord app', by.get('Duck Quest', {}).get('discordId') == '111111111111111111')
check('uses the game binary, not the uninstaller', by.get('Duck Quest', {}).get('exes') == ['duckquest'], by.get('Duck Quest', {}).get('exes'))
check('Steam launch link', by.get('Duck Quest', {}).get('launch') == 'steam://rungameid/4242')
goose = next((g for g in games if g['id'] == 'steam:77'), {})
check('a Windows (Proton) game matches by its .exe', goose.get('discordId') == '222222222222222222' and goose.get('exes') == ['goose'], goose)
check('finds games in ~/Games', any(g['store'] == 'Folder' and 'pondracer' in g['exes'] for g in games))
check('writes the library file', len(S.read_library()) == len(games))

# ---- Discord's list when it is a week old and the download fails or breaks off: keep using the saved one
import urllib.error  # noqa: E402
import urllib.request  # noqa: E402


class FakeDownload:
    """Stands in for urlopen(): hands out the given chunks, then ends (or fails, if told to)."""

    def __init__(self, chunks, fail=False):
        self.chunks, self.fail = list(chunks), fail

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n=-1):
        if self.chunks:
            return self.chunks.pop(0)
        if self.fail:
            raise OSError('connection lost (test)')
        return b''


def no_network(*a, **k):
    raise OSError('no network (test)')


def duck_id(found):
    return next((g for g in found if g['name'] == 'Duck Quest'), {}).get('discordId')


real_urlopen = urllib.request.urlopen
cache = data / 'detectable.json'
saved = cache.read_bytes()
week_old = time.time() - 8 * 86400
try:
    os.utime(cache, (week_old, week_old))
    urllib.request.urlopen = no_network
    check('an old saved Discord list is still used when the download fails', duck_id(scanner.scan(S.load(), log=lambda m: None)) == '111111111111111111')
    urllib.request.urlopen = lambda *a, **k: FakeDownload([b'[{"id": "1111'])
    check('...and when the download arrives cut off', duck_id(scanner.scan(S.load(), log=lambda m: None)) == '111111111111111111')
    check('...leaving the saved list as it was', cache.read_bytes() == saved)
    fresh = json.dumps([{'id': '333333333333333333', 'name': 'Duck Quest', 'executables': [{'os': 'linux', 'name': 'duckquest'}]}]).encode()
    urllib.request.urlopen = lambda *a, **k: FakeDownload([fresh])
    check('a good download replaces the saved list', duck_id(scanner.scan(S.load(), log=lambda m: None)) == '333333333333333333'
          and cache.read_bytes() == fresh and not (data / 'detectable.tmp').exists(), sorted(x.name for x in data.iterdir()))
finally:
    urllib.request.urlopen = real_urlopen
    cache.write_bytes(saved)

# ---- process detection, including a Wine/Proton style command line
p = subprocess.Popen([str(game_dir / 'duckquest'), '60'])
w = subprocess.Popen(['/bin/bash', '-c', 'exec -a "Z:\\\\games\\\\Goose.exe" sleep 60'])
time.sleep(0.5)
procs = system.running_processes()
check('sees the running game process', procs.get('duckquest') == p.pid)
check('sees a Windows .exe name in a command line', 'goose' in procs, sorted(n for n in procs if 'oose' in n))
check('reads the process start time', abs(system.process_start_ms(p.pid) - time.time() * 1000) < 10000)
w.kill()

# ---- a fake Discord
RUN.mkdir(parents=True, exist_ok=True)
sock_path = RUN / 'discord-ipc-0'
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(str(sock_path))
srv.listen(8)
received = []   # (client_id, activity or None)


def serve(conn):
    client = None
    try:
        while True:
            head = conn.recv(8)
            if len(head) < 8:
                return
            op, n = struct.unpack('<ii', head)
            body = b''
            while len(body) < n:
                body += conn.recv(n - len(body))
            msg = json.loads(body)
            if op == 0:
                client = msg['client_id']
                out = {'cmd': 'DISPATCH', 'evt': 'READY', 'data': {'v': 1}}
            else:
                act = msg['args'].get('activity')
                received.append((client, act))
                if act and act.get('details') == 'Refuse Me':   # lets a test make Discord say no to one card
                    out = {'cmd': 'SET_ACTIVITY', 'evt': 'ERROR', 'nonce': msg['nonce'], 'data': {'code': 4000, 'message': 'Refused (test)'}}
                else:
                    out = {'cmd': 'SET_ACTIVITY', 'evt': None, 'nonce': msg['nonce'], 'data': act}
            b = json.dumps(out).encode()
            conn.sendall(struct.pack('<ii', 1, len(b)) + b)
    except OSError:
        pass


def accept():
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=serve, args=(c,), daemon=True).start()


threading.Thread(target=accept, daemon=True).start()
check('finds the Discord socket', discord_ipc.find_sockets() == [str(sock_path)], discord_ipc.find_sockets())

# a game Discord knows is held back for 2 minutes so Discord's own detection (and streaks) counts first
held = E.Engine(dict(S.load(), official_to_discord=True, official_delay_minutes=2), E.State())
before = len(received)
held.update_games([(dict(by['Duck Quest'], enabled=True), p.pid)])
check('an official game is left to Discord for the first 2 minutes', len(received) == before and not held.game_conns)
held.s['official_delay_minutes'] = 0
held.update_games([(dict(by['Duck Quest'], enabled=True), p.pid)])
check('...and then gets our own card', len(received) > before and received[-1][1] and received[-1][1].get('name') == 'Duck Quest')
held.close_all()


def run_engine(eng, until, seconds=15):
    """Runs an engine until until() is true (or time is up), stops it and returns what it logged."""
    eng.start()
    deadline = time.time() + seconds
    while time.time() < deadline and not until():
        time.sleep(0.2)
    eng.st.stop.set()
    eng.join(10)
    lines = []
    while not eng.st.log.empty():
        lines.append(eng.st.log.get_nowait())
    return lines


# ---- a game hidden from Discord still counts as running, so "quit when the game closes" can see it
s5 = dict(S.load(), show_music=False, show_current_app=False, official_to_discord=False, disabled_games=['steam:4242'])
st5 = E.State()
st5.games = E.engine_games(games, s5)
st5.watch_id = 'steam:4242'
mark = len(received)
eng5 = E.Engine(s5, st5)
run_engine(eng5, lambda: eng5.watch['seen'])
check('a running game that is hidden from Discord is seen by "quit when the game closes"', eng5.watch['seen'] and 'steam:4242' in st5.running_ids, st5.running_ids)
check('...and still gets no card', not any(a and a.get('name') == 'Duck Quest' for _, a in received[mark:]), received[mark:])

# ---- Discord refusing the music card must not take the game card down with it
real_now_playing = system.now_playing
system.now_playing = lambda music_only=False: {'player': 'spotify', 'title': 'Refuse Me', 'artist': 'The Ducks', 'album': 'Pond',
                                               'art': 'https://example.com/a.jpg', 'length': 200.0, 'position': 50.0}
s6 = dict(S.load(), show_music=True, show_lyrics=False, show_album_art=False, show_current_app=False, official_to_discord=False)
st6 = E.State()
st6.games = E.engine_games(games, s6)
eng6 = E.Engine(s6, st6)
refused = lambda: sum(1 for c, a in received if c == S.MUSIC_ID and a and a.get('details') == 'Refuse Me')  # noqa: E731
log6 = run_engine(eng6, lambda: refused() >= 3, 20)
system.now_playing = real_now_playing
check('the music card was refused a few times in a row', refused() >= 3, log6)
check('...which is logged as a music card problem', any('Music card error' in l for l in log6), log6)
check('...while the game card stays connected (sent once, not torn down and redone)', sum(1 for l in log6 if 'Playing: Duck Quest' in l) == 1, log6)

s = dict(S.load(), show_music=False, show_current_app=False, official_to_discord=False)
st = E.State()
st.games = E.engine_games(games, s)
mark = len(received)   # only look at cards this engine sends
eng = E.Engine(s, st)
eng.start()
deadline = time.time() + 15
while time.time() < deadline and not any(a and a.get('name') == 'Duck Quest' for _, a in received[mark:]):
    time.sleep(0.2)
hit = next(((c, a) for c, a in received[mark:] if a and a.get('name') == 'Duck Quest'), None)
check('shows "Playing Duck Quest" on Discord', hit is not None, received)
check('...on the game\'s own Discord app', hit and hit[0] == '111111111111111111')
check('...with the real start time', hit and abs(hit[1]['timestamps']['start'] - system.process_start_ms(p.pid)) < 2000)
deadline = time.time() + 6
while time.time() < deadline and 'Playing Duck Quest' not in st.status:
    time.sleep(0.2)
check('the status line says so', 'Playing Duck Quest' in st.status, st.status)

p.kill()
p.wait()
deadline = time.time() + 15
while time.time() < deadline and st.running_ids:
    time.sleep(0.2)
check('notices the game closed', st.running_ids == [], st.running_ids)
st.stop.set()
eng.join(10)
check('the engine stops cleanly', not eng.is_alive())

# ---- music card from an MPRIS-shaped track (no D-Bus in CI, so feed it directly)
st2 = E.State()
eng2 = E.Engine(dict(S.load(), show_lyrics=False, show_album_art=False), st2)
system.now_playing = lambda music_only=False: {'player': 'spotify', 'title': 'Quack Song', 'artist': 'The Ducks', 'album': 'Pond',
                                               'art': 'https://example.com/a.jpg', 'length': 200.0, 'position': 50.0}
E.system.now_playing = system.now_playing
title = eng2.update_music()
music = [a for c, a in received if c == S.MUSIC_ID and a]
check('music card is sent on the music app', title == 'Quack Song' and music, received[-3:])
if music:
    m = music[-1]
    check('...as "Listening to" with artist, title, art and timing', m['type'] == 2 and m['name'] == 'The Ducks' and m['details'] == 'Quack Song'
          and m['assets']['large_image'] == 'https://example.com/a.jpg' and m['timestamps']['end'] - m['timestamps']['start'] == 200000)
eng2.close_all()

# ---- a 1-character title or lyric: Discord refuses text shorter than 2 characters
eng3 = E.Engine(dict(S.load(), show_lyrics=True, show_album_art=False), E.State())
eng3.lyrics_cache['B|A|'] = [(0.0, 'O')]
system.now_playing = lambda music_only=False: {'player': 'spotify', 'title': 'A', 'artist': 'B', 'album': '',
                                               'art': 'https://example.com/a.jpg', 'length': 0, 'position': 5.0}
E.system.now_playing = system.now_playing
eng3.update_music()
m = ([a for c, a in received if c == S.MUSIC_ID and a] or [{}])[-1]
short = [k for k, v in (('details', m.get('details', '')), ('state', m.get('state', '')), ('large_text', m.get('assets', {}).get('large_text', ''))) if len(v) < 2]
check('a 1-character title and lyric are never sent shorter than 2 characters', m.get('details', '').startswith('A') and m.get('state', '').startswith('O') and not short, m)
eng3.close_all()

# ---- lyrics and album art: a lookup that breaks is tried again later, one that finds nothing is remembered
eng7 = E.Engine(dict(S.load(), show_lyrics=True, show_album_art=True), E.State())
calls = []
real_get_json = E.get_json


def broken(url, timeout=8):
    calls.append(url)
    raise OSError('no network (test)')


def answers(reply):
    def get(url, timeout=8):
        calls.append(url)
        return reply
    return get


def not_found(url, timeout=8):
    calls.append(url)
    raise urllib.error.HTTPError(url, 404, 'Not Found', None, None)


E.get_json = broken
check('a lyrics or art lookup that breaks gives nothing', eng7.lyrics('The Ducks', 'Quack Song', 'Pond', 200) is None
      and eng7.album_art('The Ducks', 'Quack Song', 'Pond') is None and len(calls) == 2, calls)
check('...and is not remembered as "this song has none"', not eng7.lyrics_cache and not eng7.art_cache, (eng7.lyrics_cache, eng7.art_cache))
eng7.lyrics('The Ducks', 'Quack Song', 'Pond', 200)
eng7.album_art('The Ducks', 'Quack Song', 'Pond')
check('...nor asked again on the very next look', len(calls) == 2, calls)
eng7.retry_at.clear()   # as if the wait before the next try were over
E.get_json = answers({'syncedLyrics': '[00:01.00]Quack', 'resultCount': 1, 'results': [{'artworkUrl100': 'https://example.com/100x100bb.jpg'}]})
check('...so a later try can still find them', eng7.lyrics('The Ducks', 'Quack Song', 'Pond', 200) == [(1.0, 'Quack')]
      and eng7.album_art('The Ducks', 'Quack Song', 'Pond') == 'https://example.com/512x512bb.jpg')
E.get_json = answers({'syncedLyrics': '', 'resultCount': 0, 'results': []})
before = len(calls)
for _ in range(2):
    none_l, none_a = eng7.lyrics('Nobody', 'Silence', '', 0), eng7.album_art('Nobody', 'Silence', '')
check('a song with no lyrics and no art is remembered and asked about once', none_l is None and none_a is None and len(calls) == before + 2
      and 'Nobody|Silence|' in eng7.lyrics_cache and 'Nobody||Silence' in eng7.art_cache, calls[before:])
E.get_json = not_found
before = len(calls)
for _ in range(2):
    none_l = eng7.lyrics('Nobody', 'Hush', '', 0)
check('"not found" (404) from the lyrics site counts as no lyrics too', none_l is None and len(calls) == before + 1 and 'Nobody|Hush|' in eng7.lyrics_cache, calls[before:])
E.get_json = real_get_json

# ---- updates
from richpresence import updater  # noqa: E402
check('versions compare as numbers', updater.version_tuple('v1.10.0') > updater.version_tuple('1.9.3') and updater.version_tuple('1.2') == (1, 2, 0))
fake_app = TMP / 'RichPresence-x86_64.AppImage'
fake_app.write_bytes(b'old')
st_, latest, path = updater.check(current='99.0.0', appimage=str(fake_app), log=lambda m: None)
check('no update when this is newer than the latest release', st_ == 'current', (st_, latest))
st_, latest, path = updater.check(current='1.0.0', appimage=None, log=lambda m: None)
check('a .deb/source install only hears that a version is out', st_ == 'available' and latest, (st_, latest))
st_, latest, path = updater.check(current='1.0.0', appimage=str(fake_app), log=lambda m: None)
check('an AppImage downloads the real latest release and verifies it', st_ == 'ready' and path and os.path.getsize(path) > 10_000_000, (st_, latest, path))
if path:
    new = updater.install(path, appimage=str(fake_app))
    check('...and swaps it in, executable', new == str(fake_app) and fake_app.stat().st_size > 10_000_000 and os.access(fake_app, os.X_OK) and not os.path.exists(path))
bad_release = {'tag_name': 'v99.0.0', 'assets': [{'name': 'RichPresence-x86_64.AppImage', 'digest': 'sha256:' + '0' * 64,
       'browser_download_url': 'https://github.com/noice912/Discord-status/releases/latest/download/SHA256SUMS-linux.txt'}]}
before = fake_app.read_bytes()[:64]
st_, latest, path = updater.check(current='1.0.0', appimage=str(fake_app), release=bad_release, log=lambda m: None)
check('a download that fails its checksum is thrown away', st_ == 'failed' and fake_app.read_bytes()[:64] == before
      and not os.path.exists(str(fake_app) + '.download'), st_)
nodigest = {'tag_name': 'v99.0.0', 'assets': [{'name': 'RichPresence-x86_64.AppImage', 'browser_download_url': 'https://example.com/x'}]}
check('an update without a published checksum is refused', updater.check(current='1.0.0', appimage=str(fake_app), release=nodigest, log=lambda m: None)[0] == 'failed')
urllib.request.urlopen = lambda *a, **k: FakeDownload([b'half of it'], fail=True)
try:
    st_, latest, path = updater.check(current='1.0.0', appimage=str(fake_app), release=bad_release, log=lambda m: None)
finally:
    urllib.request.urlopen = real_urlopen
check('a download that breaks off half-way leaves no .download file behind', st_ == 'failed' and not os.path.exists(str(fake_app) + '.download'), st_)

# ---- a second copy started with --play hands the game to the one already running
from richpresence import __main__ as M  # noqa: E402
os.environ.pop('WAYLAND_DISPLAY', None)
request = data / 'play.request'
lock = M.single_instance()
code = M.main(['--play', 'steam:4242'])
check('a second copy with --play leaves the game id for the running one and exits 0', lock is not None and code == 0
      and request.is_file() and request.read_text() == 'steam:4242', code)
lock.close()
request.write_text('steam:4242')
M.main([])   # takes the lock, then stops because the test has no desktop
check('a request left over from before is deleted when the app starts', not request.exists())

srv.close()
shutil.rmtree(TMP, ignore_errors=True)
print(f'\n{bad} FAILURE(S)' if bad else '\nALL CHECKS PASSED')
sys.exit(1 if bad else 0)
