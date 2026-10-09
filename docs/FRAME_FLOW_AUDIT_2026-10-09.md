# Aaris Remote: frame flow, stutter audit and corrections

Audited source: `warishakhan3548-hash/updating-repository`, main `8222234f7cc263bc341a9fe0ba599a819dc21b60` (1.9.61).
SDK: `io.github.webrtc-sdk:android:150.7871.01`.
Scope: phone-to-phone primary video, its adaptation feedback, and shared browser compatibility. This report distinguishes verified code defects from recording observations and unmeasured device hypotheses.
Continuation checkpoint: PR #584 at `f67dc11aea9599f857cb7c0b8c0e6974bb34881e`. Its original corrections are preserved; the continuation adds measured-capacity recovery and coherent feedback accounting.

## The complete dependency map

```mermaid
flowchart TD
  UI["MainActivity: share or connect"] --> State["SessionCoordinator and session state"]
  State --> Host["ScreenShareService: approved host"]
  State --> Viewer["ControllerConnectionService: controller"]
  Host --> Capture["ScreenCaptureTrack: MediaProjection texture"]
  Capture --> Source["VideoSource and local VideoTrack"]
  Source --> Encode["WebRtcPeer SEND_ONLY: hardware encoder"]
  Encode --> RTP["Native RTP packetizer, congestion control and pacer"]
  RTP --> Route{"Selected ICE path"}
  Route --> Direct["Direct UDP"]
  Route --> Relay["TURN relay"]
  Direct --> Receive["Native RTP reorder, packet repair and jitter timing"]
  Relay --> Receive
  Viewer --> Receive
  Receive --> Decode["Hardware decoder with software fallback"]
  Decode --> Track["Decoded remote VideoTrack"]
  Track --> Android["InlineRemoteControllerView: EGL and Surface"]
  Track --> Browser["Browser video compositor"]
  Android --> Feedback["Actual presentation and decoder feedback"]
  Browser --> Feedback
  Feedback --> Policy["Host policy lane: pixels, cadence and freshness"]
  Policy --> Source
  Policy --> Encode
```

| Stage | Concrete source and execution | What can stall here; downstream effect |
| --- | --- | --- |
| Consent and lifetime | `MainActivity` / `SessionCoordinator` → `ScreenShareService` and `ControllerConnectionService` | A missing grant, stopped service or stale session is a lifetime failure; tuning bitrate cannot repair it. |
| Pixel production | `ScreenCaptureTrack.start` → `ScreenCapturerAndroid` → one MediaProjection virtual display → `SurfaceTextureHelper` | Android can supply sparse updates on a still screen. Holding its texture or blocking its callback delays subsequent genuine frames. |
| Capture handoff | `ScreenCaptureTrack.onFrameCaptured` → `videoSource.capturerObserver.onFrameCaptured` → `VideoTrack` | Natural frames enter the main video path before optional snapshot sinks. `CaptureActivityTracker` measures original producer timestamps; forced repeats do not count as new screen motion. |
| Capture policy | `ScreenCaptureTrack.adaptOutput` → `VideoSource.adaptOutputFormat` | Caps source pixels/FPS. Routine policy changes preserve the virtual display; actual display-shape changes alone call `changeCaptureFormat`. |
| Encoding | `WebRtcRuntime` factories → `WebRtcPeer.addLocalVideoTrack` SEND_ONLY transceiver | Negotiated hardware baseline H.264/VP8 is preferred, with software fallback. Encoder cost is measured per **encoded** frame. Large dimension changes may reconfigure a vendor codec. |
| Transmission | `WebRtcPeer.applyInteractiveVideoPolicy` → RTP sender → native GCC/TWCC, packet pacing, SRTP | Configured bitrate/FPS are ceilings. Encoded frames are not proof that their packets have left the sender. The pinned SDK aliases its sent-frame counter to encoding; sender residence and receiver decode/display evidence must remain separate from encoder count. |
| Connectivity | `CloudflareSignalingClient` + `IceServerProvider` → selected direct UDP / TURN route | SDP/ICE establishes the path. Normal video is RTP, rather than repeated Worker screenshot uploads. Packet propagation, loss and recovery constrain deadlines. |
| Assembly and decode | Native receiver reorder/NACK/jitter timing → decoder → `WebRtcPeer.onTrack` / `onAddTrack` → `ControllerWebRtcSession` | Missing dependent packets can prevent a whole frame from decoding. Decoder cost and emitted-buffer residence expose different bottlenecks. |
| Android display | `InlineRemoteControllerView.renderSink` → `EglRenderer.onFrame` → EGL swap → Surface/compositor | Latest pending frames replace obsolete pending work. Actual render callbacks feed `PresentationCadenceTracker`; decoded count alone does not establish visible smoothness. |
| Browser display | `browser-console.js` → HTML video / `requestVideoFrameCallback`; `receiver-playout.js` | Uses native video playback and a supported adaptive jitter target. A hidden/stalled compositor or unsupported callback must not manufacture display FPS. |
| Adaptation | `VideoHealthSnapshot.from` → `VideoHealthWindowTracker.sample` → `HostWebRtcSession.onVideoHealth` → `ReceiverVideoFeedback`, `MotionVideoBudget`, `VideoCadenceGovernor`, `HighCadenceProbe`, `PhotonFreshnessGovernor` | Scalar evidence determines ceilings. Incorrect demand accounting, zero-supply classification or recovery admission can cause unnecessary reductions or an unsafe recovery upshift. |
| Compatibility pixels | The same capture → `FallbackScreenStreamer` / `AiSnapshotProvider` → owned CPU copy → bounded worker | Separate recovery/AI work, rather than the normal video stream. Retaining a producer texture or allowing old JPEG work to accumulate would harm primary capture. |

## UI and state map

The local UI state sequence is `IDLE → READY → CODE_ACTIVE → PAIR_PENDING → HOST_APPROVED → SCREEN_CONSENT → CONNECTING → LIVE → CLOSED`.
The backend sequence is `CODE_ACTIVE → PAIR_PENDING → HOST_APPROVED → SCREEN_READY → LIVE → CLOSED`.

A host approves sharing and Android grants MediaProjection. `ScreenShareService` owns the foreground capture lifetime. The controller connection service prewarms signaling/ICE after approval and owns the peer independently of Activity navigation. Once the remote track exists, the inline viewer attaches its sink. A real EGL swap confirms presentation; simply connecting a peer or receiving a track does not.

```mermaid
flowchart TD
  Finger["Controller touch or swipe"] --> Pacer["GestureStreamPacer and ControllerWebRtcSession"]
  Pacer --> Lane{"Control packet type"}
  Lane --> Ordered["Reliable ordered START, END, commands and ACK"]
  Lane --> Live["Freshness-oriented CONTINUE samples"]
  Ordered --> Gate["HostWebRtcSession: lease, generation and CommandGate"]
  Live --> Gate
  Gate --> Apply["AssistAccessibilityService applies action"]
  Apply --> Pixels["Android compositor generates changed pixels"]
  Pixels --> Video["Primary capture, encode, RTP, decode and EGL path"]
  Apply --> Ack["Applied-action ACK returns to controller"]
  Ack --> Proxy["InputToGlassTracker: ACK to next swap proxy"]
  Video --> Proxy
```

The ACK-to-next-swap measurement is a proxy. A buffered picture can predate the applied action, so it is not a causal input-to-photon guarantee. Input and ACKs do not wait in an application-created video reservoir.

## Recordings inspected

All three supplied recordings were materialized, visually sampled across their duration and scanned end-to-end at 2 Hz. Diagnostic text was additionally read from multiple full-resolution frames of the trace recording. This analyzes the recordings; it does not measure the live RTP stream or prove a root cause from every dark frame.

| Recording | Duration | Directly observable evidence | Interpretation limits |
| --- | --- | --- | --- |
| `1000043400.mp4` | 62.85 s | A moving WhatsApp overlay and a host connection trace. Samples show a persistent 15-FPS target, a temporary 24-FPS rescue followed by 20/15, source cadence varying from sparse to roughly 25–27 FPS, decoded samples around 1–5 FPS or absent, and frequently zero measured sender residence. Hardware implementation is `c2.mtk.avc.encoder`; shown lifetime encode average is around 25 ms, with interval cost varying. | This is not proof that packet loss explains every freeze. Controller presentation windows are often absent. Encoder average is not full encode-to-display latency. Phone/codec/network constraints and missing feedback must be separated. |
| `1000043438.mp4` | 86.26 s | Extended dark screen content with the STOP overlay, a visible recent-apps transition, and visible WhatsApp content near the end. | The recording alone does not identify whether the dark content originated in the source, decoder, compositor, app window or another state. Current main already includes first-frame decoder and stale-EGL fixes; this change does not claim to replace those fixes. |
| `1000043462.mp4` | 144.05 s | AI/browser inspection remains at “Connecting live video” and later reports an observation-expiry condition. | This is a browser connection/observation symptom as well as a video symptom. It is not a measurement of a healthy Android decoder displaying at low FPS. |

Personal Context retrieval was attempted as requested; conversation retrieval returned an error. Current repository history, existing audit documents and the actual supplied recordings grounded this audit instead. No older source snapshot was restored over current main.

## Verified defects and surgical changes

### 1. Recovery admitted one resolution but installed a larger one

`MotionVideoBudget.observe` calculated `nextRecoveryRung = 240` when recovering from 180 pixels. Its bandwidth test approved 240, but its actuator assignment selected 360 for any current rung below 360.

At 30 FPS, a 700-kbps estimate clears 240's 500-kbps nominal demand plus the 20% recovery margin. It does not clear 360's 900-kbps demand plus that margin. The old jump could immediately exceed the admitted workload and re-enter the congestion/downshift cycle.

The original assignment now sets `shortEdge = nextRecoveryRung`. The expensive encoder-resolution actuator and the admission check use the same value. Subsequent recovery to 360 still needs its own healthy evidence and bandwidth margin.

### 2. A requested FPS ceiling was mistaken for offered traffic

The predictive bandwidth model previously priced every moving source at `targetFps`, even when original capture consistently supplied fewer frames and the sender was keeping up with that supply. The prior 1-FPS starvation fix prevented some false reductions, but a regular 15-FPS source on a 60-FPS ceiling still paid for 60-FPS traffic.

The predictive demand now uses measured source supply, capped by the requested goal. For 360-wide frames, 15 actual FPS on a 60-FPS ceiling changes the first-order demand estimate from 1.8 Mbps to 450 kbps. The source FPS cap and bitrate actuator remain at the requested goal, so new faster motion can still use that capacity. Recovery admission continues budgeting the full requested cadence. Real codec, pacer, receiver and loss pressure still receive relief.

This remains an approximate early predictor, not a replacement for WebRTC's congestion controller or a promise of exact bits per frame.

### 3. Known zero media supply manufactured presentation pressure

`PhotonFreshnessGovernor.observe` built the expected glass cadence from requested, encoded and decoded FPS, then removed every zero value. With a 60-FPS ceiling, encoded=0, decoded=0 and presented=0, that discarded both measured supply counters and compared the empty display window against 60 FPS. The resulting zero delivery ratio falsely classified a quiet stream as presentation pressure.

Known zero supply now remains in the minimum. With no upstream supply, the delivery ratio is unavailable and the window is `UNKNOWN`; it cannot invent display pressure or clean delivery proof. Genuine queue, jitter, presentation-age and ACK pressure remain independent. A separate regression checks that a 350-ms sender queue still classifies as `PRESSURE` even with zero media supply.

### 4. Proven codec capacity could remain capped below 30 FPS

Low-cadence recovery compared both codec costs with 55% of the **current** frame interval. At 24 FPS that allows only 22.9 ms. A clean 25-ms encoder or decoder therefore remained at 24 FPS indefinitely, even with fresh decoder reports and actual healthy EGL presentation.

With fresh end-to-end presentation proof, recovery now checks the exact **next permitted FPS rung** and retains 20% codec headroom. For 30 FPS the allowance is 26.7 ms: 25 ms qualifies, while 27 ms does not. Missing presentation or a sample already used for recovery retains the original conservative gate. Recovery still requires consecutive completed evidence and its change cooldown, advances one rung, respects display/device ceilings, and leaves promotion above 30 to the existing bounded trial controller.

Seven capacity regressions cover encoder and decoder admission, the exact next display-limited rung, insufficient codec headroom, absent/held presentation, cooldown and a dropped frame resetting recovery votes. Five of these assertions failed on the original policy and pass with the correction. These are admission tests, not measurements that the codec itself became faster.

### 5. Independent feedback clocks erased healthy recovery evidence

During motion the host takes outbound stats about every 500 ms. Android controller decoder stats run every 500 ms during touch and every 1500 ms while idle; EGL cadence packets have their own roughly 500-ms clock. Receiving video while not touching is still a valid moving-screen use case.

`ReceiverVideoFeedback.consume` previously constructed a zero-frame receiver window whenever a new decoder report was absent, even if new measured EGL swaps were present. The zero-frame placeholder erased clean photon/cadence/detail recovery history on the intervening host ticks. A clean path could remain at 24/30 FPS or its warm-start resolution because completed decoder reports never appeared on consecutive host ticks.

| Input to a host policy tick | Decoder state | Adaptation behavior |
| --- | --- | --- |
| New decoder report with frames | Measured sample | It may contribute one recovery vote with current encoder, transport and glass evidence. |
| New decoder report with zero frames | Measured zero | It cannot prove delivery or codec capacity; it clears recovery proof. |
| No new decoder report; last report at most 2000 ms old; healthy current sender/EGL evidence | Awaiting independent decoder clock | Preserve completed votes temporarily, without adding a vote or installing higher FPS/resolution. |
| Decoder report absent longer, or current sender/glass pressure | Expired or pressured | Clear proof; existing real-pressure relief remains active. |

The original receiver-window model now explicitly marks whether it contains a decoder sample and the host-clock age of the last report. No decoder counters, frames or textures are replayed. The 2000-ms bridge accommodates the 1500-ms idle report period plus one host tick; it is a **control-plane evidence lifetime**, not a two-second video buffer. Photon, cadence, detail recovery and high-cadence trial history use that distinction. The QD overlay also shows unavailable decode FPS as unavailable, rather than manufacturing zero.

A recent EGL window may also have arrived on an earlier host tick than the decoder report. Its pressure event was already observed, but its recovery proof was never paired. The receiver now tracks the presentation sequence used for recovery separately: unused proof at most 1000 ms old may pair with a new decoder report **once**. The original pressure-freshness flag stays separate, so pairing cannot double-count a hitch. Identity changes reset that sequence, and measured zero decode clears clean proof even when the EGL window is held.

Thirteen integration regressions exercise the actual receiver-feedback boundary with independent clocks: 24→30 recovery, a completed 30→36 trial, 360→540 detail recovery, no votes on missing reports, measured zero, expiry through continued EGL swaps, no invented capacity without any decoder report, real sender queue pressure, real glass pressure, rebuilding cadence proof after prolonged decoder silence, recovery and trial completion when EGL/decode reports arrive on different host ticks, and prevention of duplicate votes/pressure. The original phase behavior failed the recovery/proof cases. Existing lease/generation/replay and packet-format tests remain authoritative.

### SDK counter limitation and the diagnostic correction

The exact pinned SDK source was retrieved and inspected, including `media/engine/webrtc_video_engine.cc` and `pc/rtc_stats_collector.cc`. In this version, `info.frames_sent = stream_stats.frames_encoded`. Both names ultimately describe the encoding counter. `framesSent` is therefore not an independent measurement of complete frames departing the pacer or reaching the peer.

The QD overlay previously labelled its encoded FPS as `send`. The original label now reads **encode**, beside **decode** and **present**. Sender packet residence, transmitted bytes/packets and receiver evidence remain the available transport measurements. No independent wire-departure frame meter is fabricated from the SDK's aliased counter.

## Ripple checks

| Changed node | Downstream consumers | Preserved contract |
| --- | --- | --- |
| Predictive demand in `MotionVideoBudget` | Existing pixel pressure hysteresis | Only prediction discounts measured sparse production. Configured FPS, recovery budget and native GCC remain authoritative. |
| Recovery assignment | `MotionVideoBudget.apply` → adapted source dimensions and sender bitrate ceiling | The admitted rung is the installed rung; logical screen geometry and touch mapping remain separate from encoded size. |
| Zero-supply classification in `PhotonFreshnessGovernor` | Cadence/detail promotion gates in the host policy lane | No supply cannot manufacture glass pressure or clean proof. Real queue/jitter/liveness pressure still applies independently. |
| Next-rung codec admission in `VideoCadenceGovernor` | Source FPS ceiling → existing native encoder/pacer | Fresh glass proof permits measured capacity recovery with headroom; unknown evidence retains conservative behavior. |
| Availability/age in `ReceiverVideoFeedback` and `VideoHealthWindow` | Photon, cadence, fine trial and detail recovery | Missing reports are distinct from measured zero. Reports remain one-use; bounded waits never add recovery votes or promote. |
| QD measurements in `HostWebRtcSession` | Host connection trace | Encoded FPS is labelled as encoding; missing decoder samples are unavailable. The control wire format is unchanged. |

## Frame spacing and the buffer reservoir

At 30 distinct FPS, average frame spacing is 33.3 ms. At 35 it is 28.6 ms; at 60 it is 16.7 ms. These are timing identities, not device results. The stages overlap: one frame can be encoded while earlier packets are in transit and another frame is being decoded.

An arrival reservoir can absorb brief timing variation if frames reach the receiver before their deadlines. If genuine capture or successful decode supplies 2 FPS, a 100/500-ms buffer cannot create the missing screen updates. Increasing delay indefinitely makes remote input act on old pixels.

Current native policy retains best-effort playout guidance `min=10,max=500 ms`, with WebRTC owning packet reorder, packet repair, jitter timing and timed decode. The browser's supported target ladder remains `100 → 150 → 250 → 350 → 500 ms`, with measured pressure and recovery hysteresis. This patch adds no decoded-frame FIFO, second encoder, interpolation, fixed 500-ms hold or duplicated packet-pacing loop.

Hardware/software factories, shared EGL textures, `MAINTAIN_FRAMERATE` during motion, fine high-FPS trials and display/thermal limits are already present. The code can probe capacity above 30; a larger requested FPS does not force unavailable source, codec or network capacity into existence.

## Validation and remaining device gate

Four new regression tests cover a regular 15-FPS producer under a 60-FPS ceiling; exact 180→240 recovery with bandwidth insufficient for 360; zero media supply with both an empty and a buffered presentation window; and independent queue pressure during zero supply. The two motion defects were reproduced on the original baseline; the zero-supply regression is also checked against that baseline. Existing tests retain real congestion, source starvation, codec overload, presentation pressure and high-FPS recovery coverage.

The continuation adds 20 regressions (seven capacity and thirteen feedback-clock cases). Final executed Android/Node test counts, debug/release lint and assembly results, along with the final-head CI run, are recorded in PR #584 after verification.

Final executed check results are recorded in the pull request. Passing software tests/builds establishes code integrity, not Google-Meet-level smoothness on the user's phones.

A valid device comparison uses the same two physical phones for at least ten minutes before/after: Wi-Fi/direct, mobile/TURN, scrolling, rotation and animation, with and without AI snapshots. Record producer/encoded/decoded/presented FPS; transmitted bytes/packets (the SDK sent-frame statistic is aliased); encoder/decoder cost; sender residence; actual/target jitter residence; packet loss/RTT/route; display gap p95/p99/max; and thermal state. Confirm fewer freezes without hiding increased action-to-visible latency. A causal visible action marker or external camera is needed for real input-to-photon measurement.

## Auto-fixer

`tools/fix_measured_frame_flow.py` contains complete guarded diffs for the production changes and regression tests. It accepts exact source hashes from the original `8222234f` baseline or the preceding PR checkpoint `f67dc11a`, validates all files before mutation, rejects unknown edits, supports `--check`, verifies resulting hashes and handles already-fixed files idempotently. It edits the original code rather than installing an override layer.

```bash
python3 tools/fix_measured_frame_flow.py --root /path/to/AarisRemote --check
python3 tools/fix_measured_frame_flow.py --root /path/to/AarisRemote
```

## Primary implementation references

- [Pinned SDK implementation and frame-counter alias](https://github.com/webrtc-sdk/webrtc/blob/73cb8180f7258ee292878d6edd05177f41883962/media/engine/webrtc_video_engine.cc#L2623-L2624)
- [WebRTC playout-delay guidance](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/README.md)
- [WebRTC statistics specification](https://www.w3.org/TR/webrtc-stats/)
- [Android MediaProjection](https://developer.android.com/media/grow/media-projection)
