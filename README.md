# Bevel Fabric Network - Automated Setup Scripts

Three different script architectures to deploy a multi-cluster Hyperledger Fabric network across 3 PCs using Bevel.

## Quick Comparison

| Feature | 1-per-pc-setup.sh | 2-controller-setup.sh | 3-hybrid-setup.sh |
|---------|-------------------|----------------------|-------------------|
| **Where it runs** | Each PC independently | One controller PC only | Infra: each PC / Deploy: controller |
| **SSH required** | No | Yes (to all 3 PCs) | Only for kubeconfig fetch |
| **Sync between PCs** | Manual prompts + auto-check | Automatic (sequential SSH) | Manual prompts for infra, auto for deploy |
| **Complexity** | Simple | Medium | Medium |
| **Parallelism** | Can run on all PCs simultaneously | Sequential per PC | Infra in parallel, deploy sequential |
| **Best for** | Small teams, learning | Single admin managing all | Production teams |
| **Resume support** | Yes (`--resume`) | Yes (`--resume`) | Yes (`--resume`) |
| **Consensus choice** | Raft / BFT | Raft / BFT | Raft / BFT |

## Setup Overview

```
PC1 (Orderer Org)          PC2 (Peer Org1)           PC3 (Peer Org2)
├── CA                     ├── CA                     ├── CA
├── Orderer1               ├── Peer0                  ├── Peer0
├── Orderer2               ├── CouchDB                ├── CouchDB
├── Orderer3               └── HAProxy                └── HAProxy
└── HAProxy

         All connected via HAProxy TLS passthrough on port 443
         One PC acts as Ansible controller for Bevel deployment
```

---

## Script 1: Per-PC Setup (`1-per-pc-setup.sh`)

Run this script on **each PC separately**. It asks what role the PC plays and handles everything locally.

### How to run

**On PC1 (Orderer):**
```bash
cd scripts/
chmod +x 1-per-pc-setup.sh
./1-per-pc-setup.sh
# Select: Orderer Org (PC1)
# Enter IPs of PC2 and PC3
# Select consensus: Raft or BFT
# Follow prompts...
```

**On PC2 (Org1) - can run simultaneously:**
```bash
./1-per-pc-setup.sh
# Select: Peer Org1 (PC2)
# Enter IPs of PC1 and PC3
```

**On PC3 (Org2) - can run simultaneously:**
```bash
./1-per-pc-setup.sh
# Select: Peer Org2 (PC3)
# Enter IPs of PC1 and PC2
```

The script will:
1. Install all prerequisites locally
2. Configure firewall, DNS, HAProxy, Vault
3. Pause and wait for other PCs at sync points
4. Ask if this PC is the controller
5. If controller: run Ansible, generate network.yaml, deploy Bevel, setup monitoring

### Resume after interruption
```bash
./1-per-pc-setup.sh --resume
```

### Tear down
```bash
./1-per-pc-setup.sh --reset
```

---

## Script 2: Controller Setup (`2-controller-setup.sh`)

Run this on **one controller PC only**. It SSHes into all 3 PCs to manage everything.

### Prerequisites
SSH key-based auth must work to all 3 PCs:
```bash
# From the controller, set up SSH keys:
ssh-keygen -t ed25519  # if you don't have a key
ssh-copy-id user@PC1_IP
ssh-copy-id user@PC2_IP
ssh-copy-id user@PC3_IP

# Test:
ssh user@PC1_IP "echo ok"
ssh user@PC2_IP "echo ok"
ssh user@PC3_IP "echo ok"
```

### How to run
```bash
cd scripts/
chmod +x 2-controller-setup.sh
./2-controller-setup.sh
# Enter IPs of all 3 PCs
# Enter SSH usernames
# Select controller role (which PC is the controller, or 4th machine)
# Select consensus: Raft or BFT
# Follow prompts...
```

It handles everything automatically:
1. SSHes into each PC to install Docker, K3s, Vault
2. Configures firewall and DNS on all PCs remotely
3. Collects kubeconfigs
4. Installs HAProxy on all clusters
5. Sets up GitOps, generates network.yaml
6. Runs Bevel Ansible playbooks
7. Sets up monitoring

### Resume / Reset
```bash
./2-controller-setup.sh --resume
./2-controller-setup.sh --reset
```

---

## Script 3: Hybrid Setup (`3-hybrid-setup.sh`)

Two-phase approach: local infra setup + centralized deployment.

### Phase A: Infrastructure (on each PC)
```bash
cd scripts/
chmod +x 3-hybrid-setup.sh

# Run on ALL 3 PCs (can run in parallel):
./3-hybrid-setup.sh infra
# Select role, enter IPs, select consensus
# Installs: Docker, K3s, firewall, DNS, HAProxy, Vault
```

### Phase B: Deployment (on controller only)
After all 3 PCs complete Phase A:
```bash
# On the controller PC:
./3-hybrid-setup.sh deploy
# Collects kubeconfigs, sets up GitOps
# Generates network.yaml
# Runs Ansible playbooks
# Deploys monitoring
```

### Health check (anytime)
```bash
./3-hybrid-setup.sh health
```

### Tear down
```bash
./3-hybrid-setup.sh reset
```

---

## What Each Script Asks For

During setup, you'll be prompted for:

| Input | When | Example |
|-------|------|---------|
| PC role | Start | Orderer / Org1 / Org2 |
| Consensus | Start | Raft (Fabric 2.5.4) or BFT (Fabric 3.x) |
| IP addresses | Start | 192.168.1.101, .102, .103 |
| Domain suffixes | DNS phase | pc1.example.com, pc2.example.com, pc3.example.com |
| Firewall mode | Firewall phase | Open ports / Restrictive |
| Vault mode | Vault phase | Dev (in-memory) / Production |
| Vault tokens | Vault phase | roottoken-orderer |
| GitHub username | GitOps phase | your-username |
| GitHub PAT | GitOps phase | ghp_xxxxxxxxxxxx |
| Git repo name | GitOps phase | bevel |
| SSH key path | GitOps phase | ~/.ssh/gitops |
| Docker credentials | GitOps phase | For pulling Fabric images |
| Channel name | network.yaml phase | mychannel |
| Cloud provider | network.yaml phase | minikube / aws |
| Grafana passwords | Monitoring phase | Per-org admin passwords |

## State & Config

All scripts store their state in `~/.bevel-setup/`:
- `config.env` - All collected configuration values
- `state/` - Phase completion markers (for resume)
- `setup.log` - Full execution log
- `network.yaml` - Generated network configuration
- `vault.log` - Vault server log (dev mode)

## File Structure

```
scripts/
├── lib/
│   ├── common.sh           # Logging, UI, config, checklist
│   ├── prerequisites.sh    # Docker, K3s, Helm, Vault, etc.
│   ├── firewall.sh         # UFW configuration
│   ├── dns.sh              # /etc/hosts + CoreDNS
│   ├── haproxy.sh          # HAProxy Ingress Controller
│   ├── vault-setup.sh      # Vault install & configure
│   ├── kubeconfig.sh       # Kubeconfig export & management
│   ├── gitops.sh           # Git repo, SSH keys, GitHub
│   ├── network-yaml.sh     # Generate network.yaml
│   ├── bevel-deploy.sh     # Ansible playbook execution
│   ├── monitoring.sh       # Prometheus + Grafana
│   ├── verify.sh           # Health checks & verification
│   └── sync.sh             # Cross-PC synchronization
├── 1-per-pc-setup.sh       # Architecture 1
├── 2-controller-setup.sh   # Architecture 2
├── 3-hybrid-setup.sh       # Architecture 3
└── README.md               # This file
```
