# LiveSync Docker Git Backup

使用 [Self-hosted LiveSync CLI](https://github.com/vrtmrz/obsidian-livesync) 与 Docker Compose 搭建一个无头同步目标，并将同步目标中的 Vault 文件按周期提交到本地 Git 裸仓库，作为后台冷备。

## 方案概览

```text
                         CouchDB
                            ▲
                            │ LiveSync daemon
                            │
┌──────────────────┐  /vault│  ┌──────────────────┐
│ livesync         │────────┼─▶│ data/vault       │
│ ghcr.io/...:edge │        │  │ 实际 Vault 文件   │
└────────┬─────────┘        │  └────────┬─────────┘
         │ /data                         │ 只读
         ▼                               ▼
┌──────────────────┐              ┌──────────────────┐
│ data/livesync    │              │ backup           │
│ PouchDB 本地状态 │              │ 周期性 Git 提交  │
└──────────────────┘              └────────┬─────────┘
                                           ▼
                                  data/git-backup
                                  Git 裸仓库
                                           │ 可选 push
                                           ▼
                                  远程 Git 仓库
```

关键约束：

- `livesync` 服务负责 CouchDB 与 `/vault` 之间的长期双向同步。
- `backup` 服务只读 `/vault`，不会写入活动同步目录。
- Git 冷备默认只保存在 `data/git-backup`；配置 `BACKUP_REMOTE` 后才会推送远端。
- LiveSync 的设置文件会写入 `data/livesync/.livesync/settings.json`，其中包含 CouchDB 凭据和加密口令，不能提交到本仓库。

## 快速部署

### 1. 准备配置

```bash
cp .env.example .env
```

编辑 `.env`，至少设置以下值：

```dotenv
COUCHDB_URI=https://couchdb.example.com
COUCHDB_USER=<COUCHDB_USER>
COUCHDB_PASSWORD=<COUCHDB_PASSWORD>
COUCHDB_DBNAME=obsidian-livesync
LIVESYNC_ENCRYPT=true
LIVESYNC_PASSPHRASE=<LIVESYNC_PASSPHRASE>
```

`COUCHDB_URI` 必须从容器内部可访问。若 CouchDB 运行在宿主机上，不能直接填写容器内的 `localhost`；Linux 通常使用宿主机网关地址，或将 CouchDB 纳入同一 Compose 网络。

### 2. 启动

```bash
mkdir -p data/livesync data/vault data/git-backup
docker compose up -d
docker compose logs -f livesync
```

首次启动时，入口脚本会根据环境变量生成 settings 文件；已有 settings 文件不会被覆盖。LiveSync 服务随后运行 `daemon --vault /vault`，先执行一次镜像，再持续监听本地文件并消费 CouchDB 变化。

### 3. 检查状态

```bash
docker compose ps
docker compose logs --tail=100 livesync
docker compose logs --tail=100 backup
```

备份服务默认每小时检查一次。首次发现文件后会在本地裸仓库创建提交；没有变化时不会产生空提交。

## Git 冷备

### 本地裸仓库

`data/git-backup` 是由备份容器维护的裸 Git 仓库。查看提交：

```bash
git --git-dir=data/git-backup log --oneline --decorate --all
```

导出某个提交到临时目录：

```bash
mkdir -p restore
git --git-dir=data/git-backup archive <COMMIT> | tar -x -C restore
```

恢复活动 Vault 前，先停止同步服务，避免同步进程与恢复操作同时修改文件：

```bash
docker compose stop livesync backup
```

确认恢复内容后再启动服务：

```bash
docker compose start livesync backup
```

### 推送远程 Git 仓库

推荐使用专用 SSH deploy key 和只允许写入目标仓库的远端账号。先准备密钥及主机指纹：

```bash
mkdir -p secrets
cp <SSH_PRIVATE_KEY_FILE> secrets/backup_ssh_key
chmod 600 secrets/backup_ssh_key
ssh-keyscan -H <GIT_HOST> > secrets/known_hosts
```

在 `.env` 中设置：

```dotenv
BACKUP_REMOTE=git@<GIT_HOST>:<OWNER>/<REPOSITORY>.git
BACKUP_SSH_KEY_PATH=./secrets/backup_ssh_key
BACKUP_SSH_KNOWN_HOSTS_PATH=./secrets/known_hosts
```

使用 SSH 覆盖文件启动：

```bash
docker compose -f compose.yaml -f compose.ssh.yaml up -d --build
```

远端仓库应当是空仓库或允许该备份分支直接推进的仓库。脚本不会强制推送；若远端存在不相关历史，备份服务会报告 push 失败而保留本地提交。

不要把 token、密码或私钥放进 `BACKUP_REMOTE`、`.env` 或仓库文件。若使用 HTTPS 远端，请在运行环境中提供标准 Git credential helper，并避免将凭据嵌入 URL。

## 常用操作

列出 LiveSync 本地数据库中的文件：

```bash
docker compose run --rm --entrypoint /usr/local/bin/livesync-cli livesync ls
```

执行一次备份而不等待下一个周期：

```bash
docker compose run --rm backup --once
```

设置文件更新后重新生成 settings：

```bash
LIVESYNC_REWRITE_SETTINGS=true docker compose up -d --force-recreate livesync
```

确认服务正常启动后，删除该环境变量，避免后续重启重复覆盖 settings。

升级上游 CLI：

```bash
docker compose pull livesync
docker compose up -d
```

生产环境建议将 `LIVESYNC_IMAGE` 从 `edge` 改成经过验证的固定 tag 或镜像 digest，并在升级前保留 Git 冷备提交。

## 数据目录

| 路径 | 用途 | 是否应提交 |
| --- | --- | --- |
| `data/livesync` | LiveSync PouchDB 与 settings | 否，含凭据 |
| `data/vault` | 无头同步目标的实际 Vault | 否，属于运行时数据 |
| `data/git-backup` | 本地 Git 裸仓库 | 否，体积可能增长 |
| `secrets/` | SSH 私钥及 known_hosts | 否 |

`.gitignore` 已覆盖上述运行时路径。公开仓库只包含 Compose 文件、脚本和示例配置。

## 安全与运维建议

- CouchDB 使用专用数据库账号、TLS 和最小权限。
- `LIVESYNC_PASSPHRASE` 是 LiveSync 内容加密口令；丢失后无法依靠 Git 提交恢复加密内容。
- `data/livesync` 不是冷备替代品，真正的文件恢复来源是 Git 提交；首次同步完成后再确认备份提交已经产生。
- 定期测试 Git 导出和恢复流程，不要只检查容器处于 `running` 状态。
- 远端 SSH key 使用专用、可撤销、限制仓库范围的 deploy key。

## 许可证

本仓库只提供部署编排和辅助脚本；LiveSync CLI 的代码、镜像及其许可证归上游项目所有，详见 [上游仓库](https://github.com/vrtmrz/obsidian-livesync)。
