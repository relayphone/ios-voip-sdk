"""Exercise the shipping Inspector bridge context over real loopback HTTP."""
import json
import io
import http.server
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
import runpy
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen


CLI = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))


class BridgeContextTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.device = '00000001-1111-4111-8111-111111111111'
        self.container = Path(self.work.name) / self.device / 'data/Containers/Data/Application/00000002-1111-4111-8111-111111111111'
        self.root = self.container / 'Documents/.callkit-simulator'
        (self.root / 'run').mkdir(parents=True)
        self.session = dict(schemaVersion=1, runID='run', pid=123, bundleID='test.fixture',
                            profile='ios-27.0', controlTransport='directory-watch-v1')
        (self.root / 'session.json').write_text(json.dumps(self.session))
        self.row = dict(self.session, event='runtime.installed', sequence=1, t_ms=1, wallTimeMS=1000)
        (self.root / 'run/events.jsonl').write_text(json.dumps(self.row) + '\n')
        self.args = SimpleNamespace(bundle='test.fixture', app_container=self.container,
                                    runtime_dir=Path(self.work.name), timeout=1)
        self.control = Mock(return_value=dict(self.session, id='status', success=True, result={}))
        self.rpc = Mock(side_effect=AssertionError('A bridge context cannot manage simulator/app lifecycle'))

    def request(self, connection, path, body=None, authorized=True):
        environment = connection.launch_environment
        headers = {'Authorization': 'Bearer ' + environment['SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN']} if authorized else {}
        request = Request(environment['SIMCTL_CHILD_CKSIM_INSPECTOR_URL'] + path,
                          data=None if body is None else json.dumps(body).encode(), headers=headers)
        with urlopen(request, timeout=2) as response:
            return json.loads(response.read())

    def test_context_serves_pinned_events_without_any_app_lifecycle(self):
        factory = CLI['inspector_bridge']
        with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
            with factory(self.args, self.device) as connection:
                self.assertTrue(connection.is_alive())
                self.assertEqual(dict(connection.session), self.session)
                self.assertEqual(connection.target_container, self.container.resolve())
                self.assertEqual(self.request(connection, '/events?after=0'),
                                 dict(session=self.session, events=[self.row], cursor=1))
                arguments, device = self.control.call_args.args
                self.assertEqual((arguments.operation, arguments.app_container, device),
                                 ('status', self.container.resolve(), self.device))
                self.assertEqual(self.control.call_args.kwargs['expected_session'], self.session)
            self.assertFalse(connection.is_alive())
        self.rpc.assert_not_called()

    def test_authentication_commands_and_session_changes_keep_existing_contract(self):
        factory = CLI['inspector_bridge']
        with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
            with factory(self.args, self.device) as connection:
                with self.assertRaises(HTTPError) as error:
                    self.request(connection, '/events?after=0', authorized=False)
                self.assertEqual(error.exception.code, 401)
                call = '00000003-1111-4111-8111-111111111111'
                self.request(connection, '/command', dict(operation='answer', callUUID=call))
                arguments = self.control.call_args.args[0]
                self.assertEqual((arguments.operation, arguments.call), ('answer', call.lower()))
                self.assertEqual(self.control.call_args.kwargs['expected_session'], self.session)
                (self.root / 'session.json').write_text(json.dumps(dict(self.session, pid=999)))
                with self.assertRaises(HTTPError) as error:
                    self.request(connection, '/events?after=0')
                self.assertEqual(error.exception.code, 409)
                self.assertIn('session changed', error.exception.read().decode())
        self.rpc.assert_not_called()

    def test_connection_is_immutable_and_keeps_token_out_of_repr_and_logs(self):
        factory = CLI['inspector_bridge']
        output = io.StringIO()
        with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
            with redirect_stdout(output), redirect_stderr(output):
                with factory(self.args, self.device) as connection:
                    self.assertEqual(set(connection.launch_environment),
                        {'SIMCTL_CHILD_CKSIM_INSPECTOR_URL', 'SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN'})
                    token = connection.launch_environment['SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN']
                    with self.assertRaises(TypeError): connection.session['pid'] = 999
                    with self.assertRaises(TypeError): connection.launch_environment['other'] = 'value'
                    self.assertNotIn(token, repr(connection))
                    connection.wait(timeout=0.01)
                    self.assertTrue(connection.is_alive())
        self.assertNotIn(token, output.getvalue())

    def test_exception_stops_listener_and_server_thread(self):
        factory = CLI['inspector_bridge']
        with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
            with self.assertRaisesRegex(RuntimeError, 'consumer failed'):
                with factory(self.args, self.device) as connection:
                    environment = dict(connection.launch_environment)
                    raise RuntimeError('consumer failed')
            self.assertFalse(connection.is_alive())
            with self.assertRaises(OSError):
                urlopen(environment['SIMCTL_CHILD_CKSIM_INSPECTOR_URL'] + '/events', timeout=0.5)

    def test_failed_or_changed_status_never_yields_a_connection(self):
        factory = CLI['inspector_bridge']
        with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
            for success in (False, 1, 'true', None):
                self.control.return_value = dict(success=success)
                with self.subTest(success=success), self.assertRaisesRegex(RuntimeError, 'rejected inspector status'):
                    with factory(self.args, self.device): self.fail('failed status yielded a bridge')
            def restart(*args, **kwargs):
                (self.root / 'session.json').write_text(json.dumps(dict(self.session, pid=999)))
                return dict(success=True)
            self.control.side_effect = restart
            with self.assertRaisesRegex(RuntimeError, 'session changed'):
                with factory(self.args, self.device): self.fail('changed status yielded a bridge')
        self.rpc.assert_not_called()

    def test_cleanup_preserves_first_body_or_setup_failure_and_attempts_every_step(self):
        factory = CLI['inspector_bridge']
        for setup in (False, True):
            with self.subTest(setup=setup):
                original = ValueError('original failure')
                server = Mock(server_port=1234)
                server.shutdown.side_effect = RuntimeError('private-token shutdown')
                server.server_close.side_effect = RuntimeError('private-token close')
                worker = Mock(ident=1)
                worker.join.side_effect = RuntimeError('private-token join')
                worker.is_alive.side_effect = RuntimeError('private-token health')
                if setup: worker.start.side_effect = original
                output = io.StringIO()
                with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
                    with patch.object(http.server, 'ThreadingHTTPServer', return_value=server):
                        with patch.object(threading, 'Thread', return_value=worker), redirect_stderr(output):
                            with self.assertRaises(ValueError) as caught:
                                with factory(self.args, self.device): raise original
                self.assertIs(caught.exception, original)
                server.shutdown.assert_called_once()
                server.server_close.assert_called_once()
                worker.join.assert_called_once_with(timeout=5)
                worker.is_alive.assert_called_once()
                diagnostic = output.getvalue() + ' '.join(getattr(original, '__notes__', []))
                self.assertIn('cleanup', diagnostic)
                self.assertNotIn('private-token', diagnostic)

    def test_cleanup_failure_alone_fails_safely_after_attempting_remaining_steps(self):
        factory = CLI['inspector_bridge']
        server = Mock(server_port=1234)
        server.shutdown.side_effect = RuntimeError('private-token shutdown')
        server.server_close.side_effect = RuntimeError('private-token close')
        worker = Mock(ident=1)
        worker.is_alive.return_value = False
        with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
            with patch.object(http.server, 'ThreadingHTTPServer', return_value=server):
                with patch.object(threading, 'Thread', return_value=worker):
                    with self.assertRaisesRegex(RuntimeError, 'cleanup') as caught:
                        with factory(self.args, self.device): pass
        self.assertNotIn('private-token', str(caught.exception))
        server.server_close.assert_called_once()
        worker.join.assert_called_once_with(timeout=5)
        worker.is_alive.assert_called_once()

    def test_thread_start_failure_closes_the_bound_listener(self):
        factory = CLI['inspector_bridge']
        servers = []
        server_type = http.server.ThreadingHTTPServer
        def server(*args, **kwargs):
            result = server_type(*args, **kwargs)
            servers.append(result)
            return result
        try:
            with patch.dict(factory.__wrapped__.__globals__, control=self.control, simctl=self.rpc):
                with patch.object(http.server, 'ThreadingHTTPServer', side_effect=server):
                    with patch.object(threading.Thread, 'start', side_effect=RuntimeError('thread unavailable')):
                        with self.assertRaisesRegex(RuntimeError, 'thread unavailable'):
                            with factory(self.args, self.device): self.fail('thread failure yielded a bridge')
            self.assertEqual(servers[0].socket.fileno(), -1)
        finally:
            for bound in servers: bound.server_close()

    def test_cli_uses_context_and_keeps_one_bounded_launch_and_cleanup(self):
        operations = []
        class Connection:
            session = self.session
            launch_environment = dict(SIMCTL_CHILD_CKSIM_INSPECTOR_URL='http://127.0.0.1:1234',
                                      SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN='private-token')
            def wait(self):
                operations.append('wait')
                raise KeyboardInterrupt
        @contextmanager
        def bridge(args, device):
            operations.append('open')
            try: yield Connection()
            finally: operations.append('close')
        def simctl(operation, *args, **kwargs):
            operations.append(operation)
            if operation == 'list':
                return json.dumps(dict(devices={'runtime': [dict(udid=self.device, deviceTypeIdentifier='phone')]}))
            if operation == 'create': return 'owned-display'
            if operation == 'launch':
                self.assertEqual(kwargs['timeout'], 180)
                self.assertEqual(kwargs['env']['SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN'], 'private-token')
            if operation == 'bootstatus': self.assertEqual(kwargs['timeout'], 300)
        app = Path(self.work.name) / 'Inspector.app'
        app.mkdir()
        arguments = SimpleNamespace(**dict(vars(self.args), app=app, inspector_simulator=None))
        inspect_app = CLI['inspect_app']
        output = io.StringIO()
        with patch.dict(inspect_app.__globals__, inspector_bridge=bridge, simctl=simctl):
            with redirect_stdout(output), redirect_stderr(output): inspect_app(arguments, self.device)
        self.assertEqual(operations, ['open','list','create','boot','bootstatus','install','launch','wait','close','shutdown','delete'])
        self.assertNotIn('private-token', output.getvalue())

    def test_cli_shared_display_has_one_20_second_launch_and_no_owned_cleanup(self):
        connection = SimpleNamespace(session=self.session, launch_environment={})
        @contextmanager
        def bridge(args, device): yield connection
        def simctl(operation, *args, **kwargs):
            if operation == 'launch':
                self.assertEqual(kwargs['timeout'], 20)
                raise RuntimeError('launch timed out')
            self.assertEqual(operation, 'install')
        rpc = Mock(side_effect=simctl)
        app = Path(self.work.name) / 'Inspector.app'
        app.mkdir()
        args = SimpleNamespace(**dict(vars(self.args), app=app, inspector_simulator=self.device,
                                      allow_shared_simulator=True))
        inspect_app = CLI['inspect_app']
        with patch.dict(inspect_app.__globals__, inspector_bridge=bridge, simctl=rpc):
            with self.assertRaisesRegex(RuntimeError, 'launch timed out'):
                inspect_app(args, self.device)
        self.assertEqual([call.args[0] for call in rpc.call_args_list], ['install', 'launch'])


if __name__ == '__main__':
    unittest.main()
