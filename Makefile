KUBECONFIG ?= $(HOME)/.kube/config
CHART_DIR := charts/dataplane

BUILD_DIR := build
$(BUILD_DIR):
	mkdir build

TARGET_DIR := $(BUILD_DIR)/helm
$(TARGET_DIR): $(BUILD_DIR)
	mkdir $(BUILD_DIR)/helm

helm-gen-tests: $(TARGET_DIR)
	helm dep update $(CHART_DIR)
	helm template dataplane $(CHART_DIR) \
		--namespace union \
		--values $(CHART_DIR)/values.yaml \
		--set clusterName="byok-1" \
		--set orgName="byok" \
		--set storage.bucketName="union-metadata" \
		--set storage.endpoint="http://s3.default.svc:9000" \
		--set storage.accessKey="xxxxxxx" \
		--set storage.secretKey="xxxxxxx" \
		--set secrets.admin.enabled=true \
		--set secrets.admin.clientSecret="supersecret" \
		> $(TARGET_DIR)/union_dataplane_helm_test_generated.yaml
	# helm lint charts/union-dataplane -f $(TARGET_DIR)/union_dataplane_helm_test_generated.yaml
	kubeconform -ignore-missing-schemas -skip CustomResourceDefinition $(TARGET_DIR)/union_dataplane_helm_test_generated.yaml
