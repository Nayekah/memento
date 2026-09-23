# Memento

<p align="center">
  <img src="https://media1.tenor.com/m/JiTEKXHhyRUAAAAd/linne-battle-pose.gif" alt="Linne battle pose" />
</p>

> A secure, VM-based Lab environment with isolated backend grading.

<h3 align="center">A VM-based lab environment with isolated, server-side grading.</h3>

<p align="center">
  <img src="https://img.shields.io/badge/Go-1.24-00ADD8?logo=go&logoColor=white" alt="Go 1.24" />
  <img src="https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white" alt="PostgreSQL 17" />
  <img src="https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker&logoColor=white" alt="Docker" />
  <img src="https://img.shields.io/badge/VirtualBox%20%7C%20VMware-OVA%20Delivery-183A61" alt="OVA delivery" />
</p>

<p align="center">
  <a href="backend/README.md">Backend Setup</a>
  &middot;
  <a href="sandbox/README.md">VM Build Guide</a>
  &middot;
  <a href="LICENSE">License</a>
</p>

## Overview

<p align="center">
  <img width="1024" height="768" alt="VirtualBox_Memento Lab Local Test_23_09_2026_18_17_43" src="https://github.com/user-attachments/assets/f08d7428-094c-488f-8fc3-1548185cf327" />
  <img width="1024" height="768" alt="VirtualBox_Memento Lab Local Test_23_09_2026_18_16_13" src="https://github.com/user-attachments/assets/6ea3494b-bd17-488b-9570-9208f3270752" />
</p>


Memento delivers the same preconfigured OVA to every student while creating a
separate Linux account and workspace at first boot. Students edit and submit
only `bits.c`; the backend stores submissions in PostgreSQL and grades them in
an isolated Docker container using legacy lab tooling. The grader design is
inspired by [Data-Lab](https://github.com/szx503045266/Data-Lab).

The student OVA does not contain test cases, reference implementations, or the
grader. It contains only the incomplete `bits.c` starter file and the `submit`
and `status` commands.

## Technology Stack

<p align="center">
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/go/go-original-wordmark.svg" alt="Go" width="96" />
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/postgresql/postgresql-original-wordmark.svg" alt="PostgreSQL" width="96" />
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/docker/docker-original-wordmark.svg" alt="Docker" width="96" />
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/linux/linux-original.svg" alt="Linux" width="96" />
</p>

- Go API and concurrent grading worker
- PostgreSQL submission queue and global leaderboard
- Docker-isolated legacy lab grader
- Caddy reverse proxy with configurable TLS domain
- Packer-built VirtualBox OVA and VMware VMX/VMDK artifacts
- Husky pre-commit hook with Go formatting and static checks

## Features

- One reusable VM image for all students
- First-boot account activation with a student ID and token
- Per-student VM activation binding
- Submission history, detailed verdicts, and scores
- Global leaderboard based on every student's best completed submission
- PostgreSQL queue with concurrent workers and `FOR UPDATE SKIP LOCKED`
- Per-student submission rate limit
- Sandboxed grading with no network, restricted resources, and a read-only root filesystem
- Public HTTPS endpoint with an internal-only API and PostgreSQL service

## Repository Layout

```text
backend/   Go API, PostgreSQL migrations, Caddy proxy, worker, and grader image
sandbox/   Packer VM build, first-boot activation, and legacy lab sources
frontend/  Reserved for the future leaderboard interface
scripts/   Repository lint workflow used by Husky
```

`sandbox/src/` is copied into the trusted grader image. The Packer template
copies only `sandbox/src/bits.c` into the student OVA.

## Quick Start

### Backend

Requirements:

- Docker Engine or Docker Desktop
- A public DNS record for your chosen domain
- Inbound TCP ports `80` and `443`
- A Linux directory for temporary grader files

```bash
cd backend
cp .env.example .env
mkdir -p /srv/memento/grader-work
docker compose build grader-image api worker
docker compose up -d
```

Caddy obtains a TLS certificate for the configured domain and forwards HTTPS requests
to the Go API on its internal port, `8067`. PostgreSQL is never published.

Register a student and generate a private activation token:

```bash
docker compose run --rm api student 2200012345 "Student Name"
docker compose run --rm api token 2200012345
```

See [backend/README.md](backend/README.md) for deployment, queue, API, and
database details.

### Student VM

Build an OVA with the public backend URL:

```bash
cd sandbox
bash scripts/build-vm.sh \
  --iso /absolute/path/ubuntu-live-server-amd64.iso \
  --checksum sha256:PASTE_THE_OFFICIAL_SHA256_HERE \
  --backend-url https://grader.example.edu
```

On first boot, the student enters their student ID, activation token, and a new
Linux password. They then work only with:

```bash
cd ~/memento
nano bits.c
submit bits.c
status SUBMISSION_ID
```

See [sandbox/README.md](sandbox/README.md) for VirtualBox, VMware, and VM
activation details.

## Grading Flow

```text
Student VM -> HTTPS API -> PostgreSQL queue -> Worker -> Isolated grader container
                                                  -> Score, verdict, and leaderboard
```

Each worker claims one job transactionally. The grader receives the submitted
source as `bits.c` and cannot access the network, host filesystem, Docker
socket, test infrastructure, or other submissions.

## Development

Install the repository development dependencies, then run the checks:

```bash
npm install
npm run lint
```

Husky runs the same lint command before each commit. The backend smoke test can
be run from WSL after the Docker images have been built:

```bash
cd backend
bash scripts/smoke-test.sh
```

## Authors

<div align="center">
  <table width="520">
    <tr>
      <th width="50%">Name</th>
      <th width="50%">GitHub</th>
    </tr>
    <tr align="center">
      <td width="50%">Nayaka</td>
      <td>
        <a href="https://github.com/Nayekah">
          <img src="https://github.com/Nayekah.png" width="48" alt="Nayekah" /><br/>
          <sub><b>@Nayekah</b></sub>
        </a>
      </td>
    </tr>
  </table>
</div>

---

<div align="center">
  Memento &middot; Sister LabTech
</div>
