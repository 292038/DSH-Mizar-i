<!-- Generated from method-level triage at HEAD ae26bd9. Evidence: DSH-MizarUITests/ method bodies; no xcodebuild/test run performed. -->
# Phase 2 XCUITest triage: 80 methods -> 16 kept, the rest to snapshot/unit/live

Task: cut `DSH-MizarUITests` from 80 XCTest methods / 9 classes to <=16 without losing the
assertions, and design (not implement) the live layer. Repo `iOS/`, branch `main`, HEAD `ae26bd9`.

**Baseline** (recorded before this triage; no run in this session): 80 methods, 1806.6 s test
execution / 1831 s wall, avg 22.6 s. AppFlowTests 57/1196 s, AccountUITests 9/282 s,
Feature094UITests 5/130 s, LanPriorityUITests 1/86 s, ActivityUITests 2/36 s,
RunningDetailUITests 1/33 s, ForkedSessionUITests 1/26 s, LANFailoverUITests 1/18 s,
ScreenshotTour 3/0.2 s (env-gated skips). `ScratchIPadRotateUITests.swift` is untracked WIP and
is **not** part of the suite; its 1 method is ignored here.

## Reading the table

- **category** — `L` layout/copy only (asserts text/label/visibility of a fixed state),
  `S` state/flow (owns timing, relaunch, network transitions, gestures, live activity),
  `N` live-network (needs a real host/network; **no row qualifies today**, see §2.4),
  `TOOL` no assertions (screenshot tour).
- **target** — `keep` = stays XCUITest; `snapshot` = golden/presenter snapshot of the same
  screen state; `unit` = MizarKit (or new app) unit test of the same assertion; snapshots and
  units must assert the *same* identifier/label/enabled/visibility set the row asserts today
  (never weaker); `keep(merge->x)` = assertions fold into kept method x, method deleted;
  `tool-out-of-suite` = move out of the regression target, not a coverage loss.
- line numbers are the `func` declaration line; `file:line` in the first column.

## 1. Method-by-method classification


### AccountUITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:59` testSignedOutSettingsShowsBlankAccountRow | L | snapshot | Blank account row copy; fixed signed-out state (assertions :68,:72). |
| `:79` testAboutDoesNotOfferInviteRedemption | L | snapshot | Absence of a redeem row on About; fixed state (:84). |
| `:91` testRegisterCreatesAccount | S | snapshot+unit | Register -> profile -> relaunch; account client/store logic belongs to MizarKit unit tests; profile sheet snapshot. |
| `:129` testLoginWithFixtureAccount | S | snapshot+unit | Fixture-account login; same client/store path; profile snapshot. |
| `:146` testWrongPasswordShowsAnError | L | snapshot+unit | Wrong-password copy/visibility; error mapping unit + error-state snapshot. |
| `:163` testRedeemInviteMakesAccountPaid | S | snapshot+unit | Invite redeem flips plan row (:190-:192); AccountClient unit + paid-row snapshot. |
| `:203` testSubscriptionCTAUsesStoreKitAndMakesAccountPaid | S | keep | Mock StoreKit purchase flips plan (:216-:224); system transaction path cannot be snapshotted. |
| `:232` testAttachmentsAreLockedForSignedOutAccounts | L | snapshot | Signed-out composer shows locked attachments (:236-:240); composer snapshot. |
| `:247` testAttachmentsUnlockForPaidAccounts | S | snapshot+unit | Paid unlock after fresh-start+create+redeem chain (:288-:341); gate policy unit + locked/unlocked snapshots. |

### ActivityUITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:45` testFreeAccountNeverCallsSessionActivity | S | snapshot+unit | Free account sends no session.activity polls in a 4.5 s window (:53,:56-:62); gate policy unit + summary-row snapshot. |
| `:71` testPaidAccountExpandsRunningTurnDetail | S | snapshot+unit | Paid feed expands the running detail (:82-:97); expanded-state snapshot + feed-gate unit; expand/collapse mechanics remain in kept RunningDetail test. |

### AppFlowTests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:880` testSessionListNamesTheHostAndOffersANewSession | L | snapshot | Host name + new/refresh buttons in a fixed list state (:882-:887). |
| `:890` testAnUnpairedLaunchOffersPairing | L | snapshot | Unpaired launch renders the pairing screen (:897-:901); startup routing unit + pairing snapshot. |
| `:910` testTheSidebarOpensSettings | L | snapshot | Settings sheet content; close returns to list (:919-:943); nav covered by kept sidebar test. |
| `:954` testANotificationSwitchSurvivesARelaunch | S | unit | Toggle persists across relaunch (:976-:980); UserDefaults logic unit (MizarSettings); relaunch itself kept at 1198. |
| `:997` testTheLogExportMakesAZipAndOffersIt | S | snapshot+unit | Export writes a .zip and offers it (:1005-:1026); archive writer unit + settings-row snapshot; share-sheet presentation drops to manual (risk R4). |
| `:1032` testTheAboutSectionShowsTheVersionAndBothCredits | L | snapshot | About version/credits copy (:1035-:1058); fixed screen + bundle-version unit assertion. |
| `:1068` testTheSettingsScreenFollowsTheLanguage | L | snapshot+unit | zh/en settings copy across a relaunch (:1073-:1109); per-locale presenter/goldens; .strings keys already unit-checked. |
| `:1119` testAFirstPairingShowsAFullScreenDownload | L | snapshot | First-pairing download screen in a fixed state (:1129-:1149); layout from a fixed model. |
| `:1158` testRefreshingShowsAProgressWindow | S | snapshot+unit | Refresh progress window with counter/eta (:1175-:1188); progress model unit + syncing-state snapshot. |
| `:1198` testAnUnreachableMacKeepsTheStoredSessions | S | keep | Offline host -> terminate/relaunch -> stored sessions -> pull-refresh (:1201-:1267); network state + relaunch. |
| `:1274` testOpeningASessionShowsTheComposer | L | snapshot+unit | Composer presence and send enablement with text (:1276-:1289); enablement rule unit + composer snapshot. |
| `:1305` testADeletedWorkspaceIsNotListed | L | snapshot+unit | Deleted workspace filtered out (:1310-:1329); WorkspaceCatalog filter unit + list snapshot. |
| `:1342` testTheNewSessionPickerDoesNotOfferADeletedWorkspace | L | snapshot+unit | Picker excludes deleted workspace (:1344-:1351); same filter + sheet snapshot. |
| `:1362` testRefreshingReportsTheHostsWorkspaces | L | snapshot+unit | Refresh sheet workspace count (:1364-:1373); aggregation unit + sheet snapshot. |
| `:1407` testTheFiguresSurviveAReadThatFails | S | snapshot+unit | Failed read must not erase model/context figures (:1412-:1434); view-model retention unit + bar snapshot. |
| `:1450` testTheFiguresSurviveAColdAnswer | S | snapshot+unit | Cold answer must not erase figures (:1455-:1471); same retention path. |
| `:1479` testTheComposerBarShowsTheModelContextAndCommands | L | snapshot | Composer bar model/context/commands labels (:1481-:1491); fixed bar snapshot. |
| `:1510` testTheConversationRendersMessagesAndFailures | L | snapshot | Transcript renders fixture messages and failure card (:1514-:1545). |
| `:1558` testATurnRowCountsItsStepsFromTheMarkers | L | snapshot+unit | Step count derived from markers (:1564-:1565); derivation unit + row snapshot. |
| `:1585` testATurnRowIsNotExpandable | L | snapshot | Row tap reveals nothing (:1594-:1616); collapsed-row snapshot + absent detail. |
| `:1627` testARunningTurnSaysItIsRunning | L | snapshot | Running vs completed wording in a fixed fixture state (:1636-:1646). |
| `:1655` testTheRunningRowIsWordedAsAskedInChinese | L | snapshot | Chinese running-row wording (:1664-:1675); zh-locale snapshot. |
| `:1690` testARunningTurnsClockMoves | S | keep | Running row clock advances on its own (:1692-:1702); timer. |
| `:1720` testARunningTurnShowsNoAnswer | L | snapshot | Running turn shows no answer; relative frame order (:1736-:1759); layout snapshot. |
| `:1771` testTheConversationCanBeRefreshed | S | snapshot+unit | Refresh keeps the transcript while the read is in flight (:1778-:1806); view-model unit + loading snapshot. |
| `:1830` testAFinishedTurnIsNoticedWithoutARefresh | S | keep(merge->1879) | Turn finished is noticed without a tap (:1847-:1863); fold into kept poll test 1879. |
| `:1879` testASendStartsTheRunningPollWithoutATap | S | keep | Send starts the poll; 10 s interval measured at the host (:1889-:1942). |
| `:1957` testATurnThatEndsAfterASendIsNoticedWithoutATap | S | keep(merge->1879) | Turn end after send noticed without a tap (:1979-:1986); fold into 1879. |
| `:1998` testTheContextFigureOpensItsBreakdown | L | snapshot | Context breakdown popover content (:2006-:2012); fixed state. |
| `:2016` testTheCommandButtonDraftsACommand | S | snapshot+unit | Command drafts '/goal ' into the field (:2022-:2048); draft/insertion unit + sheet snapshot. |
| `:2053` testAPendingApprovalOffersExactlyTwoOutcomes | L | snapshot | Approval card offers exactly allow-once/reject; Chinese detail (:2059-:2070). |
| `:2076` testAQuestionBatchIsRefusedUntilItIsComplete | L | snapshot+unit | Submit disabled until the batch is complete (:2080-:2088); enablement unit + two-state snapshot. |
| `:2091` testASentMessageAppearsInTheConversation | S | snapshot | Transcript gains the sent message; field clears (:2113-:2153); send path kept in 1879, transcript render snapshot. |
| `:2164` testARunningTurnsClockIsNotNegativeWhenTheHostsClockIsAhead | S | unit | Clock clamped when the host clock is ahead (:2175-:2181); duration formatter unit. |
| `:2195` testAnAnswerTooLargeToDeliverIsAskedForAgainSmaller | S | unit | Oversized answer re-asked smaller (:2204-:2211); client pagination unit (PairingClient). |
| `:2244` testTheLiveActivitySurvivesEverythingFinishing | S | keep | Live Activity survives the turn finishing (:2246-:2283); extension process. |
| `:2306` testBackgroundingRefreshesTheSessionListAndTheRunningSession | S | keep | Background -> foreground refreshes list and running session (:2317-:2342). |
| `:2355` testAHostSideRefusalDoesNotRebuildTheConnection | S | unit | Host-side refusal must not rebuild the socket (:2360-:2375); connection-reuse policy unit. |
| `:2402` testSwitchingSessionsDoesNotCarryTheOtherOnesState | S | keep | Switching sessions must not carry draft/history (:2413-:2466). |
| `:2477` testTheSidebarOpensAndCloses | S | keep | Sidebar opens/closes by swipe and drag (:2482-:2511). |
| `:2521` testTheDrawersTakeDiagonalAndReverseSwipes | S | keep(merge->2477) | Diagonal/reverse drawer gestures (:2533-:2560); fold into 2477. |
| `:2568` testTheModelPickerListsTheHostsProviders | L | snapshot+unit | Model picker lists host providers (:2577-:2585); catalogue unit + sheet snapshot. |
| `:2588` testChoosingAModelRevealsItsReasoningLevels | L | snapshot | Reasoning levels revealed after model choice (:2590-:2597); two-state snapshot. |
| `:2600` testThePermissionPickerWarnsBeforeFullAccess | L | snapshot | Permission presets + full-access warning copy (:2605-:2610). |
| `:2625` testARefusedModelSwitchGoesBackAndSaysSo | S | snapshot+unit | Refused model switch rolls back and says so (:2646-:2701); refusal policy unit + error snapshot. |
| `:2730` testSwitchingcomputersDoesNotCarryTheFirstcomputersCatalog | S | snapshot+unit | Switching computers must not carry the first catalogue (:2749-:2790); per-host keying unit + list snapshot. |
| `:2802` testTheLastOpenedMacIsTheOneReopened | S | unit | Last-opened Mac reopened after relaunch (:2813-:2846); defaults unit (MizarSettings). |
| `:2863` testASendDuringAReloadDoesNotStartASecondLoad | S | keep | Send during reload must not start a second load (:2880-:2908); in-flight overlap. |
| `:2917` testInterfaceFollowsTheLanguageAndContentDoesNot | L | snapshot+unit | Interface zh/en, content unchanged (:2921-:2958); per-locale presenter/goldens. |
| `:2966` testTheDockTucksAwayWhileTyping | S | snapshot+unit | Dock tucks to a pill while typing (:2968-:2982); tuck rule unit + docked/tucked snapshots. |
| `:2987` testTheOpenSessionsWorkspaceIsExpanded | L | snapshot | Open session's workspace auto-expanded in the sidebar (:2989-:2995). |
| `:3002` testTheHomeScreenStartsASessionWithItsFirstPrompt | S | keep | Create a session from the home screen with its first prompt (:3004-:3022). |
| `:3032` testTheHomeScreenChoosesTheModelItsSessionStartsOn | S | snapshot+unit | Home model choice applies to the created session (:3040-:3076); selection unit + home snapshot. |
| `:3088` testTheTurnIndexOpensByADragAndJumps | S | keep | Turn index opens by a drag and jumps (:3095-:3112). |
| `:3116` testTheTitleOpensTheTurnIndex | S | keep(merge->3088) | Title button opens the same index (:3118-:3128); fold count assertion into 3088. |
| `:3133` testTheConnectionWindowMeasuresLatency | L | snapshot+unit | Latency class + poll copy (:3135-:3143); classification unit + panel snapshot. |
| `:3147` testTheComputersNameOpensTheComputerPicker | L | snapshot | Computer picker lists the paired host (:3151-:3154); fixed sheet. |

### Feature094UITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:66` testPermissionPresetSticksAndTheToolbarFollows | S | keep | Preset sticks and toolbar follows across picker re-open (:77-:136); 0.9.4 regression. |
| `:151` testArchivingASessionRemovesItAndKeepsTheCopyAction | S | snapshot+unit | Long-press archive removes row, keeps copy (:156-:183); menu/archive client unit + menu/row snapshot (context-menu render risk R4). |
| `:197` testRefusedArchiveKeepsTheSessionAndShowsTheError | S | snapshot+unit | Refused archive keeps row and shows error (:206-:222); error policy unit + error-row snapshot. |
| `:239` testLocalNetworkUnlocksPaidFeaturesAndSaysSo | S | snapshot+unit | LAN state forced by -mizarLocalNetwork (:265-:294): copy/layout snapshots per forced state; paid-unlock rule + 3 s poll cadence unit. |
| `:307` testReturningToTheForegroundReconnects | S | keep | Foreground return reconnects without a tap, counted at the host (:313-:346). |

### ForkedSessionUITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:83` testAForkedSessionIsListedAndOpensItsBranchHistory | S | snapshot+unit | Fork listed, subagent hidden, refresh keeps it (:93-:154); WorkspaceCatalog classification unit (filter sits there, header :14) + row snapshot. |

### LANFailoverUITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:102` testTheLANGoingAwayFailsOverToTheRelay | S | keep | LAN gone -> relay failover counted at both listeners (:106-:158). |

### LanPriorityUITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:74` testLocalNetworkFirstGatesTheScanAndSurvivesARelaunch | S | keep | LAN-first gates the hello scan and survives relaunch (:74-:158, class header :13-:30). |

### RunningDetailUITests.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:70` testScrollingBackReadsOlderDetailAndReexpandingDoesNotRefetch | S | keep | Paging back + re-expand without refetch, counted as activityPages (:70-:160, header :6-:16). |

### ScreenshotTour.swift

| method (line) | cat | target | rationale |
|---|---|---|---|
| `:70` testTour | TOOL | tool-out-of-suite | Writes screenshots; asserts nothing; env-gated skip (ScreenshotTour:24-:26). |
| `:144` testWindowsTour | TOOL | tool-out-of-suite | Windows tour; same tool, same env gate. |
| `:204` testPadTour | TOOL | tool-out-of-suite | iPad-only tour; skips on phone (ScreenshotTour:205). |

**Counts by category:** L = 31, S = 46, N = 0, TOOL = 3 (total 80).

**Counts by target (rows):** snapshot 21 pure, snapshot+unit 31, unit 5, keep 20 rows (16 methods after merges), tool-out-of-suite 3.

`keep` rows = 20, of which 4 fold into another kept method (:1830 testAFinishedTurnIsNoticedWithoutARefresh, :1957 testATurnThatEndsAfterASendIsNoticedWithoutATap, :2521 testTheDrawersTakeDiagonalAndReverseSwipes, :3116 testTheTitleOpensTheTurnIndex).

## 2. Cut plan: <=16 kept methods

### 2.1 Kept list (16 tests; 3 of them absorb the 4 merged methods above)

1. `AccountUITests/testSubscriptionCTAUsesStoreKitAndMakesAccountPaid` (:203)
2. `AppFlowTests/testAnUnreachableMacKeepsTheStoredSessions` (:1198)
3. `AppFlowTests/testARunningTurnsClockMoves` (:1690)
4. `AppFlowTests/testASendStartsTheRunningPollWithoutATap` (:1879)
5. `AppFlowTests/testTheLiveActivitySurvivesEverythingFinishing` (:2244)
6. `AppFlowTests/testBackgroundingRefreshesTheSessionListAndTheRunningSession` (:2306)
7. `AppFlowTests/testSwitchingSessionsDoesNotCarryTheOtherOnesState` (:2402)
8. `AppFlowTests/testTheSidebarOpensAndCloses` (:2477)
9. `AppFlowTests/testASendDuringAReloadDoesNotStartASecondLoad` (:2863)
10. `AppFlowTests/testTheHomeScreenStartsASessionWithItsFirstPrompt` (:3002)
11. `AppFlowTests/testTheTurnIndexOpensByADragAndJumps` (:3088)
12. `Feature094UITests/testPermissionPresetSticksAndTheToolbarFollows` (:66)
13. `Feature094UITests/testReturningToTheForegroundReconnects` (:307)
14. `LANFailoverUITests/testTheLANGoingAwayFailsOverToTheRelay` (:102)
15. `LanPriorityUITests/testLocalNetworkFirstGatesTheScanAndSurvivesARelaunch` (:74)
16. `RunningDetailUITests/testScrollingBackReadsOlderDetailAndReexpandingDoesNotRefetch` (:70)

Per class: AppFlowTests 10 (from 14 methods; 4 merged), AccountUITests 1, Feature094UITests 2,
LANFailoverUITests 1, LanPriorityUITests 1, RunningDetailUITests 1, ActivityUITests 0,
ForkedSessionUITests 0, ScreenshotTour 0. Total 16 = 20% of 80.

Why these: each kept method owns a mechanism no snapshot or MizarKit unit test can assert
faithfully — relaunch/offline recovery (:1198), self-advancing clock (:1690), host-side poll
interval (:1879), Live Activity process (:2244), background/foreground (:2306),
in-flight overlap (:2863), drag/jump gestures (:2477,:3088), session creation (:3002),
StoreKit transaction (:203), preset re-read (:66), socket reconnects (:307), and the two
network-state machines counted at the host (:74,:102) plus activity paging (:70).

### 2.2 Top 5 migration candidates (cheapest coverage-preserving; seconds are estimates from class averages — AppFlow 21 s/test, Account 31 s/test — not measured per test)

1. `AppFlowTests/testTheSettingsScreenFollowsTheLanguage` (:1068) — two full launches plus
   four drag-scrolls for pure copy; per-locale presenter goldens; est. ~50 s.
2. `AppFlowTests/testInterfaceFollowsTheLanguageAndContentDoesNot` (:2917) — two launches,
   pure copy; same per-locale goldens; est. ~50 s.
3. `AccountUITests/testAttachmentsUnlockForPaidAccounts` (:247) — fresh-start + create +
   redeem + relaunch chain; gate-policy unit + locked/unlocked snapshots; est. ~40 s.
4. `AppFlowTests/testAnUnpairedLaunchOffersPairing` (:890) — one existence assertion,
   launch-arg state; presenter test + pairing golden; est. ~20 s, lowest risk.
   已下推=快照+源码契约，原用例 XCTSkip 占位，2026-10-21。
5. `AppFlowTests/testTheHomeScreenChoosesTheModelItsSessionStartsOn` (:3032) — selection
   flow; model-selection unit + home snapshot; est. ~30 s.

### 2.3 Migration order (cheapest first)

0. **Fold before deleting (no new target).** Fold :1830/:1957 into :1879, :2521 into :2477,
   :3116 into :3088. Cheap, keeps assertions, drops 4 methods.
1. **MizarKit unit tests only (no new target; suite is 474 tests / ~6 s).** Delete methods whose
   asserted logic already lives in the package: fork classification `WorkspaceCatalog.swift`
   (:83 row), settings/defaults persistence `MizarSettings.swift` (:954,:2802), account
   client/store (:91,:129,:163 + gating part of :247), clock clamp (:2164), oversized-answer
   pagination (:2195), connection reuse (:2355), refusal rollback (:2625 policy part),
   per-host catalogue keying (:2730 part), home model-selection state (:3032 part),
   archive/error policy (:151,:197 policy part), activity gate (:45 part).
   **Ordering note:** these are 100% of the cheap part and save ~250-300 s.
2. **Delete duplicate/covered state rows.** :2091 (send path kept at :1879), :1771, :1407/:1450
   (retention model), :2016, :2966, :3032-family — after presenter tests from step 3 exist.
3. **New app-hosted unit/presenter (`ImageRenderer`) target** — biggest bucket, needs a project
   edit (owner: concurrent .xcodeproj work; do not race it). Then delete all 31 `L` rows,
   one presenter test per screen state: session list (signed-out/unpaired/fixture/offline/stored),
   pairing + first-load download (:1119), refresh progress (:1158), refresh sheet (:1362),
   deleted-workspace filtering (:1305,:1342), settings sheet (:910), About (:1032), zh/en
   settings (:1068) and zh/en interface-vs-content (:2917), composer bar (:1479) and
   enablement (:1274), transcript + failure (:1510), step-count row (:1558), non-expandable
   row (:1585), running/completed wording (:1627), Chinese wording (:1655), no-answer layout
   (:1720), context popover (:1998), approval card (:2053), question card (:2076),
   model picker (:2568), reasoning levels (:2588), permission picker (:2600),
   connection panel (:3133), computer picker (:3147), LAN copy (:239 layout part),
   activity summary/expanded (:45,:71 layout part), fork row (:83 layout part).
   Goldens must be captured per locale (zh + en) wherever copy is asserted, and the
   identifiers/labels must be exactly the ones the current assertions use — weaker goldens are
   not acceptable (e.g. :1032 checks a version regex, :2053 checks `allowAlways` is absent).
4. **ScreenshotTour out of the suite** (project edit): its 3 methods assert nothing
   (`ScreenshotTour.swift:5-:26`); move it to its own scheme/script so `expectedUiTests` counts
   regression tests. Not a coverage loss; already ~0 s (skips).
5. **Live layer last.** No existing test is real-network (§2.4); add the new live class after the
   replay cut is green.
6. **Bump the selection contract.** `test/test-routing.json` `expectedUiTests` (:4) 80 -> 16
   (or 19 if the tour stays), then regenerate `test/impact-map.json` with
   `scripts/record-impact-map.sh` (AGENTS.md:55-:62) — with 16 tests this is ~10 min, not
   30-40 min. Until it is regenerated, every diff falls back to the full (now short) suite.

Expected result: 80 -> 16 methods (20%). Estimated kept wall ~9-10 min (the kept 16 are the
heaviest: LanPriority 86 s, Feature094 307, :2402, :2863, :3002), i.e. **~30% of wall, not 20%**.
If wall must also drop below 20%, the next cut is :74/:102/:307 (see risk R5).

### 2.4 Live layer (proposal; wiring already in flight, do not re-implement)

**Finding (evidence, contradicts the brief's assumption):** no existing method is
network-real. Every class pairs to loopback mock hosts — `AppFlowTests.swift:29-:41`
(19395/19396), `AccountUITests.swift:32-:35`, `ActivityUITests.swift:31-:33`,
`Feature094UITests.swift:41-:43`, `ForkedSessionUITests.swift:178`, `LANFailoverUITests.swift:48-:51`
(relay stand-in on 19397, `mock-host.mjs:38-:43`), `LanPriorityUITests.swift:11-:13`
(scan probes counted on `/hellos`, `mock-host.mjs:270-:276`), `RunningDetailUITests.swift:34-:36`.
The LAN path itself is real code over loopback: `AppModel.swift:2489-:2506` probes
`host.info.addresses`; in tests that list is `127.0.0.1`. So live-network rows today = 0.

The replay/live seam is already being built concurrently (uncommitted WIP, not this
document's): `MizarKit/Tests/MizarKitTests/LiveNetworkTests.swift:5-:14` is the package's live
layer (`MIZAR_TEST_MODE=live` + `MIZAR_LIVE_BASE_URL`, `--filter LiveNetwork`, skips
otherwise); `MizarKit/Sources/MizarKit/HTTPReplay.swift:25-:28` is opt-in HTTP replay
(`MIZAR_HTTP_FIXTURES=<dir of .har>`), recorded by `scripts/record-http-fixtures.sh` into
`protocol/fixtures/http/`. The UI plan below predates those files and sits on the same switch.

**Contract (as already wired, uncommitted WIP):**
- `MIZAR_TEST_MODE` = `replay` | `live`, default `replay` — `TestLayer.swift:18`.
- xcodebuild strips `TEST_RUNNER_`, so both `MIZAR_TEST_MODE` and
  `TEST_RUNNER_MIZAR_TEST_MODE` are exported — `test-select.sh:124-:127`.
- A live test calls `TestLayer.requireLive("…")` as its first act: replay throws
  `XCTSkip` (`TestLayer.swift:25-:29`), and missing live values throw `XCTSkip` via
  `requireValue` (`:34-:38`) — live tests skip loudly and cheaply (~0.2 s, like the tour).
- Live-only values follow the package's `MIZAR_LIVE_BASE_URL` shape: the UI layer needs a
  `MIZAR_LIVE_PAIRING_URI` (read through `requireValue`); missing -> skip, never fail.
- `test-select.sh --live` (`:10,:40`) selects the layer (`:110,:124-:127`); default replay;
  skipped count is already reported from xcresult (`:172,:195`). `test/impact-map.json` is absent
  (`test/` holds only `test-routing.json`), so selection currently always falls back to the full
  suite; a skipped live test therefore never silently narrows a run.
- **`scripts/ios.sh` does not mention `MIZAR_TEST_MODE` yet** (only `MIZAR_NO_MOCK`,
  `MIZAR_TEST_DIAGNOSTICS`, `MIZAR_TEAM_ID`). Proposal: add `--live` handling beside the
  `test`/`test-fast` cases (`ios.sh:112,:120`) that exports both variables before invoking
  `xcb`; keep mock-host startup, because replay tests in the same run still need it. Direct
  focused invocation stays explicit: `MIZAR_TEST_MODE=live TEST_RUNNER_MIZAR_TEST_MODE=live
  scripts/ios.sh test "iPhone 18 Pro" -only-testing:DSH-MizarUITests/LiveHostUITests`.

- AGENTS.md (:23-:24) forbids tests hitting a live model in the default loop; replay stays
  the default for every scripted path, only `--live`/env makes a live test leave skip, and live
  runs are nightly/pre-release scoped. A skipped live test is not a regression signal.

**Exact live tests:** none can be a current method (their evidence is fixture counters:
`/hellos`, `/connections`, `/loads`). Seed the layer with a new `LiveHostUITests` class:
1. `testPairsWithARealHostAndListsItsSessions` — `MIZAR_LIVE_PAIRING_URI`; real pairing
   (`mizar://pair…`) and session list, no fixture names.
2. `testOpensARealConversationAndSendsAMessage` — `MIZAR_LIVE_PAIRING_URI`; real host + real
   agent turn; assert the sent message survives a refresh.
3. `testRealLocalNetworkScanFindsThisHost` — the only true LAN assertion: real `host.info`
   addresses, footer says LAN, poll says 3 s (same product rule as :239, no Debug flag).
4. `testRealRelayFailoverWhenTheLANGoesAway` — operator action (Wi-Fi off/firewall); nightly
   only, never gated in CI.
The three existing candidates (`LanPriorityUITests/testLocalNetworkFirstGatesTheScanAndSurvivesARelaunch`,
`LANFailoverUITests/testTheLANGoingAwayFailsOverToTheRelay`, `Feature094UITests/testLocalNetworkUnlocksPaidFeaturesAndSaysSo`)
stay **replay/keep**: retagging them live would either always skip them (coverage loss) or
require real-host counters they do not have.

## 3. Risks

R1 **No snapshot app target exists.** `MizarKit/Package.swift` has only `MizarKitTests`; the app
has no unit-test target, and the 31 `L` rows need an app-hosted target (project edit, currently
owned by the concurrent .xcodeproj task). Until it exists, the snapshot bucket cannot be
deleted — the 20% cut is blocked on that coordination, not on this document.
R2 **App-layer logic is in `DSH-Mizar/App/AppModel.swift` (~2500 lines), not MizarKit.**
Rows tagged `unit` for AppModel behavior (retention :1407/:1450, refusal :2625, catalogue
keying :2730, home selection :3032) need either a new app unit target or logic moved into
MizarKit; `MizarSettings`/`WorkspaceCatalog`/`PairingClient` rows are the only cheap wins.
R3 **Some system integrations have no snapshot/unit equivalent** — share sheet (:997),
long-press `UIMenu` (:151), pull-to-refresh, `-mizarMockSubscription` transaction (:203 kept),
Live Activity (:2244 kept). Those assertions leave CI coverage or stay in the 16; the document
keeps the four riskiest, and :997/:151 downgrade to unit + manual check (explicitly weaker).
R4 **Live layer is uncommitted WIP across three tasks** — `TestLayer.swift`, `test-select.sh`,
`MizarKit/.../LiveNetworkTests.swift`, `HTTPReplay.swift`, `scripts/record-http-fixtures.sh`,
`protocol/fixtures/http/*.har` are all new/modified and uncommitted. `ios.sh --live` is not
implemented; `impact-map.json` absent means selection always falls back to full. Commit and
coordinate before relying on `--live` or the 16-test count (`expectedUiTests`).
R5 **Method cut != time cut.** Kept 16 includes the 86 s LanPriority test and the long Feature094
/AppFlow flows: estimate ~9-10 min (~30% wall). If <20% wall is required, the next candidates are
`LanPriorityUITests:74` (86 s, could move to live/nightly), `Feature094UITests:307` (overlaps
:2306) and `AppFlowTests:2402`/`:3002` (foldable).

## 4. Constraints honoured by this document

- Read-only: only this file was written; no test/source/project file changed; nothing staged.
- No xcodebuild and no tests were run (simulator owned by snapshot-lab).
- `docs/phase2-triage.md` is the only deliverable; `scripts/test-select.sh` and
  `DSH-MizarUITests/TestLayer.swift` are cited as in-flight WIP from another task, not touched.
- `test/test-routing.json` `expectedUiTests: 80` (:4) must be updated to 16 (or 16+3 if the tour
  stays) when the cut lands, or the new/removed-test guard (`AGENTS.md:39-:45`) forces full runs.

