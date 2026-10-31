import SwiftUI
import VoIPCore

/// The push token, the calls with their actions, and what happened to them.
struct ContentView: View {
  let calls: Calls

  var body: some View {
    NavigationStack {
      List {
        Section("VoIP push token") {
          Text(calls.pushToken).font(.footnote.monospaced()).textSelection(.enabled)
        }
        Section("Calls") {
          Button("Report an incoming call") {
            Task { await calls.reportIncomingCall() }
          }
          ForEach(calls.client.calls) { call in
            CallRow(call: call, calls: calls)
          }
        }
        Section("Events") {
          ForEach(Array(calls.history.enumerated()), id: \.offset) { entry in
            Text(entry.element).font(.footnote)
          }
        }
      }
      .navigationTitle("Calls")
    }
  }
}

/// One call, with the actions its status allows.
struct CallRow: View {
  let call: Call
  let calls: Calls

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(call.parties.first?.displayName ?? call.id.rawValue).font(.headline)
      Text(String(describing: call.status)).font(.caption).foregroundStyle(.secondary)
      HStack {
        if call.status == .ringing {
          button("Answer", .answer(call.id))
        }
        if call.status == .connecting || call.status == .connected {
          button(call.isMuted ? "Unmute" : "Mute", .mute(call.id, muted: !call.isMuted))
        }
        button("End", .end(call.id))
      }
      .buttonStyle(.bordered)
    }
  }

  private func button(_ title: String, _ action: Action) -> some View {
    Button(title) {
      Task { await calls.request(action) }
    }
  }
}
