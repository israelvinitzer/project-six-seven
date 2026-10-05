resource "google_compute_instance" "bastion" {
  name         = "bastion"
  machine_type = "e2-micro"
  zone         = "me-west1-a"

  tags = ["bastion"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = "10.0.0.10"

    access_config {
    }
  }
}

resource "google_compute_instance" "k3s" {
  name         = "k3s"
  machine_type = "e2-medium"
  zone         = "me-west1-a"

  tags = ["k3s"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = "10.0.0.20"
  }
}
  