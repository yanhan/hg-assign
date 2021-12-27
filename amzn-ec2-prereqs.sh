#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

main() {
	local tempdir
	local return_code

	if [ -f /etc/system-release ]; then
		set +e
		grep -q '^Amazon Linux ' /etc/system-release
		return_code=${?}
		set -e
		if [ "${return_code}" -ne 0 ]; then
			printf "This script can only be run on Amazon Linux. Exiting.\n"
			exit 1
		fi
	fi

	tempdir="$(mktemp -d "${HOME}/XXXXXXXXXXXX")"
	pushd "${tempdir}"
	sudo yum update -y
	if [ "$(is_installed docker)" -ne 0 ]; then
		sudo yum install -y docker
		sudo usermod -a -G docker $(whoami)
		sudo systemctl start docker
	fi
	if [ "$(is_installed kind)" -ne 0 ]; then
		curl -Lo ./kind  'https://github.com/kubernetes-sigs/kind/releases/download/v0.11.1/kind-linux-amd64'
		chmod +x ./kind
		sudo mv ./kind /usr/local/bin/
	fi
	if [ "$(is_installed kubectl)" -ne 0 ]; then
		curl -LO 'https://dl.k8s.io/release/v1.21.1/bin/linux/amd64/kubectl'
		curl -LO 'https://dl.k8s.io/release/v1.21.1/bin/linux/amd64/kubectl.sha256'
		set +e
		echo "$(<kubectl.sha256) kubectl" | sha256sum --check | grep -q '^kubectl: OK$'
		return_code=${?}
		set -e
		if [ "${return_code}" -ne 0 ]; then
			printf "kubectl sha256sum did not match downloaded checksum file. Exiting.\n"
			exit 1
		fi
		chmod +x ./kubectl
		sudo mv ./kubectl /usr/local/bin/
	fi
	if [ "$(is_installed helm)" -ne 0 ]; then
		curl -Lo helm.tar.gz  'https://get.helm.sh/helm-v3.7.2-linux-amd64.tar.gz'
		set +e
		echo "4ae30e48966aba5f807a4e140dad6736ee1a392940101e4d79ffb4ee86200a9e helm.tar.gz" | sha256sum --check | grep -q '^helm.tar.gz: OK$'
		return_code=${?}
		set -e
		if [ "${return_code}" -ne 0 ]; then
			printf "helm.tar.gz sha256sum did not match downloaded checksum file. Exiting.\n"
			exit 1
		fi
		tar xzf helm.tar.gz
		chmod u+x ./linux-amd64/helm
		sudo mv ./linux-amd64/helm /usr/local/bin/
	fi
	if [ "$(is_installed jq)" -ne 0 ]; then
		sudo yum install -y jq
	fi
	if [ "$(is_installed git)" -ne 0 ]; then
		sudo yum install -y git
	fi
	popd
	rm -rf "${tempdir}"
}

is_installed() {
	set +e
	command -v "${1}" >/dev/null 2>&1
	local return_code=${?}
	set -e
	echo ${return_code}
}

main "$@"
