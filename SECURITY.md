# Security policy

The SDK is under active development and has not reached beta. Security fixes are made on the current default branch; released versions may not include later fixes.

## Reporting a vulnerability

Please do not post exploit details, credentials, tokens or private call data in a public issue. Use the repository's **Security** tab and **Report a vulnerability** if private reporting is available. If it is not available, open an issue asking maintainers for a private reporting channel without including the vulnerability details. Include affected versions, reproduction steps, impact and any suggested mitigation in the private report. We will acknowledge and coordinate disclosure as maintainers are available; we cannot promise a response deadline.

## Credentials and call data

Treat VoIP push tokens as sensitive device identifiers. Do not include them in issues, logs shared publicly or test fixtures; redact them before sharing diagnostic output. APNs signing keys and credentials must stay in a secrets manager or protected local storage, never in source control. If a key or token is exposed, revoke or rotate the affected credentials using the relevant Apple and service-provider processes. Use synthetic caller identities and remove personal information from traces before sharing them.
