// The pinned goldfish images attach a speaker. Add an earpiece on the same virtual output.
export function withEarpiece(policy: string) {
  const speaker = '<item>Speaker</item>';
  const port = /<devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink"\s*(?:\/>|>\s*<\/devicePort>)/u;
  const route = /<route type="mix" sink="Speaker"\s+sources="primary output"\s*\/>/u;
  if (!policy.includes(speaker) || !port.test(policy) || !route.test(policy)) {
    throw new Error('The emulator audio policy is missing the primary speaker');
  }
  if (policy.includes('<item>Earpiece</item>')) return policy;
  return policy
    .replace(speaker, speaker + '\n        <item>Earpiece</item>')
    .replace(port, match => match + '\n        <devicePort tagName="Earpiece" type="AUDIO_DEVICE_OUT_EARPIECE" role="sink"/>')
    .replace(route, match => match + '\n        <route type="mix" sink="Earpiece" sources="primary output"/>');
}
