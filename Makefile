# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# If you update this file, please follow
# https://suva.sh/posts/well-documented-makefiles

.DEFAULT_GOAL:=help

# Use GOPROXY environment variable if set
GOPROXY := $(shell go env GOPROXY)
ifeq ($(GOPROXY),)
GOPROXY := https://proxy.golang.org
endif
export GOPROXY

# Active module mode, as we use go modules to manage dependencies
export GO111MODULE=on

# Default timeout for starting/stopping the Kubebuilder test control plane
export KUBEBUILDER_CONTROLPLANE_START_TIMEOUT ?=60s
export KUBEBUILDER_CONTROLPLANE_STOP_TIMEOUT ?=60s

# This option is for running docker manifest command
export DOCKER_CLI_EXPERIMENTAL := enabled

# Directories.
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin
BIN_DIR := bin

# Binaries.
CLUSTERCTL := $(BIN_DIR)/clusterctl
CONTROLLER_GEN := $(TOOLS_BIN_DIR)/controller-gen
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/golangci-lint
MOCKGEN := $(TOOLS_BIN_DIR)/mockgen
RELEASE_NOTES_BIN := bin/release-notes
RELEASE_NOTES := $(TOOLS_DIR)/$(RELEASE_NOTES_BIN)

# Define Docker related variables. Releases should modify and double check these vars.
GCP_PROJECT ?= $(shell gcloud config get-value project)
REGISTRY ?= gcr.io/$(GCP_PROJECT)
STAGING_REGISTRY := gcr.io/k8s-staging-cluster-api-gcp
PROD_REGISTRY := us.gcr.io/k8s-artifacts-prod/cluster-api-gcp
IMAGE_NAME ?= cluster-api-gcp-controller
CONTROLLER_IMG ?= $(REGISTRY)/$(IMAGE_NAME)
TAG ?= dev
ARCH ?= amd64
ALL_ARCH = amd64 arm arm64 ppc64le s390x

# Allow overriding manifest generation destination directory
MANIFEST_ROOT ?= config
CRD_ROOT ?= $(MANIFEST_ROOT)/crd/bases
WEBHOOK_ROOT ?= $(MANIFEST_ROOT)/webhook
RBAC_ROOT ?= $(MANIFEST_ROOT)/rbac
CLUSTER_NAME ?= test1
NETWORK_NAME ?= default

# Allow overriding the imagePullPolicy
PULL_POLICY ?= Always

## --------------------------------------
## Help
## --------------------------------------

help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## --------------------------------------
## Testing
## --------------------------------------

.PHONY: test
test: generate lint ## Run tests
	go test -v ./...

.PHONY: test-integration
test-integration: ## Run integration tests
	go test -v -tags=integration ./test/integration/...

.PHONY: test-e2e
test-e2e: ## Run e2e tests
	go test -v -tags=e2e ./test/e2e/...

## --------------------------------------
## Binaries
## --------------------------------------

.PHONY: binaries
binaries: manager ## Builds and installs all binaries

.PHONY: manager
manager: ## Build manager binary.
	go build -o $(BIN_DIR)/manager .

## --------------------------------------
## Tooling Binaries
## --------------------------------------

$(CLUSTERCTL): go.mod ## Build clusterctl binary.
	go build -o $(BIN_DIR)/clusterctl sigs.k8s.io/cluster-api/cmd/clusterctl

$(CONTROLLER_GEN): $(TOOLS_DIR)/go.mod # Build controller-gen from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/controller-gen sigs.k8s.io/controller-tools/cmd/controller-gen

$(GOLANGCI_LINT): $(TOOLS_DIR)/go.mod # Build golangci-lint from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/golangci-lint github.com/golangci/golangci-lint/cmd/golangci-lint

$(MOCKGEN): $(TOOLS_DIR)/go.mod # Build mockgen from tools folder.
	cd $(TOOLS_DIR); go build -tags=tools -o $(BIN_DIR)/mockgen github.com/golang/mock/mockgen

$(RELEASE_NOTES) : $(TOOLS_DIR)/go.mod
	cd $(TOOLS_DIR) && go build -tags tools -o $(BIN_DIR)/release-notes sigs.k8s.io/cluster-api/hack/tools/release

## --------------------------------------
## Linting
## --------------------------------------

.PHONY: lint
lint: $(GOLANGCI_LINT) ## Lint codebase
	$(GOLANGCI_LINT) run -v

lint-full: $(GOLANGCI_LINT) ## Run slower linters to detect possible issues
	$(GOLANGCI_LINT) run -v --fast=false

## --------------------------------------
## Dependencies
## --------------------------------------
update-deps:
	GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org go get -u=patch ./...
	GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org go mod tidy

## --------------------------------------
## Generate
## --------------------------------------

.PHONY: modules
modules: ## Runs go mod to ensure proper vendoring.
	go mod tidy
	cd $(TOOLS_DIR); go mod tidy

.PHONY: generate
generate: ## Generate code
	$(MAKE) generate-go
	$(MAKE) generate-manifests

.PHONY: generate-go
generate-go: $(CONTROLLER_GEN) $(MOCKGEN) ## Runs Go related generate targets
	go generate ./...
	$(CONTROLLER_GEN) \
		paths=./api/... \
		object:headerFile=./hack/boilerplate/boilerplate.generatego.txt

.PHONY: generate-manifests
generate-manifests: $(CONTROLLER_GEN) ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) \
		paths=./api/... \
		crd:trivialVersions=true \
		output:crd:dir=$(CRD_ROOT) \
		output:webhook:dir=$(WEBHOOK_ROOT) \
		webhook
	$(CONTROLLER_GEN) \
		paths=./controllers/... \
		output:rbac:dir=$(RBAC_ROOT) \
		rbac:roleName=manager-role

.PHONY: generate-examples
generate-examples: clean-examples ## Generate examples configurations to run a cluster.
	./examples/generate.sh

## --------------------------------------
## Docker
## --------------------------------------

.PHONY: docker-build
docker-build: ## Build the docker image for controller-manager
	docker build --pull --build-arg ARCH=$(ARCH) . -t $(CONTROLLER_IMG)-$(ARCH):$(TAG)
	MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(MAKE) set-manifest-pull-policy

.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(CONTROLLER_IMG)-$(ARCH):$(TAG)

## --------------------------------------
## Docker — All ARCH
## --------------------------------------

.PHONY: docker-build-all ## Build all the architecture docker images
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH))

docker-build-%:
	$(MAKE) ARCH=$* docker-build

.PHONY: docker-push-all ## Push all the architecture docker images
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))
	$(MAKE) docker-push-manifest

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push-manifest
docker-push-manifest: ## Push the fat manifest docker image.
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	docker manifest create --amend $(CONTROLLER_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(CONTROLLER_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${CONTROLLER_IMG}:${TAG} ${CONTROLLER_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge ${CONTROLLER_IMG}:${TAG}
	MANIFEST_IMG=$(CONTROLLER_IMG) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(MAKE) set-manifest-pull-policy

.PHONY: set-manifest-image
set-manifest-image:
	$(info Updating kustomize image patch file for manager resource)
	sed -i'' -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' ./config/default/manager_image_patch.yaml

.PHONY: set-manifest-pull-policy
set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for manager resource)
	sed -i'' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' ./config/default/manager_image_patch.yaml

## --------------------------------------
## Release
## --------------------------------------

RELEASE_TAG := $(shell git describe --abbrev=0 2>/dev/null)
RELEASE_DIR := out

$(RELEASE_DIR):
	mkdir -p $(RELEASE_DIR)/

.PHONY: release
release: clean-release  ## Builds and push container images using the latest git tag for the commit.
	@if [ -z "${RELEASE_TAG}" ]; then echo "RELEASE_TAG is not set"; exit 1; fi
	# Push the release image to the staging bucket first.
	REGISTRY=$(STAGING_REGISTRY) TAG=$(RELEASE_TAG) \
		$(MAKE) docker-build-all docker-push-all
	# Set the manifest image to the production bucket.
	MANIFEST_IMG=$(PROD_REGISTRY)/$(IMAGE_NAME) MANIFEST_TAG=$(RELEASE_TAG) \
		$(MAKE) set-manifest-image
	PULL_POLICY=IfNotPresent $(MAKE) set-manifest-pull-policy
	$(MAKE) release-manifests

.PHONY: release-manifests
release-manifests: $(RELEASE_DIR) ## Builds the manifests to publish with a release
	kustomize build config/default > $(RELEASE_DIR)/infrastructure-components.yaml

.PHONY: release-staging
release-staging: ## Builds and push container images to the staging bucket.
	REGISTRY=$(STAGING_REGISTRY) $(MAKE) docker-build-all docker-push-all release-alias-tag

RELEASE_ALIAS_TAG=$(PULL_BASE_REF)

.PHONY: release-alias-tag
release-alias-tag: # Adds the tag to the last build tag.
	gcloud container images add-tag $(CONTROLLER_IMG):$(TAG) $(CONTROLLER_IMG):$(RELEASE_ALIAS_TAG)

.PHONY: release-notes
release-notes: $(RELEASE_NOTES)
	$(RELEASE_NOTES)

## --------------------------------------
## Development
## --------------------------------------

.PHONY: create-cluster
create-cluster: ## Create a development Kubernetes cluster on GCP in a KIND management cluster.
	@if [[ ! -f examples/_out/cert-manager.yaml ]]; then echo "Examples are missing. Run 'make generate-examples' first."; exit 1; fi
	kind create cluster --name=clusterapi
	@if [ ! -z "${LOAD_IMAGE}" ]; then \
		echo "loading ${LOAD_IMAGE} into kind cluster ..." && \
		kind --name="clusterapi" load docker-image "${LOAD_IMAGE}"; \
	fi
	# Install cert manager.
	kubectl \
		create -f examples/_out/cert-manager.yaml
	# Wait for webhook servers to be ready to take requests
	kubectl \
		wait --for=condition=Available --timeout=5m apiservice v1beta1.webhook.cert-manager.io
	# Apply provider-components.
	kubectl \
		create -f examples/_out/provider-components.yaml
	# Wait for CAPI pod
	kubectl \
		wait --for=condition=Ready --timeout=5m -n capi-system pod -l control-plane=cluster-api-controller-manager
    # Wait for CAPG pod
	kubectl \
		wait --for=condition=Ready --timeout=5m -n capg-system pod -l control-plane=capg-controller-manager
	# Create Cluster.
	sleep 10
	kubectl \
		create -f examples/_out/cluster.yaml
	# Create control plane machine.
	kubectl \
		create -f examples/_out/controlplane.yaml
	# Wait for the kubeconfig to become available.
	timeout 300 bash -c "while ! kubectl get secrets | grep $(CLUSTER_NAME)-kubeconfig; do sleep 1; done"
	# Get kubeconfig and store it locally.
	kubectl get secrets $(CLUSTER_NAME)-kubeconfig -o json | jq -r .data.value | base64 --decode > ./kubeconfig
	# Apply addons on the target cluster, waiting for the control-plane to become available.
	timeout 300 bash -c "while ! kubectl --kubeconfig=./kubeconfig get nodes | grep master; do sleep 1; done"
	kubectl --kubeconfig=./kubeconfig apply -f examples/addons.yaml
	# Create a worker node with MachineDeployment.
	kubectl \
		create -f examples/_out/machinedeployment.yaml

.PHONY: kind-reset
kind-reset: ## Destroys the "clusterapi" kind cluster.
	kind delete cluster --name=clusterapi || true

## --------------------------------------
## Cleanup / Verification
## --------------------------------------

.PHONY: clean
clean: ## Remove all generated files
	$(MAKE) clean-bin
	$(MAKE) clean-temporary

.PHONY: clean-bin
clean-bin: ## Remove all generated binaries
	rm -rf bin
	rm -rf hack/tools/bin

.PHONY: clean-temporary
clean-temporary: ## Remove all temporary files and folders
	rm -f minikube.kubeconfig
	rm -f kubeconfig

.PHONY: clean-release
clean-release: ## Remove the release folder
	rm -rf $(RELEASE_DIR)

.PHONY: clean-examples
clean-examples: ## Remove all the temporary files generated in the examples folder
	rm -rf examples/_out/
	rm -f examples/provider-components/provider-components-*.yaml

.PHONY: verify
verify: ## Runs verification scripts to ensure correct execution
	./hack/verify-boilerplate.sh
	./hack/verify-generated-files.sh
	$(MAKE) verify-modules
	$(MAKE) verify-gen

.PHONY: verify-modules
verify-modules: modules
	@if !(git diff --quiet HEAD -- go.sum go.mod hack/tools/go.mod hack/tools/go.sum); then \
		echo "go module files are out of date"; exit 1; \
	fi

.PHONY: verify-gen
verify-gen: generate
	@if !(git diff --quiet HEAD); then \
		echo "generated files are out of date, run make generate"; exit 1; \
	fi
