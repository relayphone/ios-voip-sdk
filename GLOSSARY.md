# Calling

The vocabulary of the iOS calling SDK: how an app's real-time calls are presented, controlled and connected on a device. Terms follow Apple's calling vocabulary wherever Apple has a word. Where LiveCommunicationKit uses a different word, the entry names it.

## Language

### Calls and parties

**Call**:
A real-time voice or video interaction as this device knows it: ringing here, taking part here, or followed in a preview while it continues elsewhere. LiveCommunicationKit calls this a conversation.
_Avoid_: Conversation (outside LiveCommunicationKit), session, connection

**Call ID**:
The app's identifier for a call, the same on every device that rings for it. It is distinct from the per-device UUID that the calling framework uses.
_Avoid_: UUID, conversation ID

**Party**:
A person or service on the other side of a call, known by one or more handles and an optional display name. LiveCommunicationKit's remote members are parties.
_Avoid_: Participant, contact

**Handle**:
An address at which a party can be reached: a phone number, an email address, or a generic value such as an app account, as in Apple's handle types.
_Avoid_: Number, caller ID, identity

**Contact match**:
The system recognising one of a party's handles as a person in the user's contacts.
_Avoid_: Caller lookup

### Lifecycle

**Ring**:
The time an incoming call is presented to the user and waits for an answer.
_Avoid_: Alerting, invitation

**Answer**:
The user accepting a ringing call, through any surface: the system call screen, the app, a headset or a car. LiveCommunicationKit calls this joining.
_Avoid_: Accept, pick up

**Join**:
This device starting to take part in a call that is already live without it, usually from its call preview. LiveCommunicationKit also uses joining for answering.
_Avoid_: Take over (the product's term for replacing an assistant), pull, transfer

**Hold**:
Pausing a call so that neither side hears the other, while it stays connected. LiveCommunicationKit calls this pausing.
_Avoid_: Park

**Answered elsewhere**:
An incoming call taken somewhere other than this device, on another of the user's devices or by a service acting for the user. It ends the ring on this one.
_Avoid_: Remote answer, joined elsewhere

**Declined elsewhere**:
An incoming call declined on another of the user's devices, which ends the ring on this one.
_Avoid_: Remote decline

**End reason**:
Why a call ended on this device: ended here, ended remotely, unanswered, answered elsewhere, declined elsewhere, filtered, or failed.
_Avoid_: Disconnect cause, termination code

### Presentation

**VoIP push**:
A PushKit push that announces an incoming call. Apple requires every one to be reported as a call.
_Avoid_: Call push, invite push

**Report**:
Telling the system about an incoming call so that it can be presented to the user.
_Avoid_: Post, show, display

**Presentation outcome**:
How an incoming call appears on this device once it has been presented as its presentation policy asks: it rings, it is a call preview, it isn't shown, or the system filtered or refused it. A calling framework itself only presents, filters or refuses a call.
_Avoid_: Report result

**Call preview**:
A live, non-ringing view of a call on a device that isn't taking part in it, such as a Live Activity, from which the user can join. The app's servers usually start it.
_Avoid_: Live notification, silent call

**Live Activity**:
A view of an ongoing event that the system shows on the Lock Screen and in the Dynamic Island, and that the app or its servers keep up to date.
_Avoid_: Widget, live notification

**Push-to-start token**:
The token with which the app's servers start a Live Activity on a device. Each Live Activity then has its own push token, with which they update and end it.
_Avoid_: Live Activity token

**Presentation policy**:
The app's choice of how an incoming call appears on a device: ring, preview, or not at all.
_Avoid_: Routing rule, ring mode

**Filtered call**:
An incoming call the system did not present because of the user's Do Not Disturb, Focus or block list.
_Avoid_: Silenced call, rejected call, failed call

**Cold launch**:
The system starting the app from not running because a VoIP push arrived.
_Avoid_: Background launch, wake-up

### Focus

**Focus**:
A user setting that silences calls and notifications except from the people and apps it allows. Do Not Disturb is a Focus.
_Avoid_: DND mode, quiet hours

**Focus filter**:
The app's settings for one Focus, which the system applies when that Focus turns on and resets to their defaults when it turns off.
_Avoid_: Focus status (Apple's separate shared flag), Focus mode settings

**Focus filter state**:
What the app's Focus filter last asked for: unknown, inactive, or active with the filter's settings. Inactive doesn't mean that no Focus is on.
_Avoid_: Focus status, DND state

**Communication notification**:
A notification that the system shows as coming from a person, because it is about a call or a message from them. A Focus lets it through only for the people it allows.
_Avoid_: Call banner, contact notification

**Call notification**:
A communication notification about a call that the system filtered or that the app shows only as a call preview: an incoming call that the user can join, or a missed call once it ends without being joined on this device. It never rings.
_Avoid_: Missed-call push, call alert

### Control

**Action**:
A request to change a call, such as start, answer, end, hold, mute or play tones. It is made either by the user through the system's calling surfaces or by the app.
_Avoid_: Command, request

**Server event**:
A fact about a call learned from the app's servers, such as connected, ended remotely, answered elsewhere, or a changed party.
_Avoid_: Remote update, call update

### Audio and media

**Audio session**:
The app's `AVAudioSession` as calls use it. The SDK configures it for each call before audio activation; only the system activates and deactivates it for calls.
_Avoid_: Audio context, audio engine

**Audio activation**:
The system activating the audio session for a call. Microphone and speaker use for the call may start only after it.
_Avoid_: Call audio, audio start

**Audio interruption**:
The system deactivating an active audio session for something else, such as Siri, another app's audio or a muted built-in microphone. The call's audio returns only with a new audio activation.
_Avoid_: Audio loss, audio drop

**Media services reset**:
The system restarting its media services, which ends every audio object in the app and loses the audio session's configuration.
_Avoid_: Media server crash, audio reset

**Audio recovery**:
The audio activation that a call waits for after an audio interruption ends or the media services reset. A call that takes part and isn't on hold ends with reason failed if it doesn't come in time.
_Avoid_: Audio resume, reactivation

**Audio route**:
Where calls' audio plays and records: the built-in receiver or speaker, wired headphones, a Bluetooth device, AirPlay or CarPlay.
_Avoid_: Audio device, audio output (as a domain term)

**Media**:
The app's real-time audio and video transport for a call.
_Avoid_: Room, stream, connection

**Calling framework**:
The Apple system framework that presents calls to the user on a device: LiveCommunicationKit.
_Avoid_: Provider (as a domain term), backend
