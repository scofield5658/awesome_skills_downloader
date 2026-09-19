# awesome_skills_downloader

## Quick Start

### 1. 确认仓库列表

编辑 `repos.txt`，每行一个 GitHub 地址。`#` 开头的行和空行会被忽略。

### 2. 执行下载

**Linux / macOS**（依赖 `curl`；解压需要 `unzip` 或 `python3`）

```bash
./download-repos.sh
```

**Windows PowerShell**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\download-repos.ps1
```

**Windows CMD**（需要系统自带的 `curl.exe`）

```bat
download-repos.cmd
```

### 3. 查看结果

代码会解压到 `output/{groupName}-{repoName}/`，例如：

- `vercel-labs/skills` → `output/vercel-labs-skills`
- `anthropics/skills` → `output/anthropics-skills`

重复执行会覆盖同名目录。

### 可选环境变量

| 变量 | 说明 |
| --- | --- |
| `OUTPUT_DIR` | 输出目录，默认项目根下的 `output` |
| `REPOS_FILE` | 仓库列表路径，默认 `repos.txt` |
| `DRY_RUN=1` | 只打印将要下载的地址，不落盘 |
| `GITHUB_TOKEN` | 访问私有仓或提高 API 限额时可选 |

代理走系统环境变量 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`。
