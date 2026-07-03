## Kubernetes Using kind

This guide walks through setting up a Kubernetes cluster on an Ubuntu VM running on Proxmox, using **kind** (Kubernetes in Docker). Below are the VM specifications and the steps involved.

**VM Configuration**

| Resource       | Value        |
|----------------|--------------|
| vCPU           | 12           |
| RAM            | 20 GB        |
| Disk           | 150 GB       |
| OS             | Ubuntu 24.04 |
| Container Runtime | Docker    |

### Install Required Packages

Before creating the cluster, install the necessary tools: `kind`, `kubectl`, `helm`, and `docker`. For reference, here is the script that installs these dependencies:

```sh
~$ [ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64

~$ chmod +x ./kind

~$ sudo mv ./kind /usr/local/bin/kind


~$ curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

~$ sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install helm

# Install docker based on recommendations from docker website

# Add current user to docker group

sudo usermod -aG docker $USER 
```

### Creating kind cluster

With the tools in place, define the cluster layout using a YAML configuration file. For reference, here is the cluster configuration used for this setup:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP

  - role: worker
    labels:
      node-role: inference
  - role: worker
    labels:
      node-role: platform
```

Once the configuration file is ready, create the cluster and verify it. For reference, here is the output from creating the cluster and checking the nodes:

```sh

~$ kind create cluster --name llm-lab --config kind_config.yaml
Creating cluster "llm-lab" ...
 ✓ Ensuring node image (kindest/node:v1.36.1) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-llm-lab"
You can now use your cluster with:

kubectl cluster-info --context kind-llm-lab

~$ kubectl get nodes
NAME                    STATUS   ROLES           AGE   VERSION
llm-lab-control-plane   Ready    control-plane   37s   v1.36.1
llm-lab-worker          Ready    <none>          22s   v1.36.1
llm-lab-worker2         Ready    <none>          22s   v1.36.1

```

### Setup kserve

With the cluster running, install KServe to manage model inference. For reference, here is the installation script and its output:

```sh

# Create the KServe namespace
kubectl create ns kserve

# Install kserve standard mode
curl -sL "https://github.com/kserve/kserve/releases/download/v0.18.0/kserve-standard-mode-full-install-with-manifests.sh" | bash

# Logs for reference

# [SUCCESS] Deployment 'kserve-controller-manager' in namespace 'kserve' is available!
# [SUCCESS] KServe configuration updated
# [INFO] Waiting for deployment: kserve-controller-manager
# [INFO] Waiting for deployment 'kserve-controller-manager' in namespace 'kserve' to be available...
# deployment.apps/kserve-controller-manager condition met
# [SUCCESS] Deployment 'kserve-controller-manager' in namespace 'kserve' is available!
# [SUCCESS] KServe is ready!
# [INFO] Installing ClusterServingRuntimes...
# clusterservingruntime.serving.kserve.io/kserve-huggingfaceserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-huggingfaceserver-multinode serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-lgbserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-mlserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-paddleserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-pmmlserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-predictiveserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-sklearnserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-tensorflow-serving serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-torchserve serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-tritonserver serverside-applied
# clusterservingruntime.serving.kserve.io/kserve-xgbserver serverside-applied
# ==========================================
# ✅ Installation completed successfully!
# ========================================== 
```

### Creating InferenceService

After KServe is installed, deploy an inference service to serve a model. For reference, here is the command used to create the service and the configuration applied:

```sh

# Create namespace for service
kubectl create namespace kserve-test

# Tried example shared on kserve site

kubectl apply -n kserve-test -f - <<EOF
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "qwen-llm"
  namespace: kserve-test
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      args:
        - --model_name=qwen
      storageUri: "hf://Qwen/Qwen2.5-0.5B-Instruct"
      resources:
        limits:
          cpu: "2"
          memory: 10Gi
        requests:
          cpu: "1"
          memory: 6Gi
EOF
```

Right after applying the configuration, a warning appeared indicating that the Istio VirtualService CRD was missing. For reference, here is the event log:

```sh
~$ kubectl describe inferenceservices qwen-llm -n kserve-test


Events:
  Type     Reason                     Age                From                Message
  ----     ------                     ----               ----                -------
  Warning  VirtualServiceCRDNotFound  67s (x4 over 67s)  v1beta1Controllers  Istio VirtualService CRD not present; VirtualService reconciliation skipped. If you do not use Istio, set ingress.disableIstioVirtualHost=true.
```

Following the recommendation, the KServe ConfigMap was updated and the inference service was recreated. For reference, here are the commands used:

```sh
~$ kubectl edit cm -n kserve inferenceservice-config

~$ kubectl delete inferenceservices qwen-llm -n kserve-test
inferenceservice.serving.kserve.io "qwen-llm" deleted from kserve-test namespace
```

Even after these changes, the predictor pod failed to reach a ready state. For reference, here is the deployment and pod status:

```sh
~$ kubectl get deployment -n kserve-test
NAME                 READY   UP-TO-DATE   AVAILABLE   AGE
qwen-llm-predictor   0/1     1            0           88s

~$ kubectl get pod -n kserve-test
NAME                                 READY   STATUS            RESTARTS   AGE
qwen-llm-predictor-9bf6b7d4f-gnjj7   0/1     PodInitializing   0          3m30s
```

The pod was scheduled and its init container pulled successfully. For reference, here are the detailed deployment events:

```sh
~$ kubectl describe deployment -n kserve-test qwen-llm-predictor

Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  52s   default-scheduler  Successfully assigned kserve-test/qwen-llm-predictor-9bf6b7d4f-gnjj7 to llm-lab-worker2
  Normal  Pulling    51s   kubelet            spec.initContainers{storage-initializer}: Pulling image "kserve/storage-initializer:v0.18.0"
  Normal  Pulled     37s   kubelet            spec.initContainers{storage-initializer}: Successfully pulled image "kserve/storage-initializer:v0.18.0" in 14.474s (14.474s including waiting). Image size: 95811081 bytes.
  Normal  Created    37s   kubelet            spec.initContainers{storage-initializer}: Container created
  Normal  Started    37s   kubelet            spec.initContainers{storage-initializer}: Container started
```

The main KServe container was running but never marked as ready. For reference, here are the container details:

```sh
kserve-container:
    Container ID:  containerd://2920eab3922a642deababd9b35b2335659efc3d972683715b43f99ff5cf029a5
    Image:         kserve/huggingfaceserver:v0.18.0
    Image ID:      docker.io/kserve/huggingfaceserver@sha256:c3eca773e960a147220585897d3def3ca2ff3cc2c0cdfeb0bc9a53dea10eb581
    Port:          <none>
    Host Port:     <none>
    Args:
      --model_name=qwen-llm
      --model_name=qwen
    State:          Running
      Started:      Fri, 03 Jul 2026 22:51:25 +0000
    Ready:          False
    Restart Count:  0
    Limits:
      cpu:     2
      memory:  10Gi
    Requests:
      cpu:      1
      memory:   6Gi

```

Even after increasing the Ubuntu VM's RAM to 22 GiB, the KServe container still fails to stay in a "Running" state for long. Further investigation is needed to determine the root cause.