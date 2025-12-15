#!/usr/bin/env bash
set -e

echo "::group::Installing Talos"
echo "Starting Talos setup..."

# Read inputs
VERSION="${INPUT_VERSION:-latest}"
CLUSTER_NAME="${INPUT_CLUSTER_NAME:-talos-ci}"
KUBERNETES_VERSION="${INPUT_KUBERNETES_VERSION:-}"
NODES="${INPUT_NODES:-0}"
PROVISIONER="${INPUT_PROVISIONER:-docker}"
CPUS="${INPUT_CPUS:-2}"
MEMORY="${INPUT_MEMORY:-2048}"
DISK="${INPUT_DISK:-6144}"
WITH_UEFI="${INPUT_WITH_UEFI:-true}"
TALOSCTL_ARGS="${INPUT_TALOSCTL_ARGS:-}"
WAIT_FOR_READY="${INPUT_WAIT_FOR_READY:-true}"
TIMEOUT="${INPUT_TIMEOUT:-300}"
DNS_READINESS="${INPUT_DNS_READINESS:-true}"
LOAD_NVME_MODULES="${INPUT_LOAD_NVME_MODULES:-false}"

echo "Configuration: version=$VERSION, cluster-name=$CLUSTER_NAME, kubernetes-version=$KUBERNETES_VERSION, nodes=$NODES, provisioner=$PROVISIONER, wait-for-ready=$WAIT_FOR_READY, timeout=${TIMEOUT}s, dns-readiness=$DNS_READINESS"

if [ "$PROVISIONER" = "qemu" ]; then
    echo "QEMU configuration: cpus=$CPUS, memory=${MEMORY}MB, disk=${DISK}MB, uefi=$WITH_UEFI"
fi

# Validate provisioner
if [ "$PROVISIONER" != "docker" ] && [ "$PROVISIONER" != "qemu" ]; then
    echo "::error::Invalid provisioner '$PROVISIONER'. Must be 'docker' or 'qemu'."
    exit 1
fi

# Install Docker (required for Docker provisioner)
if [ "$PROVISIONER" = "docker" ]; then
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

    # Load br_netfilter kernel module (required for Flannel CNI in Docker)
    echo "::group::Loading kernel modules"
    if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
        echo "✓ br_netfilter module already loaded"
    else
        echo "Loading br_netfilter module..."
        sudo modprobe br_netfilter || echo "::warning::Failed to load br_netfilter module"
        if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
            echo "✓ br_netfilter module loaded successfully"
        else
            echo "::warning::br_netfilter module not available - Flannel may fail"
        fi
    fi
    # Enable bridge netfilter
    echo "Enabling bridge-nf-call-iptables..."
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
    echo "::endgroup::"
    
    # Load NVMe kernel modules if requested (for NVMe-oF support with Docker provisioner)
    if [ "$LOAD_NVME_MODULES" = "true" ]; then
        echo "::group::Loading NVMe kernel modules"
        echo "Loading NVMe-oF TCP kernel modules on host..."
        
        # Load nvme-core first
        if ! lsmod | grep -q "^nvme_core"; then
            echo "Loading nvme-core module..."
            sudo modprobe nvme-core || echo "::warning::Failed to load nvme-core module"
        else
            echo "✓ nvme-core already loaded"
        fi
        
        # Load nvme-fabrics 
        if ! lsmod | grep -q "^nvme_fabrics"; then
            echo "Loading nvme-fabrics module..."
            sudo modprobe nvme-fabrics || echo "::warning::Failed to load nvme-fabrics module"
        else
            echo "✓ nvme-fabrics already loaded"
        fi
        
        # Load nvme-tcp (the key module for NVMe-oF over TCP)
        if ! lsmod | grep -q "^nvme_tcp"; then
            echo "Loading nvme-tcp module..."
            sudo modprobe nvme-tcp || echo "::warning::Failed to load nvme-tcp module"
        else
            echo "✓ nvme-tcp already loaded"
        fi
        
        # Verify modules are loaded
        echo "Loaded NVMe modules:"
        lsmod | grep nvme || echo "No NVMe modules found"
        
        echo "✓ NVMe kernel modules loaded"
        echo "::endgroup::"
    fi
fi

# Install QEMU and dependencies (required for QEMU provisioner)
if [ "$PROVISIONER" = "qemu" ]; then
    echo "::group::Checking KVM support"
    
    # Check for KVM support
    if [ ! -e /dev/kvm ]; then
        echo "::error::KVM is not available. QEMU provisioner requires hardware virtualization support."
        echo "If running in a VM, ensure nested virtualization is enabled."
        echo "If running on GitHub Actions, you need a self-hosted runner with KVM support."
        exit 1
    fi
    
    # Check KVM is accessible
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "KVM device exists but is not accessible. Attempting to fix permissions..."
        sudo chmod 666 /dev/kvm || {
            echo "::error::Cannot access /dev/kvm. Please ensure your user has access to KVM."
            exit 1
        }
    fi
    
    echo "✓ KVM is available and accessible"
    echo "::endgroup::"
    
    echo "::group::Configuring network for QEMU"
    # Load br_netfilter module (required for bridge networking)
    echo "Loading br_netfilter kernel module..."
    sudo modprobe br_netfilter || echo "::warning::Failed to load br_netfilter module"
    
    # Enable IP forwarding (required for QEMU bridge networking)
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
    
    # Set iptables FORWARD policy to ACCEPT (required for bridge traffic)
    echo "Configuring iptables for bridge networking..."
    sudo iptables -P FORWARD ACCEPT
    
    # Ensure bridge traffic is not filtered by iptables (can cause connectivity issues)
    if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
        sudo sysctl -w net.bridge.bridge-nf-call-iptables=0
        sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
    fi
    
    # Pre-configure NAT masquerading for the Talos network (10.5.0.0/24)
    # This is needed BEFORE cluster creation so VMs can reach external hosts
    echo "Setting up NAT masquerading for Talos network..."
    sudo iptables -t nat -A POSTROUTING -s 10.5.0.0/24 ! -d 10.5.0.0/24 -j MASQUERADE
    
    # Allow forwarding for the Talos network
    sudo iptables -A FORWARD -s 10.5.0.0/24 -j ACCEPT
    sudo iptables -A FORWARD -d 10.5.0.0/24 -j ACCEPT
    
    # Show current iptables rules for debugging
    echo "Current iptables FORWARD rules:"
    sudo iptables -L FORWARD -n -v | head -10
    echo "Current NAT rules:"
    sudo iptables -t nat -L POSTROUTING -n -v | head -5
    
    echo "✓ Network configured for QEMU"
    echo "::endgroup::"
    
    echo "::group::Installing QEMU dependencies"
    if command -v qemu-system-x86_64 &> /dev/null && command -v qemu-img &> /dev/null; then
        echo "✓ QEMU already installed"
    else
        echo "Installing QEMU and dependencies..."
        sudo apt-get update
        sudo apt-get install -y \
            qemu-system-x86 \
            qemu-utils \
            libvirt-daemon-system \
            libvirt-clients \
            ovmf \
            bridge-utils
        
        # Start libvirtd if not running
        sudo systemctl start libvirtd 2>/dev/null || true
        sudo systemctl enable libvirtd 2>/dev/null || true
        
        # Add user to required groups
        sudo usermod -aG libvirt "$USER" 2>/dev/null || true
        sudo usermod -aG kvm "$USER" 2>/dev/null || true
        
        echo "✓ QEMU and dependencies installed"
    fi
    echo "::endgroup::"
fi

# Debug: Show system resources
echo "::group::System Resources"
echo "=== CPU Info ==="
nproc
echo "=== Memory Info ==="
free -h 2>/dev/null || cat /proc/meminfo | head -5
echo "=== Disk Space ==="
df -h / | head -2
if [ "$PROVISIONER" = "docker" ]; then
    echo "=== Docker Info ==="
    docker info 2>/dev/null | grep -E "(CPUs|Total Memory|Storage Driver)" || true
elif [ "$PROVISIONER" = "qemu" ]; then
    echo "=== KVM Info ==="
    ls -la /dev/kvm 2>/dev/null || echo "/dev/kvm not found"
    echo "=== QEMU Version ==="
    qemu-system-x86_64 --version 2>/dev/null | head -1 || echo "QEMU not found"
fi
echo "::endgroup::"

# Resolve and install talosctl
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
    aarch64|arm64)
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

# Create Talos cluster
echo "::group::Creating Talos cluster"

# Build cluster create command
# Skip built-in wait - we'll handle readiness checking ourselves with better diagnostics
CLUSTER_CMD="talosctl cluster create --name $CLUSTER_NAME --wait=false --provisioner=$PROVISIONER"

# Add provisioner-specific options
if [ "$PROVISIONER" = "docker" ]; then
    # Disable IPv6 to avoid network issues in Docker
    CLUSTER_CMD+=" --docker-disable-ipv6"
elif [ "$PROVISIONER" = "qemu" ]; then
    # Add QEMU-specific options
    CLUSTER_CMD+=" --cpus $CPUS --memory $MEMORY --disk $DISK"
    
    if [ "$WITH_UEFI" = "true" ]; then
        CLUSTER_CMD+=" --with-uefi"
    fi
fi

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
if [ "$PROVISIONER" = "qemu" ]; then
    # QEMU provisioner requires root for CNI and KVM access
    # Use sudo -E to preserve environment, but talosconfig will be created in /root/.talos
    
    # Run talosctl cluster create and capture output, but don't fail immediately
    echo "Starting QEMU cluster creation (this may take several minutes)..."
    if ! sudo -E $CLUSTER_CMD; then
        echo "::warning::talosctl cluster create returned non-zero exit code"
        
        # Debug: Show network state after failure
        echo "=== Network debugging after cluster create ==="
        echo "Network interfaces:"
        ip link show
        echo ""
        echo "IP addresses:"
        ip addr show
        echo ""
        echo "Routes:"
        ip route
        echo ""
        echo "Bridge interfaces:"
        brctl show 2>/dev/null || echo "brctl not available"
        echo ""
        echo "QEMU processes:"
        ps aux | grep -E "qemu|talos" | grep -v grep || echo "No QEMU processes found"
        echo ""
        echo "Talos state directory:"
        sudo ls -la /root/.talos/clusters/ 2>/dev/null || echo "No clusters directory"
        echo ""
        echo "CNI config:"
        sudo cat /root/.talos/cni/conf.d/*.conf 2>/dev/null || echo "No CNI config found"
        echo "=== End network debugging ==="
        
        exit 1
    fi
    
    # Copy talosconfig from root's home to user's home
    echo "Copying talosconfig from root to user home..."
    sudo mkdir -p "$HOME/.talos"
    sudo cp /root/.talos/config "$HOME/.talos/config"
    sudo chown -R "$(id -u):$(id -g)" "$HOME/.talos"
else
    eval "$CLUSTER_CMD"
fi

echo "✓ Talos cluster created"
echo "::endgroup::"

# Configure networking after cluster creation (QEMU)
if [ "$PROVISIONER" = "qemu" ]; then
    echo "::group::Configuring QEMU network routing"
    
    # Find the talos bridge interface (usually named after the cluster)
    TALOS_BRIDGE=$(ip link show | grep -oE "talos[a-z0-9-]+" | head -1 || echo "")
    
    if [ -z "$TALOS_BRIDGE" ]; then
        # Try alternative: look for a bridge with 10.5.0.0/24 network
        TALOS_BRIDGE=$(ip route | grep "10.5.0.0" | awk '{print $3}' | head -1 || echo "")
    fi
    
    echo "Detected Talos bridge: ${TALOS_BRIDGE:-not found}"
    
    # Get the primary network interface (for NAT masquerading)
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    echo "Default network interface: $DEFAULT_IFACE"
    
    # Enable NAT masquerading so QEMU VMs can reach external hosts
    echo "Configuring NAT masquerading for QEMU VMs..."
    
    # Add masquerade rule for the Talos network (10.5.0.0/24)
    if ! sudo iptables -t nat -C POSTROUTING -s 10.5.0.0/24 -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s 10.5.0.0/24 -j MASQUERADE
        echo "Added MASQUERADE rule for 10.5.0.0/24"
    else
        echo "MASQUERADE rule already exists"
    fi
    
    # Ensure FORWARD chain accepts traffic from/to the Talos network
    sudo iptables -A FORWARD -s 10.5.0.0/24 -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -d 10.5.0.0/24 -j ACCEPT 2>/dev/null || true
    
    # Show routing table for debugging
    echo "Current routes:"
    ip route | grep -E "10.5.0|default" || true
    
    # Show iptables NAT rules
    echo "NAT rules:"
    sudo iptables -t nat -L POSTROUTING -n -v | head -10 || true
    
    echo "✓ QEMU network routing configured"
    echo "::endgroup::"
fi

# Debug: Show cluster status after creation
echo "::group::Cluster Status"
if [ "$PROVISIONER" = "docker" ]; then
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20
elif [ "$PROVISIONER" = "qemu" ]; then
    echo "QEMU VMs created. Checking libvirt domains..."
    sudo virsh list --all 2>/dev/null || echo "virsh not available, skipping VM list"
fi
echo "::endgroup::"

# Set config paths
TALOSCONFIG_PATH="$HOME/.talos/config"
KUBECONFIG_PATH="$HOME/.kube/config"

# Ensure kubeconfig directory exists
mkdir -p "$HOME/.kube"

echo "TALOSCONFIG_PATH: $TALOSCONFIG_PATH"

# Get the control plane node IP
# Docker uses 10.5.0.2 by default, QEMU uses 10.5.0.2 as well (talosctl default)
CP_NODE="10.5.0.2"

# Wait for Talos API and bootstrap
echo "::group::Bootstrapping cluster"
START_TIME=$(date +%s)

echo "Waiting for Talos API to be ready..."
while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
        echo "::error::Timeout waiting for Talos API"
        if [ "$PROVISIONER" = "docker" ]; then
            docker ps -a
        elif [ "$PROVISIONER" = "qemu" ]; then
            sudo virsh list --all 2>/dev/null || true
        fi
        exit 1
    fi
    
    if talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" version &>/dev/null; then
        echo "✓ Talos API is responding"
        break
    fi
    echo "Waiting for Talos API... (${ELAPSED}s)"
    sleep 3
done

echo "Bootstrapping etcd..."
# Bootstrap might fail if already bootstrapped, that's OK
if talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" bootstrap 2>&1; then
    echo "✓ Bootstrap initiated"
else
    echo "Bootstrap command returned non-zero (may already be bootstrapped)"
fi

echo "Waiting for etcd to be healthy..."
while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
        echo "::error::Timeout waiting for etcd"
        talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" services || true
        exit 1
    fi
    
    if talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" service etcd 2>&1 | grep -q "STATE.*Running"; then
        echo "✓ etcd is running"
        break
    fi
    echo "Waiting for etcd... (${ELAPSED}s)"
    sleep 3
done
echo "::endgroup::"

# Get kubeconfig
echo "::group::Configuring kubectl"
echo "Waiting for Kubernetes API to be available..."
while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
        echo "::error::Timeout waiting for Kubernetes API"
        talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" services || true
        exit 1
    fi
    
    if talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" kubeconfig "$KUBECONFIG_PATH" --force 2>/dev/null; then
        echo "✓ Kubeconfig retrieved"
        break
    fi
    echo "Waiting for kubeconfig... (${ELAPSED}s)"
    sleep 3
done

# Set outputs
echo "talosconfig=$TALOSCONFIG_PATH" >> "$GITHUB_OUTPUT"
echo "kubeconfig=$KUBECONFIG_PATH" >> "$GITHUB_OUTPUT"
echo "TALOSCONFIG=$TALOSCONFIG_PATH" >> "$GITHUB_ENV"
echo "KUBECONFIG=$KUBECONFIG_PATH" >> "$GITHUB_ENV"

echo "TALOSCONFIG exported: $TALOSCONFIG_PATH"
echo "KUBECONFIG exported: $KUBECONFIG_PATH"
echo "::endgroup::"

# Wait for cluster ready if requested
if [ "$WAIT_FOR_READY" = "true" ]; then
    echo "::group::Waiting for cluster ready"
    echo "Waiting for Kubernetes cluster to be fully ready (timeout: ${TIMEOUT}s)..."
    
    LAST_STATUS_TIME=0
    
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        
        if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
            echo "::error::Timeout waiting for cluster to be ready"
            echo ""
            echo "=== Diagnostic Information ==="
            echo "--- Talos cluster health ---"
            talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" health --wait-timeout=10s 2>&1 || true
            echo ""
            echo "--- Talos services ---"
            talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" services 2>&1 || true
            echo ""
            if [ "$PROVISIONER" = "docker" ]; then
                echo "--- Docker containers ---"
                docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>&1 || true
            elif [ "$PROVISIONER" = "qemu" ]; then
                echo "--- QEMU VMs ---"
                sudo virsh list --all 2>&1 || true
            fi
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
            echo "--- CoreDNS logs ---"
            for pod in $(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system -l k8s-app=kube-dns -o name 2>/dev/null); do
                echo "Logs for $pod:"
                kubectl --kubeconfig "$KUBECONFIG_PATH" logs -n kube-system "$pod" --tail=50 2>&1 || true
            done
            echo ""
            echo "--- Flannel pod details ---"
            kubectl --kubeconfig "$KUBECONFIG_PATH" describe pods -n kube-system -l app=flannel 2>&1 | tail -100 || true
            echo ""
            echo "--- Flannel logs (current) ---"
            for pod in $(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system -l app=flannel -o name 2>/dev/null); do
                echo "Logs for $pod:"
                kubectl --kubeconfig "$KUBECONFIG_PATH" logs -n kube-system "$pod" --all-containers --tail=50 2>&1 || true
            done
            echo ""
            echo "--- Flannel logs (previous) ---"
            for pod in $(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system -l app=flannel -o name 2>/dev/null); do
                echo "Previous logs for $pod:"
                kubectl --kubeconfig "$KUBECONFIG_PATH" logs -n kube-system "$pod" --all-containers --previous --tail=50 2>&1 || true
            done
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
            echo "Talos services:"
            talosctl --talosconfig "$TALOSCONFIG_PATH" --nodes "$CP_NODE" services 2>/dev/null | grep -E "SERVICE|etcd|kubelet|apid" || echo "  (not available)"
            echo "Nodes:"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null || echo "  (not available yet)"
            echo "Pods in kube-system:"
            kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system --no-headers 2>/dev/null | head -10 || echo "  (not available yet)"
            echo ""
        fi
        
        # Check if kubectl can connect
        if kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers &>/dev/null; then
            # Check if any node is Ready (use word boundary matching)
            NODES_OUTPUT=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null)
            if echo "$NODES_OUTPUT" | grep -qE '\bReady\b'; then
                # Check for CoreDNS pods existing (not necessarily ready yet)
                COREDNS_STATUS=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null || echo "")
                
                if echo "$COREDNS_STATUS" | grep -q "Running"; then
                    # Check if CoreDNS is actually ready (all containers ready)
                    COREDNS_READY=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
                    
                    if echo "$COREDNS_READY" | grep -q "True"; then
                        echo "✓ CoreDNS is running and ready"
                        
                        # Check for no critical pods failing (match Error or CrashLoopBackOff as whole words in status)
                        PODS_OUTPUT=$(kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -n kube-system --no-headers 2>/dev/null)
                        # Use grep -c to count matches; grep -c returns 0 (with exit code 1) when no matches
                        CRITICAL_FAILING=$(echo "$PODS_OUTPUT" | grep -cE '\b(Error|CrashLoopBackOff)\b' || true)
                        # Trim whitespace/newlines and default to 0
                        CRITICAL_FAILING=$(echo "$CRITICAL_FAILING" | tr -d '[:space:]')
                        CRITICAL_FAILING="${CRITICAL_FAILING:-0}"
                        
                        if [ "$CRITICAL_FAILING" = "0" ]; then
                            echo "✓ No critical pods failing"
                            
                            # Verify all expected nodes are ready
                            EXPECTED_NODES=$((NODES + 1))  # workers + control plane
                            READY_NODES=$(echo "$NODES_OUTPUT" | grep -cE '\bReady\b' || echo "0")
                            
                            if [ "$READY_NODES" -ge "$EXPECTED_NODES" ]; then
                                echo "✓ All $EXPECTED_NODES nodes are ready"
                                
                                # Show cluster info
                                echo ""
                                echo "=== Cluster Information ==="
                                kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
                                kubectl --kubeconfig "$KUBECONFIG_PATH" get pods -A
                                
                echo "✓ Talos cluster is fully ready!"
                                echo "::endgroup::"
                                break
                            else
                                echo "Waiting for all nodes to be ready ($READY_NODES/$EXPECTED_NODES ready)..."
                            fi
                        else
                            echo "DEBUG: Critical failing check failed: CRITICAL_FAILING='$CRITICAL_FAILING'"
                        fi
                    else
                        echo "CoreDNS pods exist but not ready yet (COREDNS_READY='$COREDNS_READY')..."
                    fi
                elif [ -n "$COREDNS_STATUS" ]; then
                    echo "CoreDNS status: $(echo "$COREDNS_STATUS" | awk '{print $3}' | head -1)"
                else
                    echo "DEBUG: No CoreDNS pods found yet"
                fi
            else
                echo "DEBUG: No nodes with Ready status found"
            fi
        else
            echo "DEBUG: kubectl get nodes failed"
        fi
        
        echo "Cluster not ready yet, waiting... (${ELAPSED}/${TIMEOUT}s)"
        sleep 5
    done
fi

# DNS readiness check (if requested)
if [ "$DNS_READINESS" = "true" ]; then
  echo "::group::Testing DNS readiness"
  echo "Verifying CoreDNS and DNS resolution..."
  
  # Wait for CoreDNS pods to be ready
  echo "Waiting for CoreDNS to be ready..."
  kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=ready --timeout=120s pod -l k8s-app=kube-dns -n kube-system
  echo "✓ CoreDNS is ready"
  
  # Create a test pod and verify DNS resolution
  kubectl --kubeconfig "$KUBECONFIG_PATH" run dns-test --image=public.ecr.aws/docker/library/busybox:stable --restart=Never -- sleep 300
  kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=ready --timeout=60s pod/dns-test
  
  if kubectl --kubeconfig "$KUBECONFIG_PATH" exec dns-test -- nslookup kubernetes.default.svc.cluster.local; then
    echo "✓ DNS resolution is working"
  else
    echo "::error::DNS resolution failed"
    kubectl --kubeconfig "$KUBECONFIG_PATH" delete pod dns-test --ignore-not-found
    exit 1
  fi
  
  # Cleanup test pod
  kubectl --kubeconfig "$KUBECONFIG_PATH" delete pod dns-test --ignore-not-found
  echo "::endgroup::"
fi

echo "✓ Talos setup completed successfully!"