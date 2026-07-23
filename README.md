# AI Agent 部署工程

AI 公司 Agent 自动化部署脚本和配置仓库。

## 目录结构

| 路径/文件 | 说明 |
|-----------|------|
| `http/` | HTTP 部署服务和注册脚本 |
| `binaries/` | 预编译二进制文件 |
| `v0.6.1/` | OpenClaw v0.6.1 版本归档 |
| `deploy-agent.sh` | Agent 部署主脚本 |
| `deploy-and-register.sh` | 部署并注册 Agent 到管理平台 |
| `register-agent.py` | Agent 注册 API 客户端 |
| `setup-openclaw-ubuntu.sh` | Ubuntu 系统 OpenClaw 安装脚本 |
| `patrol-register.sh` | 定时巡检注册脚本 |
| `quick-deploy.sh` | 快速部署入口 |
| `deploy-agent.service` | systemd 服务单元文件 |
| `openclaw-baseline.tar.gz` | OpenClaw 基线包（大文件，gitignored） |

## 使用方式

```bash
# 快速部署新 Agent
bash quick-deploy.sh

# 部署并注册
bash deploy-and-register.sh <agent-name>

# 注册已有 Agent
python3 register-agent.py --name <agent-name>
```

## 🗺️ 代码结构

本项目使用 [Graphify](https://github.com/Graphify-Labs/graphify) 维护代码知识图谱。

> 📝 待 graphify 完成后填入实际数据。

- 📊 [交互式图谱](graphify-out/graph.html)（待生成）
- 📝 [结构报告](graphify-out/GRAPH_REPORT.md)（待生成）

### 关键节点

| 节点 | 类型 | 连接数 | 说明 |
|------|------|--------|------|
| _（待 graphify 完成后填入）_ | | | |

### 常用查询

```bash
graphify explain <模块路径>          # 理解模块上下游
graphify path <源> --to <目标>        # 追踪调用链
```
