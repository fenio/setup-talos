#!/bin/bash
set -e

echo "Starting Talos setup..."

# Read inputs
VERSION="${INPUT_VERSION:-latest}"
CLUSTER_NAME="${INPUT_CLUSTER_NAME:-talos-ci}"
KUBERNETES_VERSION="${INPUT_KUBERNETES_VERSION:-}"
NODES="${INPUT_NODES:-0}"
TALOSCTL_ARGS="${INPUT_TALOSCTL_ARGS:-}"
WAIT_FOR_READY="${INPUT_WAIT_FOR_READY:-true}"
TIMEOUT="${INPUT_TIMEOUT:-300}"

echo "Configuration: version=$VERSION, cluster-name=$CLUSTER_NAME, kubernetes-version=$KUBERNETES_VERSION, nodes=$NODES, wait-for-ready=$WAIT_FOR_READY, timeout=${TIMEOUT}s"

# Step 1: Install Docker (required for Talos local cluster)
echo "::group::Checking Docker"
if ! command -v docker &> /dev/null; then
    echo "Docker not found, installing..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker "$USER"
    rm get-docker.sh
    echo "✓ Docker installed"
else
    echo "✓ Docker already installed"
fi
echo "::endgroup::"

# Debug: Show system resources
echo "::group::System Resources"
echo "=== CPU Info ==="
nproc
echo "=== Memory Info ==="
free -h 2>/dev/null || cat /proc/meminfo | head -5
echo "=== Disk Space ==="
df -h / | head -2
echo "=== Docker Info ==="
docker info 2>/dev/null | grep -E "(CPUs|Total Memory|Storage Driver)" || true
echo "::endgroup::"

# Step 2: Resolve and install talosctl
echo "::group::Installing talosctl"

if [ "$VERSION" = "latest" ]; then
    echo "Resolving latest Talos version..."
    ACTUAL_VERSION=$(curl -sL https://api.github.com/repos/siderolabs/talos/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    if [ -z "$ACTUAL_VERSION" ]; then
        echo "::error::Failed to resolve latest version from GitHub API"
        exit 1
    fi
    echo "Latest version: $ACTUAL_VERSION"
else
    ACTUAL_VERSION="$VERSION"
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        BINARY_ARCH="amd64"
        ;;
    aarch64)
        BINARY_ARCH="arm64"
        ;;
    *)
        echo "::error::Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Architecture: $ARCH -> $BINARY_ARCH"

# Download and install talosctl
TALOSCTL_URL="https://github.com/siderolabs/talos/releases/download/${ACTUAL_VERSION}/talosctl-linux-${BINARY_ARCH}"
echo "Downloading talosctl from: $TALOSCTL_URL"

curl -sL "$TALOSCTL_URL" -o /tmp/talosctl
sudo install -m 755 /tmp/talosctl /usr/local/bin/talosctl
rm /tmp/talosctl

# Verify installation
talosctl version --client

echo "✓ talosctl installed successfully"
echo "::endgroup::"

# Step 3: Create Talos cluster
echo "::group::Creating Talos cluster"

# Build cluster create command
# Use the action timeout for talosctl wait-timeout (add 60s buffer for cluster creation itself)
WAIT_TIMEOUT=$((TIMEOUT + 60))
CLUSTER_CMD="talosctl cluster create --name $CLUSTER_NAME --wait-timeout ${WAIT_TIMEOUT}s"

# Add workers if specified
if [ "$NODES" -gt 0 ]; then
    CLUSTER_CMD+=" --workers $NODES"
fi

# Add Kubernetes version if specified
if [ -n "$KUBERNETES_VERSION" ]; then
    CLUSTER_CMD+=" --kubernetes-version $KUBERNETES_VERSION"
fi

# Add additional args
if [ -n "$TALOSCTL_ARGS" ]; then
    CLUSTER_CMD+=" $TALOSCTL_ARGS"
fi

echo "Creating cluster with command: $CLUSTER_CMD"
eval "$CLUSTER_CMD"

echo "✓ Talos cluster created successfully"
echo "::endgroup::"

# Debug: Show Docker containers after cluster creation
echo "::group::Docker Containers"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20
echo "::endgroup::"

# Step 4: Set config paths
TALOSCONFIG_PATH="$HOME/.talos/config"
KUBECONFIG_PATH="$HOME/.kube/config"

# Ensure kubeconfig directory exists
mkdir -p "$HOME/.kube"

# Merge kubeconfig
echo "Merging kubeconfig..."
talosctl kubeconfig "$KUBECONFIG_PATH"

# Set outputs
echo "talosconfig=$TALOSCONFIG_PATH" >> "$GITHUB_OUTPUT"
echo "kubeconfig=$KUBECONFIG_PATH" >> "$GITHUB_OUTPUT"
echo "TALOSCONFIG=$TALOSCONFIG_PATH" >> "$GITHUB_ENV"
echo "KUBECONFIG=$KUBECONFIG_PATH" >> "$GITHUB_ENV"

echo "TALOSCONFIG exported: $TALOSCONFIG_PATH"
echo "KUBECONFIG exported: $KUBECONFIG_PATH"

# Step 5: Wait for cluster ready if requested
if [ "$WAIT_FOR_READY" = "true" ]; then
    echo "::group::Waiting for cluster ready"
    echo "Waiting for Talos cluster to be ready (timeout: ${TIMEOUT}s)..."
    
    START_TIME=$(date +%s)
    LAST_STATUS_TIME=0
    
    # Wait for API server
    echo "Waiting for Kubernetes API server..."
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        
        if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
            echo "::error::Timeout waiting for cluster to be ready"
            echo ""
            echo "=== Diagnostic Information ==="
            echo "--- Talos cluster health ---"
            talosctl --nodes 127.0.0.1 --talosconfig "$TALOSCONFIG_PATH" health --wait-timeout=10s 2>&1 || true
            echo ""
            echo "--- Talos services ---"
            talosctl --nodes 127.0.0.1 --talosconfig "$TALOSCONFIG_PATH" services 2>&1 || true
            echo ""
            echo "--- Docker containers ---"
            docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>&1 || true
            echo ""
            echo "--- Kubernetes nodes ---"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide 2>&1 || true
            echo ""
            echo "--- Kubernetes pods (all namespaces) ---"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A -o wide 2>&1 || true
            echo ""
            echo "--- CoreDNS pod details ---"
            kubectl --kubeconfig "$KUBECONFIG_PATH" describe pods -n kube-system -l k8s-app=kube-dns 2>&1 || true
            echo ""
            echo "--- Recent events ---"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get events -n kube-system --sort-by='.lastTimestamp' 2>&1 | tail -30 || true
            exit 1
        fi
        
        # Print detailed status every 30 seconds
        if [ $((CURRENT_TIME - LAST_STATUS_TIME)) -ge 30 ]; then
            LAST_STATUS_TIME=$CURRENT_TIME
            echo ""
            echo "=== Status at ${ELAPSED}s ==="
            echo "Nodes:"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null || echo "  (not available yet)"
            echo "Pods in kube-system:"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system --no-headers 2>/dev/null | head -10 || echo "  (not available yet)"
            echo ""
        fi
        
        # Check if kubectl can connect
        if kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers &>/dev/null; then
            # Check if node is Ready
            if kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers | grep -q " Ready "; then
                echo "✓ Control plane node is Ready"
                
                # Check for system pods readiness
                if kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q "Running"; then
                    echo "✓ CoreDNS is running"
                    
                    # Check for no critical pods failing
                    CRITICAL_FAILING=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system --no-headers 2>/dev/null | grep -cE "Error|CrashLoopBackOff" || echo "0")
                    
                    if [ "$CRITICAL_FAILING" = "0" ]; then
                        echo "✓ No critical pods failing"
                        
                        # Verify all expected nodes are ready
                        EXPECTED_NODES=$((NODES + 1))  # workers + control plane
                        READY_NODES=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers | grep -c " Ready " || echo "0")
                        
                        if [ "$READY_NODES" -ge "$EXPECTED_NODES" ]; then
                            echo "✓ All $EXPECTED_NODES nodes are ready"
                            
                            # Show cluster info
                            echo ""
                            echo "=== Cluster Information ==="
                            kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
                            kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A
                            
                            echo ""
                            echo "✓ Talos cluster is fully ready!"
                            echo "::endgroup::"
                            break
                        else
                            echo "Waiting for all nodes to be ready ($READY_NODES/$EXPECTED_NODES ready)..."
                        fi
                    fi
                fi
            fi
        fi
        
        echo "Cluster not ready yet, waiting... (${ELAPSED}/${TIMEOUT}s)"
        sleep 5
    done
fi

echo "✓ Talos setup completed successfully!"
