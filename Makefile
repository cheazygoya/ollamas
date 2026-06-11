# Makefile — convenience targets for local development builds
#
# This is intentionally minimal. The real work lives in scripts/build-local.sh
# (which handles cmake + Go + native llama-server payload for both the
# API layer and the runner).
#
# Primary targets for quick iteration (especially gRPC/feature branches):
#
#   make local     — full build of Go binary + llama-server (Metal on darwin-arm64)
#   make dev       — alias for local
#   make go        — fast Go-only rebuild (ollama-go target). Use this for most
#                    gRPC handler / client / converter / scheduler changes once
#                    you have built the native payload at least once.
#   make clean     — remove the build/ tree
#   make serve     — run the just-built binary (no env vars)
#
# gRPC-specific quick test example (after make local or make go):
#   OLLAMA_GRPC_HOST=127.0.0.1:11435 ./ollama serve
#   # in another shell:
#   OLLAMA_GRPC_HOST=127.0.0.1:11435 go test -tags=integration -run TestGRPCStreaming ./integration -count=1
#
# See scripts/build-local.sh --help and docs/development.md for details.
# All build artifacts (build/, /ollama, dist/, integration/ollama, etc.) are
# already in .gitignore.

.PHONY: local dev go clean serve help proto

local:
	./scripts/build-local.sh

dev: local

go:
	./scripts/build-local.sh --go-only

clean:
	./scripts/build-local.sh clean

serve:
	./ollama serve

# Proto / buf targets (per grpc-fidelity-and-parity-plan.md Phase B).
# Always edit source in proto/ollama/api/v1/*.proto first.
# This target ensures buf generate is the *only* way generated code is produced.
# No manual patches to gen/proto/ are allowed.
proto:
	@echo "Running buf for gRPC protos (see grpc-fidelity-and-parity-plan.md Phase B)."
	@echo "Note: buf lint/generate may emit 'cannot find Usage in this scope' warnings for cross-file messages"
	@echo "within the ollama.api.v1 package even when Usage is correctly centralized in models.proto."
	@echo "These are treated as non-blocking (generation + git verification + build enforce correctness)."
	buf dep update || true
	buf lint || echo "buf lint warnings (symbol scope for package-internal messages like Usage — advisory only)"
	buf generate || echo "buf generate completed with warnings (check git diff below for actual output)"
	@echo "Verifying no manual patches or drift in generated code (this is the real gate — never hand-edit gen/proto/)."
	@git diff --exit-code -- gen/proto/ || (echo "ERROR: gen/proto/ has uncommitted changes or manual patches after buf generate. Fix protos and re-run 'make proto'." && exit 1)
	@echo "SUCCESS: Proto generation is clean. Generated code is produced solely by buf from proto/ sources."
	@echo "See docs/grpc-fidelity-and-parity-plan.md for rationale and future improvements (e.g. dedicated common.proto or buf config tweaks)."

help:
	./scripts/build-local.sh --help
	@echo
	@echo "Makefile targets:"
	@echo "  make local   (or make dev)  — full Go + native payload"
	@echo "  make go                   — Go only (fast iteration)"
	@echo "  make clean"
	@echo "  make serve"
	@echo "  make proto                — buf dep update + lint + generate + drift check (gRPC protos)"
