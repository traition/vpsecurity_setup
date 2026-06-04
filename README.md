# vpsecurity_setup

面向 **AlmaLinux 10**（及兼容的 RHEL 系发行版）的一键脚本，用于加固 SSH 登录：自动生成 **ed25519** 密钥、启用 **Google Authenticator（TOTP）** 双因素认证，并调整 **sshd / PAM** 相关配置。

## 功能概览

| 项目 | 说明 |
|------|------|
| 用户 | 创建指定用户（已存在则跳过），加入 `wheel` 组 |
| SSH 密钥 | 生成 ed25519 密钥对，公钥写入 `~/.ssh/authorized_keys` |
| SSH 服务 | 自定义端口、禁止 root / 密码登录、仅允许 `publickey,keyboard-interactive` |
| 2FA | 非交互配置 Google Authenticator（QR 码、密钥、5 个紧急备用码） |
| PAM | 在 `sshd`、`system-auth` 中启用 `pam_google_authenticator`；注释 `sshd` 中与 2FA 冲突的 `password-auth` / `postlogin` 行 |

## 环境要求

- **操作系统**：AlmaLinux 10（或同类 RHEL 系，使用 `dnf`）
- **权限**：必须以 **root** 执行（`sudo` 或 root 登录）
- **网络**：可访问 EPEL 与软件仓库（安装 `google-authenticator`、`qrencode` 等）
- **终端**：新建用户设置密码、扫描 GA 二维码时，需要可用的 **TTY**（勿在无交互管道中创建新用户）

## 快速开始

在服务器上以 root 执行（将 `username`、`2222` 换成实际值）：

```bash
curl -sS https://raw.githubusercontent.com/traition/vpsecurity_setup/refs/heads/main/start.sh | bash -s -- -u username -p 2222
```

若当前不是 root 用户，请使用 `sudo`：

```bash
curl -sS https://raw.githubusercontent.com/traition/vpsecurity_setup/refs/heads/main/start.sh | sudo bash -s -- -u username -p 2222
```

### 本地执行

克隆仓库后：

```bash
sudo bash start.sh -u username -p 2222
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-u` | SSH 登录用户名 | `ec2-user` |
| `-p` | SSH 监听端口 | `7022` |
| `-h` | 显示帮助并退出 | — |

示例：

```bash
sudo bash start.sh -u myadmin -p 7022
```

## 执行流程中请完成的事项

1. **新建用户时**：按提示在终端输入并确认密码（需 TTY）。
2. **Google Authenticator 阶段**：
   - 用手机 App 扫描终端中的 QR 码（或手动输入密钥）；
   - **立即保存** 终端显示的 **5 个紧急备用验证码** 与密钥信息（日志副本：`/tmp/ga_output_<用户名>.txt`）。
3. **私钥**：
   - 服务器路径：`/home/<用户名>/.ssh/id_ed25519`
   - 尽快下载到本地：`chmod 600` 后用于登录；
   - 若不在服务器保留私钥，确认能登录后删除：`rm /home/<用户名>/.ssh/id_ed25519`
4. **修改 SSH 端口前**：请另开终端并保持当前会话，避免改端口后失联。

## 配置完成后的登录方式

```bash
chmod 600 ./id_ed25519
ssh -i ./id_ed25519 username@<服务器IP> -p 2222
```

连接后除密钥外，还需输入 Google Authenticator 中的 **6 位动态验证码**（或紧急备用码）。

验证 sudo 是否也要求 2FA：

```bash
sudo whoami
```

## 脚本会修改的主要文件

- `/etc/ssh/sshd_config` 及 `sshd_config.d` 下相关片段（如 `50-redhat.conf`、`50-cloud-init.conf`）
- `/etc/pam.d/sshd`（添加 2FA 模块，注释 `password-auth` / `postlogin` 相关 `auth` 行）
- `/etc/pam.d/system-auth`（备份为 `system-auth.bak` 后添加 2FA）
- `/home/<用户名>/.ssh/`、`~/.google_authenticator`

## 安全提示

- 脚本会 **关闭密码登录**、**禁止 root SSH**，仅允许密钥 + 2FA。
- 私钥与紧急备用码等同于账户权限，请离线妥善保管。
- 通过 `curl | bash` 执行前，请先审阅 [start.sh](./start.sh) 源码，确认符合你的安全策略。
- 重复执行可能覆盖 `authorized_keys`、重新生成 2FA 配置，请在维护窗口谨慎操作。

## 故障排查

| 现象 | 建议 |
|------|------|
| 无法设置新用户密码 | 不要仅用管道执行；在真实终端或 `sudo bash start.sh` 下运行 |
| 看不到 QR / 密钥 | 确认使用最新脚本（含 `-C` 与 `tee` 输出）；查看 `/tmp/ga_output_<用户名>.txt` |
| 改端口后无法连接 | 检查安全组/防火墙是否放行新端口；用旧会话修复 `sshd` 配置 |
| `sshd -t` 失败 | 根据报错检查 `/etc/ssh/sshd_config`，脚本会在失败时中止 |

## 许可证

见仓库根目录（如有）。使用前请自行评估风险并备份重要配置。
