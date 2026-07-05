## Rebuild kind

After encountering out-of-memory (OOM) errors in the previous attempt, this round rebuilds the Kind cluster nodes with explicit CPU and memory reservations. The goal is to determine whether allocating more resources allows KServe containers to start without being terminated.

### Kind configuration

For reference, here is the Kind cluster configuration that assigns resource reservations to each node:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  - role: control-plane
    kubeadmConfigPatches:
    - |
       kind: InitConfiguration
       nodeRegistration:
         kubeletExtraArgs:
           system-reserved: cpu=2,memory=3Gi
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
    kubeadmConfigPatches:
    - |
       kind: JoinConfiguration
       nodeRegistration:
         kubeletExtraArgs:
           system-reserved: cpu=4,memory=10Gi

  - role: worker
    labels:
      node-role: platform
    kubeadmConfigPatches:
    - |
       kind: JoinConfiguration
       nodeRegistration:
         kubeletExtraArgs:
           system-reserved: cpu=2,memory=3Gi
```

Once the cluster is up, confirm all nodes are running.

For reference, here is the command used to check the nodes and its output:

```sh
$ k get nodes
NAME                    STATUS   ROLES           AGE   VERSION
llm-lab-control-plane   Ready    control-plane   35s   v1.36.1
llm-lab-worker          Ready    <none>          26s   v1.36.1
llm-lab-worker2         Ready    <none>          26s   v1.36.1

```

Deploy KServe

With the nodes ready, the next step is to install KServe itself. For reference, here are the commands to create the namespace, run the standard installation script, and verify that all pods come up successfully:

```sh

# Create the KServe namespace
kubectl create ns kserve

# Install kserve standard mode
curl -sL "https://github.com/kserve/kserve/releases/download/v0.18.0/kserve-standard-mode-full-install-with-manifests.sh" | bash

# Get all pods
$ k get pods -A -o wide
NAMESPACE            NAME                                            READY   STATUS    RESTARTS   AGE     IP           NODE                    NOMINATED NODE   READINESS GATES
cert-manager         cert-manager-556d7b4d8c-4lfw9                   1/1     Running   0          119s    10.244.1.2   llm-lab-worker          <none>           <none>
cert-manager         cert-manager-cainjector-676796597b-x54bm        1/1     Running   0          119s    10.244.1.3   llm-lab-worker          <none>           <none>
cert-manager         cert-manager-webhook-7c65796f99-ng7hv           1/1     Running   0          119s    10.244.2.2   llm-lab-worker2         <none>           <none>
kserve               kserve-controller-manager-5cb9cdf87b-v2bsb      2/2     Running   0          95s     10.244.1.5   llm-lab-worker          <none>           <none>
kube-system          coredns-589f44dc88-5w7fr                        1/1     Running   0          3m22s   10.244.0.4   llm-lab-control-plane   <none>           <none>
kube-system          coredns-589f44dc88-pkn7c                        1/1     Running   0          3m22s   10.244.0.3   llm-lab-control-plane   <none>           <none>
kube-system          etcd-llm-lab-control-plane                      1/1     Running   0          3m30s   172.18.0.3   llm-lab-control-plane   <none>           <none>
kube-system          kindnet-g795q                                   1/1     Running   0          3m21s   172.18.0.4   llm-lab-worker          <none>           <none>
kube-system          kindnet-h6gq9                                   1/1     Running   0          3m21s   172.18.0.2   llm-lab-worker2         <none>           <none>
kube-system          kindnet-pxppg                                   1/1     Running   0          3m22s   172.18.0.3   llm-lab-control-plane   <none>           <none>
kube-system          kube-apiserver-llm-lab-control-plane            1/1     Running   0          3m30s   172.18.0.3   llm-lab-control-plane   <none>           <none>
kube-system          kube-controller-manager-llm-lab-control-plane   1/1     Running   0          3m29s   172.18.0.3   llm-lab-control-plane   <none>           <none>
kube-system          kube-proxy-c7gdq                                1/1     Running   0          3m21s   172.18.0.2   llm-lab-worker2         <none>           <none>
kube-system          kube-proxy-v4slf                                1/1     Running   0          3m21s   172.18.0.4   llm-lab-worker          <none>           <none>
kube-system          kube-proxy-wjgdj                                1/1     Running   0          3m22s   172.18.0.3   llm-lab-control-plane   <none>           <none>
kube-system          kube-scheduler-llm-lab-control-plane            1/1     Running   0          3m30s   172.18.0.3   llm-lab-control-plane   <none>           <none>
local-path-storage   local-path-provisioner-855c7b7774-4lgw7         1/1     Running   0          3m22s   10.244.0.2   llm-lab-control-plane   <none>           <none>

```

With all pods running, the installation also requires a configuration tweak. For reference, here is the command to update the `inferenceservice-config` ConfigMap so that KServe uses raw deployment mode and disables the Istio virtual host:

```sh

# Update defaultDeploymentMode to RawDeployment, disableIstioVirtualHost to true
$ kubectl edit cm -n kserve inferenceservice-config
configmap/inferenceservice-config edited

$ k get pod -n kserve
NAME                                         READY   STATUS    RESTARTS   AGE
kserve-controller-manager-5cb9cdf87b-sn8hp   2/2     Running   0          79s

```

Deploy InferenceService

With KServe installed and configured, the next step is to deploy a sample model. For reference, here are the commands to create a test namespace, deploy an InferenceService running a scikit-learn iris model, and verify that the service is ready:

```sh

# Create namespace for service
kubectl create namespace kserve-test

# Deploy InferenceService

kubectl apply -n kserve-test -f - <<EOF
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-iris"
  namespace: kserve-test
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
      resources:
        limits:
          cpu: "500m"
          memory: "512Mi"
        requests:
          cpu: "100m"
          memory: "256Mi"
EOF

$ k get isvc -n kserve-test
NAME           URL                                           READY   PREV   LATEST   PREVROLLEDOUTREVISION   LATESTREADYREVISION   AGE
sklearn-iris   http://sklearn-iris-kserve-test.example.com   True                                                                  69s

~$ kubectl port-forward -n kserve-test svc/sklearn-iris-predictor 8080:80
Forwarding from [::1]:8080 -> 8080
Handling connection for 8080
Handling connection for 8080

~$  curl -H "Content-Type: application/json"   -d '{"instances": [[6.8, 2.8, 4.8, 1.4]]}'   http://localhost:8080/v1/models/sklearn-iris:predict
{"predictions":[1]}

```

The scikit-learn iris model responds correctly with a prediction of `[1]`. This confirms that KServe works with a CPU-only model on the rebuilt Kind cluster, and the resource reservations resolved the earlier OOM issues.