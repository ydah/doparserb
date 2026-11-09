# M0: upstream integration findings

Date: 2026-11-09. Status: investigation complete; implementation and acceptance tests follow in M1–M9.

## Baseline and approved adjustments

The implementation targets **lrama master at `263a3a4b99b0b4856b9993b682b563369d3b51ea`**, selected by the user after comparing the released 0.8.0 gem with current upstream. Both identify themselves as version 0.8.0; the version string alone is not a sufficient compatibility check. Pin the Git revision during development and validate every weaving anchor before generating runtime-enabled output.

The engine baseline is **dopairb 0.5.0 at `da3303ccb7e1d75ee5da25fc86449a01b8a584a1`**. Probes used CRuby 4.0.9 on macOS. The primary lrama template SHA-256 is `7a46407d0822987b9afafa8f7c7cd9c45342f2314368d4553e0ca66b827349a6`.

The user approved these adjustments:

- Use the pinned lrama master revision above instead of the released gem as the implementation baseline.
- For golden tests, normalize upstream object addresses in `-t` output, variable timing values, and caller-backtrace differences. Do not filter or rewrite actual CLI output.
- Test two linked parsers using C macro renaming: upstream does not implement `api.prefix`. Do not add unsupported upstream grammar semantics to doparserb.
- Discover sidecar metadata in the current directory and the executable's directory, accept only a matching digest, and fall back to numeric symbol/rule identifiers when it cannot be found.

## Completion checklist and measurements

| M0 item | Result | Evidence |
| --- | --- | --- |
| 1. Verify anchors, with and without `-e` | Confirmed | 18 literal anchor specifications matched; both template branches rendered. See the inventory below. |
| 2. Locate repair hooks after token assignment | Confirmed | The repair-token debug line follows assignment of kind, value, location, and external token code. |
| 3. Map C rule IDs | Confirmed | All 10 calc rules matched `yyr1[rule.id + 1]` and `yyr2[rule.id + 1]`. |
| 4. Override the output template without breaking partials | Confirmed | A prepend redirected only `Output#template_file` to a pipe-backed `/dev/fd` path; header generation and upstream partial resolution succeeded. |
| 5. Evaluate a doparserb constant from ERB | Confirmed | The alternate template emitted a marker from `::Doparserb::Runtime.c_source`. |
| 6. Load and use engine components without IRB/Reline | Confirmed, with adapter adjustments | Selective requires, stderr routing, canvas/font rendering, stage retirement, synthesis, and WAV encoding were exercised. See the engine limitations below. |
| 7. Observe lexer, phases, and state additions | Confirmed | Prepend probes collected lexer tokens, LR(0)/lookahead phases, and the final state count without changing return values. |

The final pinned-master probe passed **39 assertions**: 18 anchor counts, 10 rule mappings, 3 hook checks, 6 rendering/header checks across the two repair variants, and 2 alternate-template/constant/header checks. The released 0.8.0 gem passed the same 39-assertion probe separately. The engine capability probe passed **11 assertions**. An initial engine probe intentionally expected no SGR sequences at color depth `none`; that assertion failed because upstream retains reset sequences. This is a compatibility finding to address in `engine.rb`, not an acceptance-test pass.

For upstream `sample/calc.y`, using the grammar name `calc.y`, output name `calc.c`, and header name `calc.h`:

| Metric | Value |
| --- | ---: |
| Lexer tokens, including the merged standard library | 214 |
| Grammar rules, including the accept rule | 10 |
| Symbols | 14 |
| States | 18 |
| Precedence-resolved conflicts | 16 |
| Unresolved shift/reduce conflicts | 0 |
| Unresolved reduce/reduce conflicts | 0 |
| C bytes without `-e` | 56,689 |
| C bytes with `-e` | 65,895 |
| Header bytes, either variant | 2,999 |

These are investigation assertions, not the project's later regression suite. No performance or C-runtime acceptance result is implied by them.

## Exact weaving anchors

All counts below refer to the unrendered `template/bison/yacc.c` at the pinned revision. Strings are Ruby single-quoted literals except for the two multiline anchors. Preserve leading spaces where shown. Every count is one except `token`, whose count is two.

```ruby
runtime = "/*----------.\n| yyparse.  |\n`----------*/"
declaration = "  int yylen = 0;\n\n  YYDPRINTF ((stderr, \"Starting parse\\n\"));"
begin_parse = '  YYDPRINTF ((stderr, "Starting parse\n"));'
token = 'YY_SYMBOL_PRINT ("Next token is", yytoken, &yylval, &yylloc<%= output.user_args %>);'
shift = '  YY_SYMBOL_PRINT ("Shifting", yytoken, &yylval, &yylloc<%= output.user_args %>);'
reduce = '  YY_REDUCE_PRINT (yyn<%= output.user_args %>);'
error = '      ++yynerrs;'
pop_rule = '<%= output.after_pop_stack_function("yylen", "/* %after-pop-stack function. */") %>'
pop_one = '<%= output.after_pop_stack_function(1, "/* %after-pop-stack function. */") %>'
error_shift = '  YY_SYMBOL_PRINT ("Shifting", YY_ACCESSING_SYMBOL (yyn), yyvsp, yylsp<%= output.user_args %>);'
repair_plan = '      rep_terms = yyrecover (yyss, yyssp, yychar<%= output.user_args %>);'
repair_token = '              YY_SYMBOL_PRINT ("Next error recovery token is", yytoken, &yylval, &yylloc<%= output.user_args %>);'
repair_done = '              YYDPRINTF ((stderr, "Error recovery is completed\n"));'
accept = 'yyacceptlab:'
abort_parse = 'yyabortlab:'
exhausted = 'yyexhaustedlab:'
end_parse = 'yyreturnlab:'
before_lex = '      yychar = yylex <%= output.yylex_formals %>;'
```

Insert the runtime before its anchor; insert the local declaration between `int yylen = 0;` and the start trace in the compound anchor. Insert the begin hook after the start trace, the reduce hook before its trace, and the eager-flush hook immediately before `yylex`. Other hooks go after their complete anchor lines. Repair hooks remain inside their existing `output.error_recovery` ERB blocks.

`int yylen = 0;` alone appears twice: once in the repair simulator and once in `yyparse`. After ERB rendering there is one declaration without `-e` and two with `-e`. The two Next token anchors similarly produce one or two occurrences. The six-space error anchor distinguishes the ordinary syntax-error increment from the separate two-space increment in the explicit `YYERROR` path.

### Event semantics to preserve

- At the shift trace, `yystate` still holds the previous state and `yyssp - yyss` is the pre-push depth. The destination is `yyn`; the resulting depth is `yyssp - yyss + 1`. The error-token shift has the same ordering.
- The reduce trace precedes the user action and stack mutation. Record a documented pre-reduction depth, or explicitly calculate the resulting depth as `depth - yylen + 1`; the Tower model and C3 assertions must use the same convention. User actions can exit through `YYERROR`, `YYABORT`, or `YYACCEPT` before normal reduction completion.
- `rep_terms` can be null. Inspect `rep_terms->length` only after a null check. The repair-token anchor above is after `yytoken` and `yylloc` assignment; the earlier “An error recovery token is used” trace is too early.
- The normal error anchor does not observe explicit `YYERROR` or a scanner-returned error token. Those paths need explicit coverage if they are to contribute to error/comeback statistics.
- Next token traces can revisit the same lookahead after reductions; they are not a count of lexer calls. EOF follows a separate branch. Use shift events for token scoring and document T as a preview observation unless the hook is refined.
- A user can define `YYLTYPE`; location field access must respect the available location representation. Never inspect `YYSTYPE`.

## Metadata and template API

`Context#yyr1` and `#yyr2` prepend a dummy element at index zero. `Output#user_actions` emits `case rule.id + 1`. Metadata rule IDs therefore use **`rule.id + 1`**, including the accept rule at index one. Symbol IDs use `symbol.number`, not external `token_id`; rule LHS and RHS entries use those internal numbers. `Rule#as_comment` supplies readable rule text.

`Output#template_file`, `#header_template_file`, and `#partial_file` independently resolve their paths. Override only the first. Keep the temporary template's basename `yacc.c`: `template_basename` is observable in generated output. `Lrama::ERB.render` uses `result_with_hash(context:, output:)`, which accepts fully qualified doparserb constants without additional binding changes.

Sidecar discovery follows the approved current-directory/executable-directory search. Compare the complete stored digest before using names; missing, corrupt, or mismatched metadata leaves numeric identifiers available. No absolute build-machine path needs to be embedded for discovery. Bounds, duplicate fragments, and incomplete metadata remain protocol-test responsibilities in M4/M5.

## Generation hooks and upstream differences

All lrama references belong in `lrama_adapter.rb`.

| Hook or value | Confirmed API |
| --- | --- |
| Grammar construction | Private `Command#build_grammar(text)` returns a prepared and validated grammar. |
| State construction | Private `Command#compute_status(grammar)` returns `[states, context]`, including IELR work when enabled. |
| Output | Private `Command#render_output(context, grammar)` can be wrapped around `super`. |
| Lexer | `Lexer#next_token` returns `[kind, token]` or nil. |
| Phases | `States#report_duration(name)` surrounds LR(0), lookahead subphases, conflicts, and IELR splitting. Preserve `super` and its return value. |
| State additions | `Tracer#trace_state_list_append(state_count, state)` receives the new count. |
| Conflicts | `states.sr_conflicts_count`, `states.rr_conflicts_count`, and the sum of each state's `resolved_conflicts.length`. |
| Parameterized instances | `grammar.parameterized_resolver.created_lhs_list`; definition counts also include unused standard-library rules. |
| Inline definitions | `grammar.parameterized_rules.select(&:inline?)`; counting expansions requires observing resolver work rather than equating definitions with uses. |
| Expectations | `grammar.expect`; when set, validation checks S/R equality and R/R equal to zero. Failure writes Logger errors and exits with status 1. |
| Diagnostics | Logger writes to its `@out`; Warnings keeps the Logger passed during its own construction. Replacing only Command's later `@logger` does not update Warnings. |

The released 0.8.0 gem renders output **before** `states.validate!`; an expectation mismatch can therefore leave a generated file and return status 1. The selected master validates first and renders into a `StringIO` before writing the C file. Preserve the selected upstream workflow and its artifacts exactly. Do not apply the design's “no output on failure” statement retroactively to a released-gem comparison.

The released and selected templates differ in six symbol-access expressions (`id.s_value` versus `name`), but the 18 anchors above match both. The investigated local checkout `d1244498124cb05b4a2f64a9b5c1903f0937e841` has the same template as the selected master; final probes were nevertheless rerun against the selected checkout.

Upstream `-t` output includes nondeterministic object addresses even for successful generation. Independent upstream runs differed byte-for-byte but matched after address normalization. Duration traces likewise vary. A failing debug run can additionally contain Ruby call-stack frames from an adapter. The user approved normalizing these caller-backtrace differences in comparison tests. Verify diagnostic messages against the actual upstream executable without rewriting CLI output.

## Engine integration

Require `monitor` and the individual `dopairb/{version,config,color,term,canvas,font,stage,sound}` files. The probe loaded these without defining IRB or Reline, set `Term.out = STDERR` and `Term.interactive = true`, and successfully wrote through Term. Requiring top-level `dopairb` would load both interactive libraries and their adapters.

`Canvas.new(width, height)`, `put_center`, `render(depth)`, `Font.width`, `Sound::Synth.tone`, and `Sound.wav` worked independently. `Stage#yield_to_output` retired the temporary stage and cleared `Term.overlay`; a retired Stage cannot be resumed, so later animation requires a new stage. Call `stage.yield_to_output` inside `Dopairb::Term::LOCK.synchronize`: this method does not acquire the monitor itself. The separate cross-process terminal lock is still required.

Adjustments confined to `engine.rb` are necessary:

- `Canvas#render(:none)` retains `ESC[0m`, and Stage emits resets independently of color depth. Strip SGR at the engine output boundary when strict G6/NO_COLOR behavior is requested; keep cursor controls needed by interactive drawing. Noninteractive paths must avoid Stage entirely.
- Without Reline, Term's conservative width fallback treats the half-block glyph as width two. `Term.glyph('▀', '#')` selected `#` in the probe. Use the glyph fallback to avoid broken narrow/ambiguous-width layouts; do not claim half-block rendering has been validated on every terminal.
- Term obtains window size from its input object. When stdin is redirected but stderr is a terminal, the adapter must obtain dimensions from the rendering terminal without consuming redirected input.
- The sound patch registry is frozen through `Ractor.make_shareable`. There is no public custom-patch registration API. New patches need an adapter extension that reuses synthesis, WAV/cache operations, and asynchronous playback without mutating the frozen hash.
- Sound playback references `Dopairb::OutputTap.quietly` and `Dopairb.debug`, which the selective load does not define. Supply the required bridge or load the safe supporting component explicitly. Actual audio playback and player failure paths were not exercised in M0.
- Director's priority branches depend on IRB-specific event fields and scenes. Reuse its priority-and-subtitle policy, but do not pass parser events directly to its IRB scene selector.

The upstream PTY driver assumes the external `setsid` command. Adapt the harness for macOS and retain MIT attribution if copying its VT implementation. Those files are references for M3/M5, not evidence that doparserb's PTY behavior already passes.

## Test-plan corrections and next work

The design takes priority over conflicting work-instruction wording. Default runtime generation is on regardless of TTY state, so default noninteractive generated C cannot also be byte-identical to plain lrama. Compare generated bytes with `--dopa-runtime=off`; separately compare default noninteractive diagnostics/status and deterministic runtime-enabled artifacts.

The selected `sample/parse.y` is only 59 lines and cannot be assumed to exceed the 0.25-second live-meter threshold. Add a deterministic larger grammar fixture for the live-meter and collector-overhead checks. Establish its measured duration before claiming the benchmark exercises a long-running build.

Upstream `sample/calc.y` calls `exit(0)` on lexer EOF and bypasses parser acceptance and return hooks. Keep it unchanged for compatibility and interactive relay tests; use a separate fixture whose lexer returns EOF for acceptance, badge, and combo tests.

M1 can now implement the full-off wrapper and golden comparisons. M4 must turn the anchor/mapping probes into regression tests, check deliberate anchor corruption, and compile both repair variants. C7 must use the approved macro-renaming fixture. GNU GCC is available separately from Apple's clang; use both actual compilers for the C99 warning comparison. C-runtime fuzzing, backpressure, signal propagation, profile concurrency, recordings, and performance targets remain unverified until their respective milestones.
