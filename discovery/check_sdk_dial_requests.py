#!/usr/bin/env python3
"""Offline negative controls for direct public dial-request delivery."""
import copy
import hashlib
import unittest

import sdk_dial_requests as gate
from summarize import EvidenceError


def fixture():
    values = [('app.entry', {}), ('launch', dict(mode='sdk-m3', case='direct', traceVersion=2)),
              ('sdk.activation', dict(active=True)), ('sdk.managerCreated', dict(owner='VoIPApplication.start')),
              ('sdk.snapshot', dict(conversations=[])), ('m3.ready', {})]
    for kind, handle, video, method in [('url', '+15555550142', False, gate.URL_METHOD),
                                       ('intent', '+15555550143', True, gate.INTENT_METHOD)]:
        values += [('m3.delivery', dict(kind=kind, method=method)), ('m3.returned', dict(kind=kind, handled=True)),
                   ('m3.dialRequest', dict(handleSHA256=hashlib.sha256(handle.encode()).hexdigest(), video=video, conversationCount=0))]
    values += [('sdk.result', dict(success=True)), ('done', {})]
    return [dict(event=event, sequence=i, t_ms=i, **fields) for i, (event, fields) in enumerate(values, 1)]


class DialControls(unittest.TestCase):
    def test_exact_pair_qualifies(self):
        self.assertEqual(gate.qualify(fixture(), []), dict(success=True, delivery='direct-url-and-intent', publicDialRequests=2))

    def test_missing_duplicate_reordered_or_foreign_delivery_fails(self):
        for event in ('m3.ready', 'm3.delivery', 'm3.returned', 'm3.dialRequest', 'sdk.result'):
            for duplicate in (False, True):
                rows = fixture(); row = next(r for r in rows if r['event'] == event)
                if duplicate: rows.append(copy.deepcopy(row))
                else: rows.remove(row)
                with self.subTest(event=event, duplicate=duplicate), self.assertRaises(EvidenceError): gate.qualify(rows, [])
        for event, key, value in [('launch', 'mode', 'sdk-m1'), ('m3.delivery', 'method', 'private-router'),
                ('m3.returned', 'handled', 1), ('m3.dialRequest', 'handleSHA256', 'foreign'),
                ('m3.dialRequest', 'video', 0), ('m3.dialRequest', 'conversationCount', False),
                ('sdk.snapshot', 'conversations', [{}]), ('sdk.result', 'success', False)]:
            rows = fixture(); next(r for r in rows if r['event'] == event)[key] = value
            with self.subTest(event=event, key=key), self.assertRaises(EvidenceError): gate.qualify(rows, [])

    def test_automatic_calls_or_errors_cannot_qualify(self):
        for event in ('report.incoming', 'transaction.delivered', 'action.settled'):
            with self.subTest(event=event), self.assertRaises(EvidenceError): gate.qualify(fixture(), [dict(event=event)])
        rows = fixture(); rows[-1]['errorType'] = 'failure'
        with self.assertRaises(EvidenceError): gate.qualify(rows, [])


if __name__ == '__main__': unittest.main()
