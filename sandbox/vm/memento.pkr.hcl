packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/virtualbox"
    }
    vmware = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "Absolute path or HTTPS URL of an official Ubuntu Server ISO."
}

variable "iso_checksum" {
  type        = string
  description = "Checksum in Packer form, for example sha256:..."
}

variable "backend_url" {
  type        = string
  description = "Public backend URL, for example https://grader.example.edu."
}

source "virtualbox-iso" "memento" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  http_directory   = "${path.root}/http"
  output_directory = "${path.root}/../output-virtualbox"
  guest_os_type    = "Ubuntu_64"
  format           = "ova"
  headless         = true
  cpus             = 2
  memory           = 2048
  disk_size        = 20480
  ssh_username     = "practicant"
  ssh_password     = "practicant"
  ssh_timeout      = "30m"
  shutdown_command = "echo 'practicant' | sudo -S shutdown -P now"
  boot_wait        = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/<enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]
}

source "vmware-iso" "memento" {
  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  http_directory   = "${path.root}/http"
  output_directory = "${path.root}/../output-vmware"
  guest_os_type    = "ubuntu-64"
  headless         = true
  cpus             = 2
  memory           = 2048
  disk_size        = 20480
  ssh_username     = "practicant"
  ssh_password     = "practicant"
  ssh_timeout      = "30m"
  shutdown_command = "echo 'practicant' | sudo -S shutdown -P now"
  boot_wait        = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/<enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]
  vmx_data = {
    "ethernet0.present"        = "TRUE"
    "ethernet0.connectionType" = "nat"
  }
}

build {
  sources = [
    "source.virtualbox-iso.memento",
    "source.vmware-iso.memento"
  ]

  provisioner "file" {
    source      = "${path.root}/../src/bits.c"
    destination = "/tmp/bits.c"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/provision.sh"
    execute_command = "echo 'practicant' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    environment_vars = [
      "BACKEND_URL=${var.backend_url}"
    ]
  }
}
