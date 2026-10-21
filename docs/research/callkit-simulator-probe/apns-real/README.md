# Real APNs notes

## October 21, 2026: `mustReport` false, with no report

Real sandbox pushes went to a fresh iOS 27.0 simulator. The probe used the Phone VoIP topic and had `no-report` set, so it never reports to CallKit.

| Push | App state | `mustReport` | Result |
| --- | --- | --- | --- |
| E7 | Foreground (`applicationState` 0) | false | Not reported; the app stayed alive and finished its scenario. One send produced **two deliveries**, 469 ms apart (unexplained). |
| E8b | — | — | Accepted by APNs (HTTP 200) but not delivered within 12 s. The probe's 90 s timer fired after 183 s, so the process was apparently suspended. |
| E9 | Running app, backgrounded for 25 s (`applicationState` 2) | **false** | Not reported; the app stayed alive. |

On October 20, a backgrounded app got `mustReport` true (P1), so `applicationState` does not decide the value. Apple's header (`PKPushRegistry.h`, iOS 27.1 SDK) lists three cases for false:

- the app is in the foreground;
- the app already has an active call;
- delivery was late because of network conditions.

Apple recommends ignoring pushes with `mustReport` false that need no report. Traces: `2026-10-21-sim-ios27-mustreport-false-*.jsonl`. APNs responses: `2026-10-21-sim-ios27-mustreport-apns-responses.txt`.
