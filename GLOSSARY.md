# Calling

The vocabulary of the iOS calling SDK: how an app's real-time calls are presented, controlled and connected on a device. Terms follow Apple's CallKit and LiveCommunicationKit wording wherever Apple has a word. Where the two frameworks differ, the entry names both.

## Language

### Calls and parties

**Call**:
A real-time voice or video interaction as this device knows it: ringing here, taking part here, or followed in a preview while it continues elsewhere. LiveCommunicationKit calls this a conversation.
_Avoid_: Conversation (outside LiveCommunicationKit), session, connection

**Call ID**:
The app's identifier for a call, the same on every device that rings for it. It is distinct from the per-device UUID that CallKit and LiveCommunicationKit assign.
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
What the system did with a reported incoming call: presented it, filtered it, or refused it.
_Avoid_: Report result

**Call preview**:
A live, non-ringing view of a call on a device that isn't taking part in it, such as a Live Activity, from which the user can join.
_Avoid_: Live notification, silent call

**Presentation policy**:
The app's choice of how an incoming call appears on a device: ring, preview, or not at all.
_Avoid_: Routing rule, ring mode

**Filtered call**:
An incoming call the system did not present because of the user's Do Not Disturb, Focus or block list.
_Avoid_: Silenced call, rejected call, failed call

**Cold launch**:
The system starting the app from not running because a VoIP push arrived.
_Avoid_: Background launch, wake-up

### Control

**Action**:
A request to change a call, such as start, answer, end, hold, mute or play tones. It is made either by the user through the system's calling surfaces or by the app.
_Avoid_: Command, request

**Server event**:
A fact about a call learned from the app's servers, such as connected, ended remotely, answered elsewhere, or a changed party.
_Avoid_: Remote update, call update

### Audio and media

**Audio activation**:
The system activating the audio session for a call. Microphone and speaker use for the call may start only after it.
_Avoid_: Call audio, audio start

**Media**:
The app's real-time audio and video transport for a call.
_Avoid_: Room, stream, connection

**Calling framework**:
The Apple system framework that presents calls to the user on a device: LiveCommunicationKit or CallKit.
_Avoid_: Provider (as a domain term), backend
