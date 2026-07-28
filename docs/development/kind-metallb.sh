#!/usr/bin/env bash
# Install and configure MetalLB in a kind cluster so that Services of type
# LoadBalancer get an IP from the Docker bridge network.
set -euo pipefail

METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"

echo "Installing MetalLB ${METALLB_VERSION}..."
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

echo "Waiting for MetalLB pods..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

# Derive an address range from the kind Docker network subnet.
# The kind network is typically something like 172.x.0.0/16; we use .255.200-.255.250.
SUBNET=$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' kind \
  | grep -v ':' | head -1)  # skip IPv6, take first IPv4

if [ -z "$SUBNET" ]; then
  echo "ERROR: could not determine kind Docker network subnet" >&2
  exit 1
fi

IFS='./' read -r OCTET1 OCTET2 OCTET3 _ PREFIX_LEN <<<"$SUBNET"

# Docker IPAM allocates upward from the bottom of the subnet, so a /16 has room
# to put the pool far out of its way. Anything narrower has to stay in the
# subnet's own third octet or the addresses are off-network and unroutable.
if [ "$PREFIX_LEN" -le 16 ]; then
  POOL_OCTET3=255
else
  POOL_OCTET3=$OCTET3
fi

RANGE_START="${OCTET1}.${OCTET2}.${POOL_OCTET3}.200"
RANGE_END="${OCTET1}.${OCTET2}.${POOL_OCTET3}.250"

echo "Configuring MetalLB address pool: ${RANGE_START}-${RANGE_END}"
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - ${RANGE_START}-${RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
EOF

echo "MetalLB ready."
