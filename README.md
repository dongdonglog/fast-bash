# fast-bash · 中文进程占用实时排障工具

> 一打开就知道是谁占用了 CPU / 内存 / 磁盘 IO / 网络。
> 以进程为核心，专为「出问题时快速定位」设计，纯 Bash、零依赖、开箱即用。

## 为什么做这个

排查服务器问题时，`top` / `htop` 数据全、但**英文、信息过载**；
`glances` / `netdata` 又要装一堆依赖。
`fast-bash` 的目标很朴素：**一条命令，打开就是一张按占用排序的中文进程表**，
一眼看出是哪个进程在拖垮机器。

## 快速开始

**方式一：一键安装（推荐，需要 root）**

```bash
curl -fsSL https://raw.githubusercontent.com/dongdonglog/fast-bash/main/install.sh | sudo bash

# 安装后直接运行命令（不是 bash smon.sh）
smon -h        # 先确认可用
```

**方式二：克隆仓库，在仓库目录里直接跑**

```bash
git clone https://github.com/dongdonglog/fast-bash.git && cd fast-bash
bash smon.sh   # 注意：只有在仓库目录内才能这么跑
```

> ⚠️ 安装后请使用 `smon` 命令。`bash smon.sh` 只在当前目录存在 smon.sh 时有效（即方式二的仓库目录）。
> 若提示 `smon: command not found`，见文末「安装后无法运行」排查。

## 使用

```bash
smon            # 实时进程表（默认按 CPU 排序，每 2 秒刷新）
smon -m         # 按内存排序
smon -d         # 按磁盘 IO 排序
smon -n         # 按网络排序
smon -i 1       # 刷新间隔改为 1 秒
smon -j         # 输出一次 JSON（供脚本 / Web 面板对接）
smon --json     # 同上（长选项）
smon --serve    # 启动 Web 面板（浏览器可视化，默认 8080）
smon --serve 9000   # 指定端口
smon -h         # 帮助
```

实时模式下快捷键：`c` 按 CPU、`m` 按内存、`d` 按磁盘 IO、`n` 按网络、`q` 退出。

## Web 面板（`--serve`）

一条命令起一个本地 Web 可视化面板（需要 `python3`，Linux 服务器一般自带）：

```bash
smon --serve 8080
# => smon Web 面板: http://0.0.0.0:8080/  (Ctrl+C 退出)
```

浏览器打开 `http://<服务器IP>:8080/` 即可看到中文仪表盘：

- 顶部概况卡片：CPU / 内存 / 根分区 / 进程数（带进度条，超高标红）
- 下方完整进程表：支持点击表头排序、红黄高亮
- 底部诊断建议（同 CLI 的异常告警）
- 后台每 3 秒自动采样一次，前端每 3 秒刷新

> 原理：`smon --serve` 启动一个轻量 Python HTTP 服务器，后台线程持续调用 `smon -j` 缓存最新 JSON，`/api` 接口即时返回，浏览器零依赖（无 CDN）。

## 界面

```
 系统概况
  主机: web-01 | 系统: Linux | 运行: up 3 days, 2 hours
  CPU  32%   负载 1.2/0.8/0.6   内存  8400/16384MB   磁盘/ 3%

PID       CPU%  内存   读IO   写IO 连接 收↓  发↑  用户     命令
1234        45%   1.2G   8.4M   12M    12  2.1M 0.5M app      java -jar gateway.jar
 987         8%    48M   0.1M  0.2M    34     0    0 www-data nginx: worker process
 ...
  [排序: cpu]  c=CPU  m=内存  d=磁盘IO  n=网络  q=退出
  ⚠ 诊断建议
    1分钟负载 9.5 超过核数(8)，疑似高并发或 IO 阻塞
    根分区使用 92% 接近满，清理: du -sh /* 2>/dev/null | sort -rh | head
```

- **进程主导**：下方全部是进程，按占用排序，一眼定位"谁在吃资源"。
- **占用高亮**：占用 ≥90% 标红加粗、≥60% 标黄、正常绿色。
- **诊断建议**：检测到 CPU/内存/负载/磁盘/IO/网络异常时，自动给出中文排查命令。
- 顶部一行系统概况：CPU、负载、内存、根分区使用率。

## 数据来源与说明

| 指标 | Linux 数据来源 | 说明 |
|------|---------------|------|
| CPU% | `/proc/<pid>/stat`（间隔采样差值） | 单核百分比，100% = 吃满一核 |
| 内存 | `/proc/<pid>/status` 的 VmRSS | 精确物理内存占用 |
| 磁盘 IO | `/proc/<pid>/io`（读写字节差值） | **需要 root** 才能读其他用户进程 |
| 网络连接数 | `ss -p` 统计每进程 TCP/UDP 连接数 | 无需 root 即可统计 |
| 网络带宽 | `nethogs -t`（root + 已安装时自动启用） | 显示每进程 收↓/发↑ KB/s，无则降级为连接数 |

### JSON 输出（`-j` / `--json`）

供脚本、CI、Web 面板对接的一次性采样，结构：

```json
{
  "host": "web-01",
  "os": "Linux 6.1.0",
  "cpu": { "percent": 32, "load1": 1.2, "load5": 0.8, "load15": 0.6 },
  "memory": { "total_mb": 16384, "used_mb": 8400, "percent": 51 },
  "disk_root_percent": 3,
  "processes": [
    { "pid": 1234, "cpu": 45, "rss_mb": 1228, "read_kbs": 8600,
      "write_kbs": 12200, "net": 12, "user": "app", "cmd": "java -jar gateway.jar",
      "recv_kbs": 2150, "sent_kbs": 512 }
  ],
  "alerts": [ "根分区使用 92% 接近满，清理: du -sh /* 2>/dev/null | sort -rh | head" ]
}
```

```bash
smon -j | python3 -m json.tool     # 校验并美化
```

### 阈值说明

- 高亮：CPU / 内存 / 磁盘 / 网络占用 ≥90% 红、≥60% 黄（磁盘按绝对速率 50MB/s / 10MB/s，网络连接 500 / 200）。
- 诊断触发：CPU≥90%、内存≥90%、负载>核数、根分区≥85%、磁盘读≥50MB/s、网络连接≥500。

### macOS 降级支持

macOS 没有 `/proc`，自动降级为 `ps` 采集，**只提供 CPU% 和内存**，
磁盘 IO / 网络连接数显示 `0`。以 Linux 服务器为主要目标平台。

## 常见问题

**安装后运行 `smon` 提示 `command not found`？**

1. 确认已装到哪：`ls -l /usr/local/bin/smon`
2. 确认该目录在 PATH：`echo $PATH | tr ':' '\n' | grep usr/local/bin`
   - 苹果芯片(M1/M2/M3)的 macOS 若 `/usr/local/bin` 不在 PATH，可改用：
     `sudo INSTALL_DIR=/opt/homebrew/bin bash install.sh`（或用 `brew`）
3. 临时生效：`export PATH="/usr/local/bin:$PATH"`，再试 `smon -h`

**`bash smon.sh: No such file or directory`？**

那是没在仓库目录里跑。安装后请直接用 `smon`；想用文件方式运行，先 `cd` 到有 `smon.sh` 的目录。

## 项目结构

```
fast-bash/
├── smon.sh       # 主脚本（CLI 中文进程表 + JSON + --serve 启动 Web）
├── web.py        # Web 面板：Python HTTP 服务器 + 内嵌前端（--serve 调用）
├── install.sh    # curl 一键安装到 /usr/local/bin
└── README.md
```

## 开发

```bash
# 语法与静态检查
bash -n smon.sh
shellcheck smon.sh        # 0 警告

# 本地试跑（macOS 走降级分支）
bash smon.sh
```

## 计划

- [ ] 自定义阈值配置（环境变量 / 配置文件）
- [ ] 远程批量监控多台服务器
- [ ] 发布到 GitHub Actions 自动构建 / shellcheck

## 许可

MIT
