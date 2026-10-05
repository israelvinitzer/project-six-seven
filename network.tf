resource "google_compute_network" "main" {
  name                    = "project-six-seven-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "project-six-seven-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "me-west1"
  network       = google_compute_network.main.id
}

resource "google_compute_firewall" "allow_ssh_bastion" {
  name    = "allow-ssh-bastion"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["79.177.159.133/32"]

  target_tags = ["bastion"]
}

resource "google_compute_firewall" "allow_ssh_k3s" {
  name    = "allow-ssh-k3s"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["10.0.0.10/32"]

  target_tags = ["k3s"]
}

resource "google_compute_firewall" "allow_postgres_from_bastion" {
  name    = "allow-postgres-from-bastion"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["30432"]
  }

  source_ranges = ["10.0.0.10/32"]

  target_tags = ["k3s"]
}