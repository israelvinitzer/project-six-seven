## Complete Manual Deployment Runbook

This section documents the complete deployment procedure so the environment can be rebuilt from a clean machine without relying on undocumented manual steps.

### Deployment Flow

```text
Clean Machine
      |
      v
Check / Install Prerequisites
      |
      +--> Git
      +--> Terraform
      +--> Google Cloud CLI
      +--> SSH
      |
      v
Clone Repository
      |
      v
Authenticate to GCP
      |
      v
Terraform
      |
      +--> terraform init
      +--> terraform validate
      +--> terraform plan
      +--> terraform apply
      |
      v
GCP Infrastructure
      |
      +--> VPC / Subnet
      +--> Firewall Rules
      +--> Cloud Router / NAT
      +--> Bastion VM
      +--> Private K3s VM
      |
      v
Configure SSH / ProxyJump
      |
      v
Bootstrap K3s VM
      |
      +--> Install K3s
      +--> Configure kubectl
      +--> Install Helm
      +--> Install CNPG Operator
      |
      v
Deploy PostgreSQL
      |
      +--> CNPG Cluster
      +--> Persistent Storage
      +--> NodePort Service
      |
      v
Prepare Bastion
      |
      +--> Python
      +--> pip
      +--> venv
      +--> psycopg
      +--> telnet
      |
      v
Validate Network Path
      |
      v
Run Python DB Validation
      |
      +--> Connect to PostgreSQL
      +--> Authenticate
      +--> SELECT 1
      |
      v
Final Verification
      |
      v
Environment Ready
```

---

## 1. Prerequisites

Check that the required tools are available:

```bash
git --version
terraform --version
gcloud --version
ssh -V
```

### Install Terraform on macOS

If Homebrew is available:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

Verify:

```bash
terraform --version
```

If Terraform is already installed, do not reinstall it.

---

## 2. Clone the Repository

```bash
git clone <repository-url>
cd project-c67
```

Verify the repository contents:

```bash
ls -la
```

---

## 3. Authenticate to Google Cloud

```bash
gcloud auth login
```

Configure Application Default Credentials for Terraform:

```bash
gcloud auth application-default login
```

Verify the active project:

```bash
gcloud config get-value project
```

If necessary:

```bash
gcloud config set project <PROJECT_ID>
```

---

## 4. Provision the Infrastructure with Terraform

Move to the Terraform directory if the repository uses a dedicated Terraform directory:

```bash
cd terraform
```

Initialize Terraform:

```bash
terraform init
```

Validate the configuration:

```bash
terraform validate
```

Review the execution plan:

```bash
terraform plan
```

Provision the infrastructure:

```bash
terraform apply
```

Review the plan before confirming the apply.

Terraform provisions the GCP infrastructure, including:

```text
VPC
Subnet
Bastion VM
Private K3s VM
Firewall Rules
Cloud Router
Cloud NAT
```

The K3s VM must not have a public IP.

---

## 5. Verify the Infrastructure

Verify the VM addresses.

Expected architecture:

```text
Bastion VM
  Private IP:  10.0.0.10
  External IP: Assigned

K3s VM
  Private IP:  10.0.0.20
  External IP: None
```

The Bastion is the approved entry point into the private environment.

The K3s VM uses Cloud NAT for outbound Internet connectivity.

---

## 6. Configure SSH / ProxyJump

Create or edit:

```bash
~/.ssh/config
```

Example configuration:

```text
Host bastion
    HostName <BASTION_PUBLIC_IP>
    User <SSH_USER>
    IdentityFile ~/.ssh/<PRIVATE_KEY>

Host k3s
    HostName 10.0.0.20
    User <SSH_USER>
    IdentityFile ~/.ssh/<PRIVATE_KEY>
    ProxyJump bastion
```

Set the correct permissions:

```bash
chmod 600 ~/.ssh/config
```

Test the Bastion:

```bash
ssh bastion
```

Test K3s through the Bastion:

```bash
ssh k3s
```

The resulting path is:

```text
Local Machine
      |
      | SSH
      v
Bastion
10.0.0.10
      |
      | ProxyJump / SSH
      v
K3s
10.0.0.20
```

---

## 7. Install K3s

Connect to the K3s VM:

```bash
ssh k3s
```

Install K3s:

```bash
curl -sfL https://get.k3s.io | sh -
```

Verify the service:

```bash
sudo systemctl status k3s
```

Verify the Kubernetes node:

```bash
sudo k3s kubectl get nodes
```

The node should report:

```text
Ready
```

Configure `kubectl` access for the current user as required.

Verify:

```bash
kubectl get nodes
```

---

## 8. Install Helm

On the K3s VM:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify:

```bash
helm version
```

---

## 9. Install CloudNativePG

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

Verify:

```bash
kubectl get pods -n cnpg-system
```

Do not continue until the CNPG Operator is `Running` and `Ready`.

---

## 10. Deploy PostgreSQL

Apply the PostgreSQL cluster:

```bash
kubectl apply -f kubernetes/postgres-cluster.yaml
```

Verify:

```bash
kubectl get clusters -n cnpg-system
```

Check the pods:

```bash
kubectl get pods -n cnpg-system
```

Check persistent storage:

```bash
kubectl get pvc -n cnpg-system
```

The PostgreSQL PVC should be `Bound`.

---

## 11. Deploy the PostgreSQL NodePort

Apply the NodePort service:

```bash
kubectl apply -f kubernetes/postgres-nodeport.yaml
```

Verify:

```bash
kubectl get svc -n cnpg-system
```

Expected private endpoint:

```text
10.0.0.20:30432
```

The GCP firewall should allow TCP/30432 only from the Bastion private IP:

```text
Source:
10.0.0.10/32

Destination:
K3s VM

Port:
TCP/30432
```

---

## 12. Prepare the Bastion

Connect to the Bastion:

```bash
ssh bastion
```

Update the package index:

```bash
sudo apt update
```

Install the required packages:

```bash
sudo apt install -y python3 python3-pip python3-venv telnet
```

Create a Python virtual environment:

```bash
python3 -m venv venv
```

Activate it:

```bash
source venv/bin/activate
```

Upgrade pip if required:

```bash
python -m pip install --upgrade pip
```

Install the PostgreSQL Python driver:

```bash
pip install "psycopg[binary]"
```

Verify:

```bash
python --version
pip list
```

---

## 13. Validate the Network Path

From the Bastion:

```bash
telnet 10.0.0.20 30432
```

This validates the TCP path:

```text
Bastion
10.0.0.10
      |
      | TCP/30432
      v
K3s
10.0.0.20
      |
      | NodePort
      v
PostgreSQL
```

This is a private network path. PostgreSQL is not intentionally exposed directly to the Internet.

---

## 14. Run the Python Validation

Activate the Python virtual environment if it is not already active:

```bash
source venv/bin/activate
```

Run:

```bash
python3 validate_db.py
```

The validation script should:

```text
Connect to PostgreSQL
        |
        v
Authenticate
        |
        v
Execute SELECT 1
        |
        v
Verify result = 1
```

A successful `SELECT 1` validates basic network connectivity, authentication, database availability, and SQL execution.

It does not prove HA, replication health, performance, storage capacity, or full production readiness.

---

## 15. Final Verification

Before considering the deployment complete, verify:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get clusters -n cnpg-system
kubectl get pvc -n cnpg-system
kubectl get svc -n cnpg-system
```

Confirm:

```text
[ ] Terraform apply completed successfully
[ ] Bastion is reachable
[ ] K3s VM has NO public IP
[ ] K3s VM can reach the Internet through Cloud NAT
[ ] SSH ProxyJump works
[ ] K3s node is Ready
[ ] CNPG Operator is Ready
[ ] PostgreSQL is Ready
[ ] PVC is Bound
[ ] NodePort exists on TCP/30432
[ ] TCP/30432 is allowed only from the Bastion
[ ] Bastion can reach PostgreSQL
[ ] Python validation succeeds
[ ] SELECT 1 returns 1
```

---

## 16. Destroy the Environment

When the environment is no longer required:

```bash
terraform destroy
```

Review the destroy plan before confirming.

---

## 17. Automation – Next Step

Once this manual runbook works reliably end-to-end, the same deployment flow will be converted into idempotent automation.

Target repository structure:

```text
.
├── README.md
├── terraform/
├── kubernetes/
│   ├── postgres-cluster.yaml
│   └── postgres-nodeport.yaml
├── scripts/
│   ├── bootstrap-k3s.sh
│   ├── bootstrap-bastion.sh
│   └── verify.sh
├── validate_db.py
├── up.sh
└── down.sh
```

Target automated flow:

```text
./up.sh
   |
   +--> Terraform init / plan / apply
   |
   +--> Wait for infrastructure
   |
   +--> Configure SSH access
   |
   +--> bootstrap-k3s.sh
   |       |
   |       +--> Install K3s
   |       +--> Install Helm
   |       +--> Install CNPG
   |       +--> Deploy PostgreSQL
   |       +--> Deploy NodePort
   |
   +--> bootstrap-bastion.sh
   |       |
   |       +--> Install Python
   |       +--> Install pip / venv
   |       +--> Install psycopg
   |
   +--> verify.sh
           |
           +--> K3s Ready
           +--> CNPG Ready
           +--> PostgreSQL Ready
           +--> PVC Bound
           +--> Network path reachable
           +--> SELECT 1 succeeds
```

The final goal is:

```bash
git clone <repository-url>
cd project-c67
./up.sh
```

and have the complete environment rebuilt from scratch.

Teardown:

```bash
./down.sh
```

This keeps Terraform responsible for infrastructure provisioning while the bootstrap scripts handle operating-system, K3s, Kubernetes, PostgreSQL, and validation configuration.