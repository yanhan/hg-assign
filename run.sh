#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_KUBECTL_WAIT_TIMEOUT=60s
readonly DEBIAN_POD_NAME=gpdebian
readonly INGRESS_HOST=demo.hgassign.dev
readonly INGRESS_URL_PREFIX=http://ingress-nginx-nginx-ingress

main() {
	declare -r cluster_name=hga
	local start_ts
	check_dependencies
	create_kind_cluster "${cluster_name}"
	install_prometheus
	start_ts="$(date +%s)"
	install_nginx_ingress
	deploy_foo_bar
	run_debian_pod
	check_nginx_ingress_metrics_scraped
	check_foo_bar
	load_test
	printf "\nSleeping for 30s before progressing...\n"
	sleep 30
	generate_metrics_csv_file "${start_ts}"
	delete_debian_pod
	printf "\nAll done. Please remember to delete the cluster %s when you no longer need it.\n"  "${cluster_name}"
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

load_test() {
	declare -r pod_name=load-test
	printf "\nSpinning up pod for load test...\n"
	kubectl run "${pod_name}" --image=debian:bullseye --restart=Never -- sleep 3600
	printf "\nWaiting for load test pod to be ready...\n"
	kubectl wait --for=condition=ready po/"${pod_name}" --timeout="${DEFAULT_KUBECTL_WAIT_TIMEOUT}"
	printf "\n✓ Load test pod ready\n"
	kubectl exec -it "${pod_name}" -- /bin/sh -c 'apt update && apt -y upgrade && apt install -y apache2-utils'
	printf "\nRunning load test using apache bench, please wait...\n"
	kubectl exec -it "${pod_name}" -- ab -n 1000000 -c 50 -H "Host: ${INGRESS_HOST}"  "${INGRESS_URL_PREFIX}/foo"
	kubectl exec -it "${pod_name}" -- ab -n 1000000 -c 50 -H "Host: ${INGRESS_HOST}"  "${INGRESS_URL_PREFIX}/bar"
	printf "\n✓ Load test done\n"
	printf "\nDeleting load test pod...\n"
	kubectl delete po/"${pod_name}"
}

generate_metrics_csv_file() {
	declare -r pod_name="${DEBIAN_POD_NAME}"
	declare -r prom_url_prefix=http://prometheus-kube-prometheus-prometheus:9090
	declare -r requests_file=tmp/requests.json
	declare -r cpu_file=tmp/cpu.json
	declare -r memory_file=tmp/memory.json
	declare -r metrics_csv_file=metrics.csv
	local start_ts=${1}
	local end_ts
	end_ts="$(date +%s)"
	printf "\nExtracting metrics from Prometheus...\n"
	kubectl exec -it "${pod_name}" -- curl -s "${prom_url_prefix}/api/v1/query_range?query=rate%28nginx_ingress_nginx_http_requests_total%5B5m%5D%29&start=${start_ts}&end=${end_ts}&step=30" | jq -r '.data.result[0].values' > "${requests_file}"
	kubectl exec -it "${pod_name}" -- curl -s "${prom_url_prefix}/api/v1/query_range?query=sum%28rate%28container_cpu_usage_seconds_total%7Bcontainer%3D%22ingress-nginx-nginx-ingress%22%7D%5B5m%5D%29%29&start=${start_ts}&end=${end_ts}&step=30" | jq -r '.data.result[0].values' >"${cpu_file}"
	kubectl exec -it "${pod_name}" -- curl -s "${prom_url_prefix}/api/v1/query_range?query=container_memory_usage_bytes%7Bcontainer%3D%22ingress-nginx-nginx-ingress%22%7D&start=${start_ts}&end=${end_ts}&step=30" | jq -r '.data.result[0].values' >"${memory_file}"
	printf "\nGenerating %s ...\n"  "${metrics_csv_file}"
	python gencsv.py \
		--requests-file "${requests_file}" \
		--cpu-file "${cpu_file}" \
		--memory-file "${memory_file}" \
		--output "${metrics_csv_file}"
	printf "\n✓ Generated %s\n"  "${metrics_csv_file}"
}

main "$@"
