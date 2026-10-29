# Real-device APNs probe

This target builds the discovery probe under its own `dev.callkitsim.probe`
identity with **development APNs entitlements**. The historical research target
did not request `aps-environment`; its previous device profile therefore could
not produce a PushKit token. Do not substitute a production Phone bundle ID.

Generate the ignored Xcode project with XcodeGen:

```sh
xcodegen generate --spec discovery/device/project.yml
```

Build the `Probe` scheme for the dedicated test device with automatic signing
and provisioning updates. Use existing approved Apple signing credentials;
keep any App Store Connect API key outside the checkout and build output.
Inspect the embedded provisioning profile and confirm
`aps-environment=development` before installation.

Launch with `PROBE_MODE=push`, `PROBE_PUSH_REPORT=report` and a suitable
`PROBE_PUSH_WAIT` (seconds). `PROBE_PUSH_REPORT=none` deliberately omits a report
and belongs only in a reporting-obligation experiment. The token is written to
the probe's private `Documents/voip-token.txt`, never to its trace. Retrieve it
after a fresh launch; do not rely on a token from another app or installation.

The canonical sandbox APNs authentication key is the APNs sandbox key in your secrets manager. Its metadata records the key
ID, team ID and scope. The Sign in with Apple and App Store Connect `.p8` keys
are different credentials and cannot substitute for this key.

The local operator projection is `.env/apns-sandbox.env`; it selects a private
key file, key ID, team ID and explicit sandbox environment. Keep the directory
mode `0700` and its contents `0600`. No token or key belongs in source control,
an app bundle, logs, screenshots or CI artifacts.

```sh
source .env/apns-sandbox.env
node discovery/send-apns.mjs --check-key
node discovery/send-apns.mjs \
  --token-file /private/path/current-voip-token.txt \
  --payload-file /private/path/payload.json \
  --topic dev.callkitsim.probe.voip \
  --receipt-file /private/path/new-receipt.json
```

The JSON payload must contain an `aps` dictionary. For this probe, `from` may
hold a fictional phone number. The sender targets sandbox only, sends once,
reserves the receipt file before sending and redacts credentials, tokens and
payloads. A transport failure records the request ID and an **unknown outcome**;
reconcile before retrying. HTTP 200 means APNs accepted the request. Confirm
delivery separately in the current app launch's `push.received` event.

The repository's **apns-sandbox-device-qa** GitHub Environment holds a replaceable
key projection, requires operator review and permits only `main` and
`feat/runtime-engine`. The credential-check workflow only verifies retrieval
and local ES256 signing; it does **not** send pushes or prove APNs delivery.
No APNs secret is exposed by pull-request CI.

Apple references: [APNs token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns),
[key creation and scope](https://developer.apple.com/help/account/keys/create-a-private-key/),
[push registration and entitlements](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).
