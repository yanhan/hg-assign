#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_KUBECTL_WAIT_TIMEOUT=60s
readonly DEBIAN_POD_NAME=gpdebian
readonly INGRESS_HOST=demo.hgassign.dev
readonly INGRESS_URL_PREFIX=http://ingress-nginx-nginx-ingress

main() {
	declare -r cluster_name=hga
	check_dependencies
	create_kind_cluster "${cluster_name}"
	install_prometheus
	install_nginx_ingress
	deploy_foo_bar
	run_debian_pod
	check_nginx_ingress_metrics_scraped
	check_foo_bar
	delete_debian_pod
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

install_nginx_ingress() {
	printf "\nInstalling nginx ingress...\n"
	helm repo add nginx-stable https://helm.nginx.com/stable
	helm repo update
	helm install ingress-nginx nginx-stable/nginx-ingress --set prometheus.create=true --version 0.11.3
	printf "\nWaiting for nginx ingress to be ready...\n"
	kubectl wait --for=condition=ready po -l app=ingress-nginx-nginx-ingress --timeout=60s
	printf "\nPatching nginx ingress service for metrics and installing ServiceMonitor...\n"
	kubectl patch svc/ingress-nginx-nginx-ingress --type strategic --patch "$(cat nginx/patch.yml)"
	kubectl apply -f nginx/service-monitor.yml
	printf "\n✓ nginx ingress ready\n"
}

deploy_foo_bar() {
	declare -r timeout=${DEFAULT_KUBECTL_WAIT_TIMEOUT}
	printf "\nDeploying foo and bar services, as well as create ingress..."
	kubectl apply -f ./foo.yml
	kubectl expose deploy/foo --name foo --target-port=foo
	kubectl apply -f ./bar.yml
	kubectl expose deploy/bar --name bar --target-port=bar
	printf "\nWaiting for foo and bar to be ready...\n"
	kubectl wait --for=condition=ready po --selector=app=foo --timeout="${timeout}"
	kubectl wait --for=condition=ready po --selector=app=bar --timeout="${timeout}"
	kubectl apply -f ./foobar-ingress.yml
	printf "\n✓ foo and bar ready\n"
}

run_debian_pod() {
	declare -r pod_name=${DEBIAN_POD_NAME}
	printf "\nRunning general purpose debian pod...\n"
	kubectl run "${pod_name}" --image=debian:bullseye --restart=Never -- sleep 3600
	printf "\nWaiting for debian pod to be ready...\n"
	kubectl wait --for=condition=ready po/"${pod_name}" --timeout=60s
	printf "\n✓ Debian pod ready... installing curl on it...\n"
	kubectl exec -it "${pod_name}" -- /bin/sh -c 'apt update && apt -y upgrade && apt install -y curl'
}

check_nginx_ingress_metrics_scraped() {
	declare -r targets_filename=tmp/targets.json
	declare -r pod_name=${DEBIAN_POD_NAME}
	local nginxIngressMonitored
	for i in {1..5}; do
		printf "\nChecking that prometheus is scraping nginx metrics...\n"
		kubectl exec -it "${pod_name}" -- curl -s 'http://prometheus-kube-prometheus-prometheus:9090/api/v1/targets?active=true' >"${targets_filename}"
		nginxIngressMonitored="$(jq -r 'any(.data.activeTargets[].labels.container=="ingress-nginx-nginx-ingress"; .)' <"${targets_filename}")"
		if [ "${nginxIngressMonitored}" == "true" ]; then
			printf "✓ Prometheus is scraping nginx metrics\n"
			rm -f "${targets_filename}"
			return
		fi
		sleep 30
	done

	printf "\nPrometheus is not scraping nginx metrics. Please debug it. Exiting.\n"
	exit 1
}

delete_debian_pod() {
	printf "\nDeleting pod %s...\n"  "${DEBIAN_POD_NAME}"
	kubectl delete po/"${DEBIAN_POD_NAME}"
}

check_foo_bar() {
	declare -r pod_name=${DEBIAN_POD_NAME}
	declare -r foo_response_file=tmp/foo-response.txt
	declare -r bar_response_file=tmp/bar-response.txt
	declare -r foo_url="${INGRESS_URL_PREFIX}/foo"
	declare -r bar_url="${INGRESS_URL_PREFIX}/bar"
	printf "\nVerifying ingress routes for foo and bar...\n"
	kubectl exec -it "${pod_name}" -- curl -s -H "Host: ${INGRESS_HOST}"  "${foo_url}" | tr -d '\r' >"${foo_response_file}"
	if [ "$(cat "${foo_response_file}")" != "foo" ]; then
		printf "\nHTTP GET to %s does not return foo . Please debug this. Exiting.\n"  "${foo_url}"
		exit 1
	fi
	rm -f "${foo_response_file}"

	kubectl exec -it "${pod_name}" -- curl -s -H "Host: demo.hgassign.dev"  "${bar_url}" | tr -d '\r' >"${bar_response_file}"
	if [ "$(cat "${bar_response_file}")" != "bar" ]; then
		printf "\nHTTP GET to %s does not return bar . Please debug this. Exiting.\n"  "${bar_url}"
		exit 1
	fi
	rm -f "${bar_response_file}"
	printf "✓ Ingress routes for foo and bar ok\n"
}

main "$@"
