import asyncio
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from hermes_adapter import Executor, BearerAuth, bounded_result
import native_provider as provider


class CombinedTests(unittest.TestCase):
    def setUp(self):
        self.registry = Mock()
        self.executor = Executor({'mcp_servers': {'test-readonly': {'tools': {'include': ['getItem']}}}}, self.registry)
        self.registry.get_entry.return_value = Mock(schema={'parameters': {'type': 'object',
            'properties': {'id': {'type': 'integer'}}, 'required': ['id']}})

    def test_recursion_and_external_writes_denied_before_dispatch(self):
        for name in ('delegate_task', 'terminal', 'tool_call', 'claude_code_review',
                     'mcp__test_readonly__createItem', 'mcp__test_readonly__getItem_extra'):
            self.assertTrue(self.executor.call(name, {})['denied'])
        self.registry.dispatch.assert_not_called()

    def test_exact_tool_arguments_and_errors_preserved(self):
        self.registry.dispatch.return_value = '{"error":"upstream unavailable"}'
        result = self.executor.call('mcp__test_readonly__getItem', {'id': 4})
        self.registry.dispatch.assert_called_once_with('mcp__test_readonly__getItem', {'id': 4})
        self.assertEqual(result['result']['error'], 'upstream unavailable')

    def test_invalid_schema_arguments_never_dispatch(self):
        self.assertIn('error', self.executor.call('mcp__test_readonly__getItem', {'id': 'wrong'}))
        self.registry.dispatch.assert_not_called()

    def test_truncation_is_explicit(self):
        self.assertTrue(bounded_result('x' * 40000)['truncated'])

    def test_gcp_scope_denial_before_dispatch(self):
        executor = Executor({'mcp_servers': {'gcp-trace': {'tools': {'include': ['list']}}}}, self.registry)
        for args in ({'projectId':'other-production-project'}, {'parent':'projects/other-staging-project'},
                     {'parent':'organizations/123'}):
            self.assertTrue(executor.call('mcp__gcp_trace__list', args)['denied'])
        self.registry.dispatch.assert_not_called()

    def test_auth_fails_closed(self):
        called, messages = [], []
        async def app(*args): called.append(True)
        async def send(item): messages.append(item)
        auth = BearerAuth(app, 'x' * 32)
        asyncio.run(auth({'type':'http','headers':[]}, None, send))
        self.assertFalse(called)
        self.assertEqual(messages[0]['status'], 401)

    def test_multimodal_and_oversize_fail_without_silent_loss(self):
        for content in ([{'type':'image_url','image_url':{'url':'data:test'}}], 'x' * 180001):
            with self.assertRaises(ValueError):
                provider.messages_to_prompt([{'role':'user','content':content}])

    def test_history_roles_are_preserved(self):
        prompt = provider.messages_to_prompt([{'role':'user','content':'Earlier'},
            {'role':'assistant','content':'Acknowledged'}, {'role':'user','content':'Now'}])
        self.assertIn('"role": "assistant"', prompt)
        self.assertLess(prompt.index('Earlier'), prompt.index('Now'))


if __name__ == '__main__':
    unittest.main()
