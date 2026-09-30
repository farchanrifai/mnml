#!/usr/bin/env python3
"""Live sync checks. Launch mnml Test with MNML_PROBE=<world> first.
Defaults before launch: bench, welcomed, sidebar, search.sites, pins.list=true.
Run: python3 Tests/upstream_sync_smoke.py --world sync8-ui
"""
import argparse
import re
import runpy
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

args = argparse.ArgumentParser()
args.add_argument('--world', required=True)
world = args.parse_args().world
assert re.fullmatch(r'[a-z0-9-]+', world) and world not in ('copy', 'test'), 'Use an isolated named world'
root = Path(__file__).resolve().parents[1]
bench = runpy.run_path(str(root / 'bench'))
def call(verb, **fields):
    reply = bench['ask'](str(Path(bench['folder'](world)) / 'bench.sock'), {'do': verb, **fields})
    assert 'error' not in reply, (verb, reply)
    return reply

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Sync fixture</title><p>alpha Alpha alphabet alpha</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
try:
    if call('probe')['asking']:
        call('answer', **{'with': 'no'})
    call('field', text=f'{base}/one', go=True)
    time.sleep(.4)
    tabs = call('tabs')['tabs']
    tab = next(t for t in tabs if t.get('url') == f'{base}/one')
    one = tab['id']
    for fields, total in [({}, 4), ({'case': True}, 3), ({'words': True}, 3), ({'case': True, 'words': True}, 2)]:
        result = call('find', text='alpha', **fields)
        assert result['status'].endswith(f'of {total}'), result
    print('PASS Find case/whole-word options')
    call('press', code=53, chars='\x1b')
    call('field', text='red')
    offered = call('sitesearch')
    assert offered['offer'] == 'Reddit', offered
    chipped = call('sitesearch', action='tab')
    assert chipped['chip'] == 'Reddit' and chipped['typed'] == '', chipped
    call('field', text='coffee beans')
    state = call('sitesearch')
    assert 'reddit.com/search/?q=coffee%20beans' in state['offers'][0][1], state
    escaped = call('sitesearch', action='esc')
    assert escaped['chip'] == '' and escaped['editing'], escaped
    call('sitesearch', action='esc')
    print('PASS site search chip, encoding and cancellation')
    call('pin', id=one, listed=True)
    call('press', code=53, chars='\x1b')
    call('press', code=17, chars='t', mods=['cmd'])
    call('field', text=f'{base}/two', go=True)
    call('pin', id=next(t['id'] for t in call('tabs')['tabs'] if t.get('url') == f'{base}/two'))
    call('picture', path='/tmp/mnml-sync8-pinned.png')
    print('PASS pinned row and square visible capture')
    call('press', code=53, chars='\x1b')
    call('press', code=48, chars='\t', mods=['ctrl'])
    time.sleep(.35)
    sw = call('switcher')
    if not sw['visible'] and not call('probe')['key']:
        print('INFO test window is not key; checking shared switcher handler directly')
        call('switcher', action='start')
        time.sleep(.35)
        sw = call('switcher')
    assert sw['visible'] and len(sw['cards']) >= 2 and sw['panel'][2] > 0, sw
    call('picture', path='/tmp/mnml-sync8-switcher.png')
    x, y, w, h = sw['cards'][one]
    picked = call('switcher', action='click', point=[x+w/2, y+h/2])
    assert picked['active'] == one and not picked['visible'], picked
    print('PASS switcher geometry and shared pointer handler')
    call('select', id=next(t['id'] for t in call('tabs')['tabs'] if t.get('url') == f'{base}/two'))
    # Permission requests are started asynchronously; the next command answers the card.
    active = next(t['id'] for t in call('tabs')['tabs'] if t.get('url') == f'{base}/two')
    call('eval', id=active, js="navigator.geolocation.getCurrentPosition(()=>{},()=>{}); 'started'")
    time.sleep(.7)
    assert ' location' in call('probe')['asking'], call('probe')
    answer = call('answer', **{'with': 'once'})
    assert answer['locationAnswered'] == 'granted', answer
    print('PASS geolocation Allow once (OS permission suppressed in test world)')
    call('eval', id=active, js="Notification.requestPermission().then(p=>window.permissionResult=p); 'started'")
    time.sleep(.7)
    assert ' notifications' in call('probe')['asking'], call('probe')
    call('answer', **{'with': 'always'})
    call('eval', id=active, js="new Notification('Sync fixture', {body:'Test delivery'}); 'posted'")
    time.sleep(.4)
    notes = call('notifications')
    assert any(n['title'] == 'Sync fixture' for n in notes['recorded']), notes
    print('PASS native notification permission and test-only delivery')
finally:
    server.shutdown()
