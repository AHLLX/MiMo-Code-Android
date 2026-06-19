# MiMo Code for Android

在已 Root 的 Android 设备上运行 MiMo Code。

[English](README.md)

> ⚠️ **实验性项目**
>
> 本项目处于早期阶段，尚未大规模设备验证。如遇问题，大部分可通过 AI（ChatGPT、Claude、MiMo 自身等）辅助排查解决。欢迎提交 Issue 反馈设备兼容性。

## 解决的问题

把 MiMo Code 搬到 Android 上，需要解决三个层面的不兼容：

**1. 运行库。** MiMo Code 是 glibc 编译的 Linux 二进制。Android 只有 bionic libc，无法直接运行。需要从 Debian 引入完整的 glibc 运行时（ld-linux、libc、libstdc++、libgcc 等），通过 `ld-linux --library-path` 加载。

**2. 子进程 shell。** MiMo Code 执行命令时会启动 `$SHELL`。Android 的 `/system/bin/sh` 是 bionic 链接的，不能和 glibc 程序混用——设置 `LD_LIBRARY_PATH` 会导致其崩溃，不设置则缺少 glibc 库。所以需要引入 glibc 版本的 bash 作为 MiMo 的默认 shell。

**3. 系统配置。** glibc 硬编码读取 `/etc/resolv.conf`（DNS）、`/etc/hosts`（本地解析）、`/etc/nsswitch.conf`（名称服务）、`/etc/ssl/certs`（HTTPS 证书）。Android 的 `/etc` 分区是 EROFS 物理只读，这些文件全部不存在或不可写。使用 [proot](https://github.com/proot-me/proot) —— 一个基于 ptrace 的 syscall 拦截器 —— 在进程和内核之间插入路径翻译。glibc 以打开 `/etc/resolv.conf`，proot 将路径改写为 `/data/local/tmp/mimocode/rootfs/etc/resolv.conf`，对 MiMo Code 完全透明。

不需要修改 MiMo Code 一行源码。

## KSU 全局命令

安装脚本提供**双重保障**，确保 `mimo`、`bash`、`python3` 全局可用：

**1. `/data/adb/ksu/bin/` 即时可用。** KSU 自带的 bin 目录，在 su 的 PATH 中，SELinux context 正确，写完立刻生效，**无需重启**：

```bash
su
mimo --version
bash --version
python3 -m pip --version
```

**2. `/data/adb/modules/mimo/` 重启后挂载。** systemless 模块方式，重启时 KSU 将模块内的二进制 bind-mount 到 `/system/bin/`，作为备选方案。不修改系统分区，不触发 SafetyNet，卸载时删除模块目录即可完全还原。

之所以加 `/data/adb/ksu/bin/` 方案，是因为部分设备（如 Redmi K80 Pro）上 KSU 模块目录的 SELinux context 为 `adb_data_file`，KSU 无法读取，导致全局命令失效。`/data/adb/ksu/bin/` 无此问题。

## 快速开始

**以 Termius 为例，授予 Root 权限后作为终端操作**

```bash
# 在线安装（需网络）
adb push online/install.sh /data/local/tmp/
adb shell su -c "sh /data/local/tmp/install.sh"

# 安装完成，立即全局可用（无需重启）：
su
mimo
```

## 工作原理

proot 通过 `ptrace` 拦截目标进程的每一个 syscall。当 glibc 执行 `open("/etc/resolv.conf")` 时，proot 暂停进程，将路径翻译为 `/data/local/tmp/mimocode/rootfs/etc/resolv.conf`，再恢复进程。对 MiMo Code 完全透明。

wrapper 通过 5 个 bind mount 实现文件覆盖：

| 真实路径                                         | 虚拟路径               | 用途        |
| ------------------------------------------------ | ---------------------- | ----------- |
| `.../lib/*`                                    | `/lib/*`             | glibc, bash |
| `.../rootfs/etc/resolv.conf`                   | `/etc/resolv.conf`   | DNS         |
| `.../rootfs/etc/hosts`                         | `/etc/hosts`         | 本地解析    |
| `.../rootfs/etc/nsswitch.conf`                 | `/etc/nsswitch.conf` | NSS 配置    |
| `.../rootfs/etc/ssl/certs/ca-certificates.crt` | `/etc/ssl/certs`     | HTTPS 证书  |

## 安装内容

| 组件        | 来源                | 用途               |
| ----------- | ------------------- | ------------------ |
| glibc 2.42  | Debian arm64 (USTC) | Linux 二进制运行时 |
| bash 5.3    | Debian pool         | MiMo 子进程 shell  |
| python3.13  | Debian pool         | 开发工具           |
| proot 5.3.0 | GitHub Releases     | syscall 翻译层     |
| MiMo Code   | GitHub Releases     | 应用程序本体       |

全部安装到 `/data/local/tmp/mimocode/`，该路径 SELinux 上下文为 `shell_data_file`，天然可执行。

## 环境要求

- Android 设备，ARM64 (aarch64) 处理器
- Root 权限（已验证 KernelSU；理论兼容 Magisk、APatch）
- ADB 用于初始部署

**已验证设备**:

| 设备 | 系统 | Root 方案 | 状态 |
| ---- | ---- | --------- | ---- |
| 小米 Pad 6s Pro 12.4 | Android 16, HyperOS 3.0.303 | KernelSU | ✅ 正常 |
| Redmi K80 Pro | Android 16, HyperOS 3.0.303 | KernelSU | ✅ 正常（`/data/adb/ksu/bin/`） |

其他设备理论上可用，欢迎提交验证结果。

## 待测设备

| 设备 | 状态 |
| ---- | ---- |
| — | — |

暂无其他可测试设备，欢迎提交验证结果。

## Python 环境

Python 3.13.14 + pip 26.1.2 随 MiMo Code 一起安装，安装后即刻全局可用：

```bash
su
python3 --version           # Python 3.13.14
python3 -m pip --version    # pip 26.1.2
```

| 类别   | 工具              | 状态 |
| ------ | ----------------- | ---- |
| 执行   | bash              | 正常 |
| 文件   | read, write, edit | 正常 |
| 搜索   | glob, grep        | 正常 |
| 导航   | change_directory  | 正常 |
| 记忆   | memory            | 正常 |
| 任务   | task              | 正常 |
| 子代理 | actor             | 正常 |
| 网络   | webfetch          | 正常 |
| 技能   | skill             | 正常 |
| 工作流 | workflow          | 正常 |

工作流说明：简单脚本、agent()、parallel() 均正常。内建 deep-research 可能需要更大的 timeout。

其余 9 个为辅助/内部工具，由上述工具间接调用或按需激活：`question`、`history`、`codesearch`、`websearch`、`lsp`、`apply_patch`、`multiedit`、`plan`、`invalid`。

## 文件说明

### online/ — 在线安装

| 文件 | 用途 |
| ---- | ---- |
| `install.sh` | 一键安装脚本。从 Debian 镜像和 GitHub Releases 下载 glibc、bash、python3、proot 和 MiMo Code。生成 wrapper 和 KSU 模块。再次运行支持更新、修复、卸载。 |
| `wrappers/mimo` | 运行时启动器。通过 proot 挂载 5 个虚拟路径，经由 glibc 的 `ld-linux` 启动 MiMo Code。设置 `HOME`、`MIMOCODE_HOME`、`PYTHONHOME`、`SHELL`。 |
| `wrappers/bash` | 通过动态链接器启动 glibc 版本的 bash。 |
| `wrappers/python3` | 启动 glibc 版本的 python3，设置 `PYTHONHOME` 指向 Debian 标准库。 |

## 卸载

首选通过安装脚本（自动处理权限）：

```bash
adb shell su -c "sh /data/local/tmp/install.sh"
# 选择 [2] Uninstall
```

卸载后需**重启设备**，KSU 模块挂载才会完全清除。

也可手动删除：

```bash
adb shell
su
rm -rf /data/local/tmp/mimocode /data/local/tmp/mimo /data/local/tmp/bash /data/local/tmp/python3 /data/adb/modules/mimo /data/adb/mimocode /data/local/.mimo-cache /data/local/.mimo-proot-cache
rm -f /data/adb/ksu/bin/mimo /data/adb/ksu/bin/bash /data/adb/ksu/bin/python3
```

## 致谢

- **MiMo Code** 及 **MiMo v2.5 模型** 完成了项目前期的路径验证与原型编码，实现了平板端可用
- **DeepSeek V4 Pro** 负责后期的完整项目开发、文档整理与细节调优
- **[proot](https://github.com/proot-me/proot)** 提供 syscall 拦截与路径翻译，是 glibc 兼容层的核心依赖
- **[Debian](https://www.debian.org/)** arm64 软件包提供 glibc 运行时、bash、python3
- **[KernelSU](https://github.com/tiann/KernelSU)** 提供 Android Root 方案与 systemless 模块支持

## 更新日志

### v1.0.1

- 完善 Python 运行时：新增 10 个 Debian 库
- 新增实用工具：nano、less、file、tree
- 修复 urllib HTTPS 证书验证：wrapper 新增 `SSL_CERT_FILE`
- 修复菜单"Update/Repair"选项无效
- `check_integrity` 覆盖所有运行时库和工具

<details><summary>v1.0.0</summary>

- 初始发布

</details>

## 许可证

MIT。详见 `LICENSE`。
