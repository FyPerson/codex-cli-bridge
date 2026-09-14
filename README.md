# Codex CLI Bridge

用于 Windows PowerShell 的 Codex CLI 审核桥接脚本，可通过本机订阅、用户配置的 API 或 SSH 远端执行审核。

## 使用

需要已安装 Codex CLI。订阅模式请先自行登录。

```powershell
& .\scripts\invoke_codex.ps1 -Prompt "审核这个方案" -TaskType spec-critique
```

API 模式：复制 `.env.example` 为项目根目录的 `.env`，填写 `CODEX_API_KEY` 和 `CODEX_API_BASE_URL`，然后显式传入 `-Api`。也可通过 `-ApiEnvFile` 指定配置文件。

远端模式：自行配置 SSH 密钥认证，使用 `-Remote -RemoteTarget user@remote-host`，或设置 `CODEX_BRIDGE_REMOTE_TARGET`。首次运行可加 `-RemotePreflight` 检查连通性。

详细参数、审核流程和已知限制见 [SKILL.md](SKILL.md)。该技能包含可按团队需求调整的审核流程约定。

## 凭据与输出

- 此副本已移除原使用者的个人路径、SSH 主机信息和服务商配置，且不包含原仓库的 Git 历史。
- `.env`、认证文件、私钥和常见运行日志已加入 `.gitignore`。
- API 模式仍会临时将密钥写入系统临时目录下的 `codex-bridge-workspace/api-home/auth.json`，并在结束时尝试清理；强制终止或清理失败可能残留。
- 审核 prompt、结果及会话记录可能含有传入的项目内容；分享前应自行检查。
- `.env.example` 中的值为空，需要自行配置；它不包含可用凭据。
