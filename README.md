# LiveSync Docker Git Backup

使用 [Self-hosted LiveSync CLI](https://github.com/vrtmrz/obsidian-livesync) 与 Docker Compose 搭建一个无头同步目标，并将同步目标中的 Vault 文件按周期提交到本地 Git 裸仓库，作为后台冷备。默认从 [LiveSync CLI fork](https://github.com/Skyxim/obsidian-livesync) 构建，以支持可选的点文件同步。

## 方案概览

```text
                         CouchDB
                            ▲
                            │ LiveSync daemon
                            │
┌──────────────────┐  /vault│  ┌──────────────────┐
│ livesync         │────────┼─▶│ data/vault       │
│ livesync-cli fork│        │  │ 实际 Vault 文件   │
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

Compose 默认从 fork 的 `main` 分支构建镜像。生产环境应将 `LIVESYNC_BUILD_CONTEXT` 固定到已验证的 commit，或将 `LIVESYNC_IMAGE` 改为已发布并验证的镜像。

编辑 `.env`，至少设置以下值：

```dotenv
COUCHDB_URI=https://couchdb.example.com
COUCHDB_USER=<COUCHDB_USER>
COUCHDB_PASSWORD=<COUCHDB_PASSWORD>
COUCHDB_DBNAME=obsidian-livesync
LIVESYNC_ENCRYPT=true
LIVESYNC_PASSPHRASE=<LIVESYNC_PASSPHRASE>
LIVESYNC_INTERVAL_SECONDS=
LIVESYNC_USE_REQUEST_API=true
LIVESYNC_SYNC_INTERNAL_FILES=true
LIVESYNC_USE_PATH_OBFUSCATION=false
LIVESYNC_ENCRYPT_INTERNAL_METADATA=false
LIVESYNC_USE_PLUGIN_SYNC_V2=false
LIVESYNC_CUSTOM_CHUNK_SIZE=0
LIVESYNC_E2EE_ALGORITHM=v2
```

`COUCHDB_URI` 必须从容器内部可访问。若 CouchDB 运行在宿主机上，不能直接填写容器内的 `localhost`；Linux 通常使用宿主机网关地址，或将 CouchDB 纳入同一 Compose 网络。

默认使用 CouchDB `_changes` 事件流，`LIVESYNC_INTERVAL_SECONDS` 留空即可。只有在代理会关闭长连接、且事件流产生 524 时，才将它设置为正整数，例如 `60`，作为轮询回退。

如果该 CouchDB 配置在 Obsidian 中启用了 **Use Request API**，将 `LIVESYNC_USE_REQUEST_API=true` 保持一致。事件流是否能穿过 Cloudflare 仍取决于代理行为；如果 CLI 仍收到 524，优先为 CouchDB 提供不经过 Cloudflare 空闲超时的直连地址，再保持事件模式。

如果需要同步 `.obsidian`、`.trash` 等隐藏文件和目录，将 `LIVESYNC_SYNC_INTERNAL_FILES` 设置为 `true`。这是 LiveSync 的显式 opt-in 选项，修改后需要使用 `LIVESYNC_REWRITE_SETTINGS=true docker compose up -d --force-recreate livesync` 重写一次 settings；确认生效后应移除该环境变量，避免后续重启重复覆盖配置。

隐藏文件启用后，默认会同步点文件和点目录；需要跳过的路径写入 Vault 根目录的 `.livesync/ignore`，每行一个相对路径 glob：

```text
.obsidian/workspace.json
.agents/cache/
*.tmp
```

规则支持 `minimatch` glob 和 `dot` 路径，不支持 `!` 反向规则。该文件由无头 CLI 在启动时读取，修改后重启 `livesync` 服务即可。

接入已有 LiveSync 远端时，`LIVESYNC_USE_REQUEST_API`、`LIVESYNC_USE_PATH_OBFUSCATION`、`LIVESYNC_ENCRYPT_INTERNAL_METADATA`、`LIVESYNC_USE_PLUGIN_SYNC_V2`、`LIVESYNC_CUSTOM_CHUNK_SIZE` 和 `LIVESYNC_E2EE_ALGORITHM` 必须与远端保持一致。配置不一致时，CLI 会拒绝同步，不能通过猜测参数解决；应以已有 Obsidian 客户端或 CLI 的配置检查结果为准。

### 2. 启动

```bash
mkdir -p data/livesync data/vault data/git-backup
docker compose up -d --build
docker compose logs -f livesync
```

首次启动时，Compose 会构建 fork CLI，入口脚本会根据环境变量生成 settings 文件；已有 settings 文件不会被覆盖。LiveSync 服务随后运行 `daemon --vault /vault`，先执行一次镜像，再持续监听本地文件并消费 CouchDB 变化。

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

使用 `git@host:path` 或 `ssh://` 形式的远端时，必须同时提供私钥和 `known_hosts`；脚本会拒绝缺少其中任一项的 SSH 配置。远端 push 失败会让备份容器退出并由 Compose 重启，本地 Git 提交仍会保留，具体错误可在 `docker compose logs backup` 中查看。

脚本每轮快照前都会读取远端备份分支并以远端 `HEAD` 为线性基线：本地落后时只做快进，本地领先时继续追加；如果本地与远端历史分叉，服务会直接报错，不会 merge，也不会强制推送。备份提交使用 `HEAD:<分支>` 推送，不会覆盖已有历史。首次使用时，远端可以是空仓库；非空远端会先被安全地接入本地裸仓库。

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

升级 fork CLI：

```bash
docker compose build --pull livesync
docker compose up -d
```

如果使用已发布镜像而不是 Compose 构建，将 `LIVESYNC_IMAGE` 改成固定 tag 或镜像 digest 后执行 `docker compose pull livesync && docker compose up -d`。升级前应保留 Git 冷备提交。

Git 裸仓库默认不自动清理历史。如需回收已不再被引用的对象，可在确认恢复策略后手动执行：

```bash
git --git-dir=data/git-backup gc
```

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
