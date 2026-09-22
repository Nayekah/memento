# Memento VM

> Packer configuration and first-boot workflow for the student Lab VM.

[Root README](../README.md) · [Backend Guide](../backend/README.md)

## Overview

Every participant receives the same image. On first boot, the VM creates a
personal Linux account after the student enters an ID, activation token, and
password. The workspace exposes only `~/memento/bits.c`.

The trusted grader is inspired by
[Data-Lab](https://github.com/szx503045266/Data-Lab). Its tests, checker, and
reference implementations are not copied into the student OVA.

## Student Workflow

```bash
cd ~/memento
nano bits.c
submit bits.c
status SUBMISSION_ID
```

`submit` always uploads `~/memento/bits.c`. The backend accepts exactly one
file named `bits.c` and grades it in an isolated container.

## Build Requirements

- Packer
- VirtualBox for an OVA, or VMware Workstation/Fusion for VMX/VMDK
- An official Ubuntu Server ISO and its SHA-256 checksum
- Public backend URL, preferably HTTPS

## Build the VM

```bash
bash scripts/build-vm.sh \
  --iso /absolute/path/ubuntu-live-server-amd64.iso \
  --checksum sha256:PASTE_THE_OFFICIAL_SHA256_HERE \
  --backend-url https://grader.example.edu
```

For VMware, add `--target vmware`. On Windows PowerShell:

```powershell
.\scripts\build-vm.ps1 `
  -IsoPath 'C:\path\to\ubuntu-live-server-amd64.iso' `
  -IsoChecksum 'sha256:PASTE_THE_OFFICIAL_SHA256_HERE' `
  -BackendUrl 'https://grader.example.edu'
```

VirtualBox artifacts are written to `output-virtualbox/`; VMware artifacts are
written to `output-vmware/`.

## Network and Security

The VM uses one NAT adapter and connects to the configured `BACKEND_URL`. No
host-only adapter or private IP configuration is required.

The delivered OVA contains the incomplete starter file, `submit`, and `status`.
It does not contain hidden tests, checker sources, reference implementations,
or the grader image. The Packer account is locked before delivery.

If a VM is lost or recreated, reset its activation before the student activates
the replacement VM:

```bash
docker compose run --rm api reset-activation STUDENT_ID
```

## Layout

```text
src/  Trusted legacy grader sources; only bits.c is transferred to the OVA
vm/   Packer template, autoinstall files, and first-boot provisioning
```
