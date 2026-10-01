#!/usr/bin/env python3
"""Live tab restore and panel checks in a named mnml Test world.

Launch mnml Test with MNML_PROBE=sync9 and bench/welcomed enabled first.
"""
import os
import runpy
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(__file__).resolve().parents[1]
bench = runpy.run_path(str(root / 'bench'))
socket = str(Path(bench['folder'](os.environ.get('MNML_PROBE', 'sync9'))) / 'bench.sock')


def call(verb, **fields):
    result = bench['ask'](socket, {'do': verb, **fields})
    assert 'error' not in result, (verb, result)
    return result


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f'<!doctype html><title>{self.path}</title><p>{self.path}</p>'.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'


def make(name):
    if any(t['url'] for t in call('tabs')['tabs']):
        call('press', code=17, chars='t', mods=['cmd'])
    call('field', text=f'{base}/{name}', go=True)
    return next(t['id'] for t in call('tabs')['tabs'] if t['url'] == f'{base}/{name}')


try:
    if call('probe')['asking']:
        call('answer', **{'with': 'no'})
    one, two, three = [make(name) for name in ('one', 'two', 'three')]
    call('clear')
    state = call('tabs')
    assert state['ghosts'] == 3 and state['reopenTitle'] == 'Reopen 3 Cleared Tabs', state
    call('press', code=17, chars='t', mods=['cmd', 'shift'])
    state = call('tabs')
    assert state['ghosts'] == 0 and {t['url'] for t in state['tabs'] if t['url']} == {
        f'{base}/one', f'{base}/two', f'{base}/three'}, state
    print('PASS Clear restores three pages with one shortcut')

    ids = [next(t['id'] for t in state['tabs'] if t['url'] == f'{base}/{name}')
           for name in ('one', 'two')]
    group = call('group', args=['make', *ids])['group']
    call('group', args=['name', group, 'Work'])
    call('group', args=['close', group])
    assert all(t['group'] != 'Work' for t in call('tabs')['tabs'])
    for _ in ids:
        call('press', code=17, chars='t', mods=['cmd', 'shift'])
    state = call('tabs')
    assert {t['url'] for t in state['tabs'] if t['group'] == 'Work'} == {
        f'{base}/one', f'{base}/two'}, state
    print('PASS Close Group restores name and both members')

    before = len(state['tabs'])
    call('ui', settings=True)
    assert call('probe')['settings']
    call('press', code=13, chars='w', mods=['cmd'])
    assert not call('probe')['settings'] and len(call('tabs')['tabs']) == before
    print('PASS Cmd-W closes Settings before the page')
finally:
    server.shutdown()
