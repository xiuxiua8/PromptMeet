<template>
  <div class="app-container">
    <!-- 背景装饰 -->
    <div class="bg-decoration"></div>
    
    <div class="main-layout">
      <!-- 历史会议侧边栏 -->
      <div class="sidebar">
        <div class="sidebar-header">
          <h3>历史会议</h3>
        </div>
        <div class="history-list">
          <div class="history-session-item"
            v-for="session in historySession"
            :key="session.session_id"
            @click="gainSession(session.session_id)"
          >
            <div class="session-icon">📋</div>
            <div class="session-info">
              <div class="session-title">{{ session.key_points[0] }}</div>
              <div class="session-date">{{ formatDate(session.created_at) }}</div>
            </div>
          </div>
        </div>
      </div>

      <!-- 主要内容区域 -->
      <div class="main-content">
        <!-- 控制面板 -->
        <div class="control-panel">
          <div class="panel-header">
            <div class="app-branding">
              <div class="logo-container">
                <img src="./assets/xjtu.png" alt="Logo" class="logo" />
              </div>
              <div class="title-section">
                <h1 class="app-title">PromptMeet</h1>
                <p class="app-subtitle">智能会议助手</p>
              </div>
              <div class="status-section">
                <div class="status-indicator" :class="{ active: isRunning }">
                  <div class="status-dot"></div>
                  <span class="status-text">{{ isRunning ? '会议中' : '待机中' }}</span>
                </div>
              </div>
            </div>
          </div>
          
          <div class="control-buttons">
            <button class="control-btn primary" 
              :class="{ active: isRunning }" 
              @click="handleStart">
              <i class="btn-icon">{{ isRunning ? '⏹️' : '▶️' }}</i>
              <span>{{ isRunning ? '结束会议' : '开始会议' }}</span>
            </button>
            
            <button class="control-btn secondary" 
              :disabled="!isRunning" 
              :class="{ recording: isRecording }" 
              @click="handleRecord">
              <i class="btn-icon">{{ isRecording ? '⏸️' : '🎙️' }}</i>
              <span>{{ isRecording ? '停止录音' : '开始录音' }}</span>
            </button>
            
            <button class="control-btn info" 
              :disabled="!isRunning" 
              @click="handleScreenshot">
              <i class="btn-icon">📸</i>
              <span>截图分析</span>
            </button>
            
            <button class="control-btn warning" 
              :disabled="!isRunning" 
              @click="handleCreateSummary">
              <i class="btn-icon">📝</i>
              <span>生成摘要</span>
            </button>
            
            <button class="control-btn success" 
              :disabled="!isRunning" 
              @click="saveSession">
              <i class="btn-icon">💾</i>
              <span>保存会议</span>
            </button>
          </div>
        </div>

        <!-- 聊天区域 -->
        <div class="chat-container">
          <div class="chat-header">
            <h3>AI助手对话</h3>
            <div class="chat-status">
              <div class="online-indicator"></div>
              <span>AI助手在线</span>
            </div>
          </div>
          
          <div class="chat-messages" ref="chatDisplay">
            <div v-if="qa.length === 0" class="chat-welcome">
              <div class="welcome-avatar">🤖</div>
              <div class="welcome-text">
                <h4>欢迎使用PromptMeet智能会议助手</h4>
                <p>我可以帮助您记录会议内容、生成摘要、回答问题等</p>
              </div>
            </div>
            
            <div v-for="(msg, idx) in qa" :key="idx" class="message-wrapper">
              <div class="message" :class="msg.from === 'user' ? 'user-message' : 'ai-message'">
                <div class="message-avatar">
                  {{ msg.from === 'user' ? '👤' : '🤖' }}
                </div>
                <div class="message-content">
                  <div class="message-bubble">
                    {{ msg.content }}
                  </div>
                  <div class="message-time">{{ formatTime(new Date()) }}</div>
                </div>
              </div>
            </div>
          </div>
          
          <!-- 推荐问题 -->
          <div v-if="questions.length" class="suggestions">
            <div class="suggestions-title">推荐问题</div>
            <div class="suggestion-chips">
              <button 
                v-for="(txt, i) in questions" 
                :key="i" 
                class="suggestion-chip" 
                @click="handleRecommendClick(txt)"
                :title="txt">
                {{ txt }}
              </button>
            </div>
          </div>
          
          <!-- 输入区域 -->
          <div class="chat-input-container">
            <div class="input-wrapper">
              <input 
                type="text" 
                v-model="message" 
                placeholder="输入您的问题..." 
                @keydown="onInputKeydown"
                class="chat-input" />
              <button @click="sendMessage" class="send-btn" :disabled="!message.trim()">
                <i>📤</i>
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- 右侧面板 -->
      <div class="right-panel">
        <div class="panel-tabs">
          <button 
            class="tab-btn" 
            :class="{ active: activeTab === 'tab1' }" 
            @click="activeTab = 'tab1'">
            <i>📋</i>
            <span>会议记录</span>
          </button>
          <button 
            class="tab-btn" 
            :class="{ active: activeTab === 'tab2' }" 
            @click="activeTab = 'tab2'">
            <i>📄</i>
            <span>会议摘要</span>
          </button>
        </div>
        
        <div class="panel-content">
          <!-- 会议记录 -->
          <div v-if="activeTab === 'tab1'" class="tab-panel">
            <div class="timeline-container">
              <div v-if="chatHistory.length === 0" class="empty-state">
                <div class="empty-icon">📝</div>
                <p>开始会议后，这里将显示实时记录</p>
              </div>
              <div v-else class="timeline">
                <div v-for="(msg, index) in chatHistory" :key="index" class="timeline-item">
                  <div class="timeline-dot"></div>
                  <div class="timeline-content">
                    <div class="timeline-header">
                      <span class="speaker">{{ msg.sender }}</span>
                      <span class="timestamp">{{ msg.time }}</span>
                    </div>
                    <div class="timeline-text">{{ msg.content }}</div>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
          <!-- 会议摘要 -->
          <div v-if="activeTab === 'tab2'" class="tab-panel">
            <div class="summary-container">
              <div class="summary-header">
                <h4>会议摘要</h4>
                <div class="summary-status">
                  <div class="status-dot" :class="{ active: summary !== '会议结束后自动生成……' }"></div>
                  <span>{{ summary === '会议结束后自动生成……' ? '等待生成' : '已生成' }}</span>
                </div>
              </div>
              <div class="summary-content" v-html="renderedSummary"></div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- 窗口选择模态框 -->
    <div v-if="showWindowSelection" class="modal-overlay">
      <div class="modal-container">
        <div class="modal-header">
          <h3>选择截图窗口</h3>
          <button class="modal-close" @click="cancelWindowSelection">✕</button>
        </div>
        <div class="modal-content">
          <div class="window-grid">
            <div 
              v-for="window in availableWindows" 
              :key="window.id"
              class="window-card"
              @click="selectWindow(window.id)">
              <div class="window-preview">🖼️</div>
              <div class="window-details">
                <div class="window-title">{{ window.title }}</div>
                <div class="window-type">{{ window.type === 'window' ? '应用窗口' : window.type }}</div>
              </div>
            </div>
          </div>
        </div>
        <div class="modal-footer">
          <button class="modal-btn secondary" @click="cancelWindowSelection">取消</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script>
import MarkdownIt from 'markdown-it';

export default {
  data() {
    return {
      isRecording: false,
      isRunning: false,
      baseURL: 'http://localhost:8000',
      wsbaseURL: 'ws://localhost:8000',
      sessionid: '',
      message: '',
      activeTab: 'tab1',
      chatHistory: [],
      data: {},
      websocket: null,
      questions: [],
      id: 0,
      receivedData: '',
      qa: [],
      summary: '会议结束后自动生成……',
      md: new MarkdownIt(),
      availableWindows: [],
      selectedWindowId: null,
      showWindowSelection: false,
      historySession: [],
    };
  },
  computed: {
    renderedSummary() {
      return this.md.render(this.summary);
    },
  },
  methods: {
    formatDate(dateString) {
      if (!dateString) return '';
      const date = new Date(dateString);
      return date.toLocaleDateString('zh-CN', { 
        month: 'short', 
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      });
    },
    formatTime(date) {
      return date.toLocaleTimeString('zh-CN', { 
        hour: '2-digit', 
        minute: '2-digit' 
      });
    },
    handleRecommendClick(text) {
      this.message = text;
    },
    onInputKeydown(e) {
      if (e.key === 'Enter') {
        this.sendMessage();
      }
    },
    async handleStart() {
      if (!this.isRunning) {
        await this.handleCreateSession();
      } else {
        await this.handleEndSession();
        this.isRunning = false;
      }
    },
    async gainSessionId() {
      const url = `${this.baseURL}/db/sessions`;
      const response = await fetch(url, {
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
        },
      });
      const data = await response.json();
      for (const item of data) {
        this.historySession.push(item);
      }
    },
    async gainSession(sid) {
      this.clear()
      const url = `${this.baseURL}/db/sessions/${sid}`
      const response = await fetch(url, {
        method: 'GET',
        headers: {
          'Content-Type': 'application/json',
        },
      });
      const data = await response.json();
      const transcript_segments=data.transcript_segments
      for (const segment of transcript_segments) {  
        const chat={sender:segment.speaker, time:segment.timestamp, content:segment.text}
        this.chatHistory.push(chat)
      }
      this.summary = data.current_summary.summary_text;
    },
    async handleCreateSession(){
      this.clear()
      this.isRecording = false
      this.isRunning=true
      const url=`${this.baseURL}/api/sessions`
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
      const data = await response.json();
      this.sessionid = data.session_id;
      this.websocket = new WebSocket(`${this.wsbaseURL}/ws/${this.sessionid}`);
    },
    async saveSession() {
      const url = `${this.baseURL}/api/sessions/${this.sessionid}/store-session`;
      await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
    },
    async handleStartRecord() {
      const url = `${this.baseURL}/api/sessions/${this.sessionid}/start-recording`;
      await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
    },
    async handleStopRecord() {
      const url = `${this.baseURL}/api/sessions/${this.sessionid}/stop-recording`;
      await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
    },
    async handleCreateSummary() {
      //this.isRunning = false;
      const url = `${this.baseURL}/api/sessions/${this.sessionid}/generate-summary`;
      await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
    },
    async getAvailableWindows() {
      try {
        const url = `${this.baseURL}/api/windows`;
        const response = await fetch(url);
        const data = await response.json();
        if (data.success) {
          this.availableWindows = data.windows;
        } else {
          console.error('获取窗口列表失败:', data.message);
        }
      } catch (error) {
        console.error('获取窗口列表失败:', error);
      }
    },
    async handleScreenshot() {
      await this.getAvailableWindows();
      if (this.availableWindows.length === 0) {
        alert('未检测到会议窗口');
        return;
      }
      if (this.availableWindows.length === 1) {
        this.selectedWindowId = this.availableWindows[0].id;
        await this.performScreenshot();
      } else {
        this.showWindowSelection = true;
      }
    },
    async performScreenshot() {
      try {
        let url = `${this.baseURL}/api/sessions/${this.sessionid}/start-image-processing`;
        if (this.selectedWindowId) {
          url += `?window_id=${this.selectedWindowId}`;
        }
        const response = await fetch(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
        });
        const data = await response.json();
        if (data.success) {
          console.log('截图处理已启动:', data.message);
        } else {
          console.error('截图处理失败:', data.message);
        }
      } catch (error) {
        console.error('截图处理失败:', error);
      }
      this.showWindowSelection = false;
    },
    selectWindow(windowId) {
      this.selectedWindowId = windowId;
      this.performScreenshot();
    },
    cancelWindowSelection() {
      this.showWindowSelection = false;
      this.selectedWindowId = null;
    },
    openTab(tabName) {
      this.activeTab = tabName;
    },
    sendMessage() {
      if (this.message.trim()) {
        this.qa.push({ from: 'user', content: this.message });
        this.websocket.send(JSON.stringify({
          type: 'agent_message',
          data: { content: this.message },
        }));
        this.message = '';
        this.$nextTick(() => {
          this.scrollToBottom();
        });
      }
    },
    scrollToBottom() {
      const el = this.$refs.chatDisplay;
      if (el) {
        el.scrollTop = el.scrollHeight;
      }
    },
    sendId(id) {
      this.websocket.send(JSON.stringify({
        input: id,
      }));
    },
    ShowQuestion() {
      this.questions[this.id % 3] = this.receivedData.data.content;
      this.id++;
    },
    ShowAnswer() {
      this.qa.push({ from: 'agent', content: this.receivedData.data.content });
      this.$nextTick(() => {
        this.scrollToBottom();
      });
    },
    ShowSummary() {
      this.summary = this.receivedData.data.summary_text;
    },
    ShowHistory() {
      const chat = {
        sender: this.receivedData.data.speaker,
        time: this.receivedData.timestamp,
        content: this.receivedData.data,
      };
      this.chatHistory.push(chat);
    },
    ShowEmailResponse() {
      // 处理邮件发送响应
      const emailResult = this.receivedData.data.content;
      
      // 检查是否是邮件相关的响应
      if (emailResult && typeof emailResult === 'string') {
        // 检查是否包含邮件工具的结果
        if (emailResult.includes('邮件') || emailResult.includes('email')) {
          // 如果是缺失信息的情况，显示提示
          if (emailResult.includes('邮件信息不完整') || emailResult.includes('请补充')) {
            this.qa.push({ from: 'agent', content: emailResult });
          } else if (emailResult.includes('邮件发送成功')) {
            this.qa.push({ from: 'agent', content: '✅ 邮件发送成功！' });
          } else if (emailResult.includes('邮件发送失败') || emailResult.includes('错误')) {
            this.qa.push({ from: 'agent', content: `❌ ${emailResult}` });
          } else {
            this.qa.push({ from: 'agent', content: emailResult });
          }
        } else {
          this.qa.push({ from: 'agent', content: emailResult });
        }
      } else {
        this.qa.push({ from: 'agent', content: emailResult });
      }
    },
    handleRecord() {
      if (!this.isRecording) {
        this.handleStartRecord();
        this.isRecording = true;
      } else {
        this.handleStopRecord();
        this.isRecording = false;
      }
    },
    handleEndSession() {
      // 停止录音如果正在录音
      if (this.isRecording) {
        this.handleStopRecord();
        this.isRecording = false;
      }
      // 关闭WebSocket连接
      if (this.websocket) {
        this.websocket.close();
        this.websocket = null;
      }
      // 设置会话状态为结束
      this.isRunning = false;
      this.sessionid = '';
    },
    clear() {
      this.qa = [];
      this.chatHistory = [];
      this.questions = [];
      this.id = 0;
      this.receivedData = '';
      this.summary = "会议结束后自动生成……";
    },
  },
  watch: {
    websocket(newVal, oldVal) {
      if (oldVal) {
        oldVal.close()
      }
      newVal.onmessage = (event) => {
        this.receivedData = JSON.parse(event.data);
        if(this.receivedData.type=="question"){
          this.ShowQuestion()
        }
        else if(this.receivedData.type=="answer"){
          this.ShowAnswer()
        }
        else if(this.receivedData.type=="summary_generated"){
          this.ShowSummary()
        }
        else if(this.receivedData.type=="audio_transcript" || this.receivedData.type=="image_ocr_result"){
          this.ShowHistory()
        }
        else if(this.receivedData.type=="email_response"){
          this.ShowEmailResponse()
        }
        else{
          return
        }

      };
    },
    qa() {
      this.$nextTick(() => {
        this.scrollToBottom();
      });
    }
  },
  mounted() {
    this.openTab('tab1');
    this.gainSessionId()
  },
};
</script>

<style scoped>
/* 全局样式重置 */
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

/* 主容器 */
.app-container {
  min-height: 100vh;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  position: relative;
  overflow: hidden;
}

/* 背景装饰 */
.bg-decoration {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: 
    radial-gradient(circle at 20% 80%, rgba(120, 119, 198, 0.3) 0%, transparent 50%),
    radial-gradient(circle at 80% 20%, rgba(255, 255, 255, 0.1) 0%, transparent 50%);
  pointer-events: none;
}

/* 主布局 */
.main-layout {
  display: flex;
  height: 100vh;
  position: relative;
  z-index: 1;
  gap: 20px;
  padding: 20px;
}

/* 侧边栏 */
.sidebar {
  width: 280px;
  background: rgba(255, 255, 255, 0.95);
  backdrop-filter: blur(10px);
  border-radius: 20px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.sidebar-header {
  padding: 24px 20px 16px;
  border-bottom: 1px solid rgba(0, 0, 0, 0.1);
  background: linear-gradient(135deg, #667eea, #764ba2);
  color: white;
}

.sidebar-header h3 {
  font-size: 18px;
  font-weight: 600;
  margin: 0;
}

.history-list {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
}

.history-session-item {
  display: flex;
  align-items: center;
  padding: 16px;
  margin-bottom: 12px;
  background: rgba(255, 255, 255, 0.8);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.3s ease;
  border: 1px solid rgba(0, 0, 0, 0.05);
}

.history-session-item:hover {
  background: rgba(102, 126, 234, 0.1);
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
}

.session-icon {
  font-size: 20px;
  margin-right: 12px;
}

.session-info {
  flex: 1;
}

.session-title {
  font-size: 14px;
  font-weight: 500;
  color: #333;
  margin-bottom: 4px;
  line-height: 1.4;
}

.session-date {
  font-size: 12px;
  color: #666;
}

/* 主内容区 */
.main-content {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 20px;
  min-width: 0;
}

/* 控制面板 */
.control-panel {
  background: rgba(255, 255, 255, 0.95);
  backdrop-filter: blur(10px);
  border-radius: 20px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
  padding: 24px;
}

.panel-header {
  margin-bottom: 24px;
}

.app-branding {
  display: flex;
  align-items: center;
  gap: 20px;
}

.logo-container {
  width: 60px;
  height: 60px;
  background: linear-gradient(135deg, #667eea, #764ba2);
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  box-shadow: 0 4px 12px rgba(102, 126, 234, 0.3);
}

.logo {
  width: 36px;
  height: 36px;
  border-radius: 8px;
}

.title-section {
  flex: 1;
}

.app-title {
  font-size: 28px;
  font-weight: 700;
  color: #333;
  margin: 0 0 4px 0;
  background: linear-gradient(135deg, #667eea, #764ba2);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
}

.app-subtitle {
  font-size: 14px;
  color: #666;
  margin: 0;
}

.status-section {
  display: flex;
  align-items: center;
}

.status-indicator {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 16px;
  background: rgba(244, 67, 54, 0.1);
  border-radius: 20px;
  transition: all 0.3s ease;
}

.status-indicator.active {
  background: rgba(76, 175, 80, 0.1);
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #f44336;
  animation: pulse 2s infinite;
}

.status-indicator.active .status-dot {
  background: #4caf50;
}

.status-text {
  font-size: 12px;
  font-weight: 500;
  color: #666;
}

@keyframes pulse {
  0% { opacity: 1; }
  50% { opacity: 0.5; }
  100% { opacity: 1; }
}

/* 控制按钮 */
.control-buttons {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
}

.control-btn {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 20px;
  border: none;
  border-radius: 12px;
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.3s ease;
  min-width: 120px;
  justify-content: center;
  position: relative;
  overflow: hidden;
}

.control-btn::before {
  content: '';
  position: absolute;
  top: 0;
  left: -100%;
  width: 100%;
  height: 100%;
  background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.3), transparent);
  transition: left 0.5s;
}

.control-btn:hover::before {
  left: 100%;
}

.control-btn.primary {
  background: linear-gradient(135deg, #4caf50, #45a049);
  color: white;
  box-shadow: 0 4px 12px rgba(76, 175, 80, 0.3);
}

.control-btn.primary.active {
  background: linear-gradient(135deg, #f44336, #d32f2f);
  box-shadow: 0 4px 12px rgba(244, 67, 54, 0.3);
}

.control-btn.secondary {
  background: linear-gradient(135deg, #ff9800, #f57c00);
  color: white;
  box-shadow: 0 4px 12px rgba(255, 152, 0, 0.3);
}

.control-btn.secondary.recording {
  background: linear-gradient(135deg, #f44336, #d32f2f);
  animation: recording-pulse 1.5s infinite;
}

.control-btn.info {
  background: linear-gradient(135deg, #2196f3, #1976d2);
  color: white;
  box-shadow: 0 4px 12px rgba(33, 150, 243, 0.3);
}

.control-btn.warning {
  background: linear-gradient(135deg, #ff5722, #d84315);
  color: white;
  box-shadow: 0 4px 12px rgba(255, 87, 34, 0.3);
}

.control-btn.success {
  background: linear-gradient(135deg, #4caf50, #388e3c);
  color: white;
  box-shadow: 0 4px 12px rgba(76, 175, 80, 0.3);
}

.control-btn:disabled {
  background: #e0e0e0;
  color: #9e9e9e;
  cursor: not-allowed;
  box-shadow: none;
}

.control-btn:hover:not(:disabled) {
  transform: translateY(-2px);
  box-shadow: 0 6px 16px rgba(0, 0, 0, 0.15);
}

.btn-icon {
  font-size: 16px;
}

@keyframes recording-pulse {
  0% { box-shadow: 0 4px 12px rgba(244, 67, 54, 0.3); }
  50% { box-shadow: 0 4px 20px rgba(244, 67, 54, 0.6); }
  100% { box-shadow: 0 4px 12px rgba(244, 67, 54, 0.3); }
}

/* 聊天容器 */
.chat-container {
  flex: 1;
  background: rgba(255, 255, 255, 0.95);
  backdrop-filter: blur(10px);
  border-radius: 20px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.chat-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 20px 24px;
  background: linear-gradient(135deg, rgba(102, 126, 234, 0.1), rgba(118, 75, 162, 0.1));
  border-bottom: 1px solid rgba(0, 0, 0, 0.05);
}

.chat-header h3 {
  font-size: 18px;
  font-weight: 600;
  color: #333;
  margin: 0;
}

.chat-status {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: #4caf50;
}

.online-indicator {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #4caf50;
  animation: pulse 2s infinite;
}

/* 聊天消息 */
.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 20px;
  scroll-behavior: smooth;
}

.chat-messages::-webkit-scrollbar {
  width: 6px;
}

.chat-messages::-webkit-scrollbar-track {
  background: rgba(0, 0, 0, 0.05);
  border-radius: 3px;
}

.chat-messages::-webkit-scrollbar-thumb {
  background: rgba(0, 0, 0, 0.2);
  border-radius: 3px;
}

.chat-welcome {
  display: flex;
  align-items: center;
  gap: 20px;
  padding: 40px 20px;
  text-align: left;
}

.welcome-avatar {
  font-size: 48px;
  width: 80px;
  height: 80px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(135deg, #667eea, #764ba2);
  border-radius: 20px;
  box-shadow: 0 4px 12px rgba(102, 126, 234, 0.3);
}

.welcome-text h4 {
  font-size: 20px;
  color: #333;
  margin: 0 0 8px 0;
}

.welcome-text p {
  font-size: 14px;
  color: #666;
  margin: 0;
  line-height: 1.5;
}

.message-wrapper {
  margin-bottom: 20px;
}

.message {
  display: flex;
  align-items: flex-start;
  gap: 12px;
}

.user-message {
  flex-direction: row-reverse;
}

.message-avatar {
  width: 36px;
  height: 36px;
  border-radius: 18px;
  background: linear-gradient(135deg, #667eea, #764ba2);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
  flex-shrink: 0;
}

.user-message .message-avatar {
  background: linear-gradient(135deg, #4caf50, #45a049);
}

.message-content {
  max-width: 70%;
}

.message-bubble {
  background: rgba(0, 0, 0, 0.05);
  padding: 12px 16px;
  border-radius: 16px;
  font-size: 14px;
  line-height: 1.5;
  color: #333;
  word-wrap: break-word;
}

.user-message .message-bubble {
  background: linear-gradient(135deg, #667eea, #764ba2);
  color: white;
}

.message-time {
  font-size: 11px;
  color: #999;
  margin-top: 4px;
  text-align: right;
}

.user-message .message-time {
  text-align: left;
}

/* 推荐问题 */
.suggestions {
  padding: 16px 20px;
  border-top: 1px solid rgba(0, 0, 0, 0.05);
  background: rgba(102, 126, 234, 0.02);
}

.suggestions-title {
  font-size: 13px;
  color: #667eea;
  margin-bottom: 12px;
  font-weight: 500;
  display: flex;
  align-items: center;
  gap: 6px;
}

.suggestions-title::before {
  content: '💡';
  font-size: 14px;
}

.suggestion-chips {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.suggestion-chip {
  background: rgba(102, 126, 234, 0.1);
  border: 1px solid rgba(102, 126, 234, 0.2);
  color: #667eea;
  padding: 8px 12px;
  border-radius: 12px;
  font-size: 12px;
  cursor: pointer;
  transition: all 0.3s ease;
  flex: 1;
  min-width: 0;
  max-width: 100%;
  white-space: normal;
  word-wrap: break-word;
  line-height: 1.4;
  text-align: left;
  display: block;
}

.suggestion-chip:hover {
  background: rgba(102, 126, 234, 0.15);
  border-color: rgba(102, 126, 234, 0.3);
  transform: translateY(-1px);
  box-shadow: 0 2px 8px rgba(102, 126, 234, 0.1);
}

.suggestion-chip:active {
  transform: translateY(0);
  box-shadow: 0 1px 4px rgba(102, 126, 234, 0.2);
}

/* 输入区域 */
.chat-input-container {
  padding: 20px;
  border-top: 1px solid rgba(0, 0, 0, 0.05);
}

.input-wrapper {
  display: flex;
  gap: 12px;
  align-items: center;
}

.chat-input {
  flex: 1;
  padding: 12px 16px;
  border: 2px solid rgba(0, 0, 0, 0.1);
  border-radius: 20px;
  font-size: 14px;
  outline: none;
  transition: all 0.3s ease;
  background: rgba(255, 255, 255, 0.8);
}

.chat-input:focus {
  border-color: #667eea;
  box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
}

.send-btn {
  width: 44px;
  height: 44px;
  border: none;
  border-radius: 22px;
  background: linear-gradient(135deg, #667eea, #764ba2);
  color: white;
  cursor: pointer;
  transition: all 0.3s ease;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
}

.send-btn:hover:not(:disabled) {
  transform: scale(1.1);
  box-shadow: 0 4px 12px rgba(102, 126, 234, 0.3);
}

.send-btn:disabled {
  background: #e0e0e0;
  cursor: not-allowed;
}

/* 右侧面板 */
.right-panel {
  width: 380px;
  background: rgba(255, 255, 255, 0.95);
  backdrop-filter: blur(10px);
  border-radius: 20px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.panel-tabs {
  display: flex;
  background: rgba(0, 0, 0, 0.02);
  border-bottom: 1px solid rgba(0, 0, 0, 0.05);
}

.tab-btn {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 16px;
  border: none;
  background: none;
  cursor: pointer;
  transition: all 0.3s ease;
  font-size: 14px;
  color: #666;
  position: relative;
}

.tab-btn.active {
  color: #667eea;
  background: rgba(102, 126, 234, 0.05);
}

.tab-btn.active::after {
  content: '';
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: linear-gradient(135deg, #667eea, #764ba2);
}

.tab-btn:hover:not(.active) {
  background: rgba(0, 0, 0, 0.03);
}

.panel-content {
  flex: 1;
  overflow: hidden;
}

.tab-panel {
  height: 100%;
  padding: 20px;
  overflow-y: auto;
}

.tab-panel::-webkit-scrollbar {
  width: 6px;
}

.tab-panel::-webkit-scrollbar-track {
  background: rgba(0, 0, 0, 0.05);
  border-radius: 3px;
}

.tab-panel::-webkit-scrollbar-thumb {
  background: rgba(0, 0, 0, 0.2);
  border-radius: 3px;
}

/* 时间轴 */
.timeline-container {
  height: 100%;
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  text-align: center;
  color: #666;
}

.empty-icon {
  font-size: 48px;
  margin-bottom: 16px;
  opacity: 0.5;
}

.timeline {
  position: relative;
}

.timeline::before {
  content: '';
  position: absolute;
  left: 16px;
  top: 0;
  bottom: 0;
  width: 2px;
  background: linear-gradient(to bottom, #667eea, #764ba2);
}

.timeline-item {
  position: relative;
  padding-left: 48px;
  margin-bottom: 24px;
}

.timeline-dot {
  position: absolute;
  left: 8px;
  top: 8px;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: linear-gradient(135deg, #667eea, #764ba2);
  box-shadow: 0 2px 8px rgba(102, 126, 234, 0.3);
}

.timeline-content {
  background: rgba(255, 255, 255, 0.8);
  padding: 16px;
  border-radius: 12px;
  border: 1px solid rgba(0, 0, 0, 0.05);
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.05);
}

.timeline-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.speaker {
  font-weight: 600;
  color: #667eea;
  font-size: 14px;
}

.timestamp {
  font-size: 11px;
  color: #999;
}

.timeline-text {
  font-size: 13px;
  line-height: 1.5;
  color: #333;
}

/* 摘要容器 */
.summary-container {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.summary-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 20px;
  padding-bottom: 16px;
  border-bottom: 1px solid rgba(0, 0, 0, 0.05);
}

.summary-header h4 {
  font-size: 18px;
  color: #333;
  margin: 0;
}

.summary-status {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: #666;
}

.summary-status .status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #ff9800;
}

.summary-status .status-dot.active {
  background: #4caf50;
}

.summary-content {
  flex: 1;
  font-size: 14px;
  line-height: 1.6;
  color: #333;
  overflow-y: auto;
}

.summary-content::-webkit-scrollbar {
  width: 6px;
}

.summary-content::-webkit-scrollbar-track {
  background: rgba(0, 0, 0, 0.05);
  border-radius: 3px;
}

.summary-content::-webkit-scrollbar-thumb {
  background: rgba(0, 0, 0, 0.2);
  border-radius: 3px;
}

/* 模态框 */
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.5);
  backdrop-filter: blur(5px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.modal-container {
  background: white;
  border-radius: 20px;
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
  max-width: 600px;
  width: 90%;
  max-height: 80vh;
  overflow: hidden;
}

.modal-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 24px;
  background: linear-gradient(135deg, #667eea, #764ba2);
  color: white;
}

.modal-header h3 {
  font-size: 18px;
  margin: 0;
}

.modal-close {
  background: none;
  border: none;
  color: white;
  font-size: 20px;
  cursor: pointer;
  width: 32px;
  height: 32px;
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background 0.3s ease;
}

.modal-close:hover {
  background: rgba(255, 255, 255, 0.2);
}

.modal-content {
  padding: 24px;
  max-height: 400px;
  overflow-y: auto;
}

.window-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 16px;
}

.window-card {
  padding: 16px;
  border: 2px solid rgba(0, 0, 0, 0.1);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.3s ease;
  text-align: center;
}

.window-card:hover {
  border-color: #667eea;
  background: rgba(102, 126, 234, 0.05);
  transform: translateY(-2px);
}

.window-preview {
  font-size: 32px;
  margin-bottom: 12px;
}

.window-details {
  text-align: left;
}

.window-title {
  font-size: 14px;
  font-weight: 500;
  color: #333;
  margin-bottom: 4px;
}

.window-type {
  font-size: 12px;
  color: #666;
}

.modal-footer {
  padding: 16px 24px;
  background: rgba(0, 0, 0, 0.02);
  border-top: 1px solid rgba(0, 0, 0, 0.05);
  display: flex;
  justify-content: flex-end;
}

.modal-btn {
  padding: 8px 16px;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  font-size: 14px;
  transition: all 0.3s ease;
}

.modal-btn.secondary {
  background: #f5f5f5;
  color: #666;
}

.modal-btn.secondary:hover {
  background: #e0e0e0;
}

/* 响应式设计 */
@media (max-width: 1200px) {
  .main-layout {
    gap: 16px;
    padding: 16px;
  }
  
  .sidebar {
    width: 240px;
  }
  
  .right-panel {
    width: 320px;
  }
  
  .control-buttons {
    gap: 8px;
  }
  
  .control-btn {
    min-width: 100px;
    padding: 10px 16px;
  }
}

@media (max-width: 768px) {
  .main-layout {
    flex-direction: column;
    height: auto;
    min-height: 100vh;
  }
  
  .sidebar {
    width: 100%;
    height: auto;
    max-height: 200px;
  }
  
  .right-panel {
    width: 100%;
    order: 3;
  }
  
  .main-content {
    order: 2;
  }
  
  .app-branding {
    flex-direction: column;
    text-align: center;
    gap: 12px;
  }
  
  .control-buttons {
    flex-direction: column;
  }
  
  .control-btn {
    width: 100%;
  }
}
</style>