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
                action=None, outcome=None, matches=None, evidence=None, evidenceTarget=None,
                proposedGoal=None, crop=None, mark=None, label=None,
                detail=None, value=None, ghost=None, milestone=None, plan=None,
                goalChecks=None, outcomeState=None, warning=None)


def response(result: dict, schema: dict) -> dict:
    variants = schema['properties']['presentation']['anyOf']
    variant = next((item for item in variants if result['kind'] in item['properties']['kind']['enum']), None)
    if variant is None:
        return {'presentation': {'kind': result['kind'], 'text': result['text']}}
    fields = variant['properties']
    return {'presentation': {key: value for key, value in result.items() if key in fields or value is not None}}


def answer(prompt: str, number: int) -> dict:
    request = json.loads(prompt)
    prompt = request['text']
    if request['purpose'] == 'verification':
        assert request['allowedKinds'] == ['verification_result']
        assert 'host decides advancement' in request['responseContract']
    if prompt.startswith('verification-'):
        result = presentation('Fixture verification')
        result.update(kind='verification_result', captureID=request['capture']['captureID'],
                      matches=prompt == 'verification-true', evidence='Fixture panel observation',
                      evidenceTarget=dict(x=0, y=0, width=1, height=1),
                      outcomeState='confirmed' if prompt == 'verification-true' else 'contradicted')
        return result
    if prompt == 'wrong-purpose':
        return presentation('Wrong fixture kind')
    if prompt in ['valid-step', 'missing-outcome', 'null-outcome']:
        result = presentation('Click the fixture panel')
        result.update(kind='guide_step', captureID=request['capture']['captureID'],
                      target=dict(x=0, y=0, width=1, height=1),
                      action=dict(kind='click', keyCode=None, modifiers=None),
                      outcome=dict(description='Fixture panel opens', axRole=None, axTitle=None, axValue=None),
                      milestone='Open the fixture panel', plan=['Open the fixture panel'],
                      goalChecks=['Fixture panel is open'])
        if prompt == 'missing-outcome':
            del result['outcome']
        if prompt == 'null-outcome':
            result['outcome'] = None
        return result
    if prompt == 'hang':
        time.sleep(30)
    if prompt == 'exit':
        sys.exit(7)
    result = presentation(f'turn {number}: {prompt}')
    if prompt == 'bad-schema':
        result['shell'] = 'must never run'
    return result


def config() -> dict:
    return dict(model='gpt-6-luna', model_reasoning_effort='low', project_doc_max_bytes=0,
                project_doc_fallback_filenames=[], web_search='disabled', sandbox_mode='read-only',
                approvals_reviewer='user', analytics=dict(enabled=False), feedback=dict(enabled=False),
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
        schema = json.loads(sys.argv[sys.argv.index('--json-schema') + 1])
        step = next(item for item in schema['properties']['presentation']['anyOf']
                    if item['properties']['kind']['enum'] == ['guide_step'])
        assert step['properties']['outcome']['type'] == 'object' and 'outcome' in step['required']
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
                emit(dict(type='result', is_error=False, structured_output=response(presentation('stale'), schema),
                          user_message_uuid=previous_uuid))
            emit(dict(type='result', is_error=False, structured_output=response(result, schema), user_message_uuid=message['uuid']))
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
        elif method == 'experimentalFeature/list':
            emit(dict(id=identifier, result={'data': [dict(name=name, enabled=enabled, stage='stable')
                      for name, enabled in config()['features'].items()], 'nextCursor': None}))
        elif method == 'turn/start':
            number += 1
            params = message['params']
            assert 'outputSchema' in params
            assert params['model'] == 'gpt-6-luna' and params['effort'] == 'low'
            prompt = params['input'][0]['text']
            schema = params['outputSchema']
            assert [item['properties']['kind']['enum'][0] for item in schema['properties']['presentation']['anyOf']] == json.loads(prompt)['allowedKinds']
            result = answer(prompt, number)
            turn = 'turn-' + str(number)
            emit(dict(id=identifier, result={'turn': {'id': turn}}))
            if json.loads(prompt)['text'] == 'stale-reply':
                emit(dict(method='item/agentMessage/delta', params={'threadId': 'guide-codex',
                          'turnId': 'turn-' + str(number - 1), 'delta': json.dumps(response(presentation('stale'), schema))}))
                emit(dict(method='turn/completed', params={'threadId': 'guide-codex',
                          'turn': {'id': 'turn-' + str(number - 1), 'status': 'completed'}}))
            emit(dict(method='item/agentMessage/delta', params={'threadId': 'guide-codex', 'turnId': turn, 'delta': json.dumps(response(result, schema))}))
            emit(dict(method='turn/completed', params={'threadId': 'guide-codex', 'turn': {'id': turn, 'status': 'completed'}}))


if __name__ == '__main__':
    run()
