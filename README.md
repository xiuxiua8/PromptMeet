# PromptMeet 即录

## 📌 项目名称

—— 智能化实时会议纪要与日程同步系统

---

## 🧭 项目简介

PromptMeet 是一款基于大语言模型和语音/视频处理技术的 AI 会议助手，致力于实现“边开会边生成结构化纪要”。它支持从实时会议音频中提取核心信息、生成纪要草稿、识别任务与项目计划，并自动同步至 Notion、飞书等主流协作平台的日历或任务系统中。同时，用户可在会议过程中随时提问，Agent 会基于当前上下文进行智能回应，为高效会议提供全链路支持。

## 后端

### 进入backend目录

cd backend

### 创建虚拟环境（可选）

python -m venv venv

### 激活虚拟环境

### Windows

venv\Scripts\activate

### Linux/Mac

source venv/bin/activate

### 安装依赖

pip install -r requirements.txt

### 运行程序

python ./backend/main_service.py

## 前端

### 进入frontend目录

cd frontend

### 安装node (MacOS) Windows 请在官网安装

brew install node

### 安装vite

npm install vite —save-dev

### 运行frontend程序

cd frontend; npm run dev
