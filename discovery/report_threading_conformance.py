#!/usr/bin/env python3
"""Check actual incoming-report completion queues with bound runtime evidence."""
import json
from pathlib import Path
import sys

from conformance import bound_capture
from summarize import EvidenceError, INCOMING_ERROR, one, require


def validate(directory):
    rows, engine = bound_capture(directory, 'report-threading')
    launch = one(rows, 'launch')
    require(launch.get('injected') is True and launch.get('mode') == 'report-threading',
            'report-threading runtime not active')
    callbacks = [r for r in rows if r['event'] == 'report.incomingCompleted']
    labels = ['nil-success', 'nil-duplicate', 'custom-success', 'custom-duplicate']
    require([r.get('label') for r in callbacks] == labels, 'incoming completion inventory/order differs')
    require([r.get('result') for r in callbacks] == ['ok', INCOMING_ERROR + '2'] * 2,
            'incoming success/duplicate results differ')
    for row in callbacks:
        if row['label'].startswith('nil-'):
            require(row.get('main') is True, 'nil queue incoming completion delivered off main')
        else:
            require(row.get('main') is False and row.get('onQueue') == 'custom',
                    'configured delegate queue incoming completion mismatch')
    calls = [r.get('callUUID') for r in callbacks]
    require(all(isinstance(call, str) and call for call in calls) and
            calls[0] == calls[1] and calls[2] == calls[3] and calls[0] != calls[2],
            'incoming duplicate call identity differs')
    completed = [r for r in engine if r['event'] == 'report.completed']
    require([r.get('callUUID') for r in completed] == calls and
            [r.get('error') for r in completed] == [0, 2, 0, 2],
            'incoming completions do not match engine journal')
    return dict(success=True, completions=len(callbacks),
                assertions='nil queue main; custom delegate queue; success and duplicate error')


if __name__ == '__main__':
    try:
        result = validate(Path(sys.argv[1]))
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        result = dict(success=False, error=str(error))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['success'] else 1)
