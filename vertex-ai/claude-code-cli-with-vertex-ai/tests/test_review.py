import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import claude_code_bridge as bridge
import vertex_review as review


class ReviewTests(unittest.TestCase):
    def test_vertex_environment_excludes_other_auth_and_endpoints(self):
        with patch.dict('os.environ', {'ANTHROPIC_API_KEY': 'fake',
                                      'ANTHROPIC_BASE_URL': 'https://example.invalid',
                                      'GOOGLE_APPLICATION_CREDENTIALS': '/wrong.json'}):
            env = review.child_environment('/tmp/isolated')
        self.assertEqual(env['CLAUDE_CODE_USE_VERTEX'], '1')
        for key in ('ANTHROPIC_VERTEX_PROJECT_ID', 'GOOGLE_CLOUD_PROJECT', 'GCLOUD_PROJECT'):
            self.assertEqual(env[key], review.PROJECT)
        for key in ('ANTHROPIC_API_KEY', 'ANTHROPIC_BASE_URL', 'GOOGLE_APPLICATION_CREDENTIALS',
                    'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK'):
            self.assertNotIn(key, env)

    def test_review_bounds_tools_and_cleans_workspace(self):
        result = {'text': 'Finding', 'usage': {'input_tokens': 10}, 'cost_usd': .1,
                  'tool_names': ['Read'], 'model_usage': {}}
        with tempfile.TemporaryDirectory() as td, patch.object(review, 'WORK_ROOT', Path(td)), \
                patch.object(review, 'run_blocking', return_value=result) as run:
            actual = review.review('Review the code', 'line 1')
            cfg = run.call_args.args[0]
            command = bridge.build_command(cfg, review.MODEL, 'task', 'system', 'json')
            self.assertIn('--restricted', command)
            self.assertIn('--bare', command)
            self.assertEqual(command[command.index('--tools') + 1], 'Read,Grep,Glob')
            self.assertEqual(cfg.permission_mode, 'dontAsk')
            self.assertEqual(cfg.timeout_seconds, 120)
            self.assertEqual(actual['native_tools_used'], ['Read'])
            self.assertEqual(list(Path(td).iterdir()), [])

    def test_rejects_oversize_or_empty_inputs(self):
        for task, evidence in [('', 'data'), ('task', ''), ('task', 'x' * 60001)]:
            with self.subTest(task=task):
                with self.assertRaises(ValueError): review.review(task, evidence)

    def test_concurrency_limit(self):
        review._slots.acquire()
        try:
            with self.assertRaises(RuntimeError): review.review('task', 'data')
        finally:
            review._slots.release()

    def test_invalid_or_error_cli_result_is_not_success(self):
        cfg = bridge.BridgeConfig(bridge.build_parser().parse_args([]))
        for body in ['not json', '{}', json.dumps({'type':'result', 'is_error':True}),
                     json.dumps({'type':'result', 'subtype':'error_max_turns'})]:
            proc = Mock(returncode=0)
            proc.communicate.return_value = (body, '')
            with patch.object(bridge, '_popen', return_value=proc):
                with self.assertRaises(bridge.ClaudeError):
                    bridge.run_blocking(cfg, 'model', 'task', 'system')

    def test_native_events_and_cached_usage_are_preserved(self):
        events = [{'type':'assistant', 'message':{'content':[{'type':'tool_use','name':'Read'}]}},
                  {'type':'result', 'subtype':'success', 'result':'Reviewed',
                   'usage':{'input_tokens':2,'cache_read_input_tokens':100}, 'total_cost_usd':.05}]
        proc = Mock(returncode=0)
        proc.communicate.return_value = (json.dumps(events), '')
        cfg = bridge.BridgeConfig(bridge.build_parser().parse_args([]))
        with patch.object(bridge, '_popen', return_value=proc):
            result = bridge.run_blocking(cfg, 'model', 'task', 'system')
        self.assertEqual(result['tool_names'], ['Read'])
        self.assertEqual(result['usage']['cache_read_input_tokens'], 100)

    def test_timeout_kills_process_group(self):
        proc = Mock()
        proc.communicate.side_effect = subprocess.TimeoutExpired('claude', 120)
        cfg = bridge.BridgeConfig(bridge.build_parser().parse_args([]))
        with patch.object(bridge, '_popen', return_value=proc), patch.object(bridge, '_kill') as kill:
            with self.assertRaises(bridge.ClaudeError):
                bridge.run_blocking(cfg, 'model', 'task', 'system')
            kill.assert_called_once_with(proc)


if __name__ == '__main__':
    unittest.main()
