# AI Unlock Checker

检测服务器 IP 对主流 AI 服务的可访问/解锁情况。

这个脚本适合在 VPS、云服务器、住宅代理出口机上直接运行。它不需要 API Key，不会登录账号，只通过公开入口和未认证 API 的 HTTP 响应判断网络可达性、地区限制和浏览器挑战。

脚本会在结果顶部显示出口 IP 的参考地区、城市、ASN/运营商。这个地区来自第三方 IP 库，只能作为参考；AI 平台仍可能根据账号地区、付款方式、风控、ASN、Cookie 和浏览器状态做不同判断。

普通输出会先显示中文解锁摘要，例如：

```text
AI 服务            状态     地区
OpenAI             解锁     Singapore / Southeast / Singapore
Gemini             解锁     Singapore / Southeast / Singapore
Meta AI            不解锁   Singapore / Southeast / Singapore
```

摘要里只有底层结果为 `UNLOCKED` 时显示 `解锁`；`REACHABLE`、`LOCKED`、`FAILED` 都显示 `不解锁`，详细原因会在后面的表格里列出。

## 支持检测

- OpenAI API
- ChatGPT Web
- Claude Web
- Anthropic API
- Gemini Web
- Google AI API
- Google AI Studio
- Microsoft Copilot
- Perplexity
- Grok
- Meta AI
- DeepSeek Chat
- DeepSeek API
- Mistral Le Chat
- Mistral API
- Poe
- Hugging Face Chat

## 快速使用

```bash
curl -O https://raw.githubusercontent.com/huihuang8/ai-unlock-checker/main/ai-unlock-checker.sh
bash ai-unlock-checker.sh
```

或者克隆仓库后运行：

```bash
git clone https://github.com/huihuang8/ai-unlock-checker.git
cd ai-unlock-checker
bash ai-unlock-checker.sh
```

## 参数

```bash
bash ai-unlock-checker.sh --help
```

常用参数：

```bash
# 输出 JSON，方便接入面板或监控
bash ai-unlock-checker.sh --json

# 调大超时时间
bash ai-unlock-checker.sh --timeout 20 --connect-timeout 10

# 禁用颜色
bash ai-unlock-checker.sh --no-color

# 不查询 IP 地区，只检测服务
bash ai-unlock-checker.sh --no-geo
```

## 结果说明

- `UNLOCKED`：返回了该服务的预期响应，通常表示网络和地区可用。
- `REACHABLE`：服务可达，但可能需要浏览器验证、登录或进一步人工确认。
- `LOCKED`：响应中检测到明显地区/位置限制。
- `FAILED`：连接失败、超时、TLS 错误或服务端返回异常状态。

注意：Web 端服务经常启用 Cloudflare、风控或登录态检查。`REACHABLE` 不等于账号一定可用，但说明服务器出口至少能触达服务入口。
中文摘要为了方便快速判断，会把 `REACHABLE` 也归为 `不解锁`；如果你想看它是 Cloudflare 挑战、地区限制还是连接失败，请看详细表格里的 `Result` 和 `Note`。

## 服务器环境要求

- Bash
- curl

Debian/Ubuntu 安装 curl：

```bash
sudo apt update
sudo apt install -y curl
```

CentOS/RHEL 安装 curl：

```bash
sudo yum install -y curl
```

## 免责声明

本工具只做网络连通性和地区限制检测，不绕过任何服务的访问控制、登录验证或使用条款。检测结果会随服务政策、CDN 节点、服务器 IP 信誉和网络环境变化。
