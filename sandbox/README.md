# Memento Lab ISO

[Root README](../README.md) · [Backend Guide](../backend/README.md)

Memento produces one bootable ISO for every participant. At boot, the participant enters a student ID and activation token. The workspace exposes only `~/memento/bits.c`; the trusted checker, tests, reference solutions, and grader remain on the backend.

The ISO layers the Memento workspace on a Tiny Core base ISO. Its graphical shell uses the configured wallpaper, JetBrains Mono, Catppuccin colours, and a composited transparent terminal.

## Build

Building requires Linux or WSL with `p7zip-full`, `cpio`, `gzip`, and `genisoimage` (or another provider of `mkisofs`). You must be permitted to redistribute the base ISO and every asset it contains.

```bash
cd sandbox
bash scripts/build-iso.sh \
  --source-iso /path/to/orkom.iso \
  --backend-url https://grader.example.edu
```

The result is written to `output/memento-lab.iso`. The source ISO is used as the base system; the output ISO contains the Memento overlay and the configured backend URL.

Use a publicly reachable HTTPS backend URL for distribution. For a local VirtualBox test, use an address that is reachable from the guest, such as a host-only address or a publicly exposed test endpoint.

## Student workflow

After activation, the graphical terminal opens automatically. The available terminal shortcuts are:

| Shortcut | Action |
| --- | --- |
| `Super+Enter` | Open another terminal |
| `Super+Shift+Enter` | Close the focused terminal |

```bash
cd ~/memento
nano bits.c
submit
status SUBMISSION_ID
```

`submit` always uploads `~/memento/bits.c`; it cannot select another file. It prints a submission ID while the job is queued. `status` uses that ID to display the grading verdict and score. The backend accepts only a file named `bits.c` and grades it in an isolated container.

The ISO includes common shell tools, `nano`, `vim`, and `gdb`. Participants can work normally in their temporary home directory, but only `bits.c` is submitted and evaluated.

## ISO lifecycle

An ISO is a live, read-only medium. The participant home directory and edits exist only for the current boot session. On restart, the participant activates the same VM again and receives a fresh `bits.c`; submissions and scores remain in the backend. Reset a lost VM activation before moving an account to a different virtual machine:

```bash
cd ../backend
docker compose run --rm api reset-activation STUDENT_ID
```

## Layout

```text
src/        Trusted legacy grader sources
scripts/    ISO build script
vm/overlay/ Files injected into the live ISO at build time
vm/bg/      Wallpaper asset
vm/fonts/   Terminal font asset and licence
```
