#!/usr/bin/env python3
"""Offline persistent guide transport fixture; no model or network requests."""
import json
import os
import sys
import time


def emit(message: dict) -> None:
    data = (json.dumps(message, ensure_ascii=False) + '\n').encode()
    for offset in range(0, len(data), 11):
        sys.stdout.buffer.write(data[offset:offset + 11])
        sys.stdout.buffer.flush()


def presentation(text: str) -> dict:
    return dict(kind='explanation', text=text, captureID=None, target=None,
                action=None, outcome=None, matches=None, evidence=None,
                proposedGoal=None, crop=None)


def answer(prompt: str, number: int) -> dict:
    prompt = json.loads(prompt)['text']
    if prompt == 'hang':
        time.sleep(30)
    if prompt == 'exit':
        sys.exit(7)
    result = presentation(f'turn {number}: {prompt}')
    if prompt == 'bad-schema':
        result['shell'] = 'must never run'
    return result


def config() -> dict:
    return dict(model='gpt-6-luna', model_reasoning_effort='low', project_doc_max_bytes=0, web_search='disabled',
                memories=dict(use_memories=False, generate_memories=False),
                features={**{key: False for key in
                    ['apps', 'plugins', 'hooks', 'multi_agent', 'multi_agent_v2',
                     'shell_tool', 'unified_exec', 'memories', 'image_generation',
                     'in_app_browser', 'in_app_local_automation', 'view_image', 'browser_use',
                     'browser_use_external', 'browser_use_full_cdp_access', 'computer_use', 'code_mode',
                     'code_mode_host', 'remote_plugin', 'workspace_dependencies', 'goals', 'sleep_tool',
                     'context_management', 'tool_suggest', 'shell_snapshot', 'skill_search', 'skill_mcp_dependency_install']},
                    'skip_host_skill_discovery': True},
                mcp_servers={'inherited': {'command': 'must-not-start'}})


def run() -> None:
    number = 0
    previous_uuid = None
    claude = '--print' in sys.argv
    if claude:
        assert '--safe-mode' in sys.argv and '--no-session-persistence' in sys.argv
        assert sys.argv[sys.argv.index('--setting-sources') + 1] == ''
        assert sys.argv[sys.argv.index('--model') + 1] == 'claude-haiku-5-5'
        assert sys.argv[sys.argv.index('--effort') + 1] == 'low'
        emit(dict(type='system', subtype='init', model='claude-haiku-5-5', tools=[], mcp_servers=[], plugins=[], skills=[], session_id='guide-claude'))
    for line in sys.stdin:
        message = json.loads(line)
        if claude:
            if message.get('type') == 'control_request':
                subtype = message['request']['subtype']
                result = {} if subtype == 'initialize' else dict(effective=dict(autoMemoryEnabled=False,disableAllHooks=True,claudeMdExcludes=['**']),sources=[])
                emit(dict(type='control_response',response=dict(subtype='success',request_id=message['request_id'],response=result)))
                continue
            number += 1
            prompt = message['message']['content'][0]['text']
            result = answer(prompt, number)
            if json.loads(prompt)['text'] == 'stale-reply':
                emit(dict(type='result', is_error=False, structured_output=presentation('stale'),
                          user_message_uuid=previous_uuid))
            emit(dict(type='result', is_error=False, structured_output=result, user_message_uuid=message['uuid']))
            previous_uuid = message['uuid']
            continue
        identifier, method = message.get('id'), message.get('method')
        if method == 'initialize':
            emit(dict(id=identifier, result={}))
        elif method == 'account/read':
            assert os.environ.get('CODEX_HOME')
            emit(dict(id=identifier, result={'account': {'type': 'chatgpt'}}))
        elif method == 'config/read':
            emit(dict(id=identifier, result={'config': config()}))
        elif method == 'skills/list':
            emit(dict(id=identifier, result={'data': [{'skills': [{'path': '/fixture/personal-skill'}], 'errors': []}]}))
        elif method == 'thread/start':
            params = message['params']
            assert params['ephemeral'] and 'baseInstructions' in params
            assert params['model'] == 'gpt-6-luna'
            assert params['config']['mcp_servers']['inherited']['enabled'] is False
            assert params['config']['skills']['config'] == [{'path': '/fixture/personal-skill', 'enabled': False}]
            emit(dict(id=identifier, result={'thread': {'id': 'guide-codex', 'ephemeral': True}, 'instructionSources': []}))
        elif method == 'turn/start':
            number += 1
            params = message['params']
            assert 'outputSchema' in params
            assert params['model'] == 'gpt-6-luna' and params['effort'] == 'low'
            prompt = params['input'][0]['text']
            result = answer(prompt, number)
            turn = 'turn-' + str(number)
            emit(dict(id=identifier, result={'turn': {'id': turn}}))
            if json.loads(prompt)['text'] == 'stale-reply':
                emit(dict(method='item/agentMessage/delta', params={'threadId': 'guide-codex',
                          'turnId': 'turn-' + str(number - 1), 'delta': json.dumps(presentation('stale'))}))
                emit(dict(method='turn/completed', params={'threadId': 'guide-codex',
                          'turn': {'id': 'turn-' + str(number - 1), 'status': 'completed'}}))
            emit(dict(method='item/agentMessage/delta', params={'threadId': 'guide-codex', 'turnId': turn, 'delta': json.dumps(result)}))
            emit(dict(method='turn/completed', params={'threadId': 'guide-codex', 'turn': {'id': turn, 'status': 'completed'}}))


if __name__ == '__main__':
    run()
