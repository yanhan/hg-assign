# About

Take home assignment for HG


## Overview

This creates a multi-node k8s cluster using kind, with 1 control plane node, 3 worker nodes.

Other components:

- Prometheus: using helm chart `prometheus-community/kube-prometheus-stack`
- Nginx ingress controller: using helm chart `nginx-stable/nginx-ingress`. The service is patched to expose a port for Prometheus to scrape metrics
- Deployments `foo` and `bar` using image `hashicorp/http-echo`, exposed using services of the same name
- Ingress resource to route traffic to `foo` and `bar` pods
- A Prometheus `ServiceMonitor` to scrape nginx ingress controller metrics
- Temporary containers using `debian:bullseye` image for some checks, as well as "load testing"
- "Load testing" done using Apache Bench


## Prerequisites

- docker
- kind
- Helm v3
- kubectl 1.19 to 1.23
- jq
- python 2 or 3

Existence of prereqs will be checked by the `run.sh` script.

Helm and kubectl versions will be tested to ensure they fulfil the requirements.

For kubectl, generally 1 minor version before and after the server version is fine. But we extended the range to 2 minor versions instead (we will be creating the cluster using 1.21 but tested using kubectl 1.23)

### Installation instructions

Please follow the instructions in each of the links given.

- Docker: https://www.docker.com/get-started
- kind: https://kind.sigs.k8s.io/docs/user/quick-start#installation
- Helm v3: https://helm.sh/docs/intro/install/
- kubectl: https://kubernetes.io/docs/tasks/tools/
- jq: https://stedolan.github.io/jq/download/

If you are running on Amazon Linux 2 x86-64, you can run the `amzn-ec2-prereqs.sh` script to install the above prereqs. Please ensure that its root device has at least 10GiB of space. After the script is run, you will need to logout and login again to run the docker client without using sudo.


## Tested on

- Ubuntu Linux 20.04, docker 20.10.12, kind 0.11.1, kubectl 1.23, helm v3.7.2, python 3.8.0
- Mac OS Big Sur 11.6, docker 20.10.11, kind 0.11.1, kubectl 1.22.4, helm v3.7.2, python 3.9.1
- Amazon Linux 2 (ami-0d1d4b8d5a0cd293f) m6i.2xlarge with 32GiB root device, docker 20.10.7, kind 0.11.1, kubectl 1.21.1, helm v3.7.2, python 2.7.18


## Running

```
./run.sh
```
