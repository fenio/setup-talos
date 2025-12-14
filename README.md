# Setup Talos Action

A GitHub Action for installing and configuring [Talos Linux](https://www.talos.dev/) - a modern, secure, immutable, and minimal Linux OS designed specifically for running Kubernetes. Perfect for CI/CD pipelines, testing, and development workflows.

## Features

- ✅ Automatic installation of talosctl CLI
- ✅ Creates local Talos cluster using Docker or QEMU
- ✅ Configurable number of worker nodes
- ✅ Supports custom Kubernetes versions
- ✅ Waits for cluster readiness
- ✅ Outputs both kubeconfig and talosconfig paths
- ✅ No cleanup required - designed for ephemeral GitHub Actions runners

## Quick Start

```yaml
name: Test with Talos

on: [push]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Talos
        id: talos
        uses: fenio/setup-talos@v1
        with:
          version: 'latest'
          nodes: '1'
      
      - name: Deploy and test
        env:
          KUBECONFIG: ${{ steps.talos.outputs.kubeconfig }}
        run: |
          kubectl apply -f k8s/
          kubectl wait --for=condition=available --timeout=60s deployment/my-app
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `version` | Talos version to install (e.g., `v1.8.0`) or `latest` | `latest` |
| `cluster-name` | Name of the Talos cluster | `talos-ci` |
| `kubernetes-version` | Kubernetes version to use (e.g., `v1.31.1`) | _(Talos default)_ |
| `nodes` | Number of worker nodes (in addition to control plane) | `0` |
| `provisioner` | Provisioner to use (`docker` or `qemu`) | `docker` |
| `cpus` | Number of CPUs per node (QEMU only) | `2` |
| `memory` | Memory per node in MB (QEMU only) | `2048` |
| `disk` | Disk size in MB (QEMU only) | `6144` |
| `with-uefi` | Use UEFI boot instead of BIOS (QEMU only) | `true` |
| `talosctl-args` | Additional arguments to pass to `talosctl cluster create` | `""` |
| `wait-for-ready` | Wait for cluster to be ready before completing | `true` |
| `timeout` | Timeout in seconds to wait for cluster readiness | `300` |
| `dns-readiness` | Wait for CoreDNS to be ready and verify DNS resolution works | `true` |

## Outputs

| Output | Description |
|--------|-------------|
| `kubeconfig` | Path to the kubeconfig file (`~/.kube/config`) |
| `talosconfig` | Path to the talosconfig file (`~/.talos/config`) |

## Provisioners

### Docker (Default)

The Docker provisioner runs Talos nodes as Docker containers. This is the default and recommended option for most CI/CD environments.

**Advantages:**
- Works on standard GitHub Actions runners (`ubuntu-latest`)
- Fast startup times
- Lower resource requirements
- No special hardware requirements

**Requirements:**
- Docker (automatically installed if not present)

### QEMU

The QEMU provisioner runs Talos nodes as full virtual machines using QEMU/KVM. This provides a more realistic environment closer to bare-metal installations.

**Advantages:**
- More realistic testing environment
- Full VM isolation
- Better for testing hardware-related features
- Supports UEFI boot

**Requirements:**
- KVM hardware virtualization support
- Self-hosted runner with nested virtualization enabled (standard GitHub Actions runners do NOT support this)
- QEMU and libvirt (automatically installed if not present)

## Examples

### Basic Setup (Single Node with Docker)

```yaml
- name: Setup Talos
  uses: fenio/setup-talos@v1
```

### Multi-Node Cluster

```yaml
- name: Setup Talos with 2 workers
  id: talos
  uses: fenio/setup-talos@v1
  with:
    nodes: '2'
    cluster-name: 'my-test-cluster'
```

### Specific Versions

```yaml
- name: Setup Talos with specific versions
  uses: fenio/setup-talos@v1
  with:
    version: 'v1.8.0'
    kubernetes-version: 'v1.31.1'
```

### QEMU Provisioner (Self-Hosted Runner)

```yaml
- name: Setup Talos with QEMU
  uses: fenio/setup-talos@v1
  with:
    provisioner: 'qemu'
    nodes: '1'
    cpus: '4'
    memory: '4096'
    disk: '10240'
    with-uefi: 'true'
```

### QEMU with Custom Resources

```yaml
- name: Setup Talos with QEMU (custom resources)
  uses: fenio/setup-talos@v1
  with:
    provisioner: 'qemu'
    nodes: '2'
    cpus: '2'
    memory: '2048'
    disk: '8192'
    with-uefi: 'true'
    timeout: '600'  # QEMU may need more time to boot
```

### Using Talos API

```yaml
- name: Setup Talos
  id: talos
  uses: fenio/setup-talos@v1

- name: Query cluster via Talos API
  env:
    TALOSCONFIG: ${{ steps.talos.outputs.talosconfig }}
  run: |
    talosctl --nodes 127.0.0.1 version
    talosctl --nodes 127.0.0.1 health
    talosctl --nodes 127.0.0.1 get services
```

## How It Works

This action runs a bash script that:

### Docker Provisioner
1. Installs Docker (if not already available)
2. Downloads and installs the `talosctl` CLI tool
3. Creates a local Talos cluster using Docker containers
4. Waits for the cluster to become fully ready
5. Exports both kubeconfig and talosconfig paths for use in subsequent steps

### QEMU Provisioner
1. Checks for KVM support and accessibility
2. Installs QEMU, libvirt, and OVMF (for UEFI) if not present
3. Downloads and installs the `talosctl` CLI tool
4. Creates a local Talos cluster using QEMU virtual machines
5. Waits for the cluster to become fully ready
6. Exports both kubeconfig and talosconfig paths for use in subsequent steps

**No cleanup needed** - GitHub Actions runners are ephemeral and destroyed after each workflow run, so there's no need to restore system state.

## Requirements

### Docker Provisioner (Default)
- Runs on `ubuntu-latest` (or any Linux-based runner)
- Requires `sudo` access (provided by default in GitHub Actions)
- Docker is automatically installed if not present

### QEMU Provisioner
- Requires a **self-hosted runner** with KVM support
- Standard GitHub Actions runners do NOT support nested virtualization
- Requires `sudo` access
- QEMU and dependencies are automatically installed if not present
- Minimum recommended resources:
  - 4+ CPU cores
  - 8+ GB RAM
  - 20+ GB disk space

## Setting Up a Self-Hosted Runner for QEMU

To use the QEMU provisioner, you need a self-hosted runner with KVM support:

1. **On a bare-metal Linux machine or VM with nested virtualization:**
   ```bash
   # Check if KVM is available
   ls -la /dev/kvm
   
   # If not accessible, add your user to the kvm group
   sudo usermod -aG kvm $USER
   ```

2. **For cloud VMs, enable nested virtualization:**
   - **GCP**: Use `--enable-nested-virtualization` flag
   - **AWS**: Use bare-metal instances (`.metal` instance types)
   - **Azure**: Use Dv3/Ev3 series with nested virtualization

3. **Install the GitHub Actions runner** following the [official documentation](https://docs.github.com/en/actions/hosting-your-own-runners)

## Troubleshooting

### Cluster Takes Too Long to Start

If the cluster doesn't become ready in time, increase the timeout:

```yaml
- name: Setup Talos
  uses: fenio/setup-talos@v1
  with:
    timeout: '600'  # 10 minutes
```

### QEMU: KVM Not Available

If you see "KVM is not available" error:
- Ensure you're using a self-hosted runner with KVM support
- Check that `/dev/kvm` exists and is accessible
- For VMs, verify nested virtualization is enabled

### QEMU: Permission Denied on /dev/kvm

```bash
# Add your user to the kvm group
sudo usermod -aG kvm $USER

# Or temporarily fix permissions
sudo chmod 666 /dev/kvm
```

### Need More Verbose Output

Check the GitHub Actions logs. The script uses `::group::` annotations for collapsible sections.

### Testing Locally

To test locally on a Linux machine:

**Docker provisioner:**
```bash
export INPUT_VERSION="latest"
export INPUT_CLUSTER_NAME="talos-ci"
export INPUT_KUBERNETES_VERSION=""
export INPUT_NODES="0"
export INPUT_PROVISIONER="docker"
export INPUT_TALOSCTL_ARGS=""
export INPUT_WAIT_FOR_READY="true"
export INPUT_TIMEOUT="300"
export INPUT_DNS_READINESS="true"
export GITHUB_ENV=/tmp/github_env
export GITHUB_OUTPUT=/tmp/github_output

bash setup.sh
```

**QEMU provisioner:**
```bash
export INPUT_VERSION="latest"
export INPUT_CLUSTER_NAME="talos-ci"
export INPUT_KUBERNETES_VERSION=""
export INPUT_NODES="1"
export INPUT_PROVISIONER="qemu"
export INPUT_CPUS="2"
export INPUT_MEMORY="2048"
export INPUT_DISK="6144"
export INPUT_WITH_UEFI="true"
export INPUT_TALOSCTL_ARGS=""
export INPUT_WAIT_FOR_READY="true"
export INPUT_TIMEOUT="600"
export INPUT_DNS_READINESS="true"
export GITHUB_ENV=/tmp/github_env
export GITHUB_OUTPUT=/tmp/github_output

bash setup.sh
```

## Why Talos?

Talos Linux offers several advantages for CI/CD environments:

- **Immutable**: No SSH, no shell - reduces attack surface
- **Minimal**: Small footprint, fast startup times
- **API-driven**: Everything is managed via API (talosctl)
- **Secure by default**: All system APIs use mutual TLS
- **Perfect for testing**: Quick cluster creation and destruction

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Related Projects

- [Talos Linux](https://www.talos.dev/) - Secure Kubernetes OS
- [setup-k3s](https://github.com/fenio/setup-k3s) - Lightweight Kubernetes
- [setup-k0s](https://github.com/fenio/setup-k0s) - Zero Friction Kubernetes
- [setup-kubesolo](https://github.com/fenio/setup-kubesolo) - Ultra-lightweight Kubernetes