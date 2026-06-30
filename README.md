# MiMo Code for Android

Run MiMo Code on Android devices with root access.

[中文](README.zh.md)

> ⚠️ **Experimental**
>
> This project is in early stages. Most issues can be resolved with the help of AI (ChatGPT, Claude, MiMo itself, etc.). Device compatibility reports are welcome via Issues.

## What It Does

Running MiMo Code on Android requires solving three layers of incompatibility:

**1. Runtime libraries.** MiMo Code is a glibc-compiled Linux binary. Android has only bionic libc — it cannot run glibc executables directly. We ship a complete glibc runtime from Debian (ld-linux, libc, libstdc++, libgcc, etc.) and load MiMo through `ld-linux --library-path`.

**2. Subprocess shell.** MiMo Code executes commands by spawning `$SHELL`. Android's `/system/bin/sh` is bionic-linked and cannot coexist with glibc — setting `LD_LIBRARY_PATH` crashes it, not setting it leaves glibc libraries missing. We ship a glibc-linked bash and set it as MiMo's default shell.

**3. System configuration.** glibc hard-codes reads from `/etc/resolv.conf` (DNS), `/etc/hosts` (local resolution), `/etc/nsswitch.conf` (name service), and `/etc/ssl/certs` (HTTPS certificates). Android's `/etc` is an EROFS read-only partition — these files are absent or unwritable. We use [proot](https://github.com/proot-me/proot), a ptrace-based syscall interceptor, to insert path translation between the process and the kernel. When glibc opens `/etc/resolv.conf`, proot rewrites the path to `/data/local/tmp/mimocode/rootfs/etc/resolv.conf`. MiMo Code sees no difference.

No source modifications to MiMo Code.

## KernelSU Global Commands

The installer provides **dual-guarantee** global access to `mimo`, `bash`, `python3`, and `git`:

**1. `/data/adb/ksu/bin/` — instant.** KSU's own bin directory, already on PATH under `su`, with correct SELinux context. Works immediately, **no reboot required**:

```bash
su
mimo --version
bash --version
python3 -m pip --version
git --version
```

**2. `/data/adb/modules/mimo/` — post-reboot.** Standard systemless module approach: KSU bind-mounts module binaries to `/system/bin/` on reboot. Acts as a fallback. No system partition modification, no SafetyNet impact, fully reversible.

The `/data/adb/ksu/bin/` path was added because some devices (e.g., Redmi K80 Pro) assign `adb_data_file` SELinux context to KSU module files, making them unreadable by KSU. `/data/adb/ksu/bin/` has no such issue.

## Quick Start

**Recommended: One-liner via mobile terminal (e.g. Termux)**

```bash
su -c "curl -sL https://github.com/AHLLX/MiMo-Code-Android/releases/latest/download/install.sh | sh"
```

**Alternative: PC via ADB**

```bash
adb push online/install.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/install.sh"
```

Available globally immediately (no reboot needed):
```bash
su
mimo
```

## How It Works

proot intercepts every syscall from the MiMo process via `ptrace`. When glibc opens `/etc/resolv.conf`, proot translates the path to our writable copy:

```
MiMo Code          open("/etc/resolv.conf")
    |
proot (ptrace)    translate to /data/local/tmp/mimocode/rootfs/etc/resolv.conf
    |
Linux kernel      serve the real file
```

The wrapper binds five paths:

| real path                                        | virtual path         | purpose     |
| ------------------------------------------------ | -------------------- | ----------- |
| `.../lib/*`                                      | `/lib/*`             | glibc, bash |
| `.../rootfs/etc/resolv.conf`                     | `/etc/resolv.conf`   | DNS         |
| `.../rootfs/etc/hosts`                           | `/etc/hosts`         | localhost   |
| `.../rootfs/etc/nsswitch.conf`                   | `/etc/nsswitch.conf` | NSS         |
| `.../rootfs/etc/ssl/certs/ca-certificates.crt`   | `/etc/ssl/certs`     | HTTPS       |

The CA bundle is merged from Android's 149 individual `/system/etc/security/cacerts/*.0` files at install time.

## What's Installed

| component   | source                | purpose                          |
| ----------- | --------------------- | -------------------------------- |
| glibc 2.42  | Debian arm64 (USTC)   | runtime for Linux binaries       |
| bash 5.3.9  | Debian pool           | shell for MiMo subprocesses      |
| python3.13.14 | Debian pool         | dev tool                         |
| git 2.39.5  | Debian pool           | version control                  |
| proot 5.3.0 | GitHub Releases       | syscall translation layer        |
| MiMo Code   | GitHub Releases       | the actual application           |

Everything goes under `/data/local/tmp/mimocode/`, which has the `shell_data_file` SELinux context and is naturally executable on Android.

## Requirements

- Android device with ARM64 (aarch64) CPU
- Root access (tested on KernelSU; should work on Magisk and APatch)
- ADB for initial setup

## Verified

| device | OS | Root | status |
| ------ | -- | ---- | ------ |
| Xiaomi Pad 6s Pro 12.4 | Android 16, HyperOS 3.0.303 | KernelSU | ✅ OK |
| Redmi K80 Pro | Android 16, HyperOS 3.0.303 | KernelSU | ✅ OK (`/data/adb/ksu/bin/`) |

Other devices should work in theory. Contributions confirming additional devices are welcome.

All 13 tools confirmed working on both devices:

| category   | tools                          | status  |
| ---------- | ------------------------------ | ------- |
| execution  | bash                           | OK      |
| file       | read, write, edit              | OK      |
| search     | glob, grep                     | OK      |
| navigation | change_directory               | OK      |
| memory     | memory                         | OK      |
| task       | task                           | OK      |
| subagent   | actor                          | OK      |
| network    | webfetch                       | OK      |
| skill      | skill                          | OK      |
| workflow   | workflow                       | OK      |

Workflow notes: simple scripts, agent(), parallel() all work. Built-in deep-research may need a larger timeout.

The remaining 9 are supporting/internal tools called indirectly or activated on demand: `question`, `history`, `codesearch`, `websearch`, `lsp`, `apply_patch`, `multiedit`, `plan`, `invalid`.

## Devices Pending Test

| device | status |
| ------ | ------ |
| — | — |

No additional test devices available. Contributions confirming other devices are welcome.

## Development Tools

### Python

Python 3.13.14 with pip 26.1.2 is installed alongside MiMo Code, available globally immediately after install:

```bash
su
python3 --version           # Python 3.13.14
python3 -m pip --version    # pip 26.1.2
```

### Git

Git 2.39.5 (glibc) runs through proot, supporting HTTPS and SSH. Available globally after install:

```bash
su
git --version               # git version 2.39.5
git clone https://github.com/...
```

> **Note:** Git requires proot path translation for HTTPS/SSH to work on Android. The wrapper handles this transparently.

## Files

### online/ — Online installer

| file | purpose |
| ---- | ------- |
| `install.sh` | One-shot installer. Downloads glibc, bash, python3, proot, and MiMo Code from Debian mirrors and GitHub Releases. Creates wrappers and KSU module. Supports update, repair, and uninstall on re-run. |
| `wrappers/mimo` | Runtime launcher. Invokes proot with five bind mounts, then starts MiMo Code through glibc's `ld-linux`. Sets `HOME`, `MIMOCODE_HOME`, `PYTHONHOME`, and `SHELL`. |
| `wrappers/bash` | Launches glibc bash through the dynamic linker. |
| `wrappers/python3` | Launches glibc python3 with `PYTHONHOME` pointing to the Debian stdlib. |
| `lib/git` | Git 2.39.5 (glibc) installed via Debian packages. Runs through proot for full HTTPS/SSH support. |
| `test.sh` | Smoke test: verifies `mimo --version`, `bash --version`, `python3 -m pip --version`. |


## Uninstall

Preferred method (handles permissions automatically):

```bash
adb shell su -c "sh /data/local/tmp/install.sh"
# Select [3] Uninstall
```

Reboot after uninstall to clear KSU module mounts.

Or remove manually (enter su first for full permissions):

```bash
adb shell
su
rm -rf /data/local/tmp/mimocode /data/local/tmp/mimo /data/local/tmp/bash /data/local/tmp/python3 /data/adb/modules/mimo /data/adb/mimocode /data/local/.mimo-cache /data/local/.mimo-proot-cache
rm -f /data/adb/ksu/bin/mimo /data/adb/ksu/bin/bash /data/adb/ksu/bin/python3 /data/adb/ksu/bin/git
```

## Acknowledgments

- **MiMo Code** and the **MiMo v2.5 model** handled early path exploration, validation, and prototype coding, achieving tablet usability
- **DeepSeek V4 Pro** drove the complete later-stage development, documentation, and refinements
- **[proot](https://github.com/proot-me/proot)** provides syscall interception and path translation — the core dependency for glibc compatibility
- **[Debian](https://www.debian.org/)** arm64 packages supply the glibc runtime, bash, and python3
- **[KernelSU](https://github.com/tiann/KernelSU)** provides the Android root solution and systemless module support

## Changelog

### v1.1.0

- 🚀 **Parallel Downloading**: Completely revamped dependency fetching using concurrent background jobs for all 51 Debian packages. Reduces download time from ~5-10 minutes to under 2 minutes.
- 🧠 **Dynamic Version Resolution**: No longer hardcodes Debian package versions. The script automatically parses the latest `arm64` package versions directly from the Debian mirrors via regex.
- 🛡️ **Smart Mirror Fallback**: Uses `mirrors.ustc.edu.cn` by default but dynamically falls back to `deb.debian.org` per package if an architecture build is missing or times out.
- ⏱️ **Robust Network Handling**: Added `--retry 3` and `--max-time` configurations for both HTML parsing and `.deb` downloads to gracefully handle temporary proxy drops or rate limits without hanging.

### v1.0.4

- 🚀 **Git support**: install git with all dependencies (HTTPS/SSH via proot)
- 🔧 **Re-run menu**: option [2] Install/Repair git only
- 🗑️ **Uninstall confirmation**: user chooses whether to keep data or delete everything
- 🛡️ **Dual-mirror defense**: added `dd magic` validation for all downloaded `.deb` files with robust dual-mirror (USTC + Debian) fallback to prevent environmental corruption from network anomalies

### v1.0.3

- 🐛 **Fix version detection**: API response parsing made robust with fallback patterns; prevents fallback to hardcoded v0.1.1
- 🐛 **Fix update mode crash**: `ROOTFS` variable moved to top-level config — update mode no longer fails with "parameter not set"

### v1.0.2

- 🚀 **Smart update**: "Update/Repair" only downloads the MiMo binary — skips glibc/bash/python3/tools/proot (fixed versions), ~10s update
- 💾 Update never touches user data (memory/config/pip packages)

<details><summary>v1.0.1 and earlier</summary>

- v1.0.1: Add Python runtime, tools (nano/less/file/tree), fix HTTPS certs, fix Update/Repair menu
- v1.0.0: Initial release

</details>

## License

MIT. See `LICENSE`.