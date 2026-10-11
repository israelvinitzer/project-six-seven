# Project Six Seven — GCP, K3s and CloudNativePG

## Overview

This repository contains a reproducible manual deployment of a private PostgreSQL environment on Google Cloud Platform (GCP). Terraform provisions the infrastructure, K3s hosts Kubernetes, CloudNativePG (CNPG) manages PostgreSQL, and a Python script running on the Bastion validates private database access.

The manual runbook is the current supported workflow. Bootstrap and one-command automation are planned but **not implemented**.

### Architecture

```text
Local Mac
   |
   | SSH (public IP, restricted source)
   v
Bastion VM (10.0.0.10, public IP)
   | \
   |  \ TCP/30432 (GCP firewall: Bastion only)
   |   v
   |   K3s VM (10.0.0.20, NO public IP)
   |        |
   |        v
   |   NodePort 30432 -> PostgreSQL 5432
   |
   +-- SSH ProxyJump --> K3s VM

K3s VM -- Cloud NAT --> Internet (outbound only)
```

Both VMs currently share a subnet. Access is segmented with GCP firewall rules; separate subnets could be considered for a production design. A NodePort is used for this time-boxed lab, not proposed as a default production database exposure pattern.

### Repository layout

```text
project-six-seven/
├── README.md
├── .gitignore
├── .terraform.lock.hcl        # Commit if generated
├── providers.tf
├── network.tf
├── compute.tf
├── nat.tf
├── kubernetes/
│   ├── postgres-cluster.yaml
│   └── postgres-nodeport.yaml
└── validation/
    ├── validate_db.py
    └── requirements.txt
```

Terraform files are in the **repository root**. Do not run `cd terraform` unless the repository layout changes.

The following files are required and should already exist in Git:

- `kubernetes/postgres-cluster.yaml`: CNPG `Cluster` resource, `airis-postgres`, one instance, 1Gi storage.
- `kubernetes/postgres-nodeport.yaml`: NodePort service `postgres-bastion`, exposing `30432` on the K3s VM and forwarding to PostgreSQL `5432`.
- `validation/validate_db.py`: connects to `10.0.0.20:30432`, authenticates with `DB_PASSWORD`, runs `SELECT 1`, and checks the result.
- `validation/requirements.txt`: `psycopg[binary]`.

Do not commit credentials, private SSH keys, `.terraform/`, `*.tfstate*`, or Terraform plan files. **Do commit `.terraform.lock.hcl`** to keep provider selections reproducible.

---

## Complete Manual Deployment Runbook

### Deployment flow

```text
Check prerequisites on Mac
       |
Clone repository and authenticate to GCP
       |
Terraform init -> validate -> plan -> apply
       |
Verify VPC, firewall, Cloud NAT and VMs
       |
Configure SSH ProxyJump on Mac
       |
Install K3s and configure kubectl on K3s VM
       |
Install Helm and CNPG Operator on K3s VM
       |
Copy repository manifests from Mac to K3s VM
       |
Deploy PostgreSQL Cluster and NodePort
       |
Copy validation files from Mac to Bastion
       |
Prepare Bastion Python environment
       |
Retrieve CNPG application password securely
       |
Validate private TCP path and SELECT 1
       |
Final verification
```

### 1. Prerequisites — Mac

Check installed tools:

```bash
git --version
terraform --version
gcloud --version
ssh -V
```

Install Terraform with Homebrew if needed:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform --version
```

Install and initialize the Google Cloud CLI if needed, following the official Google Cloud installation instructions for your OS. You need permission to create compute instances, VPC networking, firewall rules, Cloud Router and Cloud NAT in the target project, and sufficient quota in the selected region.

### 2. Clone the repository — Mac

```bash
git clone https://github.com/israelvinitzer/project-six-seven.git
cd project-six-seven
ls -la
ls kubernetes validation
```

The clone command creates the `project-six-seven` directory by default. Verify the `.tf`, Kubernetes YAML, and validation files exist before proceeding.

### 3. Authenticate to Google Cloud — Mac

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project red-truck-454019-n6
gcloud config get-value project
```

Terraform's Google provider uses Application Default Credentials (ADC) in this workflow. Confirm the Terraform provider project and region settings match the intended deployment (`me-west1`, zone `me-west1-a` in the current lab).

### 4. Provision infrastructure — Mac, repository root

**Before running `terraform plan` or `terraform apply`, update the Bastion SSH firewall source IP.** Your home/office public IP can change between deployments.

On your **Mac**, find your current public IPv4 address:

```bash
curl -4 -s https://api.ipify.org; echo
```

Open `network.tf` and find the firewall rule that permits **inbound SSH (TCP/22) to the Bastion**. Set its `source_ranges` to your current public IPv4 address followed by `/32`:

```hcl
source_ranges = ["79.177.159.133/32"]
```

`79.177.159.133` is an **example from this lab**, not an address to reuse automatically. Replace it with the IP printed by the command above. `/32` permits only that single IPv4 address. **Do not change** the separate PostgreSQL NodePort rule, which should allow `10.0.0.10/32` (the Bastion's private IP), or the K3s SSH rule.

Then, from the repository root, run:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

Confirm in the plan that the Bastion SSH ingress rule uses the intended `/32` address. If your public IP changes later, update `network.tf` and run `terraform apply` again.

Review the plan and confirm before applying. Terraform is responsible for the VPC, subnet, GCP firewall rules, Cloud Router, Cloud NAT, Bastion VM, and private K3s VM.

**Security requirements:** The Bastion has a public IP and SSH ingress restricted to the approved source address. The K3s VM has **no public IP**. SSH to K3s is allowed from the Bastion, and TCP/30432 to K3s is allowed from the Bastion's private IP only. Cloud NAT provides outbound Internet access for the private VM; it does not create inbound Internet access.

### 5. Verify infrastructure — Mac

```bash
gcloud compute instances list --project red-truck-454019-n6
```

Expected internal addresses:

```text
Bastion: 10.0.0.10; external IP assigned by GCP
K3s:    10.0.0.20; external IP: NONE
```

Record the Bastion's **current** external IP. If the VM uses an ephemeral external IP, it may change after stop/start or recreation.

In the GCP console, inspect **VPC network → Firewall** or use `gcloud compute firewall-rules list` to verify the actual deployed firewall rules. The NodePort rule must target the K3s VM and allow TCP/30432 from `10.0.0.10/32`, not from `0.0.0.0/0`. Also check that no broader overlapping allow rule grants unwanted access.

### 6. Configure SSH ProxyJump — Mac

Edit `~/.ssh/config` on the **Mac**:

```sshconfig
Host bastion
    HostName <BASTION_PUBLIC_IP>
    User israelvinitzer
    IdentityFile ~/.ssh/google_compute_engine
    IdentitiesOnly yes

Host k3s
    HostName 10.0.0.20
    User israelvinitzer
    IdentityFile ~/.ssh/google_compute_engine
    IdentitiesOnly yes
    ProxyJump bastion
```

Adjust the user and key path to the credentials actually configured for these VMs. Protect the SSH configuration:

```bash
chmod 600 ~/.ssh/config
ssh bastion
```

Exit the Bastion, then **from the Mac**:

```bash
ssh k3s
```

`ssh k3s` uses the Mac's SSH key and tunnels through the Bastion. Do not assume that running `ssh k3s` **inside the Bastion** works: the Bastion does not have the Mac's private key, by design. Avoid copying your private SSH key onto the Bastion.

### 7. Install K3s — K3s VM

Connect from the Mac:

```bash
ssh k3s
```

On the K3s VM:

```bash
curl -sfL https://get.k3s.io | sh -
sudo systemctl is-active k3s
sudo k3s kubectl get nodes
```

Wait until the node reports `Ready`.

Configure kubectl access for the current user **on the K3s VM**:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

This is an administrator-level kubeconfig suitable for the isolated lab; secure it carefully. In production, use appropriately scoped access and RBAC instead.

### 8. Install Helm — K3s VM

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

The following Helm commands run as the **same normal user** whose kubeconfig was configured above. Do not mix `sudo helm repo add` with a later non-sudo `helm install` because Helm repository settings are per-user.

### 9. Install CloudNativePG — K3s VM

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace
```

Verify:

```bash
kubectl get pods -n cnpg-system
kubectl get deployments -n cnpg-system
```

Wait for the CNPG operator deployment to become available before applying the PostgreSQL `Cluster` resource. For example, use `kubectl get deployments -n cnpg-system` to identify the operator deployment and then `kubectl rollout status deployment/<OPERATOR_DEPLOYMENT_NAME> -n cnpg-system`.

### 10. Deploy PostgreSQL — Mac and K3s VM

The PostgreSQL definition is **already in Git** at `kubernetes/postgres-cluster.yaml`. Do not recreate it by pasting YAML from this README.

**On the Mac**, from the repository root, copy both Kubernetes manifests to the K3s VM through SSH ProxyJump:

```bash
scp -r kubernetes k3s:~/
```

**On the K3s VM**:

```bash
kubectl apply -f ~/kubernetes/postgres-cluster.yaml
kubectl get clusters -n cnpg-system
kubectl get pods -n cnpg-system
kubectl get pvc -n cnpg-system
```

Wait for the PostgreSQL cluster to report a healthy/ready state and for its PVC to be `Bound`. A single PostgreSQL instance is **not** highly available. The 1Gi PVC is for demonstration, not production sizing.

### 11. Deploy PostgreSQL NodePort — K3s VM

The NodePort manifest is already in Git at `kubernetes/postgres-nodeport.yaml` and was copied in Section 10.

```bash
kubectl apply -f ~/kubernetes/postgres-nodeport.yaml
kubectl get svc postgres-bastion -n cnpg-system
kubectl get endpointslices -n cnpg-system
```

Expected service mapping:

```text
postgres-bastion   NodePort   10.43.x.x   <none>   5432:30432/TCP
```

`10.0.0.20:30432` is **not** a Kubernetes Service IP shown in `kubectl get svc`. It is the K3s VM's private IP combined with the NodePort. The service routes connections on port `30432` to PostgreSQL port `5432`.

The source restriction `10.0.0.10/32` is a **GCP firewall rule managed by Terraform**, not a Kubernetes Service setting.

### 12. Prepare the Bastion — Mac and Bastion VM

**On the Mac**, from the repository root:

```bash
scp -r validation bastion:~/
```

**On the Bastion**:

```bash
ssh bastion
sudo apt update
sudo apt install -y python3 python3-pip python3-venv telnet
python3 -m venv ~/venv
source ~/venv/bin/activate
python -m pip install -r ~/validation/requirements.txt
```

The `ssh bastion` command above is executed from the Mac; subsequent commands run inside the Bastion shell.

Verify:

```bash
python --version
python -m pip show psycopg
ls -l ~/validation/validate_db.py
```

### 13. Validate the private network path — Bastion VM

```bash
telnet 10.0.0.20 30432
```

A successful TCP connection confirms reachability to the NodePort from the Bastion. It does **not** confirm database authentication or SQL execution. Exit telnet (typically `Ctrl+]`, then `quit`).

If it fails, check the GCP firewall source range and target tags, NodePort Service, endpoint readiness, and PostgreSQL pod status.

### 14. Run Python database validation — K3s VM and Bastion VM

The script is stored at `validation/validate_db.py`. **Do not paste Python code into the README or recreate the script manually on the Bastion.**

**On the K3s VM**, obtain the application password generated by CNPG:

```bash
kubectl get secret airis-postgres-app -n cnpg-system \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'
```

Do not paste the password into chat, commit it to Git, or include it in screenshots. The generated credentials are stored in a Kubernetes Secret; base64 encoding is not encryption.

**On the Bastion**, activate the virtual environment and supply the password for the current shell:

```bash
source ~/venv/bin/activate
export DB_PASSWORD='PASTE_PASSWORD_HERE'
python3 ~/validation/validate_db.py
```

Expected output:

```text
PostgreSQL connection successful: SELECT 1 returned 1
```

A successful run demonstrates Bastion-to-K3s private network connectivity, PostgreSQL authentication, and a basic SQL query. It does **not** prove high availability, replication, backup recovery, performance, capacity, or full production readiness.

For production, prefer a managed secrets system, narrowly scoped credentials, and verified TLS rather than manual password handling.

### 15. Final verification — run commands on the appropriate hosts

**Mac:**

```bash
terraform plan
gcloud compute instances list --project red-truck-454019-n6
```

`terraform plan` should show no unexpected changes once the infrastructure matches configuration.

**K3s VM:**

```bash
kubectl get nodes
kubectl get pods -A
kubectl get clusters -n cnpg-system
kubectl get pvc -n cnpg-system
kubectl get svc -n cnpg-system
```

**Bastion:**

```bash
source ~/venv/bin/activate
python3 ~/validation/validate_db.py
```

Confirm:

- [ ] Terraform applied successfully, with no unexpected drift.
- [ ] Bastion is reachable using restricted SSH access.
- [ ] K3s VM has **no public IP**.
- [ ] K3s outbound access works through Cloud NAT.
- [ ] SSH ProxyJump works from the Mac.
- [ ] K3s node is `Ready`.
- [ ] CNPG operator is ready.
- [ ] PostgreSQL cluster is healthy.
- [ ] PVC is `Bound`.
- [ ] NodePort service maps `30432` to PostgreSQL.
- [ ] GCP firewall permits TCP/30432 only from Bastion's private IP; no broader overlapping allow rule exposes it.
- [ ] Bastion can connect to `10.0.0.20:30432`.
- [ ] Python validation succeeds and `SELECT 1` returns `1`.

### 16. Destroy the environment — Mac, repository root

```bash
terraform destroy
```

Review the destroy plan before confirming. **Destroying the VM and its local K3s storage destroys the lab's PostgreSQL data.** A PVC can survive an ordinary pod restart, but does not provide a backup or protect against destruction of its underlying disk.

---

## 17. Planned automation — NOT YET IMPLEMENTED

Once the manual workflow has been tested end-to-end, add scripts to automate the repeatable setup and verification:

```text
scripts/
├── bootstrap-k3s.sh
├── bootstrap-bastion.sh
└── verify.sh
up.sh
 down.sh
```

Target future workflow:

```text
./up.sh
  -> Terraform provisioning
  -> SSH/bootstrap readiness
  -> K3s and Helm installation
  -> CNPG operator and PostgreSQL deployment
  -> Bastion Python dependencies
  -> Private network and SQL verification

./down.sh
  -> Confirm and destroy Terraform-managed resources
```

These scripts **do not exist yet**. Do not run `./up.sh` or `./down.sh` until they have been implemented, reviewed, and tested. Until then, follow Sections 1–16.

## Design notes and trade-offs

- **Availability:** One K3s VM and one PostgreSQL instance form a single point of failure. Production HA would require a multi-node cluster, multiple PostgreSQL instances across failure domains, and a tested failover strategy.
- **Networking:** The K3s VM has no public IP. Cloud NAT allows outbound access only; firewall rules govern inbound connections. The Bastion is the controlled entry point.
- **Database exposure:** NodePort is convenient for this exercise, but a production design may use a private load balancer, private service networking, or another tightly controlled access pattern.
- **Storage and recovery:** A PVC provides persistent storage within the lab's lifecycle; it is not a backup. Production needs off-node backups, tested restores, retention policies, and recovery objectives.
- **Sizing:** `e2-micro` Bastion, `e2-medium` K3s, and 1Gi PostgreSQL storage are lab choices, not production capacity recommendations. Size from observed workload, memory, IOPS, WAL volume, growth, and reliability requirements.
- **Secrets:** CNPG generates application credentials in a Kubernetes Secret. Keep credentials out of source control; use managed secret distribution and verified encryption in production.
- **Verification scope:** `SELECT 1` proves a basic working connection and query, not end-to-end application health or database resilience.
