<div align="center">

# 📡 MeshTalk

**Chat, share photos, send voice messages and call people nearby, with no internet, no SIM card and no servers.**

Every phone running MeshTalk relays messages for the others, so messages hop from phone to phone
across a crowd, a building, a campus or a disaster zone. MeshTalk also speaks the
[bitchat](https://github.com/permissionlesstech/bitchat) protocol, so it can talk to bitchat users on Android and iPhone.

![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.27%2B-02569B?logo=flutter&logoColor=white)
![Offline](https://img.shields.io/badge/works-100%25%20offline-success)
![Encryption](https://img.shields.io/badge/private%20messages-end--to--end%20encrypted-blueviolet)
![Status](https://img.shields.io/badge/status-beta-orange)

</div>

---

## Table of contents

1. [What is MeshTalk?](#1-what-is-meshtalk)
2. [Features](#2-features)
3. [How it works (in plain words)](#3-how-it-works-in-plain-words)
4. [Requirements](#4-requirements)
5. [Install and run](#5-install-and-run)
6. [Using the app](#6-using-the-app)
7. [Permissions and why they're needed](#7-permissions-and-why-theyre-needed)
8. [Talking to bitchat users](#8-talking-to-bitchat-users)
9. [Architecture](#9-architecture)
10. [Project structure](#10-project-structure)
11. [Protocol specification](#11-protocol-specification)
12. [Security and privacy](#12-security-and-privacy)
13. [Performance: what to expect](#13-performance-what-to-expect)
14. [Configuration and tuning](#14-configuration-and-tuning)
15. [Testing](#15-testing)
16. [Troubleshooting](#16-troubleshooting)
17. [FAQ](#17-faq)
18. [Known limitations and roadmap](#18-known-limitations-and-roadmap)
19. [Contributing](#19-contributing)
20. [Acknowledgements](#20-acknowledgements)
21. [License and disclaimer](#21-license-and-disclaimer)

---

## 1. What is MeshTalk?

MeshTalk is an **offline mesh messenger for Android**, built with Flutter.

Normal messengers (WhatsApp, Telegram, Signal) send every message through the internet to a
server. When the internet is down because of a disaster, a protest, a remote area or an overloaded
network at a big event, they stop working.

MeshTalk doesn't use the internet at all. Phones connect **directly to each other** over
Bluetooth and Wi-Fi (no Wi-Fi network or router needed, just the radio). Each phone also **passes
messages along** for the others, so a message can travel far beyond the ~100 m range of a single
phone, as long as there's a chain of MeshTalk phones in between.

```
  You ──── Phone B ──── Phone C ──── Your friend
   ~100 m       ~100 m       ~100 m
 (no internet anywhere: B and C relay automatically)
```

**Good for:** disasters and blackouts · protests · festivals, stadiums and pilgrimages ·
hiking and remote areas · schools and campuses · anywhere the network is down, censored or overloaded.

---

## 2. Features

| Feature | Description | Range |
|---|---|---|
| 💬 **Public chat** | One room for everyone in the mesh | Whole mesh (up to 7 hops) |
| 🔒 **Private messages** | End-to-end encrypted 1-to-1 chat with delivery ticks ✓✓ | Whole mesh |
| 🆘 **SOS alerts** | One button alerts every phone with vibration and a notification; sent before any other traffic | Whole mesh |
| 📷 **Photos** | Camera or gallery, compressed on the phone, shown with progress, full-screen zoom; private photos are encrypted | Whole mesh |
| 🎤 **Voice messages** | Up to 10 seconds, sent automatically at the limit | Whole mesh |
| 📞 **Voice calls** | Live calls with mute, speaker/earpiece and echo cancellation | Direct range only (1 hop) |
| 👥 **People list** | Who's nearby and how many hops away | Whole mesh |
| 🐦 **bitchat compatible** | Public chat with bitchat users (Android and iPhone) over Bluetooth LE | Bluetooth mesh |
| 🌉 **Bridging** | Every MeshTalk phone joins the bitchat and MeshTalk networks together | Both meshes |
| 📥 **Catch-up for late joiners** | Phones arriving later receive the last 30 minutes of text | Whole mesh |
| 🔋 **Works in the background** | A foreground service keeps relaying with the screen off | — |
| 🚫 **No accounts, no servers, no tracking** | Nothing ever leaves the mesh | — |

---

## 3. How it works (in plain words)

1. **Finding phones.** Each phone advertises "I'm running MeshTalk" over Bluetooth and Wi-Fi, and
   listens for others. Phones within roughly 100 m connect automatically, up to 4 direct links each.
2. **Passing messages along.** When your phone receives a message, it shows it if it's for you
   and **forwards a copy** to its other neighbours. Every message carries a hop counter that starts
   at 7 and goes down by one at each phone; at zero it stops.
3. **No echoes.** Every message has a unique ID. A phone that has already seen an ID ignores it,
   so messages never loop forever and the network doesn't drown in copies.
4. **Catching up.** Phones remember the last 30 minutes of text and replay it to anyone who
   connects, so a person who walks into range late still gets the conversation.
5. **Privacy.** Private messages, photos and voice messages are locked with the recipient's key
   before they leave your phone. The phones relaying them can carry them but can't read them.
6. **Two radios, two networks.** MeshTalk phones talk to each other through Google Nearby
   Connections (Bluetooth + Wi-Fi). They also run a second, Bluetooth-LE-only link in
   **bitchat's format** to reach bitchat users, and they relay between the two.

---

## 4. Requirements

**To use the app**

| Requirement | Why |
|---|---|
| Android phone | iPhone isn't supported yet; iPhone users can join through [bitchat](#8-talking-to-bitchat-users) |
| Google Play services | The main mesh uses Google Nearby Connections (phones without Google, such as recent Huawei models, can't join the main mesh) |
| Bluetooth **and** Wi-Fi switched on | Both radios are used; you don't need to be connected to any Wi-Fi network |
| Location switched on (Android 12 and older only) | Android requires it for Bluetooth scanning on those versions; MeshTalk never reads your location |
| At least 2 phones | A mesh needs neighbours. Emulators have no Bluetooth/Wi-Fi P2P radio, so use real phones |

Tested on a Samsung Galaxy Note 8 (Android 9). Android 8.0 or newer is recommended.

**To build from source**

- [Flutter](https://docs.flutter.dev/get-started/install) 3.27 or newer (`flutter --version`)
- Android Studio or the Android SDK command-line tools
- A phone with USB debugging enabled

---

## 5. Install and run

### Option A: install the APK

1. Download the latest `app-release.apk` from the [Releases](https://github.com/AbdullahJatoi007/MeshTalk/releases) page.
2. On your phone, allow installing apps from your browser or file manager when asked.
3. Open MeshTalk, pick a nickname and allow the permissions it asks for.
4. Install it on at least one more phone and keep both within ~100 m.

### Option B: build from source

```bash
git clone https://github.com/AbdullahJatoi007/MeshTalk.git
cd MeshTalk
flutter pub get
flutter test          # runs the relay, media and bitchat tests
flutter run           # with a phone connected over USB
```

Build a shareable APK:

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

> **Important when changing Kotlin code:** hot reload and hot restart only reload Dart code.
> After changing anything under `android/`, stop the app and run `flutter run` again.

### Using your own package name

The Android package is `com.meshtalk.android.meshtalk`. To change it:

1. Change `namespace` and `applicationId` in `android/app/build.gradle(.kts)`.
2. Change the first line (`package …`) of **every** `.kt` file in
   `android/app/src/main/kotlin/…/` and move the files to the matching folder.
3. Stop the app and rebuild.

If these don't match, the app builds but shows *"Background mode is off"*, or the build fails with
`Unresolved reference` (see [Troubleshooting](#16-troubleshooting)).

---

## 6. Using the app

### First launch
Pick a nickname (up to 20 characters) and allow the permissions. The mesh starts by itself. The top
bar shows the status: `Searching nearby…`, then for example `2 direct · 5 in mesh · 1 bitchat`.

### Everyone tab (public chat)
- Messages here go to **everyone** in the mesh, including phones several hops away.
- Each message shows the time and how many hops it travelled. Messages from bitchat users
  are labelled **bitchat**.
- 🖼 sends a photo and 🎤 records a voice message (the mic appears when the text box is empty).

### People tab
- **In the mesh:** everyone reachable, nearest first, with their hop distance. Tap a person
  to open a private chat.
- **On bitchat (public chat only):** bitchat users nearby. Private chat with them isn't supported yet.
- **Not in the mesh right now:** people you've chatted with before who aren't reachable now.

### Private chat
- End-to-end encrypted: only the recipient can read it. ✓ = sent, ✓✓ = delivered.
- Photos and voice messages sent here are encrypted too.
- The 📞 button calls the person **only when they show "Direct"** (in direct range).

### Photos
Tap 🖼 → *Take a photo* or *Choose from gallery*. The photo is shrunk to max 800×800 px (about
50–120 KB) before sending. The receiver sees *"Receiving photo 40%"* until it arrives. Tap a
photo to view it full screen and pinch to zoom.

### Voice messages
With the text box empty, tap 🎤 to start recording. Tap ➤ to send or 🗑 to cancel. Recording
stops and sends itself at **10 seconds**. Taps shorter than 0.7 s are discarded.

### Voice calls
Open a private chat with someone marked **Direct** and tap 📞. The other phone rings from anywhere
in the app. During the call you can mute, switch between speaker and earpiece, or end it.
Unanswered calls stop after 30 s, and calls end automatically if the direct link drops for 8 s.

### SOS
Tap the red **SOS** button, describe where you are, and confirm. Every phone in the mesh gets a
red banner, vibration and a notification, even in the background. SOS messages are forwarded
before all other traffic. bitchat users receive it as a public `🆘 SOS: …` message.

### Menu (⋮)
- **Turn mesh on/off**
- **Talk with bitchat users:** enable or disable bitchat compatibility (on by default)
- **Clear message history:** deletes all messages, photos and voice messages from this phone

---

## 7. Permissions and why they're needed

| Permission | Asked when | Why |
|---|---|---|
| Nearby devices (Bluetooth scan / advertise / connect) | First launch (Android 12+) | Find and connect to nearby phones: the core of the app |
| Nearby Wi-Fi devices | First launch (Android 13+) | Faster phone-to-phone links over Wi-Fi |
| Location | First launch (Android 12 and older) | Android requires it for Bluetooth scanning on these versions. **Your location is never read or stored** |
| Notifications | First launch (Android 13+) | SOS alerts, messages and incoming calls while the app is in the background |
| Microphone | First voice message or call | Recording voice messages and calls |
| Camera / photos | When you send a photo | Taking or choosing a photo (handled by Android's own picker) |
| Foreground service | Automatic | Keeps the mesh relaying with the screen off |

MeshTalk has **no internet features**: no servers, no analytics, no ads, no accounts.

---

## 8. Talking to bitchat users

[bitchat](https://github.com/permissionlesstech/bitchat) is another offline mesh messenger, for
iPhone and Android. MeshTalk implements bitchat's Bluetooth LE protocol so the two apps can talk.

| | MeshTalk ↔ bitchat |
|---|---|
| See each other in the people list | ✅ |
| Public chat, both directions | ✅ |
| SOS from MeshTalk | ✅ arrives as a public `🆘 SOS: …` message |
| Relaying each other's messages | ✅ |
| Private messages | ⏳ planned (needs bitchat's Noise encryption) |
| Photos / voice messages | ⏳ planned (needs bitchat's file format) |
| Calls | ❌ MeshTalk-only feature |

**How it works**
- MeshTalk advertises and scans for bitchat's Bluetooth service (`F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`,
  characteristic `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D`) and acts as both GATT server and client, like bitchat.
- It sends signed announcements (nickname + keys) and signed public messages in bitchat's binary format.
- It verifies bitchat users' signatures before showing their messages.
- **Same identity on both networks:** bitchat derives its 8-byte peer ID from the X25519 key
  (first 8 bytes of SHA-256), exactly like MeshTalk's node ID.
- **Bridging:** every MeshTalk phone relays bitchat traffic over Bluetooth *and* carries it across
  the Nearby mesh. A single MeshTalk phone near a bitchat user connects that user to the whole MeshTalk network.
- **No double messages:** when a MeshTalk user's message arrives over both networks, only one copy is shown.
- **Long messages:** bitchat on iPhone re-compresses payloads of 100 bytes or more when checking a
  signature, which would break MeshTalk's signature. So MeshTalk sends longer public messages to
  bitchat as several parts of under 100 bytes each. MeshTalk users still see one message.

**Testing it:** install bitchat on a second phone, turn on Bluetooth on both, and wait about 30 seconds.
Each appears in the other's people list.

**Legal note:** MeshTalk's bitchat support was written from bitchat's **public-domain** iOS sources and
protocol [whitepaper](https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md) (Unlicense).
No code was taken from the bitchat Android app, which is GPL-3.0. MeshTalk is an independent project
and is not affiliated with bitchat.

---

## 9. Architecture

```
┌──────────────────────── Flutter UI (lib/ui) ────────────────────────┐
│  Onboarding · Everyone · People · Private chat · Call · SOS         │
└───────────────────────────────┬──────────────────────────────────────┘
                     MeshService (lib/mesh/mesh_service.dart)
          messages · media · calls · receipts · notifications · bridge
           │                         │                          │
   MeshRouter                  BitchatMesh                 Identity
   (lib/mesh/router.dart)      (lib/bitchat/bc_mesh.dart)  X25519 + Ed25519
   flood · TTL · dedup ·       bitchat flood · signatures · AES-GCM
   replay · priorities         fragments · bridge
           │                         │
   NearbyTransport             BleBitchatTransport
   Google Nearby (P2P_CLUSTER) BitchatBle.kt (GATT server + client)
   Bluetooth + Wi-Fi, ≤ 4 links Bluetooth LE, ≤ 6 client links
           │                         │
     MeshTalk phones            bitchat phones (Android + iPhone)
                                 and MeshTalk phones
```

- **The relay layers don't know about radios.** `MeshRouter` talks to a `MeshTransport` interface
  and `BitchatMesh` to a `BcLinkTransport` interface, so transports can be swapped or added (for
  example raw BLE or Wi-Fi Aware) without touching the relay logic.
- **Native Android code** (Kotlin) handles what Flutter can't: the foreground service, notifications,
  voice recording/playback, live call audio, and the Bluetooth LE GATT server.

---

## 10. Project structure

```
lib/
├── main.dart                     App entry; opens the call screen whenever a call starts
├── mesh/
│   ├── mesh_service.dart         App logic: messages, media, calls, receipts, bitchat bridge
│   ├── router.dart               MeshTalk relay: flooding, TTL, dedup, replay, priorities, peers
│   ├── packet.dart               MeshTalk packet format and validation
│   ├── media.dart                Photo/voice chunking, reassembly, file storage
│   ├── identity.dart             Keys, node ID, encryption, signatures
│   ├── transport.dart            MeshTransport interface
│   └── nearby_transport.dart     Google Nearby Connections links and link management
├── bitchat/
│   ├── bc_protocol.dart          bitchat binary format: codec, padding, compression, fragments, TLVs
│   └── bc_mesh.dart              bitchat mesh: announcements, verification, relaying, bridging
├── platform/
│   ├── native_bridge.dart        Channel to Kotlin: service, notifications, audio, calls
│   ├── ble_bridge.dart           Channel to Kotlin: bitchat Bluetooth LE links
│   └── permissions.dart          Per-Android-version permission requests
└── ui/
    ├── home_screen.dart          Status bar, SOS, Everyone and People tabs, menu
    ├── dm_screen.dart            Private chat and call button
    ├── call_screen.dart          Ringing and active-call screen
    ├── onboarding_screen.dart    Nickname setup
    ├── widgets.dart              Composer, message bubbles, photo viewer, voice player
    └── theme.dart                Colours and helpers

android/app/src/main/kotlin/com/meshtalk/android/meshtalk/
├── MainActivity.kt               Method/event channels to Flutter
├── MeshForegroundService.kt      Keeps the app alive in the background (connectedDevice + microphone)
├── MeshNotifications.kt          Notification channels: service, messages, SOS
├── VoiceNotes.kt                 Voice message recording (AAC) and playback
├── CallAudio.kt                  Live call capture/playback, echo cancellation, jitter buffer
├── AdpcmCodec.kt                 IMA ADPCM codec for call audio
└── BitchatBle.kt                 Bluetooth LE GATT server + client in bitchat's format

test/
├── router_test.dart              Relay, replay, priority, media and call-signal tests
└── bitchat_test.dart             bitchat codec, signatures, relaying, fragments, bridging
```

---

## 11. Protocol specification

### 11.1 MeshTalk packets (over Nearby)

Packets are compact JSON, UTF-8 encoded, max **16 KB**. Anything malformed, oversized or of
unknown type is dropped without being relayed.

```json
{"v":1, "id":"9f3c0a1b2d4e5f60", "t":"chat", "s":"a1b2c3d4e5f60718", "n":"Ali",
 "d":"0f1e2d3c4b5a6978", "ttl":7, "h":0, "ts":1792332360000, "b":{ ... }}
```

| Field | Meaning | Rules |
|---|---|---|
| `v` | Protocol version | 1 |
| `id` | Packet ID | 16 hex chars (64 random bits) |
| `t` | Type | see table below |
| `s` | Sender node ID | 16 hex chars |
| `n` | Sender nickname | max 24 chars |
| `d` | Destination node ID | only for private types |
| `ttl` | Hops left | 0–16, starts at 7 |
| `h` | Hops travelled | 0–16, starts at 0 |
| `ts` | Send time (ms) | dropped if more than 24 h off |
| `b` | Body | type-specific |

| Type | Body | Delivered to | Priority |
|---|---|---|---|
| `sos` | `x` text (≤ 1000 chars) | everyone | 0 (first) |
| `dm` | `pk` sender key, `n` nonce, `c` ciphertext, `m` tag | destination | 1 |
| `ack` | `r` ID of the message being confirmed | destination | 1 |
| `call` | `a` offer/accept/decline/busy/end, `c` call ID; always ttl 1 | direct neighbour | 1 |
| `chat` | `x` text (≤ 1000 chars) | everyone | 2 |
| `bc` | `p` a bitchat packet (base64), for bridging | everyone | 2 |
| `ann` | `pk` sender's X25519 public key | everyone | 3 |
| `blob` | `mid` media ID, `k` img/voice, `i` index, `cnt` count, `dur` length; `d` base64 chunk or `e` encrypted chunk | everyone, or destination if private | 4 (last) |

### 11.2 Forwarding rules

1. A frame starting with byte `0x01` is call audio: it goes straight to the call engine and is never relayed.
2. Decode; drop if invalid.
3. Drop if the sender is this phone.
4. Drop if the ID was seen in the last hour (memory of 5,000 IDs); otherwise remember it.
5. Drop if the timestamp is more than 24 h off.
6. `ann` updates the people list.
7. Deliver to the app if there's no destination or the destination is this phone.
8. If the destination is this phone, stop.
9. If `ttl > 1`, send a copy with `ttl − 1`, `h + 1` to every link except the one it came from.

**Catch-up:** the last 200 text packets (`chat`, `sos`, `dm`, `ack`, `bc`) from the past 30 minutes
are replayed to every new neighbour. Photo/voice chunks, call signals and announcements are not replayed.

**Priorities:** each link has its own send queue, sorted by priority, so SOS and private messages
never wait behind a photo.

**People list:** every phone announces itself on start, every 30 s and when a neighbour connects.
Peers silent for 100 s are removed.

### 11.3 Photos and voice messages

- Split into chunks of up to **7,000 bytes**, max **48 chunks** (336,000 bytes).
- Each chunk is its own `blob` packet; public chunks are base64, private chunks are encrypted one by one.
- The receiver reassembles by media ID, rejects inconsistent chunks, and drops incomplete media after 10 minutes.
- Fully received private media is confirmed with an `ack` (✓✓).

### 11.4 Calls

- Signalling uses `call` packets with ttl 1, so calls only work between direct neighbours.
- Audio: 8 kHz mono, IMA ADPCM, 100 ms frames (403 bytes, about 32 kbps).
- Audio frame: `[0x01][call ID, 8 bytes][sequence, 2 bytes][ADPCM]`, sent only over the direct link.
- Playback uses a small jitter buffer (starts at 2 frames, keeps at most 6).

### 11.5 bitchat packets (over Bluetooth LE)

Binary, big-endian, compatible with bitchat v1/v2 packets:

```
version(1) type(1) ttl(1) timestamp(8) flags(1) payloadLength(2, or 4 for v2)
senderID(8) [recipientID(8)] [route, v2] [originalSize if compressed] payload [signature(64)]
flags: 0x01 recipient · 0x02 signature · 0x04 compressed (raw DEFLATE) · 0x08 route · 0x10 RSR
```

| Type | Name | MeshTalk |
|---|---|---|
| `0x01` | announce (TLV: nickname, Noise key, signing key) | sends, verifies, shows in People |
| `0x02` | public message (UTF-8, signed) | sends, verifies, shows in Everyone |
| `0x03` | leave | verifies, removes the peer |
| `0x20` | fragment (`id(8) index(2) total(2) type(1) data`) | reassembles, relays |
| others | Noise, files, voice, sync… | relayed so bitchat users stay connected |

- **Signatures:** Ed25519 over the packet re-encoded with ttl 0, no signature, no RSR flag, and
  PKCS#7 padding to 256/512/1024/2048 bytes.
- **Announce TLV `0xF7`** marks MeshTalk phones; bitchat ignores unknown TLVs.
- **Relaying:** TTL 7, duplicate memory keyed on sender + timestamp + type + payload hash,
  10–220 ms random delay, TTL capped at 5 in dense areas.
- **Bridge:** bitchat packets of up to 8,000 bytes are carried across the Nearby mesh inside `bc` packets.

---

## 12. Security and privacy

### What's encrypted

| Data | Protection |
|---|---|
| Private messages, private photos, private voice messages | **End-to-end:** X25519 key exchange → HKDF-SHA256 → AES-256-GCM. Sender, recipient and packet ID are bound into the encryption, so relays can't read, change or replay them |
| Every Nearby radio link | Encrypted by Google Nearby Connections (hop to hop) |
| Sender identity | Node ID = first 8 bytes of SHA-256(public key); a private message is only accepted if its key matches the sender ID |
| bitchat announcements and public messages | Ed25519 signatures; forged or unsigned packets are dropped |

### Threat model

| Threat | Status |
|---|---|
| A relaying phone reads a private message, photo or voice message | ✅ Prevented |
| A relay alters or replays a private message | ✅ Prevented |
| Someone sends a private message pretending to be another user | ✅ Prevented |
| Someone posts a MeshTalk public chat or SOS under another user's name | ⚠️ Not prevented (MeshTalk broadcasts aren't signed yet; bitchat ones are) |
| Someone listens in on a call | ⚠️ Limited: calls never pass through relays, but rely on link encryption, not app-level end-to-end encryption |
| A stolen, unlocked phone's history is read | ⚠️ Not prevented: history and media are stored unencrypted in the app's private storage |
| Keys leak and old messages are decrypted | ⚠️ No forward secrecy yet (static keys) |
| Someone floods the mesh with junk | ⚠️ Limited by size limits and per-link queue caps |

### Privacy

- **No servers, no accounts, no phone numbers, no analytics, no ads, no internet permission.**
- Stored on your phone only: your keys, nickname, message history (last 500 messages) and media files.
  *Clear message history* deletes messages and media; uninstalling deletes everything.
- Visible to nearby phones: your nickname, your public keys, and your public messages.
- Location: never read. Older Android versions require the location *permission* for Bluetooth scanning only.

Found a security problem? Please open a private
[security advisory](https://github.com/AbdullahJatoi007/MeshTalk/security/advisories/new) instead of a public issue.

---

## 13. Performance: what to expect

These are **estimates** based on the radios used, not formal measurements. Real results depend on
phones, walls, interference and crowd density.

| | Typical |
|---|---|
| Range per hop | ~10–100 m (Nearby, depending on obstacles); ~10–50 m indoors over Bluetooth LE |
| Max hops | 7 |
| Direct links per phone | 4 (Nearby) + up to 6 Bluetooth LE client links |
| Text message | near-instant per hop |
| Voice message (~20 KB) | about a second to a few seconds per hop |
| Photo (50–120 KB) | a few seconds per hop |
| Voice call | 1 hop only; ~32 kbps; ~200–400 ms delay |
| Battery | higher than a normal messenger, because radios stay on; measure on your phones |

Please share your field results in an issue. Real numbers help everyone.

---

## 14. Configuration and tuning

All values are constants in the code.

| Constant | Value | File |
|---|---|---|
| Hop limit (`maxTtl`) | 7 | `router.dart` |
| Direct Nearby links per phone (`maxLinks`) | 4 | `nearby_transport.dart` |
| Duplicate memory | 5,000 IDs / 1 h | `router.dart` |
| Catch-up buffer | 200 packets / 30 min | `router.dart` |
| Peer timeout | 100 s | `router.dart` |
| Announce interval | 30 s | `mesh_service.dart` |
| Max packet size | 16 KB | `packet.dart` |
| Max text length | 1,000 chars | `mesh_service.dart` |
| Stored history | 500 messages | `mesh_service.dart` |
| Media chunk / max chunks | 7,000 bytes / 48 | `media.dart` |
| Voice message limit | 10 s | `media.dart` |
| Photo compression | 800 px, JPEG quality 55 | `widgets.dart` |
| Voice message encoding | AAC, 16 kHz, 16 kbps | `VoiceNotes.kt` |
| Ring timeout / call silence timeout | 30 s / 8 s | `mesh_service.dart` |
| Call audio | 8 kHz ADPCM, 100 ms frames | `CallAudio.kt` |
| bitchat TTL / announce interval | 7 / 8 s alone, 15–30 s connected | `bc_mesh.dart` |
| bitchat peer timeout | 90 s | `bc_mesh.dart` |
| Bluetooth LE client links | 6 | `BitchatBle.kt` |
| Nearby service ID | `com.example.meshtalk.mesh` | `nearby_transport.dart` |

> **Don't change the Nearby service ID or the bitchat UUIDs** unless you want a separate network:
> phones with different values can't see each other.

---

## 15. Testing

### Automated tests

```bash
flutter test
```

| Test file | Covers |
|---|---|
| `test/router_test.dart` | multi-hop delivery and hop counts, duplicate suppression in loops, TTL limit, private messages stop at the destination, people list, catch-up for late joiners, SOS priority, echo/expiry, old timestamps, call frames never relayed, call signals stay 1 hop, media not replayed, photo chunk reassembly |
| `test/bitchat_test.dart` | bitchat codec and padding, signature input, announcement size, discovery, public chat, long-message splitting, 2-hop relaying, forged/unsigned packets rejected, messages before announcements, fragmentation on small links, bridging over Nearby |

The bitchat format was also cross-checked byte for byte against an independent implementation
translated from bitchat's Swift code: 3,000 random packets plus Ed25519 signatures verified in both directions.

### Field test checklist

- [ ] Two phones connect within 30 s and exchange public chat
- [ ] Private message shows ✓✓ after delivery
- [ ] Three phones in a line (ends out of range): message shows "2 hops"
- [ ] SOS alerts every phone, including one with the app in the background
- [ ] A phone arriving 5 minutes later receives earlier messages
- [ ] Photo reaches a phone 2 hops away intact
- [ ] Voice message sends itself at 10 s and plays on the receiver
- [ ] Call connects in direct range; mute, speaker and end work
- [ ] Walking out of range ends the call within ~8 s
- [ ] A bitchat phone and a MeshTalk phone see each other and exchange public chat
- [ ] 30 minutes with the screen off: relaying continues
- [ ] Battery drain over one hour recorded

---

## 16. Troubleshooting

| Problem | Fix |
|---|---|
| Stuck on **"Searching nearby…"** | Turn on Bluetooth **and** Wi-Fi (no network needed). On Android 12 or older, also turn on Location. Check *App info → Permissions → Nearby devices*. Phones without Google Play services can't join the Nearby mesh |
| Phones see each other but don't connect | Wait 30 s (the second phone takes over connecting), or turn the mesh off and on from ⋮ |
| **"Background mode is off"** notice / `MissingPluginException … meshtalk/native` | The Kotlin files aren't in your app's package folder, have the wrong `package` line, or you only hot-restarted. Fix the files, stop the app, run `flutter run` |
| Build error `Unresolved reference 'MeshNotifications'` (or another Kotlin class) | One of the 7 Kotlin files is missing from the package folder |
| No call button | Calls need the other person to show **Direct** (1 hop) |
| No sound in a call | Allow the microphone on both phones; try the Speaker button |
| Photo stuck at "Receiving…" | A chunk was lost on a weak link; incomplete photos are dropped after 10 minutes. Try again closer |
| bitchat users don't appear | Bluetooth must be on; check ⋮ → *Talk with bitchat users* is ticked; look at the People tab for "Can't reach bitchat users"; collect logs (below) |
| The mesh stops after swiping the app away | Known limitation: keep the app open or in the background, don't swipe it away |

**Collecting logs**

```bash
flutter logs                       # app logs; mesh lines start with "mesh:"
adb logcat | grep -i nearby        # Google Nearby
adb logcat -s MeshTalkBle          # bitchat Bluetooth LE links
```

Please attach logs, phone models and Android versions when opening an issue.

---

## 17. FAQ

**Does it need internet or a SIM card?**
No. Everything works phone to phone.

**How far can a message travel?**
Up to 7 hops. With phones spread ~50–100 m apart, that's several hundred metres, more in a dense crowd.

**Can I message someone who isn't in range of anyone?**
Not yet. They need to be reachable through a chain of phones. Queued delivery for offline people is on the roadmap.

**Does it work with WhatsApp, Bridgefy, Briar or other mesh apps?**
No. Each app has its own protocol. MeshTalk is compatible with **bitchat** only (public chat for now).

**Does it work on iPhone?**
Not directly. iPhone users can install bitchat and chat publicly with MeshTalk users.

**Can relaying phones read my private messages?**
No. Private messages, photos and voice messages are end-to-end encrypted. Public chat is readable by everyone, by design.

**Why are calls only "direct"?**
Live audio relayed through several phones would be delayed and choppy. Voice messages work across the whole mesh.

**Does it drain the battery?**
More than a normal messenger, because Bluetooth and Wi-Fi stay active. Turn the mesh off from ⋮ when you don't need it.

**Is my location tracked?**
No. The location permission on older Android versions is an Android requirement for Bluetooth scanning; MeshTalk never reads your location.

---

## 18. Known limitations and roadmap

| Limitation | Planned fix |
|---|---|
| The mesh stops when the app is swiped away from Recents | Run the mesh inside the native service so it survives |
| MeshTalk public chat and SOS aren't signed | Ed25519 signatures on broadcasts (already used for bitchat) |
| No forward secrecy for private messages | Noise XX sessions, as bitchat does |
| Private messages and media flood the whole mesh | Route along the known path, flood only as fallback |
| No delivery to people who are offline right now | Store and deliver when they reappear |
| Photos and voice messages aren't replayed to late joiners | Offer recent media to newcomers on request |
| Calls only between direct neighbours | Lower-bitrate codec (Opus or Codec2) for relayed calls |
| Call audio isn't end-to-end encrypted by the app | Encrypt each audio frame with the callers' shared key |
| History and media stored unencrypted | Encrypt storage with a key in Android Keystore |
| Requires Google Play services for the main mesh | Use the Bluetooth LE transport as a full alternative |
| Private messages, photos and voice with bitchat users | Implement bitchat's Noise sessions and file transfer |
| Android only | iOS app sharing the same protocol |

---

## 19. Contributing

Contributions are welcome: code, field-test reports, translations, documentation and ideas.

1. **Open an issue first** for bigger changes, so we can agree on the approach.
2. Fork the repository and create a branch: `git checkout -b feature/my-change`.
3. Keep changes focused and run `flutter analyze` and `flutter test` before opening a pull request.
4. **Protocol changes must stay compatible.** Phones running older versions must not crash on new packets:
   add new packet types or fields instead of changing existing ones, and update [§11](#11-protocol-specification).
5. **bitchat code must come from public-domain sources only** (bitchat's iOS repo and whitepaper).
   Don't copy code from the GPL-licensed bitchat Android repository.
6. Describe how you tested on real phones (models, Android versions, number of phones).

**Good first contributions:** field-test measurements, translations, UI polish, more unit tests,
and battery measurements.

---

## 20. Acknowledgements

- [bitchat](https://github.com/permissionlesstech/bitchat): protocol design and public-domain reference implementation
- [Google Nearby Connections](https://developers.google.com/nearby/connections/overview) and the
  [`nearby_connections`](https://pub.dev/packages/nearby_connections) Flutter plugin
- [`cryptography`](https://pub.dev/packages/cryptography), [`permission_handler`](https://pub.dev/packages/permission_handler),
  [`shared_preferences`](https://pub.dev/packages/shared_preferences), [`image_picker`](https://pub.dev/packages/image_picker)
- Ideas from Bluetooth Mesh, Meshtastic and research on smartphone ad-hoc networks

---

## 21. License and disclaimer

MeshTalk is open source under the [MIT License](LICENSE).

> **Disclaimer:** MeshTalk is experimental software provided "as is", without warranty. Delivery
> over a mesh is never guaranteed: it depends on how many phones are nearby and how they're spread out.
> **Don't rely on MeshTalk as your only way to call for help.** In an emergency, always try to contact
> local emergency services by any means available.
