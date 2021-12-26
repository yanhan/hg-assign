#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_KUBECTL_WAIT_TIMEOUT=60s

main() {
	declare -r cluster_name=hga
	check_dependencies
	create_kind_cluster "${cluster_name}"
	install_prometheus
}

check_dependencies() {
	local deps=(
		docker
		kubectl
		kind
		helm
		jq
	)
	local missing_deps=false
	printf "Checking dependencies...\n"
	for dep in ${deps[@]}; do
		if [ "$(is_installed "${dep}")" -ne "0" ]; then
			printf "Missing dependency \"%s\"; you will need to install it\n"  "${dep}"
			missing_deps=true
		fi
	done

	if [ "${missing_deps}" == "true" ]; then
		printf "Exiting.\n"
		exit 1
	fi

	# Check versions
	local incorrect_versions=false
	local return_code
	set +e
	helm version | grep -q "Version:\"v3\."
	return_code=${?}
	set -e
	if [ "${return_code}" -ne 0 ]; then
		printf "Helm must be v3\n"
		incorrect_versions=true
	fi
	local kubectl_version_info
	local kubectl_major
	local kubectl_minor
	kubectl_version_info="$(kubectl version --client=true | sed 's|.*version.Info{\([^}]*\)}$|{\1\}|')"
	kubectl_major="$(sed 's|^.*Major:"\([[:digit:]]*\)".*$|\1|' <<<"${kubectl_version_info}")"
	kubectl_minor="$(sed 's|^.*Minor:\"\([[:digit:]]*\)\".*$|\1|' <<<"${kubectl_version_info}")"
	if [ "${kubectl_major}" -ne "1" ]; then
		printf "kubectl major version must be 1; got %s\n"  "${kubectl_major}"
		incorrect_versions=true
	else
		if [ "${kubectl_minor}" -lt "19" ] || [ "${kubectl_minor}" -gt "23" ]; then
			printf "kubectl minor version should be from 19 to 23, got %s; we will still proceed, but there may be some failures\n"  "${kubectl_minor}"
		fi
	fi

	if [ "${incorrect_versions}" == "true" ]; then
		printf "Exiting.\n"
		exit 1
	fi
}

is_installed() {
	set +e
	command -v "${1}" >/dev/null 2>&1
	local return_code=${?}
	set -e
	echo ${return_code}
}

create_kind_cluster() {
	declare -r timeout=120s
	local cluster_name=${1}
	set +e
	kind get clusters | grep "${cluster_name}"
	return_code=${?}
	set -e
	if [ "${return_code}" == "0" ]; then
		printf "kind cluster \"%s\" exists. Please destroy it manually, then run this script again.\n"  "${cluster_name}"
		exit 1
	fi

	kind create cluster \
		--name "${cluster_name}" \
		--config ./kind-cluster.yml \
		--image kindest/node:v1.21.1@sha256:69860bda5563ac81e3c0057d654b5253219618a22ec3a346306239bba8cfa1a6

	printf "\nWaiting for cluster nodes to be ready...\n"
	kubectl wait --for=condition=ready "node/${cluster_name}-control-plane" --timeout="${timeout}"
	kubectl wait --for=condition=ready "node/${cluster_name}-worker" --timeout="${timeout}"
	kubectl wait --for=condition=ready "node/${cluster_name}-worker2" --timeout="${timeout}"
	kubectl wait --for=condition=ready "node/${cluster_name}-worker3" --timeout="${timeout}"
	printf "✓  Cluster nodes ready\n"
}

install_prometheus() {
	declare -r timeout=${DEFAULT_KUBECTL_WAIT_TIMEOUT}
	printf "\nInstalling Prometheus...\n"
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm install prometheus prometheus-community/kube-prometheus-stack --version 25.1.0
	printf "\nWaiting for Prometheus to be ready...\n"
	kubectl wait --for=condition=ready po -l app=kube-prometheus-stack-operator --timeout="${timeout}"
	kubectl wait --for=condition=ready po -l app.kubernetes.io/name=kube-state-metrics --timeout="${timeout}"
	kubectl wait --for=condition=ready po -l app.kubernetes.io/name=prometheus --timeout="${timeout}"
	kubectl wait --for=condition=ready po -l app=prometheus-node-exporter --timeout="${timeout}"
	printf "\n✓ Prometheus ready\n"
}

main "$@"
