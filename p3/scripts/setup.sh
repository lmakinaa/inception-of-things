#!/usr/bin/env bash
#
# Part 3 — K3d + Argo CD bootstrap.
#
# Runs on a fresh Debian/Ubuntu VM (no Vagrant this time — the subject asks
# for a script that installs every package and tool during the defense).
#
# It is idempotent: re-running skips anything already present, so it's safe
# to run again if a step fails halfway.
#
# End state:
#   - Docker, kubectl, k3d (+ argocd CLI) installed
#   - a k3d cluster named `iot`
#   - namespaces: argocd, dev
#   - Argo CD installed in the argocd namespace
#   - the `inception-of-things` Application applied (deploys the app into dev)
#
# Usage:  ./setup.sh          (from anywhere; paths are resolved below)

set -euo pipefail

# --- Resolve paths so the script works no matter where it's called from -------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P3_DIR="$(dirname "$SCRIPT_DIR")"
APPLICATION_YAML="$P3_DIR/confs/application.yaml"

CLUSTER_NAME="iot"
ARGOCD_NS="argocd"
DEV_NS="dev"

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }

# --- 1. Docker ----------------------------------------------------------------
# k3d runs K3s inside Docker containers, so Docker is the hard dependency.
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh
  # let the current (non-root) user talk to the Docker socket without sudo
  sudo usermod -aG docker "$USER" || true
  echo "NOTE: you may need to log out/in (or run 'newgrp docker') for group changes to apply."
else
  log "Docker already installed — skipping"
fi

# --- 2. kubectl ---------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl"
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
else
  log "kubectl already installed — skipping"
fi

# --- 3. k3d -------------------------------------------------------------------
if ! command -v k3d >/dev/null 2>&1; then
  log "Installing k3d"
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
else
  log "k3d already installed — skipping"
fi

# --- 4. argocd CLI (optional but handy for the defense) -----------------------
if ! command -v argocd >/dev/null 2>&1; then
  log "Installing argocd CLI"
  curl -fsSLo /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
  rm -f /tmp/argocd
else
  log "argocd CLI already installed — skipping"
fi

# --- 5. k3d cluster -----------------------------------------------------------
if ! k3d cluster list | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  log "Creating k3d cluster '$CLUSTER_NAME'"
  # Map host :8888 -> loadbalancer :8888 so the playground app is reachable
  # from the host browser without a manual port-forward (optional convenience).
  k3d cluster create "$CLUSTER_NAME" -p "8888:8888@loadbalancer"
else
  log "k3d cluster '$CLUSTER_NAME' already exists — skipping"
fi

# make sure kubectl is pointed at the new cluster
kubectl config use-context "k3d-${CLUSTER_NAME}"

# --- 6. Namespaces ------------------------------------------------------------
log "Creating namespaces: $ARGOCD_NS, $DEV_NS"
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$DEV_NS"    --dry-run=client -o yaml | kubectl apply -f -

# --- 7. Argo CD ---------------------------------------------------------------
log "Installing Argo CD into '$ARGOCD_NS'"
kubectl apply -n "$ARGOCD_NS" \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log "Waiting for Argo CD to become ready (this can take a couple of minutes)"
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n "$ARGOCD_NS"

# --- 8. The Application (GitOps app) -----------------------------------------
log "Applying the Argo CD Application"
kubectl apply -f "$APPLICATION_YAML"

# --- 9. Info ------------------------------------------------------------------
log "Done. Admin credentials & access:"
echo "  username: admin"
printf '  password: '
kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

cat <<'EOF'

Access the Argo CD UI:
  kubectl port-forward -n argocd svc/argocd-server 8080:443
  → https://localhost:8080  (accept the self-signed cert)

Access the deployed app:
  kubectl port-forward -n dev svc/playground 8888:8888
  → curl http://localhost:8888

Check status:
  kubectl get applications -n argocd
  kubectl get pods -n dev
EOF
