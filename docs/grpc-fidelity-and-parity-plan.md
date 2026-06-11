# gRPC Fidelity, Parity, Reliability, and Tooling Plan

**Context**: This plan addresses key concerns from independent assessment of the gRPC/Connect integration in the `feature/grpc-initial` branch (post Phases 0-4 implementation + SKILL reviews).

Concerns to address:
1. Stronger fidelity testing (property-based or exhaustive table-driven comparison of REST vs gRPC for the same logical requests, including tool schemas and format/structured cases).
2. The buf generation story cleaned up so generated code isn't manually patched.
3. Full parity on the remaining proto surface.
4. Evidence that Pull/Push, SAMEPORT under load, and the new client methods are reliable in practice.

**Principles** (from reliable-go-systems SKILL):
- Use structured task tracking (this plan + todo_write).
- Ctx first, %w errors, rich slog with `component`, `reason`, `task_id`, `status`, `duration_ms`.
- Bounded work, no fire-and-forget, idempotent/safe.
- Verifiability: table-driven + property tests, `-race`, golangci-lint clean.
- Small units, explicit construction (no new globals).
- Agent orchestration: separate planning from execution; delegate to sub-agents where appropriate.
- Follow Diátaxis for any new docs (this plan lives as Explanation/How-to in `docs/`).

**Overall Approach**:
- Build on existing assets: `server/grpc_test.go` (TestConvert*Roundtrip tables), `integration/grpc_stream_test.go` (matrix + high-level client), `scripts/quality-grpc-comparison.go` (runtime parity + edges), converters in `server/grpc.go`, protos in `proto/ollama/api/v1/`, client in `api/grpc_client.go`, buf setup in `buf.yaml`/`buf.gen.yaml`.
- Enhance rather than replace.
- Use `make local` / `./scripts/build-local.sh` (or `--go-only`) + `buf dep update && buf lint && buf generate` for all changes.
- Run full test matrix with `OLLAMA_GRPC_HOST=...` (sep + SAMEPORT), `EXISTING=1`, `-race`.
- Gate with review sub-agent using reliable-go-systems SKILL at the end.
- Produce evidence artifacts: test logs, coverage reports, soak outputs, before/after diffs.

**Phasing** (aligned with prior phased approach for low risk):
- Phase A: Tooling & Fidelity Foundations (addresses 1 + parts of 2/4).
- Phase B: Proto Parity + Buf Hygiene (addresses 2 + 3).
- Phase C: Reliability Evidence & Soak (addresses 4, closes the loop).
- Cross-cutting: Documentation updates (in `docs/development.md`, `docs/grpc-phased-reliable-approach.md`), logging, error paths.

All changes must pass: `go build .`, `go test -tags=integration -race ./integration -run 'TestGRPC|Convert'`, `buf lint`, quality script runs, manual SAMEPORT + Pull/Push smoke.

---

## Phase A: Stronger Fidelity Testing + Tooling Foundations

**Goal**: Replace/enhance ad-hoc parity (quality script + existing tables) with systematic, automated, exhaustive comparison. Cover logical equivalence for requests/responses, tool schemas (oneof/Function), format (bytes/json schema), structured outputs, think/truncate/shift, options, usage/metrics, vision, done_reason, etc.

### A.1 Enhance Table-Driven Converters (Exhaustive Roundtrips)
- **Files**:
  - `server/grpc_test.go` (expand `TestConvertChatRoundtrip`, add `TestConvertGenerateRoundtrip`, `TestConvertEmbedRoundtrip`, `TestConvertModels*`).
  - `server/grpc.go` (add any missing bidirectional helpers if gaps found during tables, e.g. for Generate options as Struct).
- **Tasks**:
  1. Audit current tables vs `api/types.go` (ChatRequest/Response, Generate*, Embed*, Progress, etc.) and proto messages.
  2. Add cases for:
     - Tool schemas (parameters as JSON bytes in proto -> api orderedmap/Tools; roundtrip fidelity).
     - `format` (json schema bytes or "json" string).
     - `think` (bool -> *ThinkValue).
     - `truncate`/`shift`.
     - Structured: `format` + response content that should unmarshal.
     - Vision + tools mixed.
     - Options sampling (temperature etc.) + struct options.
     - Full Usage, done_reason, logprobs edges, context, metrics.
     - Bidirectional (pb->api for reqs from handlers; api->pb for resps from core).
  3. Make tables drive both directions where possible. Use `assert` + deep equal or field-by-field.
  4. Add `TestConvert*Fidelity` that exercises via real `convertToAPI*` + handler path (or mock core) vs direct REST path simulation.
- **Acceptance**:
  - All tables pass with `-race`.
  - New cases cover tool schema roundtrips exactly (name, description, parameters JSON).
  - `go test -tags=integration -run TestConvert ./server -count=1` (or move some to integration if they need runtime).
- **Why Diátaxis**: This is verifiability (Explanation + How-to in tests).

### A.2 Property-Based / Fuzzing Layer for Logical Equivalence
- **Files**:
  - `server/grpc_fidelity_test.go` (new, or extend grpc_test.go).
  - Optionally integrate with quality script.
- **Tasks** (use `testing/quick` or `github.com/leanovate/gopter` — add to go.mod if needed, keep deps minimal):
  1. Define generators for logical requests:
     - `GenChatRequest()`: model, messages (with role/content/thinking/images/tool_calls), tools (function schemas), options map, format (random schema or "json"), think bool, truncate/shift.
     - Similar for Generate (prompt + suffix + images + format + think + options), Embed (inputs + options + truncate).
  2. Property: "For any logical request R, REST path (via api.Client) and gRPC path (via GRPCClient or raw connect) produce equivalent normalized results."
     - Compare: model, messages (deep, ignoring wire), tools (name/desc/params), format (bytes), think, options (after conversion), done_reason, metrics (tokens, durations — allow tolerance on timing), tool_calls in response, content (for deterministic prompts), Usage.
     - For non-deterministic (sampling): assert structural equivalence (e.g. tool call presence, JSON validity for structured).
     - Use same core (real runner) or mock for pure converter fidelity.
  3. Run generators for N cases (e.g. 100-1000) in test; fail on first mismatch with seed for repro.
  4. Add structured output + tool schema specific properties (e.g. "if format=json, response content unmarshals to array/object"; "tool parameters roundtrip as JSON").
  5. Wire into quality script as `--fuzz N` mode or separate `go test` that quality can call.
- **Commands**:
  ```bash
  go test -tags=integration -run TestGRPCFidelity -count=1 -timeout=2m
  # With -race for soak
  ```
- **Acceptance**:
  - Properties pass for 1000+ cases including edge schemas.
  - Mismatches logged with full R (serialized) + diffs.
  - Covers SAMEPORT path (run matrix with env).
- **Risks/Mitigation**: Non-determinism — use fixed seeds or low-temp options in gens; compare post-normalization where core allows.

### A.3 Runtime End-to-End Fidelity Harness
- Enhance `scripts/quality-grpc-comparison.go`:
  - Add `--fidelity` flag that runs same logical requests (from generators or fixed table of complex cases) via both `api.Client` (REST) and `api.GRPCClient` (or raw) against same server.
  - Assert on key fields (as in A.2) + token counts (expect near-match, log deltas), tool_calls exact, structured validity.
  - Include Pull/Push smoke (if registry available in test env) and progress fidelity.
- Integrate with `integration/grpc_stream_test.go` high-level client subtests: add fidelity assertions where possible.
- **Acceptance**: quality run produces "fidelity passed" for complex cases (tools + format + structured + vision).

---

## Phase B: Buf Generation Hygiene + Full Proto Parity

**Goal**: `buf generate` always produces clean, complete code with no manual edits. Achieve parity so gRPC can be a first-class (or preferred) surface for all current REST capabilities.

### B.1 Clean Up Buf Story (No Manual Patches)
- **Root Cause** (from history): Duplicate `message Usage` across protos (chat + generate), scope/lint issues in buf v2 module when files reference each other; local plugin config; managed overrides.
- **Files**:
  - `proto/ollama/api/v1/*.proto` (centralize common types).
  - `buf.yaml`, `buf.gen.yaml`.
  - `gen/proto/ollama/api/v1/*.pb.go` + connect (regenerate, then delete any hand patches; add CI check).
  - `.github/workflows/test.yaml` (add buf lint/generate step if not present).
  - `docs/development.md`, `docs/grpc-phased-reliable-approach.md` (update instructions; remove "patch generated" notes).
- **Tasks**:
  1. Centralize shared messages: Move/keep `Usage` (and any future common like Progress) in `models.proto` (or new `common.proto` under v1). Update all references (chat.proto, generate.proto) — same package, no import needed for v1 protos in the module.
  2. Ensure `buf.yaml` covers the full module cleanly (current is good; add `breaking: use: [FILE]` already present).
  3. Improve `buf.gen.yaml`:
     - Use managed + explicit for consistency.
     - Add `protoc-gen-go-grpc` or stick with connect if preferred.
     - Document: "Always run from root after proto edits. Never edit gen/ manually."
  4. Add pre-commit/CI hook equivalent: in Makefile or script:
     ```makefile
     proto:
     	buf dep update
     	buf lint
     	buf generate
     	# Verify no uncommitted gen/ diffs (for CI)
     	git diff --exit-code gen/proto/
     ```
  5. Remove any remaining manual patches from .pb.go / .connect.go (search for "MANUAL", "HACK", added fields outside proto).
  6. Update quality/integration tests and converters to rely on generated (not patched) shapes.
  7. Add to development.md: "After proto changes: make proto (or buf commands). If buf complains about scope/Usage, ensure single definition in models.proto."
- **Commands** (must succeed cleanly every time):
  ```bash
  buf dep update && buf lint && buf generate
  git diff --exit-code -- gen/proto/  # no diffs from manual
  go build .  # generated code compiles with current converters
  ```
- **Acceptance**:
  - `make proto` (or equivalent) is the only way to update gen/.
  - No "patch generated" comments or manual field additions survive.
  - CI (if added) fails on generation drift.
- **Diátaxis**: This is How-to (reliable build process) + Explanation (why central types + managed buf).

### B.2 Full Proto Surface Parity
- **Current Gaps** (audit against `api/types.go`, HTTP handlers in `server/routes.go`, openapi.yaml, and real usage):
  - Generate: complete most fields (format/think/truncate/shift added), but check options as full Struct vs map, logprobs, images in some paths, experimental fields.
  - Embed: add `truncate` (done), but options, keep_alive parity, perhaps `dimensions` or other future.
  - Chat: very rich (tools oneof, format bytes, think, truncate/shift, usage in resp) — audit for missing (e.g. full content parts oneof for multimodal, citations/logprobs in response per TODOs in pb).
  - Models: Pull/Push progress good; flesh Show (more details from api), List details.
  - New/remaining: Any experimental (image gen?), auth, more admin (if added to ModelsService).
  - Cross-cutting: Consistent `Usage` everywhere responses have metrics; `ProgressResponse` for all async; error details in status.
- **Files**:
  - All `proto/ollama/api/v1/*.proto`.
  - `server/grpc.go` (expand handlers if new RPCs; update all convert* for new fields).
  - `api/grpc_client.go` (add any missing client methods, e.g. more on Models if needed).
  - `gen/...` (via buf).
  - `server/grpc_test.go` (add roundtrip coverage for new fields).
  - `docs/api/*.mdx` (update reference for new fields).
- **Tasks**:
  1. Side-by-side diff: `api/types.go` structs vs proto messages + current converters. List gaps (e.g. "ChatResponse has Logprobs but proto TODO").
  2. Add missing fields to protos (with comments mirroring api/types).
     - Example: in generate.proto / chat.proto responses: add `repeated Logprob logprobs` or struct equivalents.
     - For options: keep map for MVP or promote to `google.protobuf.Struct` in advanced.
  3. Implement in converters (bidirectional, with rich debug slog "reason").
  4. Wire in handlers (most already delegate via api types — just pass through).
  5. Update client if new top-level methods.
  6. Regenerate via buf (must be clean per B.1).
  7. Extend tables/properties (Phase A) to cover new fields.
- **Acceptance**:
  - All fields in current REST `api/types.go` (for Chat/Generate/Embed/Models) have direct proto equivalents or documented "gRPC uses X instead".
  - Converters handle roundtrips losslessly for covered cases.
  - No "TODO" left in protos for parity items (move to future phase if truly out of scope).
  - `quality-grpc-comparison.go` + new fidelity tests pass with complex inputs using new fields.
- **Phasing note**: Prioritize tool schemas + format/structured (as called out in concern #1). Defer exotic experimental if they would bloat MVP.

---

## Phase C: Reliability Evidence for Pull/Push, SAMEPORT, New Client Methods

**Goal**: Move from "implemented" to "proven under realistic conditions". Produce artifacts (logs, metrics, test results) showing stability.

### C.1 Pull/Push Reliability
- **Files**: `api/grpc_client.go` (Pull/Push already exist as streams), `integration/grpc_stream_test.go` (add subtests), `scripts/quality-grpc-comparison.go` (add --pull-push or smoke), new `integration/pull_push_test.go` if needed.
- **Tasks**:
  1. Add integration subtests under TestGRPCStreaming (or new TestGRPCModelsAdmin):
     - Use `OLLAMA_TEST_MODEL` or small local; call `c.Pull(...)` / `c.Push(...)` via high-level client.
     - Assert on ProgressResponse stream (status, digest, total/completed progress).
     - Test cancel mid-pull (ctx cancel aborts cleanly).
     - Mixed with SAMEPORT.
  2. Enhance quality script: optional mode that exercises Pull (if a tiny model or mock registry) and verifies progress fidelity vs REST `api.Client.Pull`.
  3. Add to high-level client tests: `TestGRPCClientPullPush` with table of insecure flags, error cases.
  4. Soak: manual or scripted concurrent Pulls (respect MaxQueue?); monitor server logs for "gRPC handler" + rich reasons.
- **Acceptance**:
  - Subtests pass with real models (or documented "requires registry setup").
  - Progress messages match between REST/gRPC (status/digest/completed).
  - Cancel works (no leaks, clean err).
  - Evidence: logs showing `component=grpc rpc=ModelsService/Pull` + duration.

### C.2 SAMEPORT Under Load + Mixed Protocol
- **Files**: `integration/grpc_stream_test.go` (the `sameport_and_cancel` etc. subtests), `server/routes.go` (cmux wiring), harness in `integration/utils_test.go`.
- **Tasks**:
  1. Make SAMEPORT subtests default-on in matrix when env set; add load variants:
     - N concurrent streams (Chat + Generate mixed) over SAMEPORT.
     - Interleaved REST (api.Client) + gRPC (GRPCClient) on same port.
     - With `-race`.
  2. Add breaker exercise: induce transient (e.g. via test that hits queue limits) and verify fail-fast + recovery.
  3. Monitor: pprof goroutines during soak (no leaks), server "MaxQueue" / retry logs, OTEL spans.
  4. Document in `docs/grpc-phased-reliable-approach.md` and test comments: "For agent load/soak: OLLAMA_GRPC_SAMEPORT=1 + multiple GRPCClient goroutines; assert health preflight."
- **Acceptance**:
  - SAMEPORT matrix passes under concurrency (document N=10-50 streams).
  - No "address already in use" or protocol detection bugs.
  - Evidence: test output + server log excerpts showing mixed protocol handlers succeeding.

### C.3 New Client Methods + Overall Client Soak
- **New methods**: Pull/Push (C.1), plus any from parity (C.2/B).
- **General**:
  - Add `TestGRPCClientReliability` (or extend existing high-level tests) that exercises all methods (unary + streams) with retry/breaker scenarios (mock errors for CodeUnavailable).
  - Circuit breaker specific tests: 5+ transients -> open; cooldown -> closed; per-client isolation (two clients, one poisoned).
  - Keepalive: long idle streams (use test timeout); verify no premature close.
  - Run quality + integration with `OLLAMA_GRPC_SAMEPORT=1` + real load.
- **Evidence Package** (commit or attach to PR):
  - `go test -tags=integration -race -count=5 -timeout=10m ./integration -run 'TestGRPC' 2>&1 | tee soak.log`
  - Quality runs with fidelity mode.
  - pprof snapshots or goroutine counts during.
  - Manual: `grpcurl` discovery (with reflection=1), health checks.
- **Acceptance**: All new paths (Pull/Push, SAMEPORT load, breaker) have passing tests + logs showing correct behavior. No new issues in review sub-agent.

---

## Cross-Cutting & Execution

**Documentation**:
- Update `docs/development.md`: add "Fidelity & Parity" section with commands from this plan. Reference this plan doc.
- Update `docs/grpc-phased-reliable-approach.md`: add Phase 6 "Fidelity, Parity & Evidence" summary + links.
- Add this plan as `docs/grpc-fidelity-and-parity-plan.md` (Explanation/How-to hybrid).
- Ensure all new tests/docs use relative paths only (no local FS).

**Tooling/CI**:
- Makefile target: `make proto-fidelity` (buf + go test converters + quality --fidelity).
- `.github/workflows/test.yaml`: add step for buf + gRPC fidelity (non-blocking initially).
- Use `todo_write` for tracking sub-tasks during execution.

**Order of Execution (recommended)**:
1. Phase B first (buf + parity) — unblocks clean generation for later tests.
2. Phase A (fidelity) — leverages parity.
3. Phase C (evidence) — uses the tests from A/B.
4. Run full matrix + quality after each phase.
5. At end of all: spawn review sub-agent.

**Success Criteria (Overall)**:
- `buf generate` is deterministic and patch-free.
- Proto messages cover all significant fields from `api/types.go` for core services (documented gaps only for true future work).
- Fidelity tests (table + property + runtime) pass for complex cases (tools + format + structured + truncate etc.).
- Soak evidence for Pull/Push + SAMEPORT + client methods (logs, no leaks/crashes under load, breaker works).
- All changes reviewed by reliable-go-systems SKILL sub-agent with zero critical findings (or remediated).
- Docs updated, cross-refs relative and accurate.
- No regression in existing integration/quality runs.

**Risks & Mitigations**:
- Buf scope issues: centralize types early (B.1).
- Non-determinism in fidelity: use fixed options/seeds, focus on structural + token counts (with tolerance).
- Test env for Pull/Push: gate behind build tag or use existing model manifests; document setup.
- Time: Parallelize table expansion (A.1) with buf work (B.1).

**References**:
- Existing: `docs/grpc-phased-reliable-approach.md`, `docs/development.md`, `server/grpc_test.go`, `scripts/quality-grpc-comparison.go`, `integration/grpc_stream_test.go`.
- SKILL: reliable-go-systems (use for all impl + final sub-agent).
- Proto source of truth: `proto/ollama/api/v1/*.proto` (always edit here first).

Execute via `todo_write` + regular commits with "gRPC fidelity plan: ..." messages. After full completion of Phases A-C + evidence artifacts, invoke sub-agent for final review.

This plan is self-contained and actionable. It turns the concerns into verifiable work with clear gates.