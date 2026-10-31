import SwiftUI
import VoIPAudio
import VoIPCore

/// The push token, the calls with their actions, the audio routes, and what happened to calls.
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
        Section("Audio route") {
          ForEach(calls.audio.routes.available) { route in
            RouteRow(route: route, calls: calls)
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

/// An audio route the user can pick, checked while calls use it.
struct RouteRow: View {
  let route: AudioRoute
  let calls: Calls

  var body: some View {
    Button {
      Task { await calls.selectRoute(route.id) }
    } label: {
      HStack {
        Text(title)
        Spacer()
        if route.id == calls.audio.routes.current?.id {
          Image(systemName: "checkmark")
        }
      }
    }
  }

  /// Built-in routes are named by their kind; others by the system's name for the device.
  private var title: String {
    switch route.kind {
    case .builtInReceiver: "iPhone"
    case .builtInSpeaker: "Speaker"
    default: route.name
    }
  }
}
