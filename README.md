# PromptMeet 即录

<p align="center">
  <img src="https://img.shields.io/badge/Python-3.8+-blue.svg" alt="Python Version">
  <img src="https://img.shields.io/badge/Vue.js-3.0+-green.svg" alt="Vue Version">
  <img src="https://img.shields.io/badge/FastAPI-0.104+-red.svg" alt="FastAPI Version">
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License">
</p>

## 📌 项目概述

**PromptMeet** 是一款基于大语言模型和多模态处理技术的智能化实时会议纪要与日程同步系统。

### 🎯 核心特性

- **🎤 实时语音转录**：基于 OpenAI Whisper 的高精度中文语音识别
- **🧠 智能纪要生成**：利用 DeepSeek 大模型自动生成结构化会议纪要
- **📋 任务自动提取**：智能识别会议中的任务、截止日期和负责人
- **🖼️ 截图OCR识别**：支持会议过程中的屏幕截图文字提取
- **💬 实时AI问答**：会议过程中可随时向AI助手提问获得即时回答
- **🔗 多平台同步**：支持同步至 Notion、飞书等主流协作平台
- **📧 邮件自动发送**：会议结束后自动发送纪要邮件给相关人员

### 🏗️ 技术架构

- **前端**：Vue.js 3 + Vite，提供现代化的用户界面
- **后端**：FastAPI + Python，高性能异步API服务
- **AI引擎**：DeepSeek + OpenAI，提供强大的语言理解能力
- **数据存储**：MySQL，可靠的关系型数据库
- **消息通信**：WebSocket，实现实时双向通信

---

## 🚀 快速开始

### 📋 系统要求

- **操作系统**：Windows 10+、macOS 10.15+、Linux
- **Python**：3.8 或更高版本
- **Node.js**：16.0 或更高版本
- **MySQL**：5.7 或更高版本
- **内存**：建议 8GB 以上

### 📥 项目安装

#### 1️⃣ 克隆项目

```bash
git clone https://github.com/your-username/PromptMeet.git
cd PromptMeet
```

#### 2️⃣ 后端环境配置

```bash
# 进入后端目录
cd backend

# 创建Python虚拟环境
python -m venv venv

# 激活虚拟环境
# Windows
venv\Scripts\activate
# macOS/Linux  
source venv/bin/activate

# 更新pip到最新版本
python -m pip install --upgrade pip

# 安装Python依赖
pip install -r requirements.txt
```

#### 3️⃣ 前端环境配置

```bash
# 进入前端目录
cd frontend

# 安装Node.js依赖
npm install

```

#### 4️⃣ 数据库初始化

```bash
# 确保MySQL服务正在运行
# 创建数据库（如果不存在）
mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS meeting_sessions CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 数据库表会在首次运行后端服务时自动创建
```

### 🏃‍♂️ 运行项目

#### 启动后端服务

```bash
cd backend

# 确保虚拟环境已激活
# Windows
venv\Scripts\activate
# macOS/Linux
source venv/bin/activate

# 启动FastAPI服务
python main_service.py

# 服务将在 http://localhost:8000 启动
```

#### 启动前端服务

```bash
cd frontend

# 启动Vue开发服务器
npm run dev



# 前端将在 http://localhost:5173 启动
```

#### 🎉 访问应用

打开浏览器访问 [http://localhost:5173](http://localhost:5173) 即可使用 PromptMeet！

---

## 🔑 API Key 配置

完整使用项目需要重命名 `.env.example` 文件为 `.env` 并配置对应接口。在项目根目录或 `backend/` 目录下创建 `.env` 文件，添加以下配置：

### 1. DeepSeek API（必需）

DeepSeek 是主要的AI推理服务提供商。

**获取方法：**
1. 访问 [DeepSeek开放平台](https://platform.deepseek.com/)
2. 注册并登录账号
3. 进入控制台 → API Keys
4. 创建新的API Key
5. 复制API Key和Base URL

**配置项：**
```env
DEEPSEEK_API_KEY=your_deepseek_api_key_here
DEEPSEEK_API_BASE=https://api.deepseek.com
```

### 2. OpenAI API（必需）

用于语音转录(Whisper)和文本嵌入。

**获取方法：**
1. 访问 [OpenAI平台](https://platform.openai.com/)
2. 注册并登录账号
3. 进入 API Keys 页面
4. 创建新的API Key
5. 复制API Key

**配置项：**
```env
OPENAI_API_KEY=sk-your_openai_api_key_here
```

### 3. MySQL数据库（必需）

用于存储会议数据和转录内容。

**获取方法：**
1. 安装MySQL服务器（本地或云端）
2. 创建数据库用户和密码
3. 创建名为 `meeting_sessions` 的数据库

**配置项：**
```env
DB_HOST=localhost
DB_USER=root
DB_PASSWORD=your_mysql_password
DB_NAME=meeting_sessions
DB_POOL_SIZE=5
DB_RECONNECT_ATTEMPTS=3
DB_CHARSET=utf8mb4
```

### 4. Notion API（可选）

用于同步会议纪要到Notion。

**获取方法：**
1. 访问 [Notion Integrations](https://www.notion.so/my-integrations)
2. 点击 "New integration" 创建新集成
3. 填写集成信息：
   - **Name**: PromptMeet Notion Tool
   - **Associated workspace**: 选择你的工作区
4. 点击 "Submit" 创建
5. 复制显示的 "Internal Integration Token"
6. 在目标Notion页面中邀请该集成

**配置项：**
```env
NOTION_API_KEY=ntn_your_notion_api_key_here
```

**详细配置指南：** 请参考项目根目录的 `NOTION_CONFIG.md` 文件

### 5. 飞书API（可选）

用于同步任务到飞书日历。

**获取方法：**
1. 访问 [飞书开放平台](https://open.feishu.cn/)
2. 创建应用并获取App ID和App Secret
3. 配置应用权限（日历读写权限）
4. 获取用户Access Token
5. 获取日历ID

**配置项：**
```env
FEISHU_USER_ACCESS_TOKEN=your_feishu_access_token
FEISHU_CALENDAR_ID=your_calendar_id
```

### 6. QQ邮箱SMTP（可选）

用于发送会议纪要邮件。

**获取方法：**
1. 登录QQ邮箱，进入设置 → 账户
2. 开启SMTP服务
3. 生成授权码（用于第三方客户端登录）
4. 记录邮箱地址和授权码

**配置项：**
```env
SENDER_EMAIL=your_qq_email@qq.com
EMAIL_AUTH_CODE=your_qq_email_auth_code
```

### 7. 阿里云OCR（可选）

用于截图文字识别。

**获取方法：**
1. 访问 [阿里云控制台](https://ecs.console.aliyun.com/)
2. 开通文字识别OCR服务
3. 创建AccessKey：
   - 进入AccessKey管理页面
   - 创建用户AccessKey
   - 记录AccessKey ID和AccessKey Secret

**配置项：**
```env
ALIBABA_CLOUD_ACCESS_KEY_ID=your_access_key_id
ALIBABA_CLOUD_ACCESS_KEY_SECRET=your_access_key_secret
```

### 8. 天气API（可选）

用于获取天气信息。

**获取方法：**
1. 访问 [OpenWeather](https://openweathermap.org/api)
2. 注册账号并登录
3. 进入API Keys页面
4. 复制默认API Key或创建新的

**配置项：**
```env
OPENWEATHER_API_KEY=your_openweather_api_key
```

### 完整配置示例

创建 `.env` 文件，包含以下内容：

```env
# AI服务配置（必需）
DEEPSEEK_API_KEY=your_deepseek_api_key_here
DEEPSEEK_API_BASE=https://api.deepseek.com
OPENAI_API_KEY=sk-your_openai_api_key_here

# 数据库配置（必需）
DB_HOST=localhost
DB_USER=root
DB_PASSWORD=your_mysql_password
DB_NAME=meeting_sessions
DB_POOL_SIZE=5
DB_RECONNECT_ATTEMPTS=3
DB_CHARSET=utf8mb4

# 可选服务配置
NOTION_API_KEY=ntn_your_notion_api_key_here
FEISHU_USER_ACCESS_TOKEN=your_feishu_access_token
FEISHU_CALENDAR_ID=your_calendar_id
SENDER_EMAIL=your_qq_email@qq.com
EMAIL_AUTH_CODE=your_qq_email_auth_code
ALIBABA_CLOUD_ACCESS_KEY_ID=your_access_key_id
ALIBABA_CLOUD_ACCESS_KEY_SECRET=your_access_key_secret
OPENWEATHER_API_KEY=your_openweather_api_key
```

### 注意事项

1. **必需配置**：DeepSeek API、OpenAI API、MySQL数据库是项目运行的基本要求
2. **可选配置**：其他API为扩展功能，可根据需要选择性配置
3. **安全提醒**：
   - 不要将 `.env` 文件提交到Git仓库
   - 定期更换API密钥
   - 妥善保管数据库密码
4. **费用说明**：部分API服务可能产生费用，请查看各平台的价格政策
