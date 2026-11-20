import { array, digit, integer, literal, nonempty, object, text, union, type Decoder } from "../calls/decode.ts";
import type { Performed } from "../calls/receipts.ts";
import type { AudioRoutesSnapshot } from "./transport.ts";

const audioRoute = object({
  id: text(),
  name: text(0, Number.MAX_SAFE_INTEGER),
  type: literal("builtInReceiver", "builtInSpeaker", "headphones", "bluetooth", "airPlay", "carAudio", "usbAudio", "other"),
});

export const audioRoutes: Decoder<AudioRoutesSnapshot> = object({
  revision: integer(),
  routes: array(audioRoute),
  current: union(audioRoute, raw => {
    if (raw !== null) throw new TypeError("Expected no current audio route");
    return null;
  }),
});

const toneDigits = nonempty(digit);
export const parseToneDigits = (digits: string) => toneDigits(Array.from(digits));

export type AndroidAudioAction =
  | { readonly kind: "mute"; readonly muted: boolean }
  | { readonly kind: "tones"; readonly digits: ReturnType<typeof parseToneDigits> };

export function matchesAudioReceipt(action: AndroidAudioAction, id: string, reply: Performed) {
  const receipt = reply.receipt.action;
  if (receipt.callID !== id) return false;
  if (action.kind === "mute") return receipt.kind === "mute" && receipt.muted === action.muted;
  return receipt.kind === "tones" && receipt.digits.join("") === action.digits.join("");
}
