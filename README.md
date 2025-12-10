# Setup Talos Action

A GitHub Action for installing and configuring [Talos Linux](https://www.talos.dev/) - a modern, secure, immutable, and minimal Linux OS designed specifically for running Kubernetes. Perfect for CI/CD pipelines, testing, and development workflows.

## Features

- ✅ Automatic installation of talosctl CLI
- ✅ Creates local Talos cluster using Docker
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
| `talosctl-args` | Additional arguments to pass to `talosctl cluster create` | `""` |
| `wait-for-ready` | Wait for cluster to be ready before completing | `true` |
| `timeout` | Timeout in seconds to wait for cluster readiness | `300` |

## Outputs

| Output | Description |
|--------|-------------|
| `kubeconfig` | Path to the kubeconfig file (`~/.kube/config`) |
| `talosconfig` | Path to the talosconfig file (`~/.talos/config`) |

## Examples

### Basic Setup (Single Node)

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
1. Installs Docker (if not already available)
2. Downloads and installs the `talosctl` CLI tool
3. Creates a local Talos cluster using Docker containers
4. Waits for the cluster to become fully ready
5. Exports both kubeconfig and talosconfig paths for use in subsequent steps

**No cleanup needed** - GitHub Actions runners are ephemeral and destroyed after each workflow run, so there's no need to restore system state.

## Requirements

- Runs on `ubuntu-latest` (or any Linux-based runner)
- Requires `sudo` access (provided by default in GitHub Actions)
- Docker is automatically installed if not present

## Troubleshooting

### Cluster Takes Too Long to Start

If the cluster doesn't become ready in time, increase the timeout:

```yaml
- name: Setup Talos
  uses: fenio/setup-talos@v1
  with:
    timeout: '600'  # 10 minutes
```

### Need More Verbose Output

Check the GitHub Actions logs. The script uses `::group::` annotations for collapsible sections.

### Testing Locally

To test locally on a Linux VM with Docker:

```bash
export INPUT_VERSION="latest"
export INPUT_CLUSTER_NAME="talos-ci"
export INPUT_KUBERNETES_VERSION=""
export INPUT_NODES="0"
export INPUT_TALOSCTL_ARGS=""
export INPUT_WAIT_FOR_READY="true"
export INPUT_TIMEOUT="300"
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
