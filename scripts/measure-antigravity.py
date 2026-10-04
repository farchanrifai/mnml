#!/usr/bin/env python3
"""Measure an isolated Release mnml run and its Antigravity process trees.

Launch mnml with MNML_PROBE=agy-qa MNML_MEASURE=1 and
MNML_AI_METRICS=<absolute output directory>/requests.jsonl, then run:
  python3 scripts/measure-antigravity.py --pid PID --world agy-qa --out DIR
Uses your subscription for synthetic-page requests. No existing tabs are sent.
RSS sums include shared pages; they are not physical footprint or energy usage.
WebKit XPC processes cannot be reliably attributed by parent PID and are excluded.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time


def cpu_seconds(value):
    days, value = value.split('-') if '-' in value else ('0', value)
    total = 0.0
    for part in value.split(':'):
        total = total * 60 + float(part)
    return int(days) * 86400 + total


def processes():
    raw = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,rss=,time=,comm='], text=True)
    rows = {}
    for line in raw.splitlines():
        pid, parent, group, rss, cpu, name = line.split(None, 5)
        rows[int(pid)] = dict(pid=int(pid), parent=int(parent), group=int(group), rss_kib=int(rss), cpu_s=cpu_seconds(cpu), name=name)
    return rows


def relatives(rows, roots, groups):
    found = {pid for pid, row in rows.items() if pid in roots or row['group'] in groups}
    while True:
        more = {pid for pid, row in rows.items() if row['parent'] in found}
        if more <= found:
            return found
        found |= more


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int)
    parser.add_argument('--world', default='agy-qa')
    parser.add_argument('--out', type=Path, default=Path('build/antigravity-qa'))
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--followups', action='store_true', help='Compare warm, conversation-only and changed-page follow-ups on a large fixture')
    args = parser.parse_args()
    if args.self_test:
        assert cpu_seconds('01:02.50') == 62.5
        assert cpu_seconds('1-00:00:01') == 86401
        assert relatives({1: {'parent': 0, 'group': 1}, 2: {'parent': 1, 'group': 2}, 3: {'parent': 2, 'group': 2}, 4: {'parent': 0, 'group': 4}}, {1}, set()) == {1, 2, 3}
        print('self-test passed')
        return
    if not args.pid or not args.world or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in args.world):
        parser.error('--pid and a lowercase test --world are required')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    metrics = out / 'requests.jsonl'
    sock = Path.home() / f'Library/Application Support/mnml ({args.world})/bench.sock'
    if not metrics.exists():
        metrics.touch()

    def call(verb, **fields):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(30)
            client.connect(str(sock))
            client.sendall((json.dumps({'do': verb, **fields}) + '\n').encode())
            data = b''
            while b'\n' not in data:
                chunk = client.recv(65536)
                if not chunk:
                    raise RuntimeError('bench socket closed')
                data += chunk
        reply = json.loads(data.split(b'\n')[0])
        if 'error' in reply:
            raise RuntimeError(reply['error'])
        return reply

    def requests():
        result = []
        for line in metrics.read_text().splitlines():
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # a writer can be between the JSON bytes and newline
        return result

    phase = 'baseline'
    stopped = threading.Event()
    samples = []
    seen = {args.pid}
    groups = set()
    sampler_error = []
    def sample():
        try:
            with (out / 'resources.jsonl').open('w') as file:
                while not stopped.is_set():
                    events = requests()
                    groups.update(e['pid'] for e in events if e['event'] == 'start')
                    rows = processes()
                    found = relatives(rows, seen, groups)
                    seen.update(found)
                    selected = [rows[pid] for pid in sorted(found)]
                    row = dict(time=time.time(), phase=phase, processes=selected)
                    samples.append(row)
                    file.write(json.dumps(row) + '\n'); file.flush()
                    stopped.wait(0.25)
        except Exception as error:
            sampler_error.append(str(error))
    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    tabs = []
    owned_chats = set()
    other_space = None
    original_space = None
    original_space_name = None
    original_spaces_on = False
    summary = {'pid': args.pid, 'world': args.world, 'metrics': str(metrics), 'scenarios': [],
               'limits': ['RSS sums double-count shared pages; not physical footprint.',
                          'CPU is cumulative process time sampled every 250 ms.',
                          'WebKit XPC processes are excluded; this isolates app and CLI overhead.',
                          'Synthetic pages and short answers; not representative of large attachments.',
                          'A single run; repeat before drawing performance conclusions.',
                          'Inactivity is advanced by test-only hooks; production thresholds remain 180 + 60 seconds.',
                          'Input-token savings do not directly measure subscription allowance.']}

    def send(tab, **fields):
        state = call('ask', id=tab, action='send', **fields)
        owned_chats.add(state['chat'])
        return state

    def sessions():
        return call('ai-sessions')['sessions']

    def wait_until(test, label, timeout=10):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            result = test()
            if result:
                return result
            time.sleep(0.1)
        raise RuntimeError(f'{label} did not settle within {timeout} seconds')

    def wait_space(name):
        def settled():
            state = call('space')
            return state if state['current'] == name and abs(state['swipe']) < 0.01 else None
        return wait_until(settled, f'space {name}', timeout=15)

    try:
        if call('ai-sessions')['sessions']:
            raise RuntimeError('Use a fresh test profile; this one already has live AI sessions')
        for color, total in [('RED', 42), ('BLUE', 17), ('GREEN', 63)]:
            page = out / f'{color.lower()}.html'
            # Exceeds the 88k page reservation, so history growth must not
            # change the clipped source or needlessly restart a warm process.
            extra = ''.join(f'<p>Record {i:04}: synthetic browser fixture, category example, status recorded, explanation for repeatable context measurement.</p>' for i in range(900)) if args.followups else ''
            page.write_text(f'<html><title>{color} measurement fixture</title><body><h1>{color}</h1><p id="total">The total is {total}.</p>{extra}</body></html>')
            tab = call('open', url=page.as_uri())['id']
            tabs.append(tab)
            call('wait', id=tab, seconds=15)
        call('select', id=tabs[0])
        time.sleep(4)
        # vmmap is a separate snapshot, outside request timing. Preserve its
        # diagnostics if permissions prevent access; never substitute RSS.
        with (out / 'baseline-vmmap.txt').open('w') as file:
            subprocess.run(['vmmap', '-summary', str(args.pid)], stdout=file, stderr=subprocess.STDOUT)

        def finish(ids, timeout=100):
            until = time.monotonic() + timeout
            while time.monotonic() < until:
                states = [call('ask', id=tab) for tab in ids]
                if not any(state['working'] for state in states):
                    return states
                time.sleep(0.25)
            raise RuntimeError(f'{phase} did not complete within {timeout} seconds')

        def resident(chat):
            return next((session for session in sessions() if session['chat'] == chat), None)

        def last_start(chat):
            starts = [event for event in requests() if event['event'] == 'start' and event['chat'] == chat]
            if not starts:
                raise RuntimeError('No request metrics; launch the test app with MNML_AI_METRICS pointing to this output directory')
            return starts[-1]

        def warm(state):
            session = wait_until(lambda: resident(state['chat']), 'warm session')
            assert not session['busy'] and session['pid'] > 0, session
            assert session['pid'] in processes(), session
            return session

        question = 'What color heading and numeric total are on this page? Answer in one short sentence, using only the page.'
        scenarios = [('single', tabs[:1])] if args.followups else [('single', tabs[:1]), ('dual', tabs[1:])]
        for name, ids in scenarios:
            phase = name
            start = time.monotonic()
            for tab in ids:
                send(tab, text=question)
            states = finish(ids)
            for state in states:
                if not state['turns'] or state['turns'][-1]['failed']:
                    raise RuntimeError(f'{name} failed: {state}')
            expected = [('RED', '42')] if name == 'single' else [('BLUE', '17'), ('GREEN', '63')]
            for state, (color, total) in zip(states, expected):
                answer = state['turns'][-1]['text']
                if color.lower() not in answer.lower() or total not in answer:
                    raise RuntimeError(f'Wrong page context: expected {color} {total}, got {answer}')
            summary['scenarios'].append(dict(name=name, elapsed_s=time.monotonic()-start, states=states))
            phase = name + '-settle'; time.sleep(3)
            live = [warm(state) for state in states]
            summary['scenarios'][-1]['warm_sessions'] = live
            assert len(sessions()) <= 2, sessions()
            if name == 'single':
                first = states[0]
                first_pid = live[0]['pid']
                first_start = last_start(first['chat'])
                assert first_start['warm'] is False, first_start
                if not args.followups:
                    phase = 'warm-followup'
                    start = time.monotonic()
                    send(tabs[0], text='What is that total plus one? Answer only with the number.')
                    again = finish(tabs[:1])[0]
                    assert again['turns'][-1]['text'].strip() == '43', again
                    assert warm(again)['pid'] == first_pid, again
                    sent = last_start(again['chat'])
                    assert sent['warm'] and sent['inputBytes'] < first_start['inputBytes'], sent
                    summary['scenarios'].append(dict(name=phase, elapsed_s=time.monotonic()-start, state=again, pid=first_pid, request=sent))
                    phase += '-settle'; time.sleep(3)
            if name == 'dual':
                assert resident(first['chat']) is None, sessions()  # the oldest idle process makes room
                summary['scenarios'].append(dict(name='lru-eviction', evicted_chat=first['chat'], resident=sessions()))
                call('select', id=ids[-1])
                time.sleep(0.2)  # let the native tab selection finish drawing
                summary['ui'] = call('probe')
                call('picture', path=str(out / 'chat.png'))

        if args.followups:
            call('picture', path=str(out / 'page-followup.png'))
            followups = [('full-page-followup', True, 'What is the original page total plus one? Answer only with the number.', '43'),
                         ('conversation-only-followup', False, 'What is the original page total plus two? Answer only with the number.', '44'),
                         ('fresh-page-followup', True, 'What is the total on the current page now? Answer only with the number.', '73')]
            for name, include_page, question, expected in followups:
                phase = name
                if name == 'fresh-page-followup':
                    call('eval', id=tabs[0], js='document.getElementById("total").textContent = "The total is 73."')
                start = time.monotonic()
                send(tabs[0], text=question, page=include_page)
                state = finish(tabs[:1])[0]
                assert not state['turns'][-1]['failed'], state
                assert state['turns'][-1]['text'].strip() == expected, state
                assert state['page'] == include_page, state
                live = warm(state)
                sent = last_start(state['chat'])
                if name == 'full-page-followup':
                    assert live['pid'] == first_pid, live
                    assert sent['warm'] and sent['inputBytes'] < first_start['inputBytes'], sent
                else:
                    assert live['pid'] != previous_pid, live  # omitted/changed sources must not keep stale native context
                    assert sent['warm'] is False, sent
                previous_pid = live['pid']
                summary['scenarios'].append(dict(name=name, elapsed_s=time.monotonic()-start, state=state, session=live, request=sent))
                phase = name + '-settle'; time.sleep(3)
                if not include_page:
                    call('picture', path=str(out / 'conversation-followup.png'))
        # Drive the same handlers as the in-app toast, without waiting four real
        # minutes or altering the production inactivity thresholds. The owner
        # tab is parked in another mnml space while its warning is drawn.
        phase = 'cross-space-toast'
        owner_tab = tabs[0] if args.followups else tabs[-1]
        owner = call('ask', id=owner_tab)
        owner_live = warm(owner)
        before_turns = owner['turns']
        space = call('space')
        original_spaces_on = space['on']
        original_space_name = space['current']
        original_space = next(index for index, item in enumerate(space['spaces'], 1) if item['name'] == space['current'])
        call('ui', spaces=True)
        made = call('space', action='new', name='AI measurement other space')
        other_space = made['spaces'][-1]['id']
        made = wait_space('AI measurement other space')
        assert made['current'] != space['current'], made
        call('ai-sessions', action='age', chat=owner['chat'], seconds=181)
        warning = resident(owner['chat'])
        assert warning is not None and 0 < warning['remaining'] <= 60, warning
        summary['scenarios'].append(dict(name=phase, owner=warning, visible_space=made['current']))
        time.sleep(0.5)  # allow the warning's entry transition to paint
        call('picture', path=str(out / 'toast-other-space.png'))
        summary['scenarios'][-1]['after_capture'] = resident(owner['chat'])
        call('ai-sessions', action='keep', chat=owner['chat'])
        kept = resident(owner['chat'])
        assert kept['pid'] == owner_live['pid'] and kept['idle'] < 2 and kept['remaining'] is None, kept
        summary['scenarios'].append(dict(name='keep-live', session=kept))
        call('ai-sessions', action='age', chat=owner['chat'], seconds=181)
        call('ai-sessions', action='go', chat=owner['chat'])
        wait_until(lambda: any(tab['id'] == owner_tab and tab['active'] for tab in call('tabs')['tabs']), 'Go to Tab')
        focused = call('space')
        assert focused['current'] == space['current'], focused
        assert resident(owner['chat'])['pid'] == owner_live['pid'], sessions()
        assert resident(owner['chat'])['idle'] < 2, sessions()
        summary['scenarios'].append(dict(name='go-to-tab', space=focused['current'], tab=owner_tab))
        call('space', action='go', index=len(made['spaces']))
        wait_space('AI measurement other space')
        # Leave enough time for the native window capture to finish before the
        # warning is removed; WebKit/space snapshots can take several seconds.
        call('ai-sessions', action='age', chat=owner['chat'], seconds=215)
        countdown = resident(owner['chat'])
        assert countdown is not None and 0 < countdown['remaining'] <= 25, countdown
        time.sleep(0.5)
        call('picture', path=str(out / 'toast-countdown.png'))
        summary['scenarios'].append(dict(name='countdown-capture', before=countdown, after=resident(owner['chat'])))
        phase = 'automatic-expiry'
        wait_until(lambda: resident(owner['chat']) is None, 'automatic expiry', timeout=30)
        wait_until(lambda: owner_live['pid'] not in processes(), 'expired process cleanup')
        call('space', action='go', index=original_space)
        wait_space(original_space_name)
        expired = call('ask', id=owner_tab)
        assert expired['turns'] == before_turns, expired
        summary['scenarios'].append(dict(name=phase, preserved_turns=len(before_turns), expired_pid=owner_live['pid']))
        # A killed/expired session must reconstruct the local conversation.
        phase = 'after-expiry-followup'
        expected = '74' if args.followups else '64'
        send(owner_tab, page=False, text='What is the most recently supplied page total plus one? Answer only with the number.')
        restarted = finish([owner_tab])[0]
        assert restarted['turns'][-1]['text'].strip() == expected, restarted
        restarted_live = warm(restarted)
        assert restarted_live['pid'] != owner_live['pid'], restarted_live
        assert last_start(restarted['chat'])['warm'] is False, last_start(restarted['chat'])
        summary['scenarios'].append(dict(name=phase, state=restarted, session=restarted_live))
        phase = 'kill-process'
        call('ai-sessions', action='kill', chat=owner['chat'])
        wait_until(lambda: restarted_live['pid'] not in processes(), 'killed process cleanup')
        assert call('ask', id=owner_tab)['turns'] == restarted['turns'], restarted
        summary['scenarios'].append(dict(name=phase, preserved_turns=len(restarted['turns'])))
        if not args.followups:
            phase = 'warm-tab-close'
            blue = call('ask', id=tabs[1])
            blue_live = warm(blue)
            call('close', id=tabs[1])
            wait_until(lambda: resident(blue['chat']) is None, 'closed-tab session')
            wait_until(lambda: blue_live['pid'] not in processes(), 'closed-tab process cleanup')
            summary['scenarios'].append(dict(name=phase, closed_pid=blue_live['pid']))
            # Replace only this fixture, leaving three independent tabs for
            # the active/queued cancellation scenario below.
            tabs[1] = call('open', url=(out / 'blue.html').as_uri())['id']
            call('wait', id=tabs[1], seconds=15)
        for live in sessions():
            if live['chat'] in owned_chats:
                call('ai-sessions', action='kill', chat=live['chat'])
        wait_until(lambda: not sessions(), 'all warm sessions stopped')

        if not args.followups:
            phase = 'queue-cancel'
            for tab in tabs:
                send(tab, text='Write a 1200-word explanation of how to check this page total. Use only the supplied page and no tools.')
            until = time.monotonic() + 5
            while time.monotonic() < until:
                states = [call('ask', id=tab) for tab in tabs]
                if sum(state['queued'] for state in states) == 1:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('Did not observe two active chats and one queued chat')
            queued = next(tab for tab, state in zip(tabs, states) if state['queued'])
            call('ask', id=queued, action='stop')
            finish([queued], timeout=5)
            time.sleep(0.75)  # allow the sampler to observe the two active processes
            until = time.monotonic() + 30
            while time.monotonic() < until:
                streaming = [call('ask', id=tab) for tab in tabs if tab != queued]
                if any(state['working'] and state['turns'][-1]['text'] for state in streaming):
                    summary['streaming_before_completion'] = True
                    break
                if not any(state['working'] for state in streaming):
                    raise RuntimeError('Long answers finished before streaming could be observed')
                time.sleep(0.1)
            else:
                raise RuntimeError('No incremental answer observed within 30 seconds')
            for tab in tabs:
                call('ask', id=tab, action='stop')
            finished = finish(tabs, timeout=10)
            if any(state['turns'][-1]['failed'] for state in finished):
                raise RuntimeError('Stopping a request incorrectly produced a failed answer')
            summary['scenarios'].append(dict(name=phase, queued_tab=queued, before=states, after=finished))
        phase = 'final-idle'; time.sleep(4)
    except Exception as error:
        summary['error'] = str(error)
    finally:
        if original_space is not None:
            try:
                call('space', action='go', index=original_space)
                wait_space(original_space_name)
            except Exception:
                pass
        try:
            for live in sessions():
                if live['chat'] in owned_chats:
                    call('ai-sessions', action='kill', chat=live['chat'])
            wait_until(lambda: not any(live['chat'] in owned_chats for live in sessions()), 'final session cleanup')
        except Exception as error:
            summary.setdefault('cleanup_error', str(error))
        for tab in tabs:
            try:
                call('ask', id=tab, action='stop')
                call('close', id=tab)
            except Exception:
                pass
        if other_space is not None:
            try:
                spaces = call('space')['spaces']
                other_index = next(index for index, item in enumerate(spaces, 1) if item['id'] == other_space)
                call('space', action='go', index=other_index)
                wait_space('AI measurement other space')
                call('space', action='delete')
                call('ui', spaces=original_spaces_on)
            except Exception as error:
                summary.setdefault('cleanup_error', str(error))
        time.sleep(0.5)
        stopped.set(); thread.join(timeout=5)
        summary['sampler_error'] = sampler_error
        summary['requests'] = requests()
        summary['phases'] = {}
        previous_cpu = {}
        cpu_by_phase = {}
        for sample in samples:
            totals = cpu_by_phase.setdefault(sample['phase'], [0.0, 0.0])
            for process in sample['processes']:
                pid = process['pid']
                prior = previous_cpu.get(pid, process['cpu_s'] if pid == args.pid else 0.0)
                totals[pid != args.pid] += max(0.0, process['cpu_s'] - prior)
                previous_cpu[pid] = process['cpu_s']
        for name in dict.fromkeys(s['phase'] for s in samples):
            rows = [s for s in samples if s['phase'] == name]
            def rss(sample, cli):
                return sum(p['rss_kib'] for p in sample['processes'] if (p['pid'] != args.pid) == cli) / 1024
            summary['phases'][name] = dict(samples=len(rows),
                app_cpu_s=round(cpu_by_phase[name][0], 3), cli_tree_cpu_s=round(cpu_by_phase[name][1], 3),
                app_peak_rss_mib=max(rss(s, False) for s in rows),
                cli_tree_peak_rss_mib=max(rss(s, True) for s in rows),
                cli_tree_peak_processes=max(sum(p['pid'] != args.pid for p in s['processes']) for s in rows),
                cli_front_end_peak_processes=max(sum(p['pid'] in groups for p in s['processes']) for s in rows))
        if any(item['cli_front_end_peak_processes'] > 2 for item in summary['phases'].values()):
            summary.setdefault('error', 'More than two CLI front ends were resident at once')
        latest = processes()
        summary['remaining_cli_pids'] = sorted(pid for pid in seen if pid != args.pid and pid in latest)
        if summary['remaining_cli_pids'] and 'error' not in summary:
            summary['error'] = 'CLI helpers remained alive after explicit session cleanup'
        (out / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps({key: summary[key] for key in ('phases', 'remaining_cli_pids', 'sampler_error')}, indent=2))
        if summary.get('error'):
            raise SystemExit(summary['error'])

if __name__ == '__main__':
    main()
