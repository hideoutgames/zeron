# Zeron for iOS

A UIKit viewport onto the zeron mesh, built on the Rust mobile core. The phone
is a **peer device**: it mirrors the workspace registry, joins per-chat session
rooms, and drives remote engines through the durable command ledger. No agent
runs on the phone.

**Rust decides what to paint and where; Swift paints, scrolls and handles
gestures.** Everything in Rust is platform-neutral — the future Android app
links the same library. See [`docs/mobile-rewrite.md`](../../docs/mobile-rewrite.md).

## Build & run

Requires Xcode 26+ and a Rust toolchain with the iOS targets:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cd apps/ios
xcodebuild -project Zeron.xcodeproj -scheme Zeron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The Zeron target's **Rust core** build phase runs `scripts/ios/build-core.sh`,
which builds `crates/mobile` for the active platform (always optimized — the
`mobile` cargo profile) and refreshes the committed UniFFI bindings in
`Zeron/Core/Generated/`. `ZERON_SKIP_CORE=1` reuses the last built library
when iterating on Swift only.

## Layout

```
Zeron/
  App/         AppDelegate, SceneDelegate, AppModel (owns CoreClient; maps
               workspace snapshots to view models; Keychain credentials)
  Core/        Generated UniFFI bindings; Fonts (the exact bytes Rust measures,
               registered with CoreText) + CoreText fallback measurer
  Design/      Palette (Zeron color roles → light/dark), Glass helpers,
               cell-grid status glyph, harness brand marks
  Transcript/  TranscriptListView (virtualized scroll host over LayoutFrame),
               RowView/RowModel (CoreText painter for Rust display lists,
               streaming veil), FrameRelay
  Session/     SessionViewController, SessionSource (Core/Fixture), new-session
               canvas
  Composer/    ComposerBar (glass capsule ⇄ card with inline context chips;
               send/queue/steer/stop), question and queue panels, attachments
  Threads/     Sessions (foldable sidebar sections)/folder/search lists,
               cells, new-project folder browser
  Shell/       Tab bar (Sessions, Settings, search; "New session" accessory
               with live summary), sign-in
  Debug/       Transcript lab + hitch meter
```

At regular iPad widths, the Sessions sidebar keeps its title and persistent
search at the top beside the detail column. Its navigation controller is
registered as the sidebar's first child before the split assigns the primary
column, so UIKit does not add an extra navigation bar above it. Compact widths
use the phone's tab shell.

### Model picker

The composer model chip opens a native Swift/UIKit sheet drawer in both new
and existing sessions. It retains the provider tabs, scoped search, favorites,
model rows and pinned settings tray from the
[ZRemote iOS picker](https://github.com/hideoutgames/zremote/tree/ebf047056a307965c2a329eb7dce2bac9ed583dd/apps/ios/Zeron/Composer).
The drawer offers a content-sized detent and a large detent. Drag its grabber
down, press Escape, or use the accessibility escape gesture to close it.
The list and settings tray remain scrollable when space is limited or search
opens the keyboard.

Provider tabs browse without changing the selection. Inactive logos, including
Claude, use the same muted template tint; the selected tab retains its brand
color. Selected model rows share the drawer's corner-radius setting. Favorites
persist on this device; demo launches keep them in memory.

Effort and model options live in the drawer's settings tray. Devin Fusion opens
a separate native Liquid Glass popup containing Lead, Effort, Sidekick and its
advertised switches. It has no back button; dismissing the popup returns to
the still-open drawer. The popup stays a popover on both iPhone and iPad.

Existing sessions keep their current provider and sandbox settings. New-session
drafts retain model options, including when reopened; drafts saved before model
options were introduced still decode. Catalog refreshes retain the latest pick
and discard responses for an obsolete host or request. The Swift catalog uses
the existing core model metadata and sends validated choices through `ChatConfig`.

Picker coverage lives in `ZeronTests/ModelCatalogTests.swift`,
`ZeronTests/ModelPickerPresentationTests.swift`, and the model-picker cases in
`ZeronUITests/SessionFlowTests.swift`. Run those targeted cases on Xcode 26+;
Swift syntax checks on other platforms do not replace a native build or
simulator run.

From `apps/ios`, the targeted picker checks are:

```sh
xcodebuild -project Zeron.xcodeproj -scheme Zeron \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ZeronTests/ModelCatalogTests \
  -only-testing:ZeronTests/ModelPickerPresentationTests \
  -only-testing:ZeronUITests/SessionFlowTests/testModelPickerInNewSession \
  -only-testing:ZeronUITests/SessionFlowTests/testModelPickerInSession \
  -only-testing:ZeronUITests/SessionFlowTests/testEffortPickerInSession \
  -only-testing:ZeronUITests/SessionFlowTests/testServiceTierInSession \
  -only-testing:ZeronUITests/SessionFlowTests/testNewSessionRemembersDraftWhenClosed test
```

### Transcript pipeline

1. `zeron-client` applies session-doc updates incrementally (O(changed
   entries)) and publishes immutable snapshots.
2. `TranscriptView.attach(client, chatId)` subscribes **in Rust**; the layout
   thread turns entries into rows (one per markdown block / user message / tool
   group), reparses streaming markdown incrementally, and measures every row
   with `zeron-text` at the viewport width.
3. Each pass publishes a `LayoutFrame`: exact heights + prefix-sum offsets.
   `rowsIn(y0, y1)` is a binary search; `display(i)` builds a display list
   (text runs at exact positions, boxes, links, scrollers, widgets).
4. `TranscriptListView` positions reusable `RowView`s at those offsets and
   paints runs with CoreText at the Rust coordinates — measurement and
   rendering can't disagree. Display models for rows beyond the viewport are
   prefetched off the main thread.

## Launch arguments

| Arg | Effect |
| --- | --- |
| `-demo` | Offline demo workspace (Rust `DemoHost`: registry, docs, streaming replies) |
| `-fast` / `-longreply` | Demo stream speed / reply length |
| `-big` / `-huge` | Demo transcripts with 120 / 600 turns |
| `-route chat:<id>` / `new` / `more` / `search` | Open a screen at launch |
| `-signedout` | Clear stored credentials |
| `-dev <userId> <orgId> [-edge <url>]` | Dev bearer against an `AUTH_MODE=dev` edge (e.g. `wrangler dev`); not persisted |
| `-harness <id>` | Default harness for new sessions (`mock` for live-stack tests) |
| `-bench` (with `-lab`) | Display-link fling benchmark; writes `Documents/bench.json` |
| `-measureopen` | Session open latency; writes `Documents/open.json` |
| `-lab [-turns N] [-autostream] [-autoscroll] [-top] [-meter]` | Transcript lab over fixture markdown, with an on-screen hitch meter |

## Tests

The composer's attachment button sits above the shared glass as a sibling,
with the same layout anchors in both capsule and card modes. Keeping the menu
source out of the glass content prevents the whole resting composer from
morphing into the Photos / Camera / Files / Paste menu.

From the repository root, run the attachment-menu regression on both an
iPhone and an iPad simulator (the test uses landscape on iPad):

```sh
xcodebuild -project apps/ios/Zeron.xcodeproj -scheme Zeron \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -parallel-testing-enabled NO \
  -only-testing:ZeronUITests/SessionFlowTests/testAttachMenuOpens test
```

This covers the resting capsule, the new-session card, a focused draft, and
repeated opening/dismissal with an unfocused draft. Inspect its
`attach-resting-*` screenshots and the opening/closing animation: the composer
should remain visible and stationary while the menu originates at `+`.

```sh
# Rust
cargo test -p zeron-text -p zeron-markdown -p zeron-client -p zeron-mobile
cargo test --release -p zeron-mobile --lib bench_layout -- --ignored --nocapture

# Line-break accuracy vs CoreText (same font bytes), flows, hitch benchmarks
xcodebuild … -only-testing:ZeronTests/LineBreakAccuracyTests test
xcodebuild … -only-testing:ZeronUITests/SessionFlowTests test
xcodebuild … -only-testing:ZeronUITests/ScrollPerformanceTests test

# iPad sidebar title/search placement in landscape and portrait
xcodebuild -project Zeron.xcodeproj -scheme Zeron \
  -destination 'platform=iOS Simulator,name=<installed iPad simulator>' \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:ZeronUITests/IPadLayoutTests/testSidebarHeaderStaysAtTop test
```

Live stack (real edge + headless engine; see `ZeronUITests/LiveStackTests.swift`):

```sh
(cd edge && npx wrangler dev --port 27650 --var AUTH_MODE:dev) &
ZERON_DATA_DIR=/tmp/e2e ZERON_IPC_PORT=27811 ZERON_EDGE_URL=http://localhost:27650 \
  ZERON_EDGE_TOKEN=alice@org1 ZERON_ORG_ID=org1 ZERON_HARNESS=mock target/debug/zeron headless &
TEST_RUNNER_ZERON_LIVE_EDGE=http://localhost:27650 xcodebuild … -only-testing:ZeronUITests/LiveStackTests test
```

The test launches the app with `-harness mock`: a chat's configured harness
wins over the engine's `ZERON_HARNESS` default, so without it a real agent
would run.

## Session notifications

The edge sends them (`edge/src/push-notify.ts`, `registry-room.ts`): when a
session's registry row changes it applies the desktop's rule (run finished,
waiting on your input, run failed) and pushes to every phone that registered
with `POST /registry/:org/push-target`. The app asks for permission the first
time a session is started from the phone (or from Settings → Notifications),
registers its APNs token with the choices from Settings, stays quiet while
open, and opens the session a notification is tapped for.

Setup once per deployment: an APNs auth key (Apple Developer → Keys →
Apple Push Notifications service), then `wrangler secret put APNS_KEY_P8` (the
`.p8` contents) and `wrangler secret put APNS_KEY_ID` in `edge/`. The
TestFlight workflow enables the Push capability on the App ID itself.
`/registry/:org/stats` shows registered phones and recent deliveries.

## TestFlight release

Run the **TestFlight** workflow from GitHub Actions on `main`. It installs the
Rust iOS targets, selects the next build number from App Store Connect,
archives (device, Release — the Rust core builds in the archive) with
automatic signing, and uploads a TestFlight build (internal, or external with
beta review). Secrets: `AC_API_KEY_P8`, `AC_API_KEY_ID`,
`AC_API_ISSUER_ID`.
