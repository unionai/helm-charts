KUBECONFIG ?= $(HOME)/.kube/config
CHART_DIR := charts/dataplane

TESTS_DIR := tests
$(TESTS_DIR):
	mkdir tests

GEN_DIR := $(TESTS_DIR)/generated
$(GEN_DIR): $(TESTS_DIR)
	mkdir -p $(TESTS_DIR)/generated

TMP_DIR := $(TESTS_DIR)/tmp
$(TMP_DIR): $(TESTS_DIR)
	mkdir -p $(TESTS_DIR)/tmp

.PHONY: generate-expected
generate-expected: $(GEN_DIR) vendor-crds
	./tests/run.sh generate

.PHONY: test
test: check-vendored-crds helm-test kubeconform-test check-image-paths

.PHONY: snapshot-generator-test
snapshot-generator-test:
	bash ./tests/test-atomic-render.sh

# Must-fail tests. tests/run.sh only compares successful renders against golden
# files, so a `fail` guard that stops firing leaves no trace there.
.PHONY: render-guards-test
render-guards-test:
	bash ./tests/test-render-guards.sh

# Gate on fully qualified image references. Reads the checked-in
# tests/generated/ corpus, so it needs neither network nor helm — but that
# means it is only as fresh as `make generate-expected`. helm-test is what
# enforces that freshness.
.PHONY: check-image-paths
check-image-paths:
	python3 scripts/check-image-paths.py

# Vendored CRDs (crds/<name>/) — see crds/README.md.
# Each subdirectory has its own scripts/sync.sh (refresh from upstream chart)
# and scripts/check.sh (drift gate). These targets iterate so adding a new
# vendored set is a matter of creating crds/<name>/ with the same script
# layout — no Makefile edits required.

.PHONY: vendor-crds
vendor-crds:
	@set -e; for d in crds/*/; do \
	  if [ -x "$${d}scripts/sync.sh" ]; then \
	    echo ">> vendoring $${d}"; \
	    "$${d}scripts/sync.sh"; \
	  fi; \
	done

# Run every check and exit non-zero if any of them failed (instead of stopping
# at the first failure) so a single CI run surfaces all drift at once.
.PHONY: check-vendored-crds
check-vendored-crds:
	@fail=0; \
	for d in crds/*/; do \
	  if [ -x "$${d}scripts/check.sh" ]; then \
	    "$${d}scripts/check.sh" || fail=1; \
	  fi; \
	done; \
	exit $${fail}

.PHONY: helm-test
helm-test: $(TMP_DIR) snapshot-generator-test render-guards-test
	./tests/run.sh helm

.PHONY: kubeconform-test
kubeconform-test:
	./tests/run.sh kubeconform

.PHONY: requirements
requirements:
	uv sync

# Bump all lockstep charts to the next version. For a pre-release of the next
# version, pass PRERELEASE=alpha or PRERELEASE=beta, e.g.
#   make gen_version_bump                  # 2026.6.9 -> 2026.6.10
#   make gen_version_bump PRERELEASE=beta  # 2026.6.9 -> 2026.6.10-beta.0
PRERELEASE ?=
_PRERELEASE_FLAG = $(if $(PRERELEASE),--prerelease $(PRERELEASE),)

.PHONY: gen_version_bump
gen_version_bump: requirements
	uv run invoke builder.version-bumper --file charts/controlplane/Chart.yaml $(_PRERELEASE_FLAG)
	uv run invoke builder.version-bumper --file charts/dataplane/Chart.yaml $(_PRERELEASE_FLAG)
	uv run invoke builder.version-bumper --file charts/dataplane-crds/Chart.yaml $(_PRERELEASE_FLAG)
	uv run invoke builder.version-bumper --file charts/knative-migration/Chart.yaml $(_PRERELEASE_FLAG)
	uv run invoke builder.version-bumper --file charts/sandbox/Chart.yaml $(_PRERELEASE_FLAG)

.PHONY: gen_dataplane_release
gen_dataplane_release: requirements
	uv run invoke builder.release --chart dataplane

.PHONY: gen_dataplane_crds_release
gen_dataplane_crds_release: requirements
	uv run invoke builder.release --chart dataplane-crds

.PHONY: gen_knative_migration_release
gen_knative_migration_release: requirements
	uv run invoke builder.release --chart knative-migration

.PHONY: gen_sandbox_release
gen_sandbox_release: requirements
	uv run invoke builder.release --chart sandbox

.PHONY: release-notes-dry-run
release-notes-dry-run:
	./scripts/generate-release-notes.sh

.PHONY: lint
lint: lint-dataplane lint-dataplane-crds lint-knative-migration lint-sandbox

.PHONY: lint-dataplane
lint-dataplane:
	helm lint charts/dataplane

.PHONY: lint-dataplane-crds
lint-dataplane-crds:
	helm lint charts/dataplane-crds

.PHONY: lint-knative-migration
lint-knative-migration:
	helm lint charts/knative-migration

.PHONY: lint-sandbox
lint-sandbox:
	helm lint charts/sandbox

.PHONY: generate-metrics-manifest
generate-metrics-manifest:
	python3 scripts/extract-metrics.py > metrics-manifest.yaml
