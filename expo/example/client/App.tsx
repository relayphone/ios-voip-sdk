import {
  endConversation, joinConversation, reportConversation, reportIncomingConversation,
  selectAudioRoute, setConversationHandler, setHeld, setMuted, startConversation,
  useAudioRoutes, useCallPreviewActivities, useConversationEvent, useConversations, useFocusFilterState,
  usePushToken,
} from "@relayphone/ios-voip-sdk";
import { useRef, useState } from "react";
import { Button, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import { Journeys } from "./journeys/Journeys";

// Attach before React mounts. The example accepts local signaling without a media server.
setConversationHandler({ join() {}, start() {} });

export default function App() {
  const calls = useConversations();
  const audio = useAudioRoutes();
  const token = usePushToken();
  const previews = useCallPreviewActivities();
  const focus = useFocusFilterState();
  const [message, setMessage] = useState("Ready");
  const [busy, setBusy] = useState(false);
  const running = useRef(false);
  useConversationEvent("callNotificationRoute", (route) => setMessage(route.type === "callBack"
    ? `Call back ${route.caller.displayName ?? route.caller.id}` : "Joining from a call notification"));
  async function perform(work: () => Promise<unknown>) {
    if (running.current) return;
    running.current = true; setBusy(true);
    try { await work(); setMessage("Completed"); }
    catch (error) { setMessage(String(error)); }
    finally { running.current = false; setBusy(false); }
  }
  return <SafeAreaProvider><SafeAreaView style={styles.screen}>
    <Journeys />
    <ScrollView contentContainerStyle={styles.content}>
      <Text style={styles.title}>VoIP Conversations</Text>
      <Text>Local signaling example. No media room is connected.</Text>
      <Text>Push registration: {token ? "registered" : "none"}</Text>
      {previews && <Text>Call preview Live Activities: {previews.authorization.activitiesEnabled ? "allowed" : "off"}</Text>}
      {focus && <Text>Focus filter: {focus.state === "active" ? JSON.stringify(focus.settings) : focus.state}</Text>}
      <Text accessibilityLiveRegion="polite">{message}</Text>
      <Button title="Report incoming" disabled={busy} onPress={() => void perform(async () => {
        const stamp = Date.now().toString();
        const result = await reportIncomingConversation({ eventId: stamp, serverCallId: `manual-${stamp}`,
          caller: { handleType: "generic", value: "caller", displayName: "Example caller" }, hasVideo: false });
        if (result.status !== "reported") throw new Error(result.status);
      })} />
      <Button title="Start outgoing" disabled={busy} onPress={() => void perform(async () => {
        const id = await startConversation({ id: `outgoing-${Date.now()}`, to: { id: "callee" }, video: false });
        await reportConversation(id, { type: "connected" });
      })} />
      {calls.map((call) => <View key={call.id} style={styles.card}>
        <Text>{call.members[0]?.displayName ?? call.members[0]?.id} · {call.status}</Text>
        {call.status === "ringing" && <Button title="Answer" disabled={busy} onPress={() => void perform(async () => {
          await joinConversation(call.id); await reportConversation(call.id, { type: "connected" });
        })} />}
        {(call.status === "connected" || call.status === "held") && <Button title={call.status === "held" ? "Resume" : "Hold"}
          disabled={busy} onPress={() => void perform(() => setHeld(call.id, call.status !== "held"))} />}
        <Button title={call.isMuted ? "Unmute" : "Mute"} disabled={busy}
          onPress={() => void perform(() => setMuted(call.id, !call.isMuted))} />
        <Button title="End" disabled={busy} onPress={() => void perform(() => endConversation(call.id))} />
      </View>)}
      <Text>Audio output: {audio.current?.name ?? "none"}</Text>
      {audio.routes.map((route) => <Button key={route.id} title={route.name} disabled={busy}
        onPress={() => void perform(() => selectAudioRoute(route.id))} />)}
    </ScrollView>
  </SafeAreaView></SafeAreaProvider>;
}
const styles = StyleSheet.create({
  screen: { flex: 1 }, content: { padding: 20, gap: 12 },
  title: { fontSize: 24, fontWeight: "600" }, card: { padding: 12, borderWidth: 1, borderColor: "#ccc" },
});
