#!/bin/sh

# Token needs:
#   ReadConfig
#   WriteConfig
#   Create and read synthetic monitors, locations, and nodes
#   CaptureRequestData

# This setup.sh should only be used when you have exposed fib3r with a LoadBalancer
# As it looks up the LB IP and uses it to configure the app detection rule.

# Usage:
# ./dt_setup.sh \
# https://abc12345.live.dynatrace.com \
# dt0c01.foo.bar

export CLUSTER_NAME=openfeature-demo
export DT_URL=$1
export DT_TOKEN=$2
export MONACO_VERSION=v1.8.9
export JQ_VERSION=1.6

# Download jq
if [ ! -f "jq" ]; then
  wget -q -O jq https://github.com/stedolan/jq/releases/download/jq-$JQ_VERSION/jq-linux64
  chmod +x jq
fi

# Get k8s integration details
K8S_INTEGRATIONS=$(curl -X GET "$DT_URL/api/v2/settings/objects?schemaIds=builtin%3Acloud.kubernetes&fields=objectId%2Cvalue" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $DT_TOKEN")
# Search response and store ObjectID for this integration
# Bug potential here: Assumes only one k8s integration exists called "openfeature-demo"
DT_OBJECT_ID=$(echo "$K8S_INTEGRATIONS" | jq .items | jq -c "map(select(.value.label | contains(\"$CLUSTER_NAME\")))" | jq -r .[0].objectId)

# Store CLUSTER_ID as well
CLUSTER_ID=$(echo "$K8S_INTEGRATIONS" | jq .items | jq -c "map(select(.value.label | contains(\"$CLUSTER_NAME\")))" | jq -r .[0].value.clusterId)

# PUT to Enable events integration
curl -s -X PUT "$DT_URL/api/v2/settings/objects/$DT_OBJECT_ID" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $DT_TOKEN" -H "Content-Type: application/json; charset=utf-8" -d "{\"value\":{\"enabled\":true,\"label\":\"openfeature-demo\",\"clusterIdEnabled\":true,\"clusterId\":\"$CLUSTER_ID\",\"cloudApplicationPipelineEnabled\":true,\"pvcMonitoringEnabled\":true,\"openMetricsPipelineEnabled\":true,\"eventProcessingActive\":true,\"filterEvents\":false}}"

# Capture span attributes
curl -s -X POST "$DT_URL/api/v2/settings/objects?validateOnly=false" -H "accept: application/json; charset=utf-8" -H "Authorization: Api-Token $DT_TOKEN" -H "Content-Type: application/json; charset=utf-8" -d "[{\"schemaVersion\":\"0.0.28\",\"externalId\":\"feature_flag.flag_key\",\"schemaId\":\"builtin:span-attribute\",\"value\":{\"key\":\"feature_flag.flag_key\",\"masking\":\"NOT_MASKED\"},\"scope\":\"environment\"},{\"schemaVersion\":\"0.0.28\",\"externalId\":\"feature_flag.provider_name\",\"schemaId\":\"builtin:span-attribute\",\"value\":{\"key\":\"feature_flag.provider_name\",\"masking\":\"NOT_MASKED\"},\"scope\":\"environment\"},{\"schemaVersion\":\"0.0.28\",\"externalId\":\"feature_flag.evaluated_variant\",\"schemaId\":\"builtin:span-attribute\",\"value\":{\"key\":\"feature_flag.evaluated_variant\",\"masking\":\"NOT_MASKED\"},\"scope\":\"environment\"}]"

# Download Monaco binary
if [ ! -f "monaco" ]; then
  wget -q -O monaco https://github.com/dynatrace-oss/dynatrace-monitoring-as-code/releases/download/$MONACO_VERSION/monaco-linux-amd64
  chmod +x monaco
fi

# Get LB IP for fib3r and replace the placeholder in monaco
# This sets the app-detection-rule properly
export FIB3R_IP=$(kubectl -n default get svc/fib3r -o json | jq -r .status.loadBalancer.ingress[0].ip)
sed -i "s/\"OF_PUBLIC_ADDRESS_PLACEHOLDER\"/$FIB3R_IP/g" monaco_config/app-detection-rule-v2/rules.yaml
sed -i "s/OF_PUBLIC_ADDRESS_PLACEHOLDER/$FIB3R_IP/g" monaco_config/synthetic-monitor/monitors.yaml

# Apply config
export NEW_CLI=1
./monaco deploy -p="monaco_config" --environments="environments.yaml"
