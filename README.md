# OpenFeature demo

## Prerequisite
The following tools need to be install on your machine :
- jq
- kubectl
- git
- gcloud ( if you are using GKE)
- Helm


## Deployment Steps in GCP

You will first need a Kubernetes cluster with 2 Nodes.
You can either deploy on Minikube or K3s or follow the instructions to create GKE cluster:
### 1.Create a Google Cloud Platform Project
```shell
PROJECT_ID="<your-project-id>"
gcloud services enable container.googleapis.com --project ${PROJECT_ID}
gcloud services enable monitoring.googleapis.com \
    cloudtrace.googleapis.com \
    clouddebugger.googleapis.com \
    cloudprofiler.googleapis.com \
    --project ${PROJECT_ID}
```
### 2.Create a GKE cluster
```shell
ZONE=europe-west3-a
NAME=isitobservable-openfeature
gcloud container clusters create "${NAME}" \
 --zone ${ZONE} --machine-type=e2-standard-2 --num-nodes=4
```


## Getting started
### 1. Nginx Ingress Controller
```
helm upgrade --install ingress-nginx ingress-nginx  --repo https://kubernetes.github.io/ingress-nginx  --namespace ingress-nginx --create-namespace
```
#### Get Ip adress 
```
IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -ojson | jq -j '.status.loadBalancer.ingress[].ip')
```
#### Enable the ssl passthrough
```
kubectl edit deployment ingress-nginx-controller -n ingress-nginx
```
you need to add an extra args to nginx pod:

![nginx](assets/nginx_ssl_passthrough.png)

#### Update ingress Rules
```
sed -i "s,IP_TO_REPLACE,$IP," argocd/argo-access-service.yaml
sed -i "s,IP_TO_REPLACE,$IP," fib3r/helm/fib3r/templates/service.yaml
sed -i "s,IP_TO_REPLACE,$IP," observability/ingress.yaml
```

### 2. Prometheus Operator
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack
kubectl apply -f observability/ingress.yaml
PASSWORD_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
USER_GRAFANA=$(kubectl get secret --namespace default prometheus-grafana -o jsonpath="{.data.admin-user}" | base64 --decode)
```

### 3. OpenTelemetry Operator
#### 1. Cert-manager
```
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
```
#### 2. OpenTelemetry Operator
```
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```


### 4. Dynatrace Tenant
#### 1. Dynatrace Tenant - start a trial
If you don't have any Dyntrace tenant , then i suggest to create a trial using the following link : [Dynatrace Trial](https://bit.ly/3KxWDvY)
Once you have your Tenant save the Dynatrace (including https) tenant URL in the variable `DT_TENANT_URL` (for example : https://dedededfrf.live.dynatrace.com)
```
DT_TENANT_URL=<YOUR TENANT URL>
sed -i "s,DT_TENANT_URL_TO_REPLACE,$DT_TENANT_URL," dynatrace/dynakube.yaml
sed -i "s,DT_TENANT_URL_TO_REPLACE,$DT_TENANT_URL," klt/trigger-dt-synthetics-ktd.yaml
sed -i "s,DT_URL_TO_REPLACE,$DT_TENANT_URL," observability/otel-collector.yaml
```


#### 2. Create the Dynatrace API Tokens
The dynatrace operator will require to have several tokens:
* Token to deploy and configure the various components
* Token to ingest metrics , logs, Traces

##### Token to deploy
Create a Dynatrace token ( left menu Access TOken/Create a new token), this token requires to have the following scope:
* Create ActiveGate tokens
* Read entities
* Read Settings
* Write Settings
* Access problem and event feed, metrics and topology
* Read configuration
* Write configuration
* Paas integration - installer downloader
  ![token_operator](assets/operator_token.png)

Save the value of the token . We will use it later to store in a k8S secret
```
DYNATRACE_API_TOKEN=<YOUR TOKEN VALUE>
```
##### Token to ingest data
Create a Dynatrace token with the following scope:
* Ingest metrics
* Ingest OpenTelemetry traces
* Ingest logs (logs.ingest)
* Ingest events
  ![token_ingest](assets/data_ingest.png)
Save the value of the token . We will use it later to store in a k8S secret

```
DATA_INGEST_TOKEN=<YOUR TOKEN VALUE>
sed -i "s,DT_TOKEN_TO_REPLACE,$DATA_INGEST_TOKEN," observability/otel-collector.yaml
```
##### Deploy the Dynatrace Operator 
```
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v0.10.2/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v0.10.2/kubernetes-csi.yaml
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DYNATRACE_API_TOKEN" --from-literal="dataIngestToken=$DATA_INGEST_TOKEN"
kubectl apply -f dynatrace/dynakube.yaml -n dynatrace
```

### 5. ArgoCD
```
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd apply -f argo-access-service.yaml
```
Get the ArgoCD password:
```
ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo)
```
#### install the argocd cli
```
VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/$VERSION/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
```

#### connect the cli with the ArgoCD server
```
argocd login https://argocd.$IP.nip.io --username admin  --password $ARGO_PWD
```

#### create the git repository in the argocd server
```
GITHUB_REPO_URL=<Your FORK GITHUB REPO>
GITHUB_USER=<GITHUB USER NAME>
GITHUB_PAT_TOKEN=<YOUR GITHUB PAT TOKEN>
argocd repo add $GITHUB_REPO_URL --username $GITHUB_USER --password $GITHUB_PAT_TOKEN --insecure-skip-server-verification
```


#### Create the argocd applications
```
kubectl apply -f argocd/applications.yaml
argocd app sync fibonacci
argicd app sync fib3r
```

#### Create Prometheus ServiceMonitors
```
kubectl apply -f argocd/service_monitor.yaml
```

### 5. Keptn LifeCycle Toolkit


## Webhook.site URL

Go to `https://webhook.site` and get your URL. It should look like: `https://webhook.site/abcd1234-12ab-34cd-abcd-1234abcd1234`

## Update ArgoCD notifications ConfigMap (One-off task)

These files will force argo to notify DT events v2 API (and the webhook.site page for testing purposes) in two cases:

1) Every time argo goes out-of-sync (send a CUSTOM_INFO event)
2) Every time argo goes back in sync (send a CUSTOM_DEPLOYMENT event)

Modify `openfeature-perform2023/argocd/argocd-notifications-secret.yaml` with your details.

```
kubectl -n argocd apply -f openfeature-perform2023/argocd/argocd-notifications-secret.yaml
```

DO NOT COMMIT THIS FILE TO Git. TODO (future): Use sealed-secrets?

Now apply the `notifications-cm.yaml` (as-is because it relies on the secrets ConfigMap you just created)

```
kubectl -n argocd apply -f openfeature-perform2023/argocd/notifications-cm.yaml
```

## Add Notification subscriptions to apps in argo (One-off task)
In argo, modify the `fib3r` app and add a notification subscription:

`notifications.argoproj.io/subscribe.on-out-of-sync-status.webhooksite = ""`

The two double quotes `""` are critical. It won't work without those.

Repeat again for:

```
notifications.argoproj.io/subscribe.on-in-sync-status.webhooksite=""
notifications.argoproj.io/subscribe.on-in-sync-status.dt_service=""
notifications.argoproj.io/subscribe.on-in-sync-status.dt_application=""
notifications.argoproj.io/subscribe.on-in-sync-status.dt_synthetic_test=""
notifications.argoproj.io/subscribe.on-out-of-sync-status.webhooksite=""
notifications.argoproj.io/subscribe.on-out-of-sync-status.dt_service=""
notifications.argoproj.io/subscribe.on-out-of-sync-status.dt_application=""
notifications.argoproj.io/subscribe.on-out-of-sync-status.dt_synthetic_test=""
```

You should have `8` notification subscriptions for `fib3r` now.

Repeat the whole process for the `fibonacci`.

At the end, each app should have `8x` notification subscriptions.

![notifications list](assets/argo-app-notifications.png)


Note: The events won't appear in DT yet because they rely on tag rules that have not yet been applied.
The webhook.site events will work so you can test now:

Change the app color from green to blue. Modify `openfeature-perform2023/fib3r/helm/fib3r/templates/configmap.yaml` line 26 and change `defaultColor` to something else.

```
git add fib3r/*
git commit -sm "update app color"
git push
```

Click refresh and app should go "out of sync". A notification should appear in `webhook.site`.

![out of sync](assets/webhook.site.oos.png)

Sync the application and you should see a second notification on `webhook.site`.

![in sync](assets/webhook.site.insync.png)

## Apply Dynatrace Configuration (One-off task)

Create a DT Access token with:

- `ReadConfig`
- `WriteConfig`
- `ExternalSyntheticIntegration`
- `CaptureRequestData`
- `settings.read`
- `settings.write`
- `syntheticExecutions.write`
- `syntheticExecutions.read`
- `events.ingest`
- `events.read`

```
DT_TOKEN=<TOKEN VALUE>
cd openfeature-perform2023/dt_setup
chmod +x setup.sh
./setup.sh $DT_TENANT_URL $DT_TOKEN
```

This script:
- Downloads `jq`
- Retrieves the K8S integration details setup when the OneAgent dynakube was installed
- Enables k8s events integration
- Configures DT to capture 3x span attributes: `feature_flag.flag_key`, `feature_flag.provider_name` and `feature_flag.evaluated_variant`
- Downloads the `monaco` binary
- Uses `sed` to get and replace the public LoadBalancer IP in the monaco template files (for app detection rule and synthetics)

Then the script uses monaco to create:

- 1x application called `OpenFeature` with User Action properties linked to the serverside request attributes
- 1x application url rule that maps the public LoadBalancer IP to the `OpenFeature` application
- 1x management zone called `openfeature`
- 1x auto-tag rule which adds `app: OpenFeature` tag to the application and synthetics
- 4x request attributes: `feature_flag.evaluated_variant`, `feature_flag.provider_name`, `feature_flag.flag_key` and `fibn` (captures query param for the number that fib is being calculated)
- 2x synthetic monitors: `OpenFeature Default` and `OpenFeature Logged In` (running on-demand only) (Note: the GEOLOCATION ID is currently set to a sprint one - TODO variabilise this)

## Out-of-sync and In-sync events on DT Service
Now that DT is configured, each time Argo goes out-of-sync or back in-sync, you should see events on the DT `openfeature` service:

![out-of-sync](assets/dt-event-from-argo-out-of-sync.png)
![in-sync](assets/dt-event-from-argo-in-sync.png)

## KLT Toolkit working for fib3r

- KLT: Find a way to trigger on-demand synthetics from a post-deploy task
- KLT: Find out how to pull metrics from DT
- Playground app: Modify CM so rule is `UserAgent in DynatraceSynthetic` and set it up so `DynatraceSynthetic` uses `remote service`
- Playground app: Modify CM so remote service password is wrong to start with (this won't affect any real users)

## Install otel collector

```
kubectl apply -f observability/rbac.yaml
kubectl apply -f observability/openTelemetry-manifest_prometheus.yaml
```



## Grafana

```
echo User: $USER_GRAFANA
echo Password: $PASSWORD_GRAFANA
echo grafana url : http://grafana.IP_TO_REPLACE.nip.io"
```



## Dynatrace Gen3 Notebook

*n Deployments*
```
fetch events
| filter `event.type` == "CUSTOM_DEPLOYMENT"
| summarize count()
```

*n out-of-sync(s)*
```
fetch events
| filter `event.type` == "CUSTOM_INFO"
| filter `app name` == "fib3r"
| filter contains(`event.name`,"out of sync")
| summarize count()
```
