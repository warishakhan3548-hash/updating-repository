"""Disposable HTTPS/WS phone fixture for inspecting the deployed AI link UI.

Uses synthetic pixels and action results, not an Android device or real apps.
Requires Pillow and websockets. The capability is written only to a mode-0600
state file; the session is revoked and that file removed on exit.
"""
import argparse
import asyncio
import base64
import io
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid

from PIL import Image, ImageDraw, ImageFont
import websockets


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-file', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=600)
    args = parser.parse_args()
    base = 'https://aaris-remote-ice.aaris-remote-wk3548.workers.dev'

    def call(path, token=None, data=None):
        headers = {'Content-Type': 'application/json', 'User-Agent': 'Aaris-AI-Link-UI-Test/1.0'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(base + path, headers=headers,
            data=None if data is None else json.dumps(data).encode())
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)

    session = await asyncio.to_thread(call, '/v1/browser-sessions', data={})
    sid, host = session['sessionId'], session['hostToken']
    route = '/v1/sessions/' + sid
    nonce = str(uuid.uuid4())
    version, scene, action_count = 0, 'Home', 0
    last_action = None
    try:
        font = ImageFont.truetype('DejaVuSans.ttf', 18)
        small = ImageFont.truetype('DejaVuSans.ttf', 13)
    except OSError:
        font = small = ImageFont.load_default()

    def observe():
        nonlocal version
        version += 1
        image = Image.new('RGB', (360, 720), '#142435')
        draw = ImageDraw.Draw(image)
        draw.text((18, 22), 'SYNTHETIC TEST PHONE', font=font, fill='#a1d4ff')
        draw.text((18, 56), 'UI/control test; no physical device', font=small, fill='white')
        draw.text((18, 105), scene, font=font, fill='white')
        hints = []
        if scene == 'Home':
            for label, rect in [('WhatsApp (test)', (36, 210, 324, 290)), ('Gallery (test)', (36, 320, 324, 400))]:
                draw.rounded_rectangle(rect, radius=12, fill='#237e66')
                draw.text((rect[0]+18, rect[1]+28), label, font=font, fill='white')
                hints.append({'text': label, 'role': 'Button', 'clickable': True, 'enabled': True,
                    'bounds': [x * 3 for x in rect]})
        else:
            draw.rounded_rectangle((36, 210, 324, 460), radius=12, fill='#204860')
            draw.text((54, 246), 'Simulated app screen', font=font, fill='white')
            draw.text((54, 294), 'Tap anywhere or press Home', font=small, fill='white')
        draw.text((18, 560), f'Applied actions: {action_count}', font=font, fill='#8ce7c0')
        if last_action:
            draw.text((18, 605), str(last_action)[:44], font=small, fill='white')
        draw.text((18, 674), 'Back             Home             Recents', font=small, fill='#b7c9db')
        raw = io.BytesIO()
        image.save(raw, 'JPEG', quality=90)
        return {'observationId': str(uuid.uuid4()), 'screenVersion': version, 'commandNonce': nonce,
            'currentPackage': 'synthetic.test.phone', 'display': {'width': 1080, 'height': 2160,
                'coordinateSpace': 'full-upright-display-normalized-0-to-1'}, 'uiHints': hints,
            'image': {'mimeType': 'image/jpeg', 'width': 360, 'height': 720,
                'data': base64.b64encode(raw.getvalue()).decode()}, 'redacted': False,
            'note': 'Disposable synthetic phone fixture. Results do not establish Android performance.'}

    url = base + '/remote/?session=' + sid + '&access=' + session['controllerToken'] + '&client=' + session['browserClientId']
    state = {'url': url, 'actions': [], 'scene': scene}

    def save():
        args.state_file.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(args.state_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream)

    try:
        await asyncio.to_thread(call, route + '/state', host, {'target': 'SCREEN_READY'})
        async with websockets.connect(base.replace('https:', 'wss:') + route + '/agent-socket',
                additional_headers={'Authorization': 'Bearer ' + host}, open_timeout=20,
                close_timeout=3) as socket:
            current = observe()
            await asyncio.to_thread(call, route + '/agent-publish', host, {'result': current})
            await asyncio.to_thread(call, route + '/state', host, {'target': 'LIVE'})
            save()
            print('Synthetic phone connected. Private state file ready.', flush=True)
            deadline = time.monotonic() + max(1, min(args.seconds, 1800))
            while time.monotonic() < deadline:
                try:
                    incoming = await asyncio.wait_for(socket.recv(), min(15, deadline-time.monotonic()))
                except asyncio.TimeoutError:
                    await socket.send('ping')
                    continue
                if incoming == 'pong':
                    continue
                message = json.loads(incoming)
                if message.get('kind') == 'session' and message.get('session', {}).get('state') == 'CLOSED':
                    break
                if message.get('kind') != 'agent_request':
                    continue
                request_id = message['requestId']
                try:
                    await asyncio.to_thread(call, route + '/agent-start', host, {'requestId': request_id})
                except urllib.error.HTTPError:
                    continue
                if message['operation'] == 'observe':
                    current = observe()
                    result = current
                else:
                    command = message['args']
                    applied = command.get('nonce') == nonce and command.get('observationId') == current['observationId'] and command.get('screenVersion') == current['screenVersion']
                    if applied:
                        action_count += 1
                        action = command['action']
                        last_action = action
                        if action in ('home', 'back'):
                            scene = 'Home'
                        elif action == 'tap':
                            x, y = command['x'] * 360, command['y'] * 720
                            last_action = f'Tap x={command["x"]:.3f} y={command["y"]:.3f}'
                            if scene == 'Home' and 36 <= x <= 324:
                                if 210 <= y <= 290:
                                    scene = 'WhatsApp (test)'
                                elif 320 <= y <= 400:
                                    scene = 'Gallery (test)'
                        state['actions'].append({k: command[k] for k in ('action', 'x', 'y') if k in command})
                        state['scene'] = scene
                        current = observe()
                        save()
                    result = {**current, 'actionId': command['actionId'], 'applied': applied}
                    if not applied:
                        result['error'] = 'STALE_SCREEN'
                try:
                    await asyncio.to_thread(call, route + '/agent-publish', host,
                        {'result': result, 'requestId': request_id})
                except urllib.error.HTTPError as error:
                    if error.code != 409:
                        raise
                    failure = json.loads(error.read())
                    if failure.get('error') != 'REQUEST_EXPIRED_OR_USED':
                        raise
                    print('Expired/replaced fixture request fenced; awaiting a new observation.', flush=True)
    finally:
        try:
            await asyncio.to_thread(call, route + '/close', host, {})
        finally:
            args.state_file.unlink(missing_ok=True)
        print('Synthetic session revoked.', flush=True)


if __name__ == '__main__':
    asyncio.run(main())
