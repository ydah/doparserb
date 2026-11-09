# Implementation progress

## M0 report

- Work completed: inspected both upstreams; confirmed weaving anchors, rule IDs, alternate-template rendering, generation hooks, and standalone engine loading.
- Completion criteria: all seven investigation items are confirmed or have documented adapter adjustments in [m0-findings.md](m0-findings.md). Independent source review found no blocker to M1.
- Measurements: 39 lrama assertions and 11 engine capability assertions passed on Ruby 4.0.9. These are investigation checks, not the product acceptance suite.
- Design changes: target the approved pinned lrama master; normalize nondeterministic diagnostics and caller backtraces only in tests; use C macro renaming for the two-parser link test; discover sidecars by matching digest in the working and executable directories.
- Recordings/screenshots: not applicable to the investigation; terminal recordings are required in M3 and M5.
- Next: implement the pass-through CLI and golden comparison matrix.
- Decisions needed: none outstanding for M0. The user approved the compatibility adjustments. Documentation was left uncommitted at this milestone, as requested.

## M1 report

- Work completed: added the CLI executable and pass-through Command subclass, pinned both Git dependencies, replaced RSpec scaffolding with test-unit, and added nine grammar fixtures.
- Completion criteria: the golden matrix passes for 13 grammars and 13 option variants. Full-off artifacts, diagnostics, and statuses match upstream; default noninteractive diagnostics and statuses match. Help and version remain upstream output.
- Measurements: 177 tests and 1,390 assertions passed with no failures, errors, or omissions in 77.67 seconds. The matrix runs upstream, full-off, and default modes for each combination.
- Design changes: the matrix preserves the specified spaced `-H FILE` error behavior and additionally tests the valid attached `-HFILE` syntax. Debug comparisons normalize only approved unstable fields and wrapper call frames.
- Review: fixed a short-option forwarding bug where letters inside an attached header filename consumed the next doparserb option. All four regression cases pass; no blocking findings remain.
- Recordings/screenshots: not applicable to the pass-through wrapper.
- Next: collect generation events and verify collector overhead in M2.
- Decisions needed: none. Subcommands and runtime hooks remain scheduled for later milestones.

## M2 report

- Work completed: added immutable events, a thread-safe queue, generation statistics, adapter hooks, hidden JSON debug output, and failure classification while preserving upstream exceptions and exit status.
- Completion criteria: fixture statistics match lrama; grammar, validation, and expectation failures retain diagnostics and status; queue concurrency and observer-error isolation pass. Matching expectations retain real conflict counts and produce tamed/flawless events.
- Measurements: the full suite passed 191 tests and 1,542 assertions with no failures, errors, or omissions in 79.245 seconds. Collector overhead was +2.54% on `sample/parse.y`, within the +5% target; see [bench.md](bench.md).
- Review: fixed output-device handling by counting the existing rendered buffer instead of reopening output destinations. A bounded FIFO regression verifies termination and exact byte/line counts. No blocking findings remain.
- Design changes: none beyond the approved M0 corrections.
- Recordings/screenshots: drawing begins in M3.
- Next: implement generation scenes, configuration, terminal locking, cancellation, and PTY acceptance tests.
- Decisions needed: none.

## M3 report

- Work completed: added presentation configuration, the standalone engine adapter, all generation scene definitions, concurrent intro/live meter, bounded reels, badges, terminal locking, cancellation, and demo playback.
- Completion criteria: G1–G10 pass on real PTYs, including narrow terminals, NO_COLOR, quick mode, preserved keys, and concurrent generators. Additional regressions cover native Ruby warnings, C output written to the terminal, canonical stdin grammar input, and byte-identical help/version output.
- Measurements: the full suite passed 232 tests and 2,266 assertions in 104.68 seconds with no failures, errors, or omissions. The final stdin/help guard also passed its focused two-test, 11-assertion suite. Live-meter overhead was +1.69%; cancellation and quick-mode bounds passed.
- Review: fixed direct file-output bypasses, parallel diagnostic races, native warning interception, stdin raw-mode interference, and help/version blank lines. Final independent review found no remaining blocker.
- Design changes: terminal-input grammars retain canonical input and defer presentation until generation completes, preserving typed source and Ctrl-D. ASCII artwork avoids ambiguous-width corruption. Daily-intro persistence and game-driven scene triggers remain assigned to M6; custom sound patches remain assigned to M7.
- Recordings: [calculator](recording/generation-calc.cast), [large grammar with live meter](recording/generation-large.cast), and [conflicts](recording/generation-conflicts.cast), reproducible with [generation.rb](recording/generation.rb).
- Next: weave deterministic C hooks, metadata, and the nonblocking runtime; verify C1–C8 with GCC and clang.
- Decisions needed: none. Specifications, reports, and recordings were left uncommitted at this milestone, as requested.

## M4 report

- Work completed: added validated skeleton weaving, embedded and sidecar metadata, default-on C hooks, and a standalone C99 runtime with nonblocking datagram transport and terminal badges.
- Completion criteria: C1–C8 pass. GCC 16 and clang add no warnings over the corresponding upstream parsers. Compile-out and `_WIN32` tests remove runtime metadata and symbols. Metadata literals, header preservation, unsupported anchors, recovery, explicit parser actions, and scanner errors are covered. Real-PTY and repeated generations produce identical artifacts in both metadata modes.
- Measurements: the remaining suite passed 270 tests and 3,025 assertions in 133.28 seconds. Separately, all 10,000 seeded JSON cases passed 10,005 assertions in 159.12 seconds with the event sink active. Final focused checks passed 13 C-runtime tests / 217 assertions, 16 weaving tests / 265 assertions, two badge tests / 20 assertions, and one terminal-determinism test / 10 assertions.
- Review: no blocking findings remain. ASan/UBSan probes covered extreme integer formatting and maximum loss notices in 51 near-full datagrams. Fixed strict-POSIX socket compilation, narrow badge wrapping, and an ERB-local warning under Ruby warning mode.
- Design details: `R` records pre-reduction state/depth because user actions can exit before reduction completes. Three additional anchors cover EOF preview, scanner errors, and explicit `YYERROR`. Full SHA-256 identifies metadata; its eight-character prefix identifies protocol chunks. Where headers hide `MSG_DONTWAIT`, the dedicated event descriptor receives `O_NONBLOCK`.
- Recordings/screenshots: standalone badges are tested through PTY reconstruction; interactive parser recordings follow in M5.
- Next: implement play's descriptor-preserving launcher, protocol reader, stack model, and replay scenes.
- Decisions needed: none. Linux execution and parser performance measurements remain for final validation; macOS GCC/clang transport and failure paths are verified.

## M5 report

- Work completed: added the descriptor-preserving play launcher, validated protocol reader, bounded stack model, full/highlight/off replay, tower scenes, cancellation, resize, signal handling, and parse-scene demos.
- Completion criteria: P1–P8 pass. Real PTYs verify intact calculator output, Unicode input, partial prompts, exit status/signals, redirected stdin/stdout, resize, and exact full-replay event/depth order at 20 events per second. Both interactive recordings reconstruct without unknown terminal sequences or temporary-region debris.
- Measurements: the full remaining suite passed 361 tests and 4,412 assertions in 148.58 seconds; the unchanged 10,000-input fuzz case was already verified separately in M4. Final focused launcher checks passed 16 tests / 85 assertions, and the PTY suite passed 10 tests / 46 assertions. See [bench.md](bench.md) for relay measurements and one 5.757 ms sidecar tail-latency observation above the 5 ms target.
- Review: corrected hidden-input echo, empty datagram handling, synchronous sidecar lookup, per-parse cache growth, replay pacing, and cancellation incorrectly suppressing later input in the same parse. A controlling-terminal bootstrap preserves raw Ctrl-C bytes, custom interrupt characters, external signals, and inherited Ruby environment values.
- Design details: sidecar resolution uses one bounded background worker and updates labels when available. Full replay retains up to 2,048 pending events; older events fold into totals. Stack snapshots retain the top 256 blocks, and up to 128 parse contexts remain active. Missing history is marked approximate. Actual painting is capped at 40 fps.
- Recordings: [upstream calculator](recording/play-calc.cast) and [recovery/comeback](recording/play-comeback.cast), reproducible with [play.rb](recording/play.rb).
- Next: implement scoring, profile persistence, achievements, records, and the procedural llama ranch.
- Decisions needed: none. Linux execution and final parser-performance measurements remain outstanding; the relay deviation is recorded rather than hidden.

## M6 report

- Work completed: added deterministic scoring, positive ranks, level thresholds, per-grammar build streaks, parse combos and fever, career transactions, daily intros, all eleven achievements, records, status, and 64 procedural ranch variants. Generation and play fold rewards into their existing bounded presentations.
- Completion criteria: scoring/probability/boundary tests pass; eight processes perform 160 locked updates without loss or malformed JSON; all 64 variants have checked 40- and 80-column snapshots. PTY tests cover status, daily intro, quiet generation, cancellation, and unchanged noninteractive/demo profiles.
- Measurements: the full remaining suite passed 449 tests and 7,503 assertions in 156.21 seconds, with no failures, errors, or omissions. The final focused Game/Career/Play checks passed 72 tests and 1,240 assertions after the ending-screen correction. The unchanged C fuzz case remains verified separately in M4.
- Review: fixed blocking FIFO reopens during digest calculation, loss notices incorrectly creating failed parses, and rewards disappearing after live replay drained its queue. Profile updates precede animation filters and survive cancellation; corrupt or unsafe profile files remain untouched.
- Design details: compare conflict improvements across edits at the same realpath; compare timing only for equal content digests and improvements of at least 10% and 5 ms. Skip grammar history for stdin labels and nonregular inputs. Disabled storage keeps ephemeral session scores without filesystem access. Multiple reward triggers grant one uncollected llama per completion.
- Recordings/screenshots: static ranch snapshots cover every variant; real PTYs verify cleanup, widths, and preserved cancellation keys. Existing generation/play recording scripts exercise the integrated shows.
- Next: synthesize the requested sound patches through the engine adapter, then finish documentation, watch mode, and performance validation.
- Decisions needed: none. Specifications and documentation were left uncommitted at this milestone.

## M7 report

- Work completed: added nine synthesized patches, semitone CHAIN pitches, scene and live-frame sound dispatch, a 30 ms throttle, namespaced WAV caching, bell fallback, and cancellation of queued and active audio.
- Completion criteria: the strict silent path bypasses lookup, clocks, backend discovery, synthesis, cache access, and worker creation. Cold-cache and backend work run on a bounded worker. Missing players ring the bell; capacity limits stay silent. Real PTY generation and play produce valid WAV logs, and sound-off runs create no audio files.
- Measurements: the final focused sound and PTY suite passed 20 tests and 251 assertions; cross-module integration passed 113 tests and 2,772 assertions. Controlled blocking tests verify prompt caller return; harmless child processes verify the four-player limit, one pending launch, and termination even when helpers ignore TERM.
- Review: fixed integer-frequency DC waveforms, stale cold-cache requests, canceled launches, unbounded pending threads in the upstream playback helper, native-key cancellation, and slow-backend deadline handling.
- Design details: reuse upstream synthesis, WAV encoding, cache helpers, backend discovery, command prefixes, and logging. The adapter owns bounded process launches because the upstream asynchronous helper cannot cancel pending launches. CHAIN pitch caps at three octaves to keep sound audible and the cache finite.
- Recordings/screenshots: automated terminal tests log sound files instead of using an audio device. Physical speaker/headphone playback has not been listened to.
- Next: retain the validated standalone badge, then finish watch mode, documentation, recordings, and benchmarks.
- Decisions needed: none.

## M8 report

- Work completed: reviewed the standalone C badge implemented during M4, including COMEBACK priority, success/failure labels, counts, color controls, and narrow-terminal clipping.
- Completion criteria: the optional presentation review retains one width-bounded line and introduces no parser sleeps or animation. C8 and narrow-terminal regressions already verify the behavior.
- Measurements: no C runtime changes or new performance claims in this milestone; the five-mode parser benchmark follows in M9.
- Design details: retain the compact badge so program output remains readable on narrow terminals.
- Recordings/screenshots: covered by the existing standalone-badge PTY tests.
- Next: M9 final integration and measurements.
- Decisions needed: none.

## M9 report

- Work completed: added watch mode with debounced saves and a conflict-count HUD; updated the English README and specification; refreshed generation/play recordings and added demo, ranch, tour, and watch recordings; implemented the five-mode 10 MB C benchmark and refreshed generation/display/relay measurements.
- Completion criteria: watch unit and PTY checks cover atomic replacement, temporary deletion, saves during generation, grammar and debug-validation failure recovery, fatal runtime/I/O errors, retained output/header arguments, idle terminal-lock release, quiet noninteractive behavior, and Ctrl-C status 130. All nine recordings reconstruct without unknown control sequences. Package inspection confirms the executable, runtime template, specification, README, and license are included.
- Measurements: on 2026-11-10, the full suite passed **493 tests and 18,013 assertions** in **361.733 seconds**, with zero failures, errors, pendings, omissions, or notifications. This includes all **10,000 seeded JSON fuzz inputs**. The focused watch and adjacent CLI/event/show checks passed 61 tests and 940 assertions; the playback startup regression and related launcher/PTY checks passed 32 tests and 162 assertions.
- Performance: final collector overhead was +2.60% on the upstream sample and +1.06% on the larger generated grammar; live-meter overhead was +0.134%. Relay maxima were 5.073 ms and 4.135 ms with 128 sidecars. The first exceeds the 5 ms target by 0.073 ms; earlier measurements and their deviations are retained in [bench.md](bench.md).
- C benchmark limits: all fifty measured parses accepted the corpus and preserved stdout. Numerical median ratios meet their thresholds, but timing variation exceeds the narrow 2–3% budgets. Batch playback received approximately 0.0033% of shifts and no acceptance event under backpressure. The specified cutoff after 64 consecutive send failures remains unchanged; full-stream performance is unestablished.
- Review: fixed startup ordering so the event consumer is initialized before the child starts, without changing the child's terminal mode. Fixed watch termination during an input-replacement gap and after debug validation failures; preserve fatal unsupported-skeleton and I/O errors. Final independent review found no remaining blocker.
- Design details: watch polls every 100 ms and waits for 150 ms of stable file metadata before rebuilding. It leaves a persistent conflict-count badge while releasing the terminal lock between builds. Presentation initialization now precedes parser launch; there is no benchmark-only readiness barrier.
- Recordings: [generation](recording/generation-calc.cast), [large grammar](recording/generation-large.cast), [conflicts](recording/generation-conflicts.cast), [calculator](recording/play-calc.cast), [comeback](recording/play-comeback.cast), [demo](recording/demo.cast), [ranch](recording/ranch.cast), [tour](recording/ranch-tour.cast), and [watch recovery](recording/watch.cast). Reproduction scripts are in the same directory.
- Remaining validation limits: local execution used macOS and Ruby 4.0.9. Linux and other supported Ruby versions have not been run locally, and synthesized sounds have not been listened to through physical speakers or headphones.
- Next: no implementation milestone remains. Platform execution, physical audio listening, and complete-stream performance measurements remain follow-up validation work.
- Decisions needed: none. The final `First implementation` commit includes the specification, README, reports, benchmark samples, and recordings.

## Arcade presentation refresh

- Changes: added original full and compact ASCII characters, large rainbow pixel lettering, colored backgrounds and stack blocks, sparks, shockwaves, fireworks, moving rule cards, and independently stopping jackpot reels. Generation uses up to 18 rows and playback up to 16. Playback now paints intermediate animation frames without repeating event sounds; the demo holds parse scenes longer.
- Validation: 520 tests and 10,369 assertions passed in 164.636 seconds, with zero failures, errors, pendings, omissions, or notifications. This run excludes the unchanged 10,000-input C fuzz test; the earlier full-suite result remains above. Tests cover animation timing, output priority, cancellation, NO_COLOR, hostile labels, narrow layouts, glyph-width fallback, and spinning reels. Independent review found no remaining blocker.
- Visual inspection: six actual ANSI frames were rendered to the [preview](visual-preview.png), inspected, and refined for readable headings and connected compact sprites. All nine recordings were refreshed and reconstructed with no unknown terminal controls or screen-bound violations.
- Performance: relay medians were 1.459 ms and 1.424 ms with 128 sidecars; maxima were 6.810 ms and 4.403 ms. The first exceeds the 5 ms target by 1.810 ms. No child output was lost. Raw samples and limitations are in [bench.md](bench.md#arcade-presentation-refresh).
- Remaining checks: physical terminal/font combinations, physical audio, and Linux were not verified locally. The generated C runtime and its documented backpressure cutoff remain unchanged.

## Playback choreography refresh

- Changes: replaced the generic Shift, Reduce, and Recovery mascots with a falling token prism, colliding RHS blocks that reveal their LHS result, and a repair gantry that reconnects a broken bridge. Preparation, impact, and reward phases follow dopairb's Hit, Clash, and Jackpot sequences. Core hit sounds and optional flashes meet the impact. The chain meter points to actual configured bonuses.
- Rare rewards: critical hits reveal their multiplier after a slash; jackpot reels stop separately before coin rain, a large 777, and counted points. Live highlights have readable holds; the finishing reel preserves its one-to-two-second budget and favors the strongest scene. Full replay retains its speed setting. Demo snapshots now match their parser actions and show nonzero rare rewards.
- Validation: 537 tests and 10,475 assertions passed in 159.962 seconds with zero failures, errors, pendings, omissions, or notifications. The unchanged 10,000-input C fuzz test was excluded. New regressions cover actual action phases, next-token semantics, delayed rewards and sounds, flash timing, glyph variants, bounded replay, output interruption, and demo snapshots. Independent review found no remaining blocker.
- Visual checks: inspected twenty actual rendered frames and the [animated preview](play-choreography.gif), fixing clipped operand edges and an oversized payoff title. The [frame sequence](play-choreography.png), general preview, and three affected recordings are refreshed. Recordings pass JSON, timestamp, control-sequence, and screen-bound checks.
- Performance: relay maxima were 3.396 ms and 3.062 ms with 128 sidecars, below the 5 ms target in these runs, with no child output lost. [Measurements and earlier deviations](bench.md#playback-choreography-refresh) are retained. Longer live highlights may fold more visual events under sustained load; queue bounds, C transport, and scoring probabilities are unchanged.
- Remaining checks: physical audio, other terminal/font combinations, and Linux were not verified locally.

## Final acceptance checklist

- [x] Full-off compatibility: the 13-grammar × 13-option golden matrix matches pinned lrama artifacts, diagnostics, and statuses, using only the approved comparison normalization.
- [x] Noninteractive output: no presentation control sequences; profiles remain untouched.
- [x] Original diagnostics: warning/error text and ordering survive terminal presentation, including native Ruby warnings and direct output destinations.
- [x] Deterministic artifacts: repeated and real-PTY generation produce the same C, headers, reports, diagrams, and metadata for equal arguments.
- [x] Exit behavior: generation statuses and playback child exits/signals are preserved; watch exits 130 on Ctrl-C.
- [x] Generation scenes: TITLE, STATES, SLASH, BOSS/FLAWLESS, FORGE, FINALE, and the retained badge are covered by scenes, PTY tests, and recordings.
- [x] Playback scenes: shifts, reductions, CHAIN, TOWER, SYNTAX BREAK, RECOVERY, AUTO REPAIR, STAGE CLEAR, and COMEBACK are covered by models, scenes, C events, PTY tests, and demo/calculator/recovery recordings.
- [x] Parser behavior: C1 and the full C2 fuzz corpus match instrumented and plain parser output and status; C3 verifies event/depth invariants.
- [x] Transport failure: closed receivers and sustained backpressure never block or kill the parser; missing history is approximate.
- [x] Compile-time removal: `DOPA_RT_DISABLE` removes runtime symbols and metadata; the benchmark additionally confirms identical plain/disabled machine code.
- [x] Shared terminals: parallel generators and an idle watcher release or share terminal ownership safely.
- [x] User controls: NO_COLOR, flash/motion/sound off, quick mode, and key cancellation work; pending keys remain available.
- [x] Terminal widths: narrow-terminal cleanup and ambiguous-width glyph fallback pass, including every llama at 40 and 80 columns.
- [x] Performance reporting: generation targets pass; relay deviations, C timing uncertainty, and severe large-input event loss are documented in [bench.md](bench.md).
- [x] Career: scoring, boundaries, achievements, profile locking, and all 64 ranch variants pass; eight concurrent writers retain all 160 updates.
- [x] Deliverables: English README/specification, milestone reports, nine recordings with reproduction scripts, benchmark scripts/raw results, and a validated gem package are present. Documentation is included in the final implementation commit.
