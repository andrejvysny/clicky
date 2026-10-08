#!/usr/bin/env python3
"""Offline protocol fixture. Never starts a real agent or makes a network request."""
import json
import base64
import os
import sys
import time

def emit(message):
    data = (json.dumps(message, ensure_ascii=False) + '\n').encode()
    # Exercise framing across byte and Unicode boundaries.
    for offset in range(0, len(data), 7):
        sys.stdout.buffer.write(data[offset:offset + 7])
        sys.stdout.buffer.flush()

def result(identifier, value):
    emit({'id': identifier, 'result': value})

def image_result(prompt, content):
    if prompt != 'attachment-test':
        return prompt
    images = [block for block in content if block.get('type') == 'image']
    if not images:
        return 'no image'
    block = images[0]
    if 'source' in block:
        assert block['source']['media_type'] == 'image/png'
        data = base64.b64decode(block['source']['data'], validate=True)
    else:
        assert block['url'].startswith('data:image/png;base64,')
        data = base64.b64decode(block['url'].split(',', 1)[1], validate=True)
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    return f'image received: {len(data)} bytes'

if '--print' in sys.argv:
    content = json.loads(sys.stdin.readline())['message']['content']
    prompt = content[0]['text']
    answer = image_result(prompt, content)
    sys.stderr.write('fixture diagnostic\n' * 10_000)
    sys.stderr.flush()
    if prompt == 'hang':
        time.sleep(30)
    elif prompt == 'incomplete':
        sys.exit(0)
    elif prompt == 'fail':
        sys.exit(7)
    else:
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'claude-fixture'})
        emit({'type': 'stream_event', 'event': {'delta': {'type': 'text_delta', 'text': answer}}})
        emit({'type': 'result', 'is_error': False, 'result': answer, 'session_id': 'claude-fixture'})
else:
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get('method')
        if method == 'initialize':
            result(message['id'], {'userAgent': 'fixture'})
        elif method == 'account/read':
            result(message['id'], {'account': None if 'unauth' in os.path.basename(sys.argv[0]) else {'type': 'chatgpt'}})
        elif method == 'config/read':
            result(message['id'], {'config': {'mcp_servers': {'fixture-server': {'command': 'x'}}}})
        elif method in ('thread/start', 'thread/resume'):
            params = message['params']
            disabled = params.get('config', {}).get('mcp_servers', {}).get('fixture-server', {}).get('enabled') is False
            if params.get('approvalsReviewer') != 'user' or not disabled:
                emit({'id': message['id'], 'error': {'code': -32602, 'message': 'fixture: tools not disabled'}})
                continue
            result(message['id'], {'thread': {'id': message['params'].get('threadId', 'codex-fixture')}})
        elif method == 'turn/start':
            prompt = message['params']['input'][0]['text']
            answer = image_result(prompt, message['params']['input'])
            thread = message['params']['threadId']
            result(message['id'], {'turn': {'id': 'turn-fixture'}})
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': 'turn-fixture', 'delta': answer}})
            emit({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': 'turn-fixture', 'status': 'completed'}}})
