# Aaris Pharmacy — scan/photo/video evidence hardening (2026-09-11)

## Dependency and state map

The authoritative write path remains unchanged:

`camera/photo/video -> ML Kit OCR + barcode -> MedicineFrameEvidence -> deterministic medicine understanding -> optional selected Local AI -> evidence validation -> intake resolution -> explicit/verified save gate -> PharmacyController -> revision-bound atomic database write`.

The scanner and AI services still cannot write inventory directly. Local AI remains an evidence-grounded proposal layer and a stale/changed route cannot gain write authority.

## Direct camera intersection

`ScannerScreen` continuously builds a bounded evidence window before the user taps Capture. Previously the `autoSubmit` path erased that entire live evidence window immediately before OCR of the high-resolution still. This could lose a barcode/front label already read by the stream when the still image mainly contained the composition or expiry panel.

The capture path now preserves the bounded live evidence and appends the captured still as the final frame. The still is explicitly labelled `Captured still photo` for traceability. Deterministic understanding and the later Local-AI handoff therefore receive one fused, bounded view of the same pack instead of a single fragile snapshot.

## Photo path

Queued photo capture already follows the durable intake path: the selected source is copied into app-private storage, the job row is committed before acknowledgement, OCR runs locally, deterministic drafts are checkpointed, the selected Local AI is consulted only when the capture-bound route remains valid, and source cleanup happens only after durable OCR state exists.

The immediate Upload photo path remains intentionally interactive: it runs the same `MedicineVisionService` OCR/barcode extraction and opens the same review inbox. It does not bypass validation or the authoritative controller save boundary.

## Video-window intersection

Video intake processes bounded native sampling windows and checkpoints `completed drafts + unresolved carry + cursor` atomically. A boundary bug existed in the carry rule: as soon as at least one draft existed, only frame sequences already assigned to the final draft were retained. If the user had just turned the camera toward the next medicine near the end of the window, those new but not-yet-grouped frames could be discarded before the next window.

The carry rule now keeps both:

- every frame belonging to the final unresolved draft; and
- the last 12 transition frames from the current window, even if they are not yet assigned to a draft.

Carry remains bounded to 48 frames, preserving the earliest identity views and newest transition evidence. Completed drafts are still emitted exactly once, so the change improves cross-window recall without creating a second queue or unbounded memory growth.

## Regression coverage

`test/medicine_intake_concurrency_test.dart` now verifies that unassigned trailing frames survive a video-window boundary and that the enlarged carry remains bounded while completed drafts are emitted once.
