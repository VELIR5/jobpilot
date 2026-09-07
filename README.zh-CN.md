# JobPilot

[![CI](https://github.com/VELIR5/jobpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/VELIR5/jobpilot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![版本](https://img.shields.io/github/package-json/v/VELIR5/jobpilot)](https://github.com/VELIR5/jobpilot)

[English](README.md) · [在线演示](https://job.vcrelay.com:8443) · [Issues](https://github.com/VELIR5/jobpilot/issues)

JobPilot 是一个结合简历信息的岗位匹配与投递辅助工具，帮助求职者完成
简历解析、求职偏好设置、真实岗位搜索、匹配证据查看，以及在用户明确
确认后准备或提交投递。

仓库包含 Next.js 网页端和原生微信小程序端。两个客户端共用服务端领域
逻辑和 API 契约。

> 在线演示地址只是一个部署端点，不代表可用性或邮件送达保证。岗位数据、
> 岗位源内容和邮件送达状态都必须由用户独立复核。

## 立即使用

打开公网网页端：

**[https://job.vcrelay.com:8443](https://job.vcrelay.com:8443)**

使用邮箱登录，上传简历，填写求职偏好，然后查看匹配岗位，再决定是否投递。

部署后的公网版本可以通过
[`https://job.vcrelay.com/api/health`](https://job.vcrelay.com/api/health) 查看发布健康状态。

## 功能范围

- 邮箱访问和签名 HttpOnly 浏览器会话。
- 简历上传，以及 PDF/DOCX 文本提取和用户确认。
- 目标城市、岗位方向、行业和工作方式设置。
- 后台岗位库从管理员配置的公开 ATS、JSON、RSS 或 Atom 来源定时更新，并进行确定性规范化、过期处理、去重和本地筛选。
- 也可选用后台联网采集器，以通用城市和岗位方向搜索扩充岗位库；它不会把用户简历发送给采集器。
- 明确区分“可邮件投递岗位”和“官方入口手动投递岗位”。
- 投递任务、幂等控制、状态历史和按用户隔离的数据记录。
- 可选 Google OAuth，以及通过 Resend 的平台统一邮件代发。
- 微信小程序登录、简历、偏好、岗位匹配和投递记录页面。

## 安全边界

JobPilot 选择如实返回较少结果，而不是用虚构结果补足数量。

- 外部岗位源和岗位内容都被视为不可信输入。
- 岗位必须通过配置的来源、URL、城市和结构校验，才能成为正式结果。
- 系统不会猜测招聘邮箱、公司、岗位、URL、任职条件或送达结果。
- 没有直接核验招聘邮箱的岗位只能作为手动或官方入口操作，不能自动发邮件。
- 真实邮件投递必须经过用户选择、最终确认、有效发信配置和幂等任务控制。
- 测试和 CI 使用模拟适配器，不发送真实邮件，也不读取用户简历进行搜索。
- 不绕过登录、验证码、访问频率限制、访问控制或招聘网站规则。

## 环境要求

- Node.js 22.5 或更高版本。内置 SQLite 运行时要求 Node 22。
- npm，以及安装锁定依赖所需的网络连接。
- 自托管时，需要由管理员在 `config/job-feeds.json` 配置至少一个公开岗位源，或明确配置后台联网采集器。
- 启用 Google 登录时需要 Google Cloud OAuth 凭据。
- 启用微信登录交换时需要微信小程序凭据。
- 启用平台统一代发时需要 Resend 发信凭据。

## 本地开发

```powershell
npm ci
Copy-Item .env.example .env
# 使用你自己的本地密钥填写 .env
npm run db:push
npm run dev
```

打开 `http://localhost:3000`。`.env`、数据库、上传文件和日志都被 Git
忽略，不得提交。

自托管时，岗位库调度器使用以下配置：

| 变量 | 用途 |
| --- | --- |
| `JOBPILOT_SESSION_SECRET` | 签名浏览器和 Bearer 会话，应使用长随机值。 |
| `JOBPILOT_ACCESS_PASSWORD_HASH` | 进入登录页的共享访问密码哈希。 |
| `JOBPILOT_INVITE_PASSWORD_HASH` | 注册用户时使用的邀请码哈希。 |
| `JOBPILOT_CATALOG_REFRESH_MINUTES` | 后台更新间隔，默认 60 分钟。 |
| `JOBPILOT_CATALOG_STALE_HOURS` | 岗位未再次出现后仍可检索的时间，默认 48 小时。 |
| `JOBPILOT_CATALOG_MAX_ACTIVE_JOBS` | 岗位库有效岗位上限，默认 5000。 |
| `JOBPILOT_JOB_FEEDS` | 可选的内联 JSON 岗位源配置；未设置时使用 `config/job-feeds.json`。 |

全部变量和安全说明见 [`.env.example`](.env.example)。管理员岗位源配置见
[`docs/JOB_CATALOG.md`](docs/JOB_CATALOG.md)。使用线上服务的普通用户不需要配置这些值。

## 生产启动

```powershell
npm ci
npm run db:push
npm run build
npm run start
```

`next start` 启动时只加载一次生产构建。修改服务端代码或环境配置后，必须
重新构建并重启进程。部署时应使用 HTTPS 和独立的访问控制；隧道只提供传输，
不能替代身份认证和租户隔离。

服务启动后会自动运行岗位库调度器。也可以交给进程管理器单独运行：

```powershell
npm run catalog:worker
```

## 微信小程序

1. 将 [`miniapp/`](miniapp/) 导入微信开发者工具。
2. 将 `project.config.json` 中的占位 AppID 换成自己的 AppID。
3. 在 [`miniapp/config.js`](miniapp/config.js) 中设置生产 HTTPS API 地址。
4. 在微信平台配置合法 request/upload 域名。
5. 真机测试前运行 `npm run check:miniapp`。

小程序包不包含邮件密钥、数据库、简历或服务端会话密钥。微信
真实登录、上传、页面跳转和设备验收仍必须在微信开发者工具和真机中完成。

## 许可证和安全

JobPilot 使用 [MIT License](LICENSE) 发布。安全问题请私下联系仓库维护者。
