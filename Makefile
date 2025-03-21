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
generate-expected: $(GEN_DIR)
	./tests/run.sh generate

.PHONY: test
test: helm-test kubeconform-test

.PHONY: helm-test
helm-test: $(TMP_DIR)
	./tests/run.sh helm

.PHONY: kubeconform-test
kubeconform-test:
	./tests/run.sh kubeconform

.PHONY: requirements
requirements:
	@pip-sync

.PHONY: gen_dataplane_version_bump
gen_dataplane_version_bump: requirements
	invoke builder.version-bumper --file charts/dataplane/Chart.yaml

.PHONY: gen_dataplane_crds_version_bump
gen_dataplane_crds_version_bump: requirements
	invoke builder.version-bumper --file charts/dataplane-crds/Chart.yaml

.PHONY: gen_sandbox_crds_version_bump
gen_sandbox_crds_version_bump: requirements
	invoke builder.version-bumper --file charts/sandbox/Chart.yaml

.PHONY: gen_dataplane_release
gen_dataplane_release: requirements
	invoke builder.release --chart dataplane

.PHONY: gen_dataplane_crds_release
gen_dataplane_crds_release: requirements
	invoke builder.release --chart dataplane-crds

.PHONY: gen_sandbox_release
gen_sandbox_release: requirements
	invoke builder.release --chart sandbox

.PHONY: lint
lint: lint-dataplane lint-dataplane-crds lint-sandbox

.PHONY: lint-dataplane
lint-dataplane:
	helm lint charts/dataplane

.PHONY: lint-dataplane-crds
lint-dataplane-crds:
	helm lint charts/dataplane-crds

.PHONY: lint-sandbox
lint-sandbox:
	helm lint charts/sandbox
