import type { NativeTransport } from "./transport.ts";
import type { ConversationErrorCode, ConversationFailure } from "./types.ts";

const codes: ReadonlySet<string> = new Set<ConversationErrorCode>([
  "invalid_arguments",
  "unknown_conversation",
  "not_foreground",
  "unsupported",
  "conversation",
  "duplicate_sdk_linkage",
  "deadline_exceeded",
  "handler_failed",
  "refused",
]);

function isObject(value: unknown): value is object {
  return value !== null && typeof value === "object";
}

function isText(value: unknown): value is string {
  return typeof value === "string";
}

function isNativeCode(value: unknown): value is string | number {
  return isText(value) || typeof value === "number";
}

function isCommandCode(value: unknown): value is ConversationErrorCode {
  return isText(value) && codes.has(value);
}

function isCallable(value: unknown): value is Function {
  return typeof value === "function";
}

/** Decode sanitized native details without assuming every caught value came from this library. */
export function commandError<Value>(value: Value) {
  if (!(value instanceof Error)) return value;
  const prefix = "expo-conversation:";
  const offset = value.message.indexOf(prefix);
  if (offset < 0) return value;
  try {
    const [line = ""] = value.message.slice(offset + prefix.length).split("\n");
    const data: unknown = JSON.parse(line.slice(0, line.lastIndexOf("}") + 1));
    if (
      !isObject(data) ||
      !("code" in data) ||
      !isCommandCode(data.code) ||
      !("message" in data) ||
      !isText(data.message)
    )
      return value;
    const details: ConversationFailure = {
      code: data.code,
      message: data.message,
      ...("nativeCode" in data && isNativeCode(data.nativeCode) && { nativeCode: data.nativeCode }),
      ...("nativeDomain" in data && isText(data.nativeDomain) && { nativeDomain: data.nativeDomain }),
    };
    return Object.assign(new Error(details.message), details);
  } catch {
    return value;
  }
}

/** Native functions whose rejections carry a `ConversationFailure`. */
const commands: ReadonlySet<PropertyKey> = new Set<keyof NativeTransport>([
  "getConversations",
  "getMediaPermissions",
  "requestMediaPermissions",
  "conversationMediaReadiness",
  "getAudioRoutes",
  "getPushToken",
  "startConversation",
  "joinConversation",
  "endConversation",
  "setHeld",
  "setMuted",
  "setConversationVideo",
  "playTones",
  "mergeConversations",
  "reportConversation",
  "reportIncomingConversation",
  "receiveCallEnded",
  "selectAudioRoute",
]);

/** Wraps the native module so that its commands reject with typed `ConversationFailure` errors. */
export function withCommandErrors<Native extends object>(
  native: Native
) {
  return new Proxy(native, {
    get(target, key) {
      const member: unknown = Reflect.get(target, key, target);
      if (!isCallable(member)) return member;
      if (!commands.has(key)) return member.bind(target);
      return async (...arguments_: unknown[]) => {
        try {
          const result: unknown = await Reflect.apply(member, target, arguments_);
          return result;
        } catch (error: unknown) {
          throw commandError(error);
        }
      };
    },
  });
}
