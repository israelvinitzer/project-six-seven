# Airis Labs – GCP K3s PostgreSQL Infrastructure

## Overview

This project provisions a small GCP environment for running PostgreSQL on K3s using CloudNativePG (CNPG).

The main goals are:

- Provision the GCP infrastructure using Terraform.
- Keep the K3s VM private, with no external IP.
- Use a Bastion host as the approved entry point.
- Allow the private K3s VM outbound Internet access through Cloud NAT.
- Deploy PostgreSQL using CloudNativePG.
- Expose PostgreSQL only through the approved private network path.
- Validate database connectivity from the Bastion using Python.
- Keep the design simple for the exercise while documenting production considerations and future improvements.

---

## Architecture

```text
                         Internet
                            |
                            | SSH
                            v
                  +-------------------+
                  |     Bastion VM    |
                  |   External IP     |
                  |   10.0.0.10       |
                  +-------------------+
                       |          |
                 SSH/22|          |TCP/30432
                       |          |
                       v          v
                  +-------------------+
                  |      K3s VM       |
                  |   10.0.0.20       |
                  | No External IP    |
                  +-------------------+
                            |
                            |
                      Kubernetes
                            |
                  +-------------------+
                  | CloudNativePG     |
                  | PostgreSQL        |
                  | Persistent PVC    |
                  +-------------------+

K3s outbound Internet access
            |
            v
     Cloud NAT / Router
            |
            v
         Internet
```

Both VMs currently reside in the same private subnet.

Network access is controlled using GCP firewall rules. The Bastion is allowed to reach only the required services on the K3s VM.

For this small exercise, a single subnet keeps the architecture simple. In a larger production environment, I would consider separate subnets and security boundaries for Bastion/public-facing components and private workloads.

---

## Prerequisites

The machine running Terraform should have:

- Git
- Terraform
- Google Cloud CLI (`gcloud`)
- SSH client

Authenticate to GCP before starting:

```bash
gcloud auth login
gcloud auth application-default login
```

Verify the active project:

```bash
gcloud config get-value project
```

---

## 1. Provision the Infrastructure

Go to the Terraform directory:

```bash
cd terraform
```

Initialize Terraform:

```bash
terraform init
```

Review the proposed infrastructure changes:

```bash
terraform plan
```

Provision the environment:

```bash
terraform apply
```

Do not run `terraform apply` without reviewing the plan first.

Terraform provisions the required GCP infrastructure, including:

- VPC
- Subnet
- Bastion VM
- Private K3s VM
- Firewall rules
- Cloud Router
- Cloud NAT

The K3s VM intentionally has no public IP.

---

## 2. Verify the Infrastructure

After Terraform completes, verify the VM addresses.

The expected design is similar to:

```text
Bastion
Private IP:  10.0.0.10
External IP: Assigned

K3s
Private IP:  10.0.0.20
External IP: None
```

The Bastion is the trusted entry point into the environment.

---

## 3. Connect to the K3s VM

Connect first to the Bastion:

```bash
ssh <user>@<BASTION_PUBLIC_IP>
```

From the Bastion, connect to K3s:

```bash
ssh <user>@10.0.0.20
```

Alternatively, SSH ProxyJump can be used from the local machine:

```bash
ssh -J <user>@<BASTION_PUBLIC_IP> <user>@10.0.0.20
```

The K3s VM is never accessed directly from the Internet.

---

## 4. Install K3s

On the K3s VM:

```bash
curl -sfL https://get.k3s.io | sh -
```

Verify the service:

```bash
sudo systemctl status k3s
```

Verify the node:

```bash
sudo k3s kubectl get nodes
```

Expected result:

```text
STATUS: Ready
```

Configure `kubectl` access as required for the current user.

Verify:

```bash
kubectl get nodes
```

---

## 5. Install Helm

Install Helm on the K3s VM:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify:

```bash
helm version
```

---

## 6. Install CloudNativePG

Add the CloudNativePG Helm repository:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
```

Install the operator:

```bash
helm install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg
```

Verify that the operator is running:

```bash
kubectl get pods -n cnpg-system
```

Wait until the CNPG Operator is `Running` and `Ready` before deploying PostgreSQL.

---

## 7. Deploy PostgreSQL

Apply the PostgreSQL cluster manifest:

```bash
kubectl apply -f kubernetes/postgres-cluster.yaml
```

Verify:

```bash
kubectl get clusters -n cnpg-system
```

Check the PostgreSQL pods:

```bash
kubectl get pods -n cnpg-system
```

Check persistent storage:

```bash
kubectl get pvc -n cnpg-system
```

The current `1Gi` storage size is intended for the exercise only.

Production sizing should be based on workload requirements such as:

- Current database size
- Expected growth
- WAL generation
- Retention requirements
- Index size
- Read/write workload
- IOPS and throughput
- Required storage headroom

---

## 8. Expose PostgreSQL Through the Approved Path

Apply the NodePort service:

```bash
kubectl apply -f kubernetes/postgres-nodeport.yaml
```

Verify:

```bash
kubectl get svc -n cnpg-system
```

PostgreSQL is reachable through:

```text
10.0.0.20:30432
```

This is the **private IP** of the K3s VM.

The GCP firewall allows TCP port `30432` only from the Bastion private IP:

```text
10.0.0.10/32
```

PostgreSQL is therefore not intentionally exposed directly to the Internet.

---

## 9. Prepare the Bastion for Validation

Connect to the Bastion:

```bash
ssh <user>@<BASTION_PUBLIC_IP>
```

Install the required packages:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip telnet
```

Create a Python virtual environment:

```bash
python3 -m venv venv
source venv/bin/activate
```

Install the PostgreSQL Python driver required by the validation script:

```bash
pip install psycopg[binary]
```

---

## 10. Validate Network Connectivity

From the Bastion, test that the PostgreSQL NodePort is reachable:

```bash
telnet 10.0.0.20 30432
```

This verifies the basic TCP network path:

```text
Bastion
   |
   | TCP/30432
   v
K3s private IP
   |
   v
PostgreSQL
```

The same port should not be publicly exposed through the K3s VM because the VM has no external IP.

---

## 11. Validate PostgreSQL with Python

Run the validation script from the Bastion:

```bash
python validate_db.py
```

The script connects to PostgreSQL and executes:

```sql
SELECT 1;
```

A successful result proves:

- Network connectivity from the Bastion
- PostgreSQL is accepting connections
- Authentication works
- Basic SQL query execution works

It does **not** prove:

- Database performance
- High availability
- Replication health
- Application schema correctness
- Storage capacity
- Production readiness

---

## 12. Troubleshooting

### Kubernetes

Check pods:

```bash
kubectl get pods -A
```

Inspect a failing pod:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Check logs:

```bash
kubectl logs <pod-name> -n <namespace>
```

For a restarting container:

```bash
kubectl logs <pod-name> -n <namespace> --previous
```

Check recent Kubernetes events:

```bash
kubectl get events -A --sort-by=.lastTimestamp
```

### CloudNativePG

Check the PostgreSQL cluster:

```bash
kubectl get cluster -n cnpg-system
```

Check the CNPG Operator:

```bash
kubectl get pods -n cnpg-system
```

If the CNPG Operator fails while PostgreSQL is already running, the database may continue serving traffic, but CNPG reconciliation, lifecycle management, and automated recovery capabilities are degraded.

### OOMKilled

If a container reports `OOMKilled`, check:

- Memory requests
- Memory limits
- Actual memory usage
- Node memory pressure
- PostgreSQL workload/configuration

Do not increase memory blindly before understanding the cause.

---

## 13. Destroy the Environment

Before destroying anything, review what Terraform manages:

```bash
terraform plan
```

Destroy the GCP infrastructure:

```bash
terraform destroy
```

Review the destroy plan carefully before confirming.

---

## Current Limitations

This implementation intentionally keeps the exercise small.

Current limitations include:

- Single K3s node
- Single infrastructure failure domain
- No infrastructure-level HA
- PostgreSQL storage depends on the current single-node design
- Manual K3s bootstrap
- Manual Helm installation
- Manual CNPG deployment
- Manual Bastion preparation
- No automated external database backup
- Terraform state currently needs a production-grade remote backend strategy

Setting multiple PostgreSQL instances on the same single K3s node would **not** provide infrastructure HA because a failure of that VM would affect all instances.

---

## Production Improvements

For a production environment I would consider:

- Multiple Kubernetes nodes
- Multiple failure domains/zones
- CNPG PostgreSQL replication and failover
- External database backups
- Backup retention policies
- Regular restore testing
- Remote Terraform state
- Strict IAM for Terraform state
- Separate network/security tiers where appropriate
- Secret Manager or another dedicated secret-management mechanism
- Monitoring and alerting
- Resource requests and limits based on measured workload
- Automated bootstrap/configuration management

---

## Automation – Next Step

The current README documents the complete deployment procedure so the environment can be reproduced without relying on undocumented manual knowledge.

The next step is to automate the remaining configuration.

Target workflow:

```text
./up.sh
   |
   +-- terraform init/apply
   |
   +-- wait for infrastructure
   |
   +-- bootstrap K3s
   |     +-- install K3s
   |     +-- install Helm
   |     +-- install CNPG
   |     +-- deploy PostgreSQL
   |     +-- deploy NodePort
   |
   +-- bootstrap Bastion
   |     +-- install Python
   |     +-- create venv
   |     +-- install psycopg
   |
   +-- verify
         +-- Kubernetes Ready
         +-- CNPG Ready
         +-- PostgreSQL Ready
         +-- SELECT 1 succeeds
```

Teardown:

```bash
./down.sh
```

The goal is for the repository to become fully reproducible:

```bash
git clone <repository>
cd <repository>
./up.sh
```

and rebuild the complete environment from scratch.

---

## Repository Structure

Target repository structure:

```text
.
├── README.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── ...
│
├── kubernetes/
│   ├── postgres-cluster.yaml
│   └── postgres-nodeport.yaml
│
├── scripts/
│   ├── bootstrap-k3s.sh
│   ├── bootstrap-bastion.sh
│   └── verify.sh
│
├── validate_db.py
├── up.sh
└── down.sh
```

---

## Security Notes

The Bastion is a high-trust component.

If compromised, an attacker may attempt to access services explicitly permitted by firewall rules, including SSH to the K3s VM and the PostgreSQL NodePort.

For that reason:

- Expose only required ports.
- Restrict firewall source ranges.
- Avoid storing long-lived credentials on the Bastion.
- Keep the K3s VM without a public IP.
- Use least-privilege IAM.
- Treat database credentials and Terraform state as sensitive data.

---

## Design Philosophy

This exercise deliberately favors a small, understandable architecture over unnecessary complexity.

The important distinction is between:

```text
Lab / Exercise
      vs.
Production Architecture
```

The current design demonstrates:

```text
Infrastructure as Code
        +
Private networking
        +
Controlled access
        +
Kubernetes
        +
CloudNativePG
        +
Persistent storage
        +
Application-level validation
```

The remaining manual steps are explicitly documented and are intended to be progressively replaced by idempotent automation.