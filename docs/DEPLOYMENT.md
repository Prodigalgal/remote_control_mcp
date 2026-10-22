# Java/React 生产发布门禁

> 本文保留历史发布细节，其中的 `java-release.yml` 已移除。当前日常操作请以 [组件发布](COMPONENT_RELEASES.md) 为准。

产品需求基线：[`docs/REQUIREMENTS.md`](REQUIREMENTS.md)。本文只描述构建、发布和部署验收，不定义新的产品范围。

Java Center/Agent 的目标发布物是 Java 25 Native Image；JVM JAR 只作为 CI 诊断产物。所有测试、JVM 包、React 资源和 Native Image 均由 GitHub Actions 完成；开发机和目标宿主机不执行任何编译或打包，避免 Native Image 峰值占满内存。

可选 `runtime.user_context` 通过响应头 `X-RCM-Agent-User-Context: 1` 协商。新 Agent 首次注册和未协商的心跳发送原有字段，旧 Center 可正常解析；新 Center 接受后才发送路径提示。Center 回退导致字段被拒绝时，下次正常重试自动恢复原有字段。桌面 companion 的 port/token endpoint 保持原格式，用户路径另写在可选 `desktop-user.json` 中，旧 Agent 不受影响。Windows 桌面路径只在 companion 启动时解析一次，心跳不启动 PowerShell。

## 构建

提交源码后推送 `main` 或 `java-vX.Y.Z` 标签即可触发工作流：

```text
git push origin <branch>
git tag java-vX.Y.Z
git push origin java-vX.Y.Z
```

`.github/workflows/change-checks.yml` 负责 PR/main 的 JVM、React、PostgreSQL、Liquibase 和 Native
门禁；`.github/workflows/java-release.yml` 在 `main` 推送时额外构建并发布不可变的
`java-v0.0.0-main.<run>` 预发布版本，在 `java-vX.Y.Z` 标签时发布稳定版本。两种 Release 都经过
匹配架构 Native Image、烟测、校验、SBOM 和签名；预发布不会移动 GHCR 的 `latest` 标签。开发机
不需要安装或运行 Gradle、JDK、GraalVM、Node 或 pnpm。烟测脚本只接受已经从 Actions 下载的
Native Image bundle，不会自行触发构建或退回 JVM JAR。

两个工作流都会先执行 `scripts/scan-repository-secrets.sh`。检查只输出命中文件名，不会把令牌或
私钥内容写入日志；真实域名、内网地址和部署 Secret 必须留在集群外的私有配置层。

产物名为 `rcm-center`、`rcm-agent`、`rcm-desktop-companion`、`rcm-browser-agent` 和独立的一次性 `rcm-updater`。其中 Agent
目标分别隔离命令、用户桌面和浏览器适配器生命周期；当前仓库的 Linux Native Docker builder 固定为
`ghcr.io/graalvm/native-image-community:25@sha256:0d936f32bb8acb5bc60c41b33e05f064d7a6aaf36b726538296c54949bd4a3c0`；更新构建器时必须同步更新两个 Dockerfile、重新跑全套 Native smoke，并记录新的 digest。当前 GraalVM/NIK 25 的可验证 Native Image
矩阵是 Linux amd64/arm64、Windows amd64；Windows arm64 会被脚本明确拒绝，不进入发布矩阵，不能把交叉编译结果当作原生生产物。每个支持目标都必须分别构建
并附带 SHA-256、SBOM 和签名；没有通过 native smoke test 的产物不得发布。Windows Native Image 的
GraalVM 运行时 DLL 会分别与 `rcm-center.exe`、`rcm-agent.exe` 放入各自 bundle，并逐个生成 SHA-256；不能
只分发裸 `.exe`，否则桌面/运行时所需 DLL 可能缺失。Center 与 Agent 不共用 Windows DLL 目录，避免
不同 Native Image 链接结果的同名 `java.dll`/`jvm.dll` 互相覆盖。Linux Native Dockerfile
同样复制完整 `nativeCompile/` 运行目录，使 `libawt`、字体和其他 `.so` 旁路库与对应 ELF
一起进入镜像；不能只把 `rcm-center`/`rcm-agent` 单文件复制到最终层。

仓库只保留 `scripts/build-java.*`、`scripts/build-native.*` 两个 CI 构建入口；这些脚本在非 GitHub Actions 环境会安全退出，不会在本机启动编译。Native 构建仍由工作流按当前 OS/架构输出 Center 加三个 Agent 二进制、`.sha256`、manifest、SBOM 和安装归档；Linux 会把各目标可能生成的 `.so` 与对应 ELF 放入隔离 bundle，Windows 同样生成隔离 bundle、三个平铺 ZIP 及完整 bundle ZIP。

`java/Dockerfile.*.native` 和 `web/Dockerfile` 同样要求构建参数 `RCM_CI_BUILD=true`；工作流会自动注入，本机直接 `docker build` 会在编译前拒绝执行。

Windows 安装器 `scripts/install-agent.ps1` 的 `-BinaryPath` 只接收平铺 command-agent ZIP；`-DesktopBinaryPath` 和 `-BrowserBinaryPath` 只接收两个独立 companion ZIP，安装到隔离子目录，避免 `java.dll`/`jvm.dll` 同名覆盖。凭据、启动宿主与所有 ZIP 先检查，再停止旧任务、替换完整 bundle。安装过程使用 PowerShell 7，注册最长等待 90 秒（可通过 `RegistrationTimeoutSeconds` 调整）；command-agent 的 SYSTEM 开机任务使用 Windows 自带的固定路径 `System32\WindowsPowerShell\v1.0\powershell.exe`，运行兼容 PowerShell 5.1 的轻量启动器，不依赖 Store/MSIX 版本目录、用户 PATH 或安装终端。启用 Desktop 时，登录触发任务使用 `wscript.exe //B //NoLogo` 调用生成的 VBS 启动器。

若旧开机任务因 Store 自动更新出现 `0x80070002`（旧 PowerShell 路径不存在），在管理员终端执行 `scripts/repair-agent-task.ps1`。它先备份原任务 XML，仅更新启动宿主，保留身份、配置、开机触发器、SYSTEM 账户和原重试设置；实际 Agent 进程持续运行后才返回 `started`。仍需通过 Center 心跳和一条终态命令确认远程执行能力，不能仅用任务 Running 作为在线证明。

Windows 下载脚本对临时网络错误最多尝试 3 次，每次有超时，使用临时文件完成下载后再发布；404、鉴权和 SHA-256 错误直接失败，不盲目重试安装。桌面/浏览器延后安装任务也使用 Windows 固定宿主，执行时重新发现 PowerShell 7，避免持久化 Store 的版本路径。`scripts/test-windows-scripts.ps1` 在 Windows PowerShell 5.1 下验证这些故障场景，PR 和 Agent 发布工作流均执行该门禁。

睡眠机器需要硬件、驱动和 Windows 设备唤醒权限共同支持 WoL/WoWLAN；`powercfg /devicequery wake_programmable` 与 `wake_armed` 应分别核对，网卡高级属性启用 Magic Packet 不代表 Windows 已允许该设备唤醒。用同一局域网内仍在线的机器执行 `scripts/wake-machine.ps1 -MacAddress 02-11-22-33-44-55 -InterfaceAlias Ethernet`，按真实网卡和目标 MAC 替换参数。该脚本只向选定接口的子网广播发送最多 5 个唤醒包，发送成功只返回 `sent`；必须再核对 Windows 唤醒来源、Center 新心跳和终态命令才能确认唤醒成功。睡眠中的 Agent 无法自行接收并执行唤醒命令；中继机器离线、休眠、关机或断电的情况需要单独验收，不能用 S3 睡眠测试替代。

Linux 首次注册也受默认 90 秒的进程超时限制，可通过 `REMOTE_CONTROL_MCP_AGENT_REGISTRATION_TIMEOUT_SECONDS` 在 15–600 秒之间调整；凭据与 `timeout` 命令在安装前检查。

已安装旧版本若仍有登录黑框，可在管理员 PowerShell 7 中单独执行
`scripts/repair-desktop-companion-task.ps1`；该脚本只更新桌面计划任务和 VBS 启动器，
不触碰 Agent 身份、Enrollment Token 或 Center 配置。

需要一次性给 Windows 目标启用三套能力时，可使用 `scripts/deploy-desktop-browser.ps1`：必须显式传入
`-CenterUrl`，脚本会下载并校验同版本的 command-agent、desktop 和 browser ZIP，并为 Playwright
浏览器安装一个 `ProgramData` 共享缓存，再由 SYSTEM Agent 继承 `PLAYWRIGHT_BROWSERS_PATH`；这样按
用户安装的 Chromium 不会在 SYSTEM 会话中丢失。`-DesktopUser` 用于指定登录桌面账号；没有活动会话时
仍只注册登录触发的 Companion 任务，不会把“已部署”误报为“桌面在线”。

首次安装推荐使用 `scripts/first-install-agent.ps1` 或 `scripts/first-install-agent.sh`。控制台会将
`CenterUrl`、稳定 Agent 名称、Release tag 和一次性 Enrollment Token 组合成可复制命令；入口只负责
下载/校验对应平台的 command ZIP，`--mode full` 或 `-Mode full` 时再下载独立 Desktop/Browser ZIP。
Windows 入口会在 PowerShell 5/非管理员终端中自动重新进入已安装的 PowerShell 7（包含 MSIX 安装）并按需提权；
Linux 入口在非 root 时通过 `sudo` 重新执行。两者均不安装 Bootstrap 常驻进程，也不会把 Enrollment Token 写入长期
服务环境；安装器完成注册后只留下 Agent identity 和不含一次性 Token 的服务配置。

正式发布使用 `.github/workflows/java-release.yml`：推送 `main` 或 `java-vX.Y.Z` Tag 后，CI 先执行
JVM/React 门禁，再在匹配架构的 GitHub-hosted runner（`ubuntu-24.04` 与
`ubuntu-24.04-arm`）上构建并执行 Linux amd64/arm64 Native Image 烟测，随后在 Windows
amd64 runner 上构建 Windows Native Image。Release 同时
上传安装压缩包和按 `remote-control-mcp-agent-vX.Y.Z-<os>-<arch>` 命名的 Agent
升级资产及 `.sha256`，供 Center 自动升级解析；Linux/Windows 资产都是包含 Agent 可执行文件与
Native Image 运行库的同名平铺 ZIP。Windows 主安装包另外包含 `center/`、`agent/`、`desktop/` 与 `browser/` 四个
隔离 bundle。main 推送会创建预发布 Release，供 Center 版本目录选择；稳定 Tag 会创建正式 Release；
手动运行工作流只构建，不创建 Release。

Linux 完整 tar 包的根目录包含 `install-agent.sh` 和匹配版本的
`remote-control-mcp-agent.service`；必须把正式 bundle ZIP 传给
`REMOTE_CONTROL_MCP_AGENT_BINARY`，例如
`REMOTE_CONTROL_MCP_AGENT_BINARY=./agent/remote-control-mcp-agent-<version>-linux-amd64.zip ./install-agent.sh`。需要桌面/浏览器能力时，再设置
`REMOTE_CONTROL_MCP_AGENT_DESKTOP_BINARY=./desktop/rcm-desktop-companion.zip` 和
`REMOTE_CONTROL_MCP_AGENT_BROWSER_BINARY=./browser/rcm-browser-agent.zip`；安装器会将两个
companion 放到隔离目录。Linux 同时设置 `REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED=true`、
`REMOTE_CONTROL_MCP_AGENT_DESKTOP_USER=<登录用户名>` 后，安装器会为该账号创建
systemd user companion unit，并仅通过 ACL 授予 `state_dir/desktop` 访问；没有 `acl` 或活动图形会话时只安装二进制，不伪造桌面在线状态。
Linux Browser 目标还应将 `REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH` 指向 root
和图形用户均可读的共享目录，并在该目录安装 Chromium；安装器会把该变量写入 systemd
环境，command-agent 启动 browser worker 时自动继承，避免 systemd 服务使用 root profile
时找不到按用户下载的浏览器。
Windows 仍由 `-DesktopEnabled` 创建按用户登录触发的 Scheduled Task。安装器会在每个 ZIP 旁存在 `.sha256`
时先校验，再安装完整 ZIP 内的 Native Image 运行库，并使用包内 systemd 模板（也可用
`REMOTE_CONTROL_MCP_AGENT_SERVICE_FILE` 显式覆盖）。

## PostgreSQL 与 Liquibase

生产 Center 设置（包含 `006-agent-config` 的 Agent 热更新字段）：

```text
RCM_CENTER_PERSISTENCE_MODE=postgres
RCM_CENTER_REQUIRE_DURABLE_STORAGE=true
RCM_CENTER_LIQUIBASE_ENABLED=false
RCM_CENTER_PUBLIC_BASE_URL=https://remote-control-mcp-center.example.invalid
RCM_CENTER_OAUTH_ENABLED=true
RCM_CENTER_OAUTH_ISSUER=https://remote-control-mcp-center.example.invalid
RCM_CENTER_OAUTH_RESOURCE=https://remote-control-mcp-center.example.invalid
RCM_CENTER_OAUTH_ALLOW_STATIC_TOKEN_BOOTSTRAP=true
RCM_CENTER_DATABASE_URL=jdbc:postgresql://<host>:5432/remote_control_mcp
RCM_CENTER_DATABASE_USERNAME=<user>
RCM_CENTER_DATABASE_PASSWORD=<password>
REMOTE_CONTROL_MCP_CENTER_ARTIFACT_SIGNING_SECRET=<at-least-32-char-secret>
# Optional during a rolling rotation; remove after the signed URL TTL window.
REMOTE_CONTROL_MCP_CENTER_ARTIFACT_SIGNING_SECRET_PREVIOUS=<previous-secret>
REMOTE_CONTROL_MCP_CENTER_ARTIFACT_SIGNING_KID=v2
REMOTE_CONTROL_MCP_CENTER_ARTIFACT_SIGNING_KID_PREVIOUS=v1
```

`RCM_CENTER_PUBLIC_BASE_URL` 必须是用户/ChatGPT Web 能访问的稳定 HTTPS Center
Origin；它用于签名 Artifact URL 和 MCP Apps Viewer 的 CSP 元数据。`RCM_CENTER_OAUTH_ISSUER`
和 `RCM_CENTER_OAUTH_RESOURCE` 也必须是稳定 HTTPS URL；同一 Center 部署通常把两者设置为
同一 Origin，独立授权服务器可以使用不同 issuer。Artifact URL
签名使用独立的 `REMOTE_CONTROL_MCP_CENTER_ARTIFACT_SIGNING_SECRET`，不要复用 MCP
或 Admin Token。

启用混合认证后，Center 提供 `/.well-known/oauth-protected-resource`、
`/.well-known/oauth-authorization-server`、`/oauth/authorize` 和 `/oauth/token`。
ChatGPT Web 通过 Authorization Code + PKCE（S256）打开授权页；用户在 Console“连接凭证”
创建 MCP 凭证时选择可访问的机器及每台机器上的工具，再在授权页输入该凭证。Center 只把它换成短期 OAuth access/refresh token，并继续按源凭证的权限矩阵校验调用。Codex/CLI 可直接携带
`Authorization: Bearer <Console-issued MCP credential>`，仍使用同一权限矩阵。撤销源凭证会使其
OAuth access/refresh token 失效。Center 不读取或接受进程级共享 MCP Bearer 环境变量；
`REMOTE_CONTROL_MCP_CENTER_ADMIN_TOKEN` 仅用于 Console 管理 API，与 MCP 凭证用途分开。
ChatGPT 连接器不支持自定义 API Key，且生产授权元数据不提供 DCR registration endpoint，优先走
CIMD（`https://chatgpt.com/oauth/client.json`）。

Artifact signing supports a current and previous key simultaneously. New URLs
use the current `KID`; verification accepts both keys, so rotating the current
secret does not invalidate in-flight Viewer downloads. Keep the previous key
for at least the configured `RCM_CENTER_ARTIFACT_URL_TTL_SECONDS` and then
remove it in a later deployment.

Java 发布工作流使用 `java-vX.Y.Z` 作为 Git Tag，但升级活动中填写的版本保持
`vX.Y.Z`。因此生产 Center 默认使用 `RCM_CENTER_RELEASE_TAG_PREFIX=java-`，它只影响
Release URL 的 Tag 路径，不会改变 Agent 原始资产名。若改用普通 `vX.Y.Z` Tag，显式将
该变量设为空字符串。

Center 的 `GET /api/v1/admin/releases?include_prerelease=true` 在控制台进入时或显式刷新时读取
GitHub Releases API，成功结果缓存两分钟并以 `stale=true` 标记过期快照；没有后台固定轮询。目录只
接受 `java-v<semver>` 标签，忽略草稿，并仅返回预期的 Linux amd64/arm64、Windows amd64 Agent
ZIP 与 checksum 是否存在。创建升级活动时，Center 仍会再次按版本/平台下载并校验 `.sha256`，不会
信任前端提交的任意下载地址。

发布工作流的 JVM/React 门禁同时启动临时 PostgreSQL 16 服务容器，执行
`PostgresIntegrationTest`：真实运行 Liquibase、注册/心跳、幂等任务、租约领取、输出游标
续传、断点重放、工件写入和终态更新。GitHub Actions 是该集成门禁的唯一执行入口；开发机
不运行 Gradle 或 PostgreSQL 集成测试，也不会把离线 changelog 解析误报成 PostgreSQL 验收。

### 备份与恢复

正式切换前必须保存 PostgreSQL custom-format 备份，并在独立数据库完成一次恢复演练。仓库提供
跨平台脚本；数据库密码通过 `PGPASSWORD` 或受保护的 `.pgpass` 提供，不要作为命令行参数传入，
脚本不会把密码写入备份元数据：

```bash
export PGHOST=db.example.internal PGPORT=5432
export PGDATABASE=remote_control_mcp PGUSER=rcm_center PGPASSWORD='从 Secret 临时注入'
bash ./scripts/backup-postgres.sh
```

```powershell
$env:PGHOST = 'db.example.internal'
$env:PGPORT = '5432'
$env:PGDATABASE = 'remote_control_mcp'
$env:PGUSER = 'rcm_center'
$env:PGPASSWORD = '<从 Secret 临时注入>'
pwsh ./scripts/backup-postgres.ps1
Remove-Item Env:PGPASSWORD
```

脚本在发布备份前会用 `pg_restore --list` 校验归档索引，并生成同名 `.sha256` 和不含凭据的
`.json` 元数据。恢复时先创建隔离目标库，再使用 `pg_restore --exit-on-error --no-owner --no-acl`，
执行 `rcm-center --migrate`/`liquibase validate` 后检查 `rcm_agent`、`rcm_task`、输出游标和工件
表；确认应用读写和 Agent 心跳后才允许切换生产路由。生产 Center 可挂载独立持久卷并设置
`RCM_CENTER_ARTIFACT_STORE=filesystem`、`RCM_CENTER_ARTIFACT_ROOT`，或设置
`RCM_CENTER_ARTIFACT_STORE=http`、`RCM_CENTER_ARTIFACT_HTTP_BASE_URL`（必要时再注入
`RCM_CENTER_ARTIFACT_HTTP_TOKEN`）接入内部 HTTPS 对象网关。外部对象存储是可选后端，
默认的 filesystem 已经满足单 Center 生产运行；两种后端都实现同一个 `ArtifactStore`
接口，Agent/MCP 协议不感知后端差异。`/api/v1/readyz` 只要求 PostgreSQL 和一个可用的
持久字节后端，不要求必须存在 S3/MinIO/R2。备份目录已加入 `.gitignore`，对象文件还应由
卷/对象存储策略设置加密、保留期和访问审计。

Linux/Windows 原生二进制还会由 GitHub OIDC 生成 Artifact Attestation（工作流同时声明
`id-token: write`、`attestations: write` 和 `artifact-metadata: write`）；下载 Release 资产后，
可使用 `gh attestation verify <binary> -R Prodigalgal/remote_control_mcp` 校验构建来源。GitHub
仓库必须允许 Actions 写入 attestations；若仓库权限或计划不支持该能力，发布 Job 会失败，
不会降级为“只有 SHA-256 但没有来源证明”的生产 Release。

迁移由单独 Job 执行，不在 Center Pod 启动时抢迁移锁。原生 Center 也支持一次性入口：

```text
rcm-center --migrate
```

该入口只启动 Liquibase、完成 `validate/update` 后退出。变更集位于 `java/center/src/main/resources/db/changelog`，当前为 `001-core` 至 `029-artifact-gc-index`（包含 `027` 生命周期策略、`028` 主体归一化和 `029` TTL GC 索引）；仓库不使用 Flyway。

Java Center 的 memory 模式只用于协议回归/开发。生产必须同时设置
`RCM_CENTER_PERSISTENCE_MODE=postgres` 和
`RCM_CENTER_REQUIRE_DURABLE_STORAGE=true`，并设置
`RCM_CENTER_ARTIFACT_STORE=filesystem`、`RCM_CENTER_ARTIFACT_ROOT` 指向持久卷，或配置
`http` 后端的 HTTPS 对象网关；后者会让 `/api/v1/readyz` 在模式或工件存储错误时返回
503，即使进程本身仍能响应 `/api/v1/healthz`，从而阻止错误实例被 Service 接收流量。

文件传输的临时 spool 默认使用 JVM 临时目录；生产建议把
`RCM_CENTER_TRANSFER_SPOOL_ROOT` 指向工件持久卷上的独立子目录，并让
`RCM_CENTER_TRANSFER_MAX_SPOOL_BYTES` 小于该卷的可用容量。这样 4 GiB 单文件上限
不会被 512 MiB 的容器 `/tmp` 配额意外截断，实际仍受可用磁盘 reservation 保护。
同时可用 `RCM_CENTER_TRANSFER_STALL_TIMEOUT_SECONDS`（默认 120 秒）限制已建立连接后
连续无进展的读取；该值与 30 分钟绝对传输生命周期及进度节流独立。

### 工件 TTL 与定时清理

每个已发布工件都带有独立的 `expires_at`。默认 TTL 为 7 天；Web→Agent、文本/日志和
大文件可以分别通过 `RCM_CENTER_ARTIFACT_WEB_RETENTION_SECONDS`、
`RCM_CENTER_ARTIFACT_TEXT_RETENTION_SECONDS`、`RCM_CENTER_ARTIFACT_LARGE_RETENTION_SECONDS`
收紧或延长。`pinned` 工件不会被自动 GC，但仍可以由管理员显式删除。签名下载 URL 默认
只有 15 分钟有效，不能反向延长文件 TTL。

Center 不运行定时清理线程，也不靠高频轮询。Kubernetes 模板随 Center 部署一个可选的、
低频有界 `CronJob`（默认每 6 小时执行一次），使用同一份 Admin Secret 调用：

```text
POST /api/v1/admin/artifacts/gc?retentionDays=30&outputRetentionDays=7&limit=100
Authorization: Bearer <Admin Token>
```

其中 `retentionDays` 只用于旧任务投影工件；新的双向文件工件始终以数据库中的
`expires_at` 为准。每次最多处理 100 条，且 `concurrencyPolicy=Forbid`。GC 先删除字节对象，
对象删除成功后才删除元数据；对象网关暂时不可用时保留元数据并在下一轮重试。filesystem
后端额外清理一小时宽限期以前、且没有数据库引用的 `fs-v1` 孤儿对象。若不需要自动清理，
可以在部署 overlay 中移除 `artifact-gc-cronjob.yaml`，然后由外部运维平台按同一接口触发。

Agent 端可用 `REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS`（默认 120 秒，
5 秒至 1 小时）收紧已建立文件流的无进展等待；它与 30 分钟绝对传输上限独立。

审计记录默认只通过有界异步队列写入 PostgreSQL。保留清理由管理员或外部
维护作业显式触发，不运行定时轮询线程：

```text
POST /api/v1/admin/audit/gc?retentionDays=365&limit=500
Authorization: Bearer <Admin Token>
```

接口最多处理 5000 条/次，返回删除数量；任务、工件和机器数据不会因审计清理被删除。

### MCP 凭证与权限

在 Console“连接凭证”创建凭证时，逐台勾选 `command`、`desktop`、`browser`、`artifact`、
`task_read`、`task_cancel`。机器清单/详情在某台机器至少有一项授权时自动可见；任务读取、取消和工件访问会再次根据任务所属机器校验。明文凭证只在创建时返回一次，Center 只保存其哈希；撤销凭证会同时撤销由它换出的 OAuth 令牌。

当前单人管理使用同一个 Principal `owner`，凭证名称只用于区分客户端，不会创建额外用户。Admin Token 仅用于 Console 管理 API；不再配置全局 MCP Bearer。`expires_in_seconds=0` 表示不过期，其他值限制为 1 小时至 3650 天。迁移会把原 Principal 的有效机器授权转换为每张凭证的工具矩阵；旧通配授权只展开到当前已注册机器，重叠授权按最早期限收口，避免权限被意外延长。无法确认来源凭证的旧 OAuth 会话会撤销；ChatGPT 需要重新授权一次。

执行会话可通过 `GET /api/v1/admin/execution-sessions` 查看有界摘要，并用
`POST /api/v1/admin/execution-sessions/close`（提交 `principal_id` 与 `session_id`）显式关闭；
会话表只保存最新合同元数据，不保存 MCP Token、Cookie 或完整任务输出。

生产切换前先完成 PostgreSQL 备份，再执行当前 Liquibase migration Job；Center 只读取当前 Java 数据模型，不提供旧状态导入入口。

## Kubernetes

`deploy/k8s/java-center` 是 Java Center 的模板：

1. 复制 `secret.example.yaml` 到集群外的 Secret 管理流程，只填入 Console 管理用 Admin Token、Artifact 签名密钥和 PostgreSQL 连接信息；MCP 凭证由 Console 按客户端签发，不配置全局 MCP Bearer。不要把一次性 Enrollment Token 写入 Center Secret，也不要直接提交替换后的 Secret。
2. 在 `kustomization.yaml` 中把镜像改成实际签名的 Center Native Image 镜像。
3. 先运行 Argo CD `PreSync` migration Job，再滚动 Center Deployment。
4. 验收 `/api/v1/healthz`、`/api/v1/readyz`、MCP `initialize`/`tools/list`、Agent 注册/轮询、长任务超时和断线恢复。

### 生产 Overlay 预检

仓库中的 `deploy/k8s/overlays/java-production` 只是一份公开、占位安全的
模板，不应直接同步到集群。将它复制到集群外的私有部署层，替换三个
`remote-control-mcp-*` 域名、Center/Console 镜像的 SHA-256 digest、Center
版本和外部 Secret 后，先执行：

```bash
bash scripts/validate-java-production-overlay.sh --strict /path/to/private/java-production
kustomize build /path/to/private/java-production > /tmp/rcm-java-rendered.yaml
```

预检会拒绝 `example.invalid`/`replace-me`/旧模板版本、可变镜像 tag、重复或格式错误的
路由主机名，以及内联 Kubernetes Secret；若本机有 `kustomize` 或 `kubectl`，还会检查最终
渲染结果是否仍含占位符并确认镜像按 digest 固定。预检通过也不等于生产切换授权，仍需完成
迁移 Job、旁路路由、ChatGPT Web MCP、Agent canary、备份恢复和回滚验收。

云上双区集群可先使用 `deploy/k8s/overlays/java-production`：它把镜像切换到
`ghcr.io/prodigalgal/remote-control-mcp-{center-java,console}` 的版本标签、三个
`remote-control-mcp-*.example.invalid` 占位路由（MCP、Agent、控制台）并启用 Agent WebSocket
唤醒通道。正式同步前必须在集群外的部署参数/私有 overlay 中替换为真实域名，并把镜像标签改为已
验证 Release 的 digest；Secret 管理流程创建 `remote-control-mcp-secrets`，公共 overlay
不得包含真实域名、Token 或数据库密码。

React 控制台使用独立的 `web/Dockerfile` 镜像和 `console.yaml` Deployment。Nginx 只托管静态资源，并把同源 `/api/` 反向代理到 Center；因此 Admin Token 仍只在浏览器内存中，生产无需开启宽泛 CORS。控制台域名与 MCP/Agent 域名分开，均保留 `remote-control-mcp-*` 前缀。

### CI → GitOps CD

`.github/workflows/java-release.yml` 的 `gitops-deploy` Job 只在完整 Native、镜像和
GitHub Release 成功后运行。`main` 推送产生的不可变预发布版本更新私有
`remote-control-mcp-staging` overlay；`java-vX.Y.Z` 稳定 Tag 更新
`remote-control-mcp-production` overlay。Job 查询 GHCR 多架构镜像的 manifest digest，
只改写私有 GitOps 仓库中的 `center.yaml`、`migration-job.yaml` 和 `console.yaml`，提交后由
Argo CD 的既有 Application 自动同步；它不直接持有 kubeconfig，也不在应用仓库写入生产域名或 Secret。

启用该 Job 只需要在应用仓库配置一个布尔变量 `RCM_GITOPS_ENABLED=true`，以及两个 Actions
Secret：`RCM_GITOPS_REPOSITORY`（例如组织/私有 GitOps 仓库名）和
`RCM_GITOPS_SSH_KEY`（仅允许该 GitOps 仓库写入的 Deploy Key 私钥）。Deploy Key 不应复用
个人 PAT；轮换时先在 GitOps 仓库新增 Deploy Key，再更新应用仓库 Secret，最后删除旧 Key。
如果没有启用变量，构建/Release 仍正常完成，但 CD Job 会明确跳过。

模板域名均使用 `remote-control-mcp-*` 示例名；真实域名只应在部署层注入，不进入源码、日志、指标或前端构建产物。

Actions 产出的工件可在需要时下载到临时目录，再运行短时烟测，验证真实 HTTP 启动和 MCP 工具发现；
烟测本身不编译：

```powershell
./scripts/smoke-java.ps1 -CenterBinary <downloaded-center-binary> -Port 18181
```

Linux shell 版本支持 `./scripts/smoke-java.sh /path/to/downloaded/rcm-center`，并会保留 MCP
`Mcp-Session-Id` 再调用 `tools/list`。

若要验证 Agent 的完整生命周期（一次性 Enrollment Token 注册、注册后删除该令牌、使用
identity 文件建立日常心跳、Center 判定在线、创建命令任务并核对输出），Windows 可运行：

```powershell
./scripts/smoke-java-agent.ps1 `
  -CenterBinary ./dist/java-windows-amd64/center/rcm-center.exe `
  -AgentBinary ./dist/java-windows-amd64/agent/rcm-agent.exe `
  -Port 18182
```

该脚本同样只使用内存模式、临时令牌和临时状态目录；成功输出
`registration=ok`、`identity_without_enrollment_token=ok` 和 `command=ok` 后才算原生 Agent
工件通过本地端到端门禁。

Linux 目标使用同一契约：

```bash
bash ./scripts/smoke-java-agent.sh ./rcm-center ./rcm-agent 18183
```

发布工作流会在 Linux amd64/arm64 目标构建后以及 Windows amd64 构建后自动执行 Center
MCP 和 Agent 端到端烟测；任一目标烟测失败都不会上传 Release 工件。
Agent 烟测同时在注册后的空闲/命令阶段采样 Agent 工作集，生成仅含 PID、峰值 RSS 和样本数的
临时 resource JSON；该报告作为 CI 工件保存，不进入公开 Release，也不包含令牌、命令或路径。

烟测使用临时内存模式和临时令牌，检查 `/api/v1/healthz`、MCP
`initialize`/`tools/list`，并在退出时终止临时 Center；不会读取或修改生产 Secret。

## 异步性门禁

- `command`、`desktop`、`browser` 只创建任务并返回 `task_id`；不在 MCP 请求线程等待进程完成。
- MCP 使用官方异步 Server，工具处理在专用虚拟线程执行器上调度。
- Agent/Admin Servlet 控制器返回 `CompletableFuture<ResponseEntity<?>>`；认证后的 JDBC、任务写入、输出和工件处理统一提交到可关闭的虚拟线程执行器，容器请求线程只负责解析和挂起响应。
- `/readyz` 的 PostgreSQL 探针同样异步执行；数据库不可达或 Liquibase 核心表不存在时返回 503，避免迁移未完成就接收流量。
- Agent 的进程等待、stdout/stderr drain 和 Center 上传完全分离：子进程只写有界磁盘 spool，HTTP 使用 `sendAsync`，超时线程可以随时终止无输出进程；输出上报按游标幂等并在网络抖动时退避重试。
- 无超时任务使用可恢复日志文件，但仍受 `REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES` 硬上限保护；超过上限会终止该任务、保留前缀并以 `failed + output_truncated` 收口，避免离线期间无限占满磁盘。
- Agent 重连使用指数退避和抖动；Center 租约过期后重新排队，不复制逻辑任务。
- 控制台 API 只加载分页摘要，长输出按 cursor 获取；Admin Token 只保留在当前页面内存。
- Agent 空闲时只保留一个有界 HTTPS 长轮询请求和少量虚拟线程；任务、取消、配置或升级事件到达即返回，服务端 deadline 结束空闲请求。任务并发、输出磁盘上限和 Browser 默认超时均有配置边界。无超时任务额外由独立文件事件看门器监控日志，离线期间超过上限会终止并收口，避免用“可靠恢复”换取无限资源占用。

如果这些门禁未全部通过，发布仍停留在迁移环境，不切换生产流量。

## Agent 资源预算

默认值按 1C/1G 级别终端设计：空闲 Agent 只保持一个最长 25 秒的 HTTPS 长轮询请求，不运行固定 5 秒心跳；事件到达或服务端 deadline 才结束请求，断线时才使用指数退避。`MAX_CONCURRENCY=1` 限制同时子进程数，`MAX_BROWSER_WORKERS=1` 再对浏览器适配器做独立上限；每任务 stdout/stderr 默认为 64 MiB，普通任务共享 `MAX_AGGREGATE_OUTPUT_BYTES` 聚合 spool 上限（默认随并发增长但不超过 256 MiB）；输出上传使用 16 KiB 分片。每个运行中的任务另外由任务级监督器限制进程树（默认 32）、合同/任务墙钟时长，并可通过 `MAX_RSS_BYTES`（Linux procfs）、`MAX_CPU_SECONDS` 和采样间隔启用资源硬边界；在 Linux 可将预创建的 cgroup v2 目录通过 `REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH` 交给每个任务，Agent 无法附加时 fail-closed；Windows 由 JDK 进程树监督配合内置启动任务，暂不伪造 Job Object 已启用。command 任务和 browser-agent supervisor 共享 `MAX_TOTAL_CHILD_PROCESSES` Agent 级总进程预算（默认 `min(256,max(32,MAX_CONCURRENCY*32))`，范围 1–4096），超额任务在启动后立即 fail-closed，现有任务结束即归还名额；desktop-companion 不进入该预算。超限会终止整棵子进程树并回传明确失败原因，不会给空闲 Agent 增加轮询。Browser 任务无显式超时时默认 300 秒，最长 24 小时；配置 `REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR` 后，Playwright/Patchright/Comoufox Worker 使用目标机持久 Profile，Center 只看到脱敏 origin/path 标记；引擎、浏览器和 headless 选项均为 Agent 本地环境配置。引用失效时 Worker 返回一次新的有界 snapshot 建议，不会盲目重放动作。durable 日志看门器由 fsnotify/WatchService 文件事件驱动；Desktop companion 另有最多 4 个并发 IPC 请求和 16 个活动启动进程，并通过文件锁保证单实例；没有用户会话时 command-agent 只返回明确的 companion 不可用错误。聚合上限达到时普通任务继续执行并标记输出截断，只有 durable 任务达到其硬上限才会终止，确保节约资源不会把可恢复任务静默杀掉。确需并行时逐台提高并发并观察 RSS、磁盘和 Center 延迟，不建议在小规格主机上直接设置 32 个槽位或 1 GiB 输出上限。
### Artifact deduplication and optional compression

The Center keeps the original SHA-256/size in PostgreSQL and can optionally
store equal content once. These switches are off by default so artifact
storage remains independent from the Native component release lifecycle:

```text
RCM_CENTER_ARTIFACT_DEDUP_ENABLED=true
RCM_CENTER_ARTIFACT_COMPRESSION=off   # off or gzip; gzip is disk-spooled
RCM_CENTER_TRANSFER_SPOOL_ROOT=/var/lib/remote-control-mcp-center/transfer
RCM_CENTER_ARTIFACT_RETENTION_SECONDS=604800
RCM_CENTER_ARTIFACT_WEB_RETENTION_SECONDS=604800
RCM_CENTER_ARTIFACT_LARGE_RETENTION_SECONDS=259200
RCM_CENTER_ARTIFACT_TEXT_RETENTION_SECONDS=1209600
```

控制台生命周期策略支持 `ephemeral`、`task-bound` 和 `pinned`；固定为
`pinned` 的工件不会因 `expires_at` 到期而被公共 URL 拒绝，但仍只能由管理员显式删除。

Enable gzip only when the object-store gateway and the PVC have enough
temporary capacity. The opaque `gzip-v1/...` key is decoded by Center, so
Agents and MCP URLs continue to use the original file hash and byte count.
