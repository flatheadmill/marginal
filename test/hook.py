#!/usr/bin/env python3
"""Exercise the actual hook entry point with dummy Secrets and a fake kubectl."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CANARY = 'MARGINAL_DUMMY_PRIVATE_KEY_CANARY_20260912'
RECIPE = {'metadata': {'name': 'reload', 'namespace': 'marginal', 'uid': 'recipe-uid'}, 'spec': {
    'apiVersion': 'v1', 'kind': 'Secret',
    'jobTemplates': [{'name': name, 'executeHookOnEvent': ['Added', 'Modified'],
                     'uniqueKey': '.data.private_key', 'env': '{}',
                     'spec': {'template': {'spec': {'containers': [{'name': 'test', 'image': 'fixture'}]}}}}
                    for name in ['first', 'second']]}}


def secret(name):
    return {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {
        'name': name, 'namespace': 'certificates', 'uid': name, 'resourceVersion': '17',
        'annotations': {'embedded': CANARY}}, 'data': {'private_key': CANARY}}


def event(obj, binding='reload'):
    return {'type': 'Event', 'binding': binding, 'watchEvent': 'Modified', 'object': obj}


def complete_job(conditions, succeeded=1):
    return {'apiVersion': 'batch/v1', 'kind': 'Job', 'metadata': {'name': 'job', 'namespace': 'marginal',
        'annotations': {'marginal.flatheadmill.com/origin-kind': 'Secret',
                        'marginal.flatheadmill.com/origin-namespace': 'certificates',
                        'marginal.flatheadmill.com/origin-name': 'first',
                        'marginal.flatheadmill.com/completed-key': 'marginal.flatheadmill.com/reload-first',
                        'marginal.flatheadmill.com/completed-value': 'job'}},
        'spec': {'completions': 3}, 'status': {'succeeded': succeeded, 'conditions': conditions}}


with tempfile.TemporaryDirectory(prefix='marginal-hook-test-') as directory:
    tmp = Path(directory)
    fake = tmp / 'kubectl'
    fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['MARGINAL_TEST_DIR'])
args=sys.argv[1:]
mode=os.environ['MARGINAL_TEST_MODE']
calls=root/'calls.json'
history=json.loads(calls.read_text()) if calls.exists() else []
history.append(args)
calls.write_text(json.dumps(history))
if 'marginaljobs.marginal.flatheadmill.com' in args:
    if mode == 'config-error': sys.exit(1)
    print((root/'recipes.json').read_text())
elif 'job' in args and 'get' in args:
    count=sum('job' in call and 'get' in call for call in history)
    if mode == 'lookup-error' and count == 1: sys.exit(1)
    if mode == 'create-error': sys.exit(0)
    if mode == 'partial-failed':
        print(json.dumps({'spec':{'completions':3},'status':{'succeeded':1,'conditions':[{'type':'Failed','status':'True'}]}}))
    elif mode == 'scheduler-completion-error':
        print(json.dumps({'status':{'conditions':[{'type':'Complete','status':'True'}]}}))
    else: print(json.dumps({'status':{'active':1}}))
elif args[0] == 'get':
    if mode != 'deleted-origin': print('secret/first')
elif args[0] == 'apply':
    sys.stdin.read()
    sys.exit(1)
elif args[0] == 'annotate':
    if mode in ['annotation-error','scheduler-completion-error']: sys.exit(1)
else:
    print('unexpected kubectl call',file=sys.stderr)
    sys.exit(99)
''')
    fake.chmod(0o755)
    (tmp / 'recipes.json').write_text(json.dumps({'items': [RECIPE]}))

    def run(label, contexts, mode='active', succeeds=True, annotations=0, debug=False, config=False):
        (tmp / 'context.json').write_text(json.dumps(contexts))
        (tmp / 'calls.json').unlink(missing_ok=True)
        env = dict(os.environ, PATH=str(tmp)+os.pathsep+os.environ['PATH'],
                   BINDING_CONTEXT_PATH=str(tmp/'context.json'), MARGINAL_TEST_DIR=str(tmp),
                   MARGINAL_TEST_MODE=mode, MARGINAL_DUMP_BINDING='1' if debug else '0')
        result = subprocess.run(['zshctl', str(ROOT/'hooks'/'hook'), *(['--config'] if config else [])],
                                env=env, capture_output=True, text=True)
        assert CANARY not in result.stdout + result.stderr, f'{label}: Secret canary leaked'
        assert (result.returncode == 0) == succeeds, f'{label}: unexpected exit {result.returncode}: {result.stderr}'
        history = json.loads((tmp/'calls.json').read_text()) if (tmp/'calls.json').exists() else []
        assert sum(call[0] == 'annotate' for call in history) == annotations, f'{label}: unexpected annotation calls'
        if config and succeeds:
            assert 'allowFailure: true' not in result.stdout, 'controller errors must remain retryable'
        print('ok - '+label)

    contexts = [event(secret('first')), event(secret('second'))]
    run('batched Secret events and multiple templates never log values', contexts)
    run('debug binding output contains identities only', contexts, debug=True)
    run('failed lookup survives a later successful event', contexts, mode='lookup-error', succeeds=False)
    run('Job creation failure reaches controller retry', contexts, mode='create-error', succeeds=False)
    run('synchronization aggregates object failures', [
        {'type': 'Synchronization', 'binding': 'reload', 'objects': [{'object': secret('first')}, {'object': secret('second')}]}],
        mode='lookup-error', succeeds=False)
    run('partially successful failed Job is not completed by scheduler', contexts, mode='partial-failed')
    run('scheduler completion write failure remains retryable', [event(secret('first'))], mode='scheduler-completion-error', succeeds=False, annotations=1)
    partial = complete_job([{'type': 'Failed', 'status': 'True'}])
    run('one successful Pod does not complete a failed Job', [event(partial, 'marginal-managed-jobs')])
    run('one successful Pod does not complete an active Job', [event(complete_job([]), 'marginal-managed-jobs')])
    complete = complete_job([{'type': 'Complete', 'status': 'True'}], succeeded=3)
    run('terminal Complete condition records completion', [event(complete, 'marginal-managed-jobs')], annotations=1)
    run('completion error survives a later successful event', [event(complete, 'marginal-managed-jobs'), event(secret('last'))],
        mode='annotation-error', succeeds=False, annotations=1)
    run('deleted origin does not create a permanent retry', [event(complete, 'marginal-managed-jobs')], mode='deleted-origin')
    run('configuration API failure is not treated as zero recipes', [], mode='config-error', succeeds=False, config=True)
    run('event bindings retain failures for exponential retry', [], config=True)
