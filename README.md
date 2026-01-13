# sshcfg

一个用于**交互式安全配置 OpenSSH Server** 的小工具：通过安装脚本生成并安装命令 `ssh-config`，帮助你一键完成公钥登录配置、（可选）禁用密码登录、（可选）禁止/允许 root 登录，并在应用前后做备份与语法校验，最后自动重启 SSH 服务。

## 功能

- **交互式向导**：引导你选择是否允许 root 登录、是否禁用密码登录、为哪个用户写入公钥。
- **多种公钥来源**：
  - 直接粘贴公钥
  - 输入 URL（脚本会抓取第一行作为公钥）
  - 输入 `github:用户名` / `gitlab:用户名`（自动从 `*.keys` 拉取）
- **安全措施**：
  - 修改前备份 `/etc/ssh/sshd_config`
  - `sshd -t` 语法测试失败则恢复备份并退出
  - 重启 SSH 服务失败则恢复备份并退出
- **日志记录**：执行日志写入 `/var/log/ssh-config.log`

## 适用环境 / 依赖

- **Linux 服务器**（需要可管理 OpenSSH Server；脚本会操作 `/etc/ssh/sshd_config` 并重启服务）
- **必须 root 权限**（`install.sh` 与 `ssh-config` 都会检查 `id -u`）
- 依赖命令（通常系统自带或可安装）：
  - `bash`, `sshd`, `sed`, `grep`, `cp`, `chmod`, `chown`, `getent`
  - `curl`（用于从 URL / GitHub / GitLab 拉取公钥）
  - `systemctl` 或 `service`（用于重启 SSH 服务）

> Windows 上请在目标 Linux 服务器执行，或使用 WSL（且需要能管理 WSL 内的 SSH 服务与 `/etc/ssh/`）。

## 安装

在目标服务器上执行（默认以 **root** 身份运行；请先 `su -` 切到 root 再执行）：

```bash
wget -O install.sh "https://raw.githubusercontent.com/B-ug/sshcfg/refs/heads/main/install.sh" && chmod +x install.sh && ./install.sh
```

安装完成后会生成并安装命令：

- `ssh-config` → `/usr/local/bin/ssh-config`

## 使用

运行交互式向导（必须 root）：

```bash
ssh-config
```

向导大致流程：

- 选择是否允许 root 登录
- 选择是否禁用密码登录（仅密钥登录）
- 提供公钥（粘贴 / URL / `github:xxx` / `gitlab:xxx`）
- 选择写入公钥的目标用户（root / 当前登录用户 / 指定用户）
- 应用配置 → 语法校验 → 重启 SSH 服务 → 检查服务状态

## 备份与日志

- **配置备份目录**：`/etc/ssh/backups/`
  - 备份文件类似：`/etc/ssh/backups/sshd_config.YYYYmmdd_HHMMSS.bak`
- **日志文件**：`/var/log/ssh-config.log`

## 会修改哪些 SSH 配置

脚本会在 `/etc/ssh/sshd_config` 中设置/更新（若已存在会替换，包含被注释的条目）：

- `PubkeyAuthentication yes`
- `AuthorizedKeysFile .ssh/authorized_keys`
- `PermitRootLogin yes|no`（由交互选择决定）
- `PasswordAuthentication yes|no`（由交互选择决定）

并为目标用户写入公钥到：

- `<用户家目录>/.ssh/authorized_keys`

同时确保权限合理：

- `~/.ssh`：`700`
- `authorized_keys`：`600`

## 重要安全提示

- **在禁用密码登录前，请务必确认你的密钥登录可用**，否则可能把自己锁在服务器外。
- 强烈建议在远程服务器操作时：
  - 保持当前 SSH 会话不断开
  - 另开一个新终端测试新配置连接成功后，再关闭旧会话
- 若服务器有控制台/救援模式，请确保你有备用登录方式以防万一。

## 卸载

本项目的安装行为是把命令脚本写入 `/usr/local/bin/ssh-config`，卸载只需删除该文件：

```bash
rm -f /usr/local/bin/ssh-config
```

（不会自动回滚你已修改的 SSH 配置；如需回滚请从 `/etc/ssh/backups/` 选择备份恢复。）

