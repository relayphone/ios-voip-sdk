#!/bin/bash
# Sends one sandbox VoIP push to the probe's own simulator token. Prints status and apns-id only.
A="$(dirname "$0")"; LABEL="$1"; DATA="$(cat "$A/data-path.txt")"
TOKEN="$(cat "$DATA/Documents/voip-token.txt")"
CODE=$(curl -sS --http2 -o "$A/body-$LABEL.txt" -D "$A/hdr-$LABEL.txt" -w "%{http_code}" \
  --cert "$A/voip-cert.pem" --key "$A/voip-key" \
  -H "apns-push-type: voip" -H "apns-topic: com.ziahamza.phoneapp.voip" -H "apns-priority: 10" -H "apns-expiration: 0" \
  -d "{\"aps\":{},\"from\":\"+15555550142\",\"callId\":\"$LABEL\"}" \
  "https://api.sandbox.push.apple.com/3/device/$TOKEN")
echo "$(date +%H:%M:%S.%3N 2>/dev/null || date +%H:%M:%S) push $LABEL -> HTTP $CODE $(grep -i '^apns-id' "$A/hdr-$LABEL.txt" | tr -d '\r') $(cat "$A/body-$LABEL.txt")"
