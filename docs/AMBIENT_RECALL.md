# Ambient recall: behavior and device acceptance

## Use

Open **Yaad → Apna timer set karein**, choose one or more words/ayahs, set an interval
between 1 and 120 minutes, and tap **Shuru karein**. Android asks for permission to display
over other apps. Return to Aaris after allowing it. Notification permission is optional;
allowing it keeps the session's stop control visible in the notification drawer.

**10 second mein test card** uses the real service and selected source content. Leave Aaris
and open another app. This short first interval does not change the chosen regular interval.

The Hadith tab is separate: its six collection links and search open Sunnah.com in a browser.
They require internet and are not an installed/offline Hadith corpus.

## Delivery contract

- One timer across external apps. Switching from WhatsApp to YouTube does not reset it.
- Only unlocked, interactive screen time outside Aaris counts. Opening Aaris or locking the
  screen pauses the timer and removes a visible card. No app-usage access is needed.
- Dismissing or rating a card starts a fresh interval. Only one card can exist. A card left
  alone for two minutes closes without a learning rating; there is no backlog of missed cards.
- Default interval practice rotates explicitly enrolled items, preferring due work. Optional
  due-only mode shows nothing if there is no due work. Unknown/missing-source targets are skipped.
- Words reveal the source meaning. Phrases and ayahs reveal original source text. Transition
  cards show the source ending and next opening with separate coordinates.
- Display, dismissal and reveal never become successful recall. Only explicit self-ratings
  enter the existing learning ledger, with one immutable event ID per card's rating.
- Stop from the card, Yaad settings, Android's active-apps controls or the session notification.
  The session is not silently restarted after process termination, reboot or a user stop.
- Android/OEM power management and apps that suppress third-party overlays can prevent delivery.
  This is a user-started study session, not a guarantee that every app permits overlays.

## Native implementation

`AmbientSession` owns the monotonic timer, single-card state and fair candidate rotation.
`AmbientRecallService` adapts it to elapsed realtime, screen/keyguard eligibility, the same
learning database, and `TYPE_APPLICATION_OVERLAY`. API 30+ uses a display-associated window
context for the actual view hierarchy and window metrics. API 34+ declares the `specialUse`
foreground-service type and corresponding permission/property. Launch waits for the Activity
to resume after permission results. The service and its stop action are not exported.

No accessibility service, usage-statistics access, exact alarms, boot receiver, wake lock,
screen capture or internet permission was added. Permission/session preferences stay on the
device and cannot be enabled by a restored learning backup. It needs no cloud credentials.

## Automated verification

19 timer/selection regressions cover visible time, switching apps, long lock pauses, exact
expiry, no stacked cards, reset on dismissal, hidden-card reset, stopping, preview behavior,
invalid intervals, fair rotation, due-only abstention and no implicit learning events.
The 113-check core suite, corpus/source integrity, Android Java compilation and resource/
manifest linking pass. These are not Android runtime or screenshot tests.

## Physical-device acceptance — not yet run

Use API 26 and a recent API 34/35 device, including a low-memory/OEM battery-managed phone.

1. Install as an update over 0.2.0; confirm bookmarks, position and learning remain.
2. Deny overlay permission: no service/window should start. Grant it: a user-started session
   should show the test card over WhatsApp/YouTube after ten active seconds outside Aaris.
3. Repeat with notification permission denied, then enabled. Check each available stop control.
4. Close the card; check the next chosen interval. Change external apps halfway through.
5. Lock before expiry, unlock later: count only the remaining active time. Open Aaris while a
   card is visible: the card must disappear and the timer must pause.
6. Revoke overlay permission during a session. Force-stop/reboot/kill the process: no hidden
   restart or queued burst; status should offer an explicit fresh start.
7. Reveal/dismiss without rating: review counts must remain unchanged. Rate once rapidly:
   exactly one rating. Pause an item in Aaris: it should no longer be selected.
8. Check narrow screens, landscape/cutouts, 200% font size, TalkBack, keyboard/insets, long
   ayahs, RTL word taps and close/stop controls. Only the card rectangle should intercept touch.
9. Test source links online and while offline; test Quran search/reading in airplane mode.
10. Verify export/restore and process recreation with the system file picker on the device.

## Platform references

- https://developer.android.com/reference/android/provider/Settings#canDrawOverlays(android.content.Context)
- https://developer.android.com/reference/android/content/Context#createWindowContext(int,%20android.os.Bundle)
- https://developer.android.com/develop/background-work/services/fgs/service-types#special-use
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://developer.android.com/develop/ui/views/notifications/notification-permission
- https://sunnah.com/
