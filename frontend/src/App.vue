<template>
  <div class="app-container">
    <!-- 背景装饰 -->
    <div class="bg-decoration"></div>
    
    <div class="main-layout">
      <!-- 历史会议侧边栏 -->
      <div class="sidebar" :class="{ collapsed: sidebarCollapsed }">
        <div class="sidebar-header">
          <h3 v-if="!sidebarCollapsed">历史会议</h3>
          <button class="toggle-btn" @click="toggleSidebar" :title="sidebarCollapsed ? '展开历史会议' : '折叠历史会议'">
            {{ sidebarCollapsed ? '📂' : '📁' }}
          </button>
        </div>
        <div class="history-list" v-if="!sidebarCollapsed">
          <div class="history-session-item"
            v-for="session in historySession"
            :key="session.session_id"
            @click="gainSession(session.session_id)"
          >
            <div class="session-icon">📋</div>
            <div class="session-info">
              <div class="session-title">   {{ session.key_points[0]?.split(/[:：]/)[0] || '无标题'}}</div>
              <div class="session-date">{{ formatDate(session.created_at) }}</div>
            </div>
          </div>
        </div>
      </div>

      <!-- 主要内容区域 -->
      <div class="main-content" :class="{ expanded: sidebarCollapsed }">
        <!-- 控制面板 -->
        <div class="control-panel">
          <div class="panel-header">
            <div class="app-branding">
              <div class="hero-title-section">
                <div class="main-title-container">
                  <h1 class="hero-title">
                    <span class="title-prompt">Prompt</span><span class="title-meet">Meet</span>
                  </h1>
                  <div class="title-accent-line"></div>
                </div>
                <p class="hero-subtitle">智能会议助手</p>
                <div class="title-particles">
                  <div class="particle particle-1"></div>
                  <div class="particle particle-2"></div>
                  <div class="particle particle-3"></div>
                </div>
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
              <div class="welcome-container">
                <div class="welcome-question">{{ randomWelcomeQuestion }}</div>
              </div>
            </div>
            
            <div v-for="(msg, idx) in qa" :key="idx" class="message-wrapper">
              <div class="message" :class="msg.from === 'user' ? 'user-message' : 'ai-message'">
                <div class="message-avatar">
                  {{ msg.from === 'user' ? '👤' : '🤖' }}
                </div>
                <div class="message-content">
                  <div class="message-bubble">
                    <div v-if="msg.from === 'agent'" class="message-html" v-html="md.render(msg.content)"></div>
                    <div v-else class="message-text">{{ msg.content }}</div>
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
      <div class="right-panel" :class="{ expanded: sidebarCollapsed }">
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
          <div v-if="activeTab === 'tab1'" class="tab-panel record-panel">
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
          <div v-if="activeTab === 'tab2'" class="tab-panel summary-panel">
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
import hljs from 'highlight.js';
import 'highlight.js/styles/github-dark.css';

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
      md: new MarkdownIt({
        highlight: function (str, lang) {
          if (lang && hljs.getLanguage(lang)) {
            try {
              return `<pre class="hljs"><code class="language-${lang}">${hljs.highlight(str, { language: lang }).value}</code></pre>`;
            } catch (__) {}
          }
          return `<pre class="hljs"><code>${MarkdownIt().utils.escapeHtml(str)}</code></pre>`;
        }
      }),
      availableWindows: [],
      selectedWindowId: null,
      showWindowSelection: false,
      historySession: [],
      sidebarCollapsed: false,
      welcomeQuestions: [
        '您在忙什么？',
        '有什么安排？',
        '准备好开始了吗？',
        '今天有什么计划？',
        '需要我帮您记录什么吗？',
        '您想聊些什么？',
        '有什么想法要分享吗？',
        '准备好开启智能会议了吗？'
      ],
      randomWelcomeQuestion: '',
    };
  },
  computed: {
    renderedSummary() {
      return this.md.render(this.summary);
    },
  },
  methods: {
    selectRandomWelcomeQuestion() {
      const randomIndex = Math.floor(Math.random() * this.welcomeQuestions.length);
      this.randomWelcomeQuestion = this.welcomeQuestions[randomIndex];
    },
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
      const data = this.receivedData;
      const delta = data.data && (data.data.delta || data.data.chunk);
      const content = data.data && data.data.content;
      if (delta !== undefined) {
        // 流式分片，拼接
        if (this.qa.length > 0 && this.qa[this.qa.length - 1].from === 'agent') {
          this.qa[this.qa.length - 1].content = (this.qa[this.qa.length - 1].content || '') + delta;
        } else {
          this.qa.push({ from: 'agent', content: delta });
        }
      } else if (content !== undefined) {
        // 完整内容，直接覆盖最后一条 agent 消息
        if (this.qa.length > 0 && this.qa[this.qa.length - 1].from === 'agent') {
          this.qa[this.qa.length - 1].content = content;
        } else {
          this.qa.push({ from: 'agent', content: content });
        }
      }
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
        content: this.receivedData.data.text,
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
    toggleSidebar() {
      this.sidebarCollapsed = !this.sidebarCollapsed;
    },
    clear() {
      this.qa = [];
      this.chatHistory = [];
      this.questions = [];
      this.id = 0;
      this.receivedData = '';
      this.summary = "会议结束后自动生成……";
    },
    enhanceCodeBlocks() {
      this.$nextTick(() => {
        const blocks = this.$el.querySelectorAll('.message-html pre code');
        blocks.forEach(code => {
          const pre = code.parentElement;
          if (!pre || pre.tagName.toLowerCase() !== 'pre') return;
          // 先移除旧的
          pre.querySelectorAll('.code-lang-label, .copy-btn').forEach(e => e.remove());
          // 语言标注
          let lang = '';
          code.classList.forEach(cls => {
            if (cls.startsWith('language-')) {
              lang = cls.replace('language-', '');
            }
          });
          // 调试输出
          console.log('代码块', pre, lang);
          if (lang) {
            const label = document.createElement('div');
            label.className = 'code-lang-label';
            label.innerText = lang.toUpperCase();
            pre.appendChild(label);
          }
          // 复制按钮
          const btn = document.createElement('button');
          btn.className = 'copy-btn';
          btn.innerText = '复制';
          btn.onclick = () => {
            navigator.clipboard.writeText(code.innerText);
            btn.innerText = '已复制!';
            setTimeout(() => (btn.innerText = '复制'), 1200);
          };
          pre.appendChild(btn);
          pre.style.position = 'relative';
        });
      });
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
      this.enhanceCodeBlocks();
    },
    qa() {
      this.$nextTick(() => {
        this.scrollToBottom();
        this.enhanceCodeBlocks();
      });
    },
    summary() {
      this.enhanceCodeBlocks();
    }
  },
  mounted() {
    this.openTab('tab1');
    this.gainSessionId();
    this.enhanceCodeBlocks();
    this.selectRandomWelcomeQuestion();
  },
};
</script>


<style scoped>
/* CSS变量定义 - 莫兰迪配色系统 */
:root {
  /* 莫兰迪主色调 */
  --morandi-sage: #a8b89a;          /* 灰绿色 */
  --morandi-rose: #d4b5b0;          /* 玫瑰灰 */
  --morandi-sky: #7ba3b8;           /* 天空蓝 */
  --morandi-lavender: #b8a0c4;      /* 薰衣草 */
  --morandi-coral: #c4a8a8;         /* 珊瑚色 */
  --morandi-mint: #9cb3a0;          /* 薄荷绿 */
  --morandi-golden: #d4a574;        /* 金色 */
  --morandi-gray-100: #74779f;      /* 深蓝灰 */
  --morandi-gray-200: #a69e9e;      /* 中性灰 */
  --morandi-gray-300: #e8e6e1;      /* 浅灰 */
  --morandi-gray-400: rgba(160, 168, 165, 0.3);  /* 边框灰 */
  --morandi-gray-500: rgba(120, 130, 127, 0.5);  /* 深边框灰 */
  
  /* 强调色系 */
  --morandi-accent-primary: #6b7ba8;     /* 主强调色 */
  --morandi-accent-secondary: #a67b6b;   /* 次强调色 */
  --morandi-accent-tertiary: #8a6b9a;    /* 第三强调色 */
  --morandi-accent-cool: #7ba3b8;        /* 冷色调强调 */
  --morandi-accent-warm: #d4a574;        /* 暖色调强调 */
  --morandi-accent-sage: #a8b89a;        /* 智慧绿强调 */
  --morandi-accent-rose: #d4b5b0;        /* 玫瑰强调 */
  --morandi-accent-peach: #e8c4a0;       /* 桃色强调 */
  --morandi-accent-lavender: #b8a0c4;    /* 薰衣草强调 */
  
  /* 标题渐变色 */
  --morandi-title-cool-dark: #4a6b78;
  --morandi-title-sky-dark: #5a7d91;
  --morandi-title-lavender-dark: #7d6b8a;
  --morandi-title-warm-dark: #a67b4a;
  --morandi-title-peach-dark: #c49574;
  --morandi-title-golden-dark: #b8914a;
  
  /* 背景色系 */
  --morandi-bg-primary: rgba(248, 248, 248, 0.95);
  --morandi-bg-secondary: rgba(244, 244, 242, 0.9);
  --morandi-bg-tertiary: rgba(255, 255, 255, 0.85);
  
  /* 玻璃效果背景 */
  --morandi-glass-sidebar: rgba(168, 184, 154, 0.08);
  --morandi-glass-control: rgba(212, 181, 176, 0.08);
  --morandi-glass-chat: rgba(123, 163, 184, 0.06);
  --morandi-glass-record: rgba(184, 168, 196, 0.08);
  
  /* 专区背景色 */
  --morandi-sidebar-bg: rgba(255, 255, 255, 0.6);
  --morandi-chat-bg: rgba(255, 255, 255, 0.8);
  --morandi-record-bg: rgba(243, 248, 251, 0.4);
  --morandi-summary-bg: rgba(251, 248, 248, 0.4);
  
  /* 文字颜色 */
  --morandi-text-primary: #2d3748;
  --morandi-text-secondary: #4a5568;
  --morandi-text-tertiary: #718096;
  --morandi-text-sidebar: #4a5568;
  --morandi-text-chat: #2d3748;
  --morandi-text-record: #2d3748;
  --morandi-text-summary: #2d3748;
  
  /* 阴影系统 */
  --morandi-shadow-light: rgba(74, 107, 120, 0.08);
  --morandi-shadow-medium: rgba(74, 107, 120, 0.15);
  --morandi-shadow-heavy: rgba(74, 107, 120, 0.25);
}

/* 全局样式重置 - 确保无滚动无白边 */
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

html {
  width: 100vw;
  height: 100vh;
  overflow: hidden;
  margin: 0;
  padding: 0;
  position: fixed;
  top: 0;
  left: 0;
}

body {
  width: 100vw;
  height: 100vh;
  overflow: hidden;
  margin: 0;
  padding: 0;
  position: fixed;
  top: 0;
  left: 0;
}

/* 主容器 */
.app-container {
  width: 100vw;
  height: 100vh;
  background: transparent;
  position: fixed;
  top: 0;
  left: 0;
  overflow: hidden;
  margin: 0;
  padding: 0;
}

/* 背景装饰 - 多彩莫兰迪风格 */
.bg-decoration {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: 
    radial-gradient(circle at 20% 80%, rgba(168, 184, 154, 0.15) 0%, transparent 50%),
    radial-gradient(circle at 80% 20%, rgba(184, 168, 196, 0.12) 0%, transparent 50%),
    radial-gradient(circle at 60% 40%, rgba(212, 165, 116, 0.08) 0%, transparent 60%),
    radial-gradient(circle at 30% 60%, rgba(123, 163, 184, 0.1) 0%, transparent 55%);
  pointer-events: none;
}

/* 主布局 */
.main-layout {
  display: flex;
  height: 100vh;
  position: relative;
  z-index: 1;
  gap: 16px;
  padding: 16px;
  overflow: hidden;
  box-sizing: border-box;
}

/* 侧边栏 - 历史会议区域专用配色 */
.sidebar {
  width: 280px;
  background: var(--morandi-glass-sidebar);
  backdrop-filter: blur(15px);
  border-radius: 20px;
  border: 1px solid var(--morandi-gray-400);
  box-shadow: 0 8px 32px var(--morandi-shadow-light);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  transition: all 0.3s ease;
}

.sidebar.collapsed {
  width: 60px;
  box-shadow: 0 4px 16px var(--morandi-shadow-medium);
}

.sidebar.collapsed .sidebar-header {
  border-bottom: none;
}

.sidebar-header {
  padding: 24px 20px 16px;
  border-bottom: 1px solid var(--morandi-gray-400);
  background: linear-gradient(135deg, var(--morandi-gray-100), var(--morandi-accent-primary));
  color: white;
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 80px;
}

.sidebar.collapsed .sidebar-header {
  padding: 24px 10px 16px;
  justify-content: center;
}

.sidebar-header h3 {
  font-size: 18px;
  font-weight: 600;
  margin: 0;
  transition: opacity 0.3s ease;
}

.toggle-btn {
  background: none;
  border: none;
  color: white;
  font-size: 18px;
  cursor: pointer;
  padding: 8px;
  border-radius: 8px;
  transition: background 0.3s ease;
  display: flex;
  align-items: center;
  justify-content: center;
}

.toggle-btn:hover {
  background: rgba(255, 255, 255, 0.25);
}

.history-list {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
  transition: all 0.3s ease;
}

.history-session-item {
  display: flex;
  align-items: center;
  padding: 16px;
  margin-bottom: 12px;
  background: var(--morandi-sidebar-bg);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.3s ease;
  border: 1px solid var(--morandi-gray-400);
}

.history-session-item:hover {
  background: var(--morandi-gray-50);
  transform: translateY(-2px);
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
  border-color: var(--morandi-gray-500);
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
  color: var(--morandi-text-sidebar);
  margin-bottom: 4px;
  line-height: 1.4;
}

.session-date {
  font-size: 12px;
  color: var(--morandi-text-secondary);
}

/* 主内容区 */
.main-content {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 20px;
  min-width: 0;
  transition: all 0.3s ease;
}

.main-content.expanded {
  /* 当侧边栏折叠时，主内容区可以获得更多空间 */
}

/* 控制面板 - 专用配色 */
.control-panel {
  background: var(--morandi-glass-control);
  backdrop-filter: blur(15px);
  border-radius: 20px;
  border: 1px solid var(--morandi-gray-400);
  box-shadow: 0 8px 32px var(--morandi-shadow-light);
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

/* 英雄级主标题样式 */
.hero-title-section {
  flex: 1;
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  padding: 8px 0;
}

.main-title-container {
  position: relative;
  margin-bottom: 8px;
}

.hero-title {
  font-size: 42px;
  font-weight: 900;
  letter-spacing: -1px;
  margin: 0;
  line-height: 1;
  position: relative;
  display: flex;
  align-items: baseline;
  text-shadow: 
    0 2px 8px rgba(0,0,0,0.2),
    0 8px 32px rgba(74, 107, 120, 0.4),
    0 16px 48px rgba(166, 123, 74, 0.2);
  animation: titleGlow 3s ease-in-out infinite alternate;
}

.title-prompt {
  background: linear-gradient(135deg, 
    var(--morandi-title-cool-dark) 0%, 
    var(--morandi-title-sky-dark) 30%,
    var(--morandi-title-lavender-dark) 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  position: relative;
}

.title-meet {
  background: linear-gradient(135deg, 
    var(--morandi-title-warm-dark) 0%, 
    var(--morandi-title-peach-dark) 50%,
    var(--morandi-title-golden-dark) 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  margin-left: 2px;
  position: relative;
}

.title-accent-line {
  position: absolute;
  bottom: -4px;
  left: 0;
  right: 0;
  height: 3px;
  background: linear-gradient(90deg, 
    var(--morandi-accent-cool), 
    var(--morandi-accent-warm), 
    var(--morandi-accent-sage));
  border-radius: 2px;
  animation: lineFlow 2s ease-in-out infinite;
  box-shadow: 0 2px 8px rgba(123, 163, 184, 0.4);
}

.hero-subtitle {
  font-size: 16px;
  font-weight: 500;
  color: var(--morandi-text-secondary);
  margin: 0;
  letter-spacing: 2px;
  text-transform: uppercase;
  position: relative;
  opacity: 0.9;
  animation: subtitleFade 2s ease-in-out infinite alternate;
}

/* 动态粒子效果 */
.title-particles {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  pointer-events: none;
  overflow: hidden;
}

.particle {
  position: absolute;
  width: 4px;
  height: 4px;
  border-radius: 50%;
  opacity: 0.6;
}

.particle-1 {
  background: var(--morandi-accent-cool);
  top: 20%;
  left: 80%;
  animation: float1 4s ease-in-out infinite;
}

.particle-2 {
  background: var(--morandi-accent-warm);
  top: 60%;
  left: 10%;
  animation: float2 3s ease-in-out infinite;
}

.particle-3 {
  background: var(--morandi-accent-sage);
  top: 30%;
  left: 60%;
  animation: float3 5s ease-in-out infinite;
}

/* 动画效果 */
@keyframes titleGlow {
  0% { 
    text-shadow: 
      0 2px 8px rgba(0,0,0,0.2),
      0 8px 32px rgba(74, 107, 120, 0.4),
      0 16px 48px rgba(166, 123, 74, 0.2);
  }
  100% { 
    text-shadow: 
      0 2px 8px rgba(0,0,0,0.3),
      0 8px 32px rgba(74, 107, 120, 0.6),
      0 16px 64px rgba(166, 123, 74, 0.4),
      0 24px 80px rgba(107, 74, 120, 0.3);
  }
}

@keyframes lineFlow {
  0% { transform: scaleX(0.8); opacity: 0.8; }
  50% { transform: scaleX(1); opacity: 1; }
  100% { transform: scaleX(0.8); opacity: 0.8; }
}

@keyframes subtitleFade {
  0% { opacity: 0.7; }
  100% { opacity: 1; }
}

@keyframes float1 {
  0%, 100% { transform: translate(0, 0) scale(1); opacity: 0.6; }
  50% { transform: translate(10px, -15px) scale(1.2); opacity: 0.8; }
}

@keyframes float2 {
  0%, 100% { transform: translate(0, 0) scale(1); opacity: 0.6; }
  50% { transform: translate(-8px, -12px) scale(1.1); opacity: 0.9; }
}

@keyframes float3 {
  0%, 100% { transform: translate(0, 0) scale(1); opacity: 0.6; }
  50% { transform: translate(12px, -10px) scale(1.3); opacity: 0.7; }
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
  background: rgba(212, 181, 176, 0.2);
  border-radius: 20px;
  transition: all 0.3s ease;
}

.status-indicator.active {
  background: rgba(156, 175, 158, 0.2);
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--morandi-rose);
  animation: pulse 2s infinite;
}

.status-indicator.active .status-dot {
  background: var(--morandi-sage);
}

.status-text {
  font-size: 12px;
  font-weight: 500;
  color: var(--morandi-text-secondary);
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
  background: linear-gradient(135deg, var(--morandi-accent-cool), var(--morandi-sky));
  color: white;
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
}

.control-btn.primary.active {
  background: linear-gradient(135deg, var(--morandi-coral), var(--morandi-accent-rose));
  box-shadow: 0 4px 12px var(--morandi-shadow-heavy);
}

.control-btn.secondary {
  background: linear-gradient(135deg, var(--morandi-accent-warm), var(--morandi-accent-peach));
  color: white;
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
}

.control-btn.secondary.recording {
  background: linear-gradient(135deg, var(--morandi-coral), var(--morandi-accent-rose));
  animation: recording-pulse 1.5s infinite;
}

.control-btn.info {
  background: linear-gradient(135deg, var(--morandi-lavender), var(--morandi-accent-lavender));
  color: white;
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
}

.control-btn.warning {
  background: linear-gradient(135deg, var(--morandi-golden), var(--morandi-accent-warm));
  color: white;
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
}

.control-btn.success {
  background: linear-gradient(135deg, var(--morandi-sage), var(--morandi-mint));
  color: white;
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
}

.control-btn:disabled {
  background: var(--morandi-gray-300);
  color: var(--morandi-text-tertiary);
  cursor: not-allowed;
  box-shadow: none;
}

.control-btn:hover:not(:disabled) {
  transform: translateY(-2px);
  box-shadow: 0 6px 16px var(--morandi-shadow-heavy);
}

.btn-icon {
  font-size: 16px;
}

@keyframes recording-pulse {
  0% { box-shadow: 0 4px 12px var(--morandi-shadow-medium); }
  50% { box-shadow: 0 4px 20px var(--morandi-shadow-heavy); }
  100% { box-shadow: 0 4px 12px var(--morandi-shadow-medium); }
}

/* 聊天容器 - 对话区域专用配色 */
.chat-container {
  flex: 1;
  background: var(--morandi-glass-chat);
  backdrop-filter: blur(15px);
  border-radius: 20px;
  border: 1px solid var(--morandi-gray-400);
  box-shadow: 0 8px 32px var(--morandi-shadow-light);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.chat-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 20px 24px;
  background: linear-gradient(135deg, rgba(148, 167, 155, 0.15), rgba(184, 160, 130, 0.15));
  border-bottom: 1px solid var(--morandi-gray-400);
}

.chat-header h3 {
  font-size: 18px;
  font-weight: 600;
  color: var(--morandi-text-chat);
  margin: 0;
}

.chat-status {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: var(--morandi-sage);
}

.online-indicator {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--morandi-sage);
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
  background: var(--morandi-gray-400);
  border-radius: 3px;
}

.chat-messages::-webkit-scrollbar-thumb {
  background: var(--morandi-gray-500);
  border-radius: 3px;
}

/* 简约随机问题欢迎界面 */
.chat-welcome {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 60vh;
  padding: 60px 40px;
}

.welcome-container {
  text-align: center;
  max-width: 600px;
  animation: welcomeFadeIn 1.5s ease-out;
}

.welcome-question {
  font-size: 36px;
  font-weight: 300;
  line-height: 1.3;
  color: var(--morandi-text-chat);
  background: linear-gradient(135deg, 
    var(--morandi-title-cool-dark) 0%, 
    var(--morandi-title-warm-dark) 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
  animation: questionFloat 4s ease-in-out infinite;
  text-shadow: 0 4px 12px rgba(74, 107, 120, 0.2);
  font-family: 'SF Pro Display', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  letter-spacing: -0.5px;
}

/* 问题浮动动画 */
@keyframes welcomeFadeIn {
  from {
    opacity: 0;
    transform: translateY(30px) scale(0.95);
  }
  to {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

@keyframes questionFloat {
  0%, 100% {
    transform: translateY(0) scale(1);
  }
  50% {
    transform: translateY(-5px) scale(1.02);
  }
}

.message-wrapper {
  margin-bottom: 20px;
  animation: messageSlideIn 0.3s ease-out;
}

@keyframes messageSlideIn {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
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
  background: linear-gradient(135deg, var(--morandi-gray-100), var(--morandi-accent-primary));
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
  flex-shrink: 0;
}

.user-message .message-avatar {
  background: linear-gradient(135deg, var(--morandi-sage), var(--morandi-gray-100));
}

.message-content {
  max-width: 70%;
}

.message-bubble {
  background: var(--morandi-chat-bg);
  padding: 12px 16px;
  border-radius: 16px;
  border: 1px solid var(--morandi-gray-400);
  font-size: 14px;
  line-height: 1.5;
  color: var(--morandi-text-chat);
  word-wrap: break-word;
}

.user-message .message-bubble {
  background: linear-gradient(135deg, var(--morandi-gray-100), var(--morandi-accent-primary));
  border: 1px solid var(--morandi-gray-500);
  color: white;
}

.message-time {
  font-size: 11px;
  color: var(--morandi-text-tertiary);
  margin-top: 4px;
  text-align: right;
}

.user-message .message-time {
  text-align: left;
}

/* 消息内容格式化样式 */
.message-html {
  line-height: 1.6;
}

.message-text {
  line-height: 1.5;
}

/* AI消息中的Markdown样式 - 莫兰迪风格 */
.message-html h1, .message-html h2, .message-html h3, .message-html h4, .message-html h5, .message-html h6 {
  margin: 8px 0 4px 0;
  color: var(--morandi-text-primary);
  font-weight: 600;
}

.message-html h1 { font-size: 18px; }
.message-html h2 { font-size: 16px; }
.message-html h3 { font-size: 15px; }
.message-html h4 { font-size: 14px; }
.message-html h5 { font-size: 13px; }
.message-html h6 { font-size: 12px; }

.message-html p {
  margin: 8px 0;
  line-height: 1.5;
}

.message-html ul, .message-html ol {
  margin: 8px 0;
  padding-left: 20px;
}

.message-html li {
  margin: 4px 0;
  line-height: 1.5;
}

.message-html ul li {
  list-style-type: none;
  position: relative;
}

.message-html ul li::before {
  content: "•";
  color: var(--morandi-accent-primary);
  font-weight: bold;
  position: absolute;
  left: -16px;
}

.message-html ol li {
  list-style-type: none;
  position: relative;
  counter-increment: item;
}

.message-html ol {
  counter-reset: item;
}

.message-html ol li::before {
  content: counter(item) ".";
  color: var(--morandi-accent-primary);
  font-weight: bold;
  position: absolute;
  left: -20px;
  width: 16px;
  text-align: right;
}

.message-html blockquote {
  margin: 8px 0;
  padding: 8px 12px;
  background: rgba(168, 178, 165, 0.1);
  border-left: 4px solid var(--morandi-accent-primary);
  border-radius: 4px;
  color: var(--morandi-text-secondary);
  font-style: italic;
}

.message-html code {
  background: var(--morandi-gray-300);
  padding: 2px 4px;
  border-radius: 3px;
  font-family: 'Monaco', 'Consolas', 'Courier New', monospace;
  font-size: 12px;
  color: var(--morandi-accent-tertiary);
}

/* DeepSeek风格Markdown增强样式（scoped穿透） */
:deep(pre.hljs) {
  background: #23272e !important;
  border-radius: 10px;
  padding: 18px 16px 16px 16px;
  margin: 16px 0;
  font-size: 14px;
  font-family: 'JetBrains Mono', 'Fira Mono', 'Consolas', 'Menlo', monospace;
  overflow-x: auto;
  position: relative;
  box-shadow: 0 2px 8px rgba(30, 34, 40, 0.08);
}

:deep(pre.hljs) .code-lang-label {
  position: absolute;
  top: 8px;
  right: 60px;
  background: #4f8cff;
  color: #fff;
  font-size: 12px;
  padding: 2px 10px;
  border-radius: 8px;
  font-family: 'JetBrains Mono', monospace;
  z-index: 10;
  pointer-events: none;
  display: inline-block !important;
}

:deep(pre.hljs) .copy-btn {
  position: absolute;
  top: 8px;
  right: 16px;
  background: #23272e;
  color: #fff;
  border: 1px solid #4f8cff;
  border-radius: 6px;
  font-size: 12px;
  padding: 2px 10px;
  cursor: pointer;
  z-index: 10;
  transition: background 0.2s, color 0.2s;
  display: inline-block !important;
}
:deep(pre.hljs) .copy-btn:hover {
  background: #4f8cff;
  color: #fff;
}

:deep(.message-html) pre {
  background: #23272e;
  color: #f8f8f2;
  border-radius: 10px;
  padding: 18px 16px 16px 16px;
  margin: 16px 0;
  font-size: 14px;
  font-family: 'JetBrains Mono', 'Fira Mono', 'Consolas', 'Menlo', monospace;
  overflow-x: auto;
  position: relative;
  box-shadow: 0 2px 8px rgba(30, 34, 40, 0.08);
}

:deep(.message-html) pre code {
  background: none;
  color: inherit;
  padding: 0;
  font-size: inherit;
  font-family: inherit;
}

:deep(.message-html) code {
  background: #f4f4f5;
  color: #d63384;
  border-radius: 4px;
  padding: 2px 6px;
  font-size: 13px;
  font-family: 'JetBrains Mono', 'Fira Mono', 'Consolas', 'Menlo', monospace;
}

:deep(.message-html) blockquote {
  border-left: 4px solid #4f8cff;
  background: #f6f8fa;
  color: #444;
  padding: 12px 18px;
  margin: 16px 0;
  border-radius: 8px;
  font-style: normal;
}

:deep(.message-html) h1,
:deep(.message-html) h2,
:deep(.message-html) h3,
:deep(.message-html) h4 {
  color: #22223b;
  font-weight: 700;
  margin: 18px 0 10px 0;
  line-height: 1.3;
}

:deep(.message-html) p {
  color: #34344a;
  margin: 10px 0;
  line-height: 1.7;
}

:deep(.message-html) ul,
:deep(.message-html) ol {
  margin: 12px 0 12px 28px;
  color: #34344a;
}

:deep(.message-html) li {
  margin: 6px 0;
  line-height: 1.7;
}

:deep(.message-html) blockquote {
  border-left: 4px solid #4f8cff;
  background: #f4f7fa;
  color: #4a5568;
  padding: 12px 18px;
  margin: 16px 0;
  border-radius: 8px;
  font-style: normal;
  font-size: 15px;
}

:deep(.message-html) table {
  width: 100%;
  border-collapse: collapse;
  margin: 16px 0;
  font-size: 14px;
  background: #f8fafd;
  border-radius: 8px;
  overflow: hidden;
}

:deep(.message-html) th,
:deep(.message-html) td {
  border: 1px solid #e3e8ee;
  padding: 8px 12px;
  text-align: left;
}

:deep(.message-html) th {
  background: #eaf1fb;
  color: #23272e;
  font-weight: 600;
}

:deep(.message-html) a {
  color: #2563eb;
  text-decoration: underline;
  transition: color 0.2s;
  word-break: break-all;
}

:deep(.message-html) a:hover {
  color: #4f8cff;
  background: #eaf1fb;
}

:deep(.message-html) strong {
  color: #22223b;
  font-weight: 700;
}

:deep(.message-html) em {
  color: #4f8cff;
  font-style: italic;
}

:deep(.message-html) hr {
  border: none;
  border-top: 1px solid #e3e8ee;
  margin: 18px 0;
}



/* 用户消息保持简单样式 */
.user-message .message-bubble {
  background: linear-gradient(135deg, #667eea, #764ba2);
  color: white;
}

.user-message .message-text {
  color: white;
}

/* 推荐问题 */
.suggestions {
  padding: 16px 20px;
  border-top: 1px solid rgba(0, 0, 0, 0.05);
  background: rgba(102, 126, 234, 0.02);
}

.suggestions-title {
  font-size: 13px;
  color: #1b5e20;
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
  background: rgba(27, 94, 32, 0.08);
  border: 1px solid rgba(27, 94, 32, 0.2);
  color: #1b5e20;
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
  background: rgba(27, 94, 32, 0.15);
  border-color: rgba(27, 94, 32, 0.3);
  transform: translateY(-1px);
  box-shadow: 0 2px 8px rgba(27, 94, 32, 0.2);
}

.suggestion-chip:active {
  transform: translateY(0);
  box-shadow: 0 1px 4px rgba(27, 94, 32, 0.3);
}

/* 输入区域 - 对话区域专用配色 */
.chat-input-container {
  padding: 20px;
  border-top: 1px solid var(--morandi-gray-400);
}

.input-wrapper {
  display: flex;
  gap: 12px;
  align-items: center;
}

.chat-input {
  flex: 1;
  padding: 12px 16px;
  border: 2px solid var(--morandi-gray-400);
  border-radius: 20px;
  font-size: 14px;
  outline: none;
  transition: all 0.3s ease;
  background: var(--morandi-bg-tertiary);
  color: var(--morandi-text-chat);
}

.chat-input:focus {
  border-color: var(--morandi-accent-sage);
  box-shadow: 0 0 0 3px rgba(168, 184, 154, 0.15);
}

.send-btn {
  width: 44px;
  height: 44px;
  border: none;
  border-radius: 22px;
  background: linear-gradient(135deg, var(--morandi-accent-sage), var(--morandi-mint));
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
  box-shadow: 0 4px 12px var(--morandi-shadow-medium);
}

.send-btn:disabled {
  background: var(--morandi-gray-300);
  cursor: not-allowed;
}

/* 右侧面板 - 记录和摘要区域 */
.right-panel {
  width: 380px;
  background: var(--morandi-glass-record);
  backdrop-filter: blur(15px);
  border-radius: 20px;
  border: 1px solid var(--morandi-gray-400);
  box-shadow: 0 8px 32px var(--morandi-shadow-light);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  transition: all 0.3s ease;
}

.right-panel.expanded {
  width: 600px;
}

.panel-tabs {
  display: flex;
  background: rgba(148, 158, 155, 0.08);
  border-bottom: 1px solid var(--morandi-gray-400);
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
  color: var(--morandi-text-secondary);
  position: relative;
}

.tab-btn.active {
  color: var(--morandi-accent-cool);
  background: rgba(123, 163, 184, 0.15);
}

.tab-btn.active::after {
  content: '';
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: linear-gradient(135deg, var(--morandi-accent-cool), var(--morandi-sky));
}

.tab-btn:hover:not(.active) {
  background: rgba(148, 158, 155, 0.05);
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

/* 会议记录面板 - 淡雅蓝灰背景 */
.record-panel {
  background: var(--morandi-record-bg);
  color: var(--morandi-text-record);
}

/* 摘要面板 - 轻柔玫瑰白背景 */
.summary-panel {
  background: var(--morandi-summary-bg);
  color: var(--morandi-text-summary);
}

.tab-panel::-webkit-scrollbar {
  width: 6px;
}

.tab-panel::-webkit-scrollbar-track {
  background: var(--morandi-gray-400);
  border-radius: 3px;
}

.tab-panel::-webkit-scrollbar-thumb {
  background: var(--morandi-gray-500);
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
  color: var(--morandi-text-secondary);
}

.empty-icon {
  font-size: 48px;
  margin-bottom: 16px;
  opacity: 0.6;
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
  background: linear-gradient(to bottom, var(--morandi-gray-100), var(--morandi-accent-primary));
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
  background: linear-gradient(135deg, var(--morandi-gray-100), var(--morandi-accent-primary));
  box-shadow: 0 2px 8px var(--morandi-shadow-medium);
}

.timeline-content {
  background: var(--morandi-bg-tertiary);
  padding: 16px;
  border-radius: 12px;
  border: 1px solid var(--morandi-gray-400);
  box-shadow: 0 2px 8px var(--morandi-shadow-light);
}

.timeline-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.speaker {
  font-weight: 600;
  color: var(--morandi-accent-primary);
  font-size: 14px;
}

.timestamp {
  font-size: 11px;
  color: var(--morandi-text-tertiary);
}

.timeline-text {
  font-size: 13px;
  line-height: 1.5;
  color: var(--morandi-text-record);
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
  border-bottom: 1px solid var(--morandi-gray-400);
}

.summary-header h4 {
  font-size: 18px;
  color: var(--morandi-text-summary);
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
  padding: 0;
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

/* 会议摘要专用 Markdown 结构化样式 */
:deep(.summary-content) h1,
:deep(.summary-content) h2,
:deep(.summary-content) h3,
:deep(.summary-content) h4,
:deep(.summary-content) h5,
:deep(.summary-content) h6 {
  margin: 24px 0 12px 0;
  padding: 8px 0;
  font-weight: 700;
  line-height: 1.3;
  position: relative;
  color: #1a1a1a;
}

:deep(.summary-content) h1 {
  font-size: 24px;
  color: #1a1a1a;
  border-bottom: 2px solid #333;
  padding-bottom: 8px;
  margin-top: 0;
}

:deep(.summary-content) h1::before {
  content: "📋";
  margin-right: 8px;
  font-size: 22px;
}

:deep(.summary-content) h2 {
  font-size: 20px;
  color: #2d2d2d;
  border-left: 4px solid #666;
  padding-left: 12px;
  background: rgba(0, 0, 0, 0.02);
  border-radius: 0 8px 8px 0;
  margin-left: -8px;
  padding-right: 8px;
}

:deep(.summary-content) h2::before {
  content: "📌";
  margin-right: 8px;
  font-size: 18px;
}

:deep(.summary-content) h3 {
  font-size: 18px;
  color: #333;
  padding-left: 20px;
  position: relative;
}

:deep(.summary-content) h3::before {
  content: "▶";
  position: absolute;
  left: 0;
  color: #666;
  font-size: 14px;
  top: 50%;
  transform: translateY(-50%);
}

:deep(.summary-content) h4 {
  font-size: 16px;
  color: #404040;
  padding-left: 28px;
  position: relative;
}

:deep(.summary-content) h4::before {
  content: "•";
  position: absolute;
  left: 8px;
  color: #666;
  font-size: 16px;
  top: 50%;
  transform: translateY(-50%);
}

:deep(.summary-content) h5,
:deep(.summary-content) h6 {
  font-size: 15px;
  color: #4a4a4a;
  font-weight: 600;
  margin: 16px 0 8px 0;
}

:deep(.summary-content) p {
  margin: 12px 0;
  line-height: 1.7;
  color: #333;
  text-align: justify;
}

:deep(.summary-content) ul,
:deep(.summary-content) ol {
  margin: 16px 0;
  padding-left: 24px;
  color: #333;
}

:deep(.summary-content) ul {
  list-style: none;
}

:deep(.summary-content) ul li {
  position: relative;
  margin: 8px 0;
  padding-left: 20px;
  line-height: 1.6;
}

:deep(.summary-content) ul li::before {
  content: "●";
  position: absolute;
  left: 0;
  color: #666;
  font-size: 12px;
  top: 0.3em;
}

:deep(.summary-content) ul ul li::before {
  content: "○";
  color: #666;
}

:deep(.summary-content) ul ul ul li::before {
  content: "▪";
  color: #666;
}

:deep(.summary-content) ol {
  counter-reset: item;
}

:deep(.summary-content) ol li {
  position: relative;
  margin: 8px 0;
  padding-left: 8px;
  line-height: 1.6;
  counter-increment: item;
}

:deep(.summary-content) ol li::before {
  content: counter(item) ".";
  position: absolute;
  left: -20px;
  color: #666;
  font-weight: 600;
  width: 16px;
  text-align: right;
}

:deep(.summary-content) blockquote {
  margin: 16px 0;
  padding: 16px 20px;
  background: rgba(0, 0, 0, 0.03);
  border-left: 4px solid #666;
  border-radius: 0 12px 12px 0;
  color: #555;
  font-style: normal;
  position: relative;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
}

:deep(.summary-content) blockquote::before {
  content: "💡";
  position: absolute;
  top: 12px;
  left: -14px;
  background: white;
  padding: 4px;
  border-radius: 50%;
  font-size: 12px;
  box-shadow: 0 2px 4px var(--morandi-shadow-medium);
}

:deep(.summary-content) code {
  background: #f5f5f5;
  color: #333;
  padding: 2px 6px;
  border-radius: 4px;
  font-family: 'JetBrains Mono', 'Consolas', monospace;
  font-size: 13px;
  font-weight: 500;
}

:deep(.summary-content) pre {
  background: #f8f9fa;
  border: 1px solid var(--morandi-gray-400);
  border-radius: 8px;
  padding: 16px;
  margin: 16px 0;
  overflow-x: auto;
  font-family: 'JetBrains Mono', 'Consolas', monospace;
  font-size: 13px;
  line-height: 1.5;
}

:deep(.summary-content) pre code {
  background: none;
  padding: 0;
  border-radius: 0;
  font-size: inherit;
  color: #333;
}

:deep(.summary-content) table {
  width: 100%;
  border-collapse: collapse;
  margin: 20px 0;
  background: white;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 2px 8px var(--morandi-shadow-light);
}

:deep(.summary-content) th,
:deep(.summary-content) td {
  padding: 12px 16px;
  text-align: left;
  border-bottom: 1px solid var(--morandi-gray-400);
}

:deep(.summary-content) th {
  background: linear-gradient(135deg, 
    var(--morandi-gray-100), 
    var(--morandi-accent-primary));
  color: white;
  font-weight: 600;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

:deep(.summary-content) td {
  color: #333;
  font-size: 14px;
}

:deep(.summary-content) tr:nth-child(even) td {
  background: rgba(168, 184, 154, 0.03);
}

:deep(.summary-content) tr:hover td {
  background: rgba(168, 184, 154, 0.08);
}

:deep(.summary-content) hr {
  border: none;
  height: 1px;
  background: linear-gradient(90deg, 
    transparent, 
    var(--morandi-gray-400), 
    transparent);
  margin: 24px 0;
}

:deep(.summary-content) strong {
  color: #1a1a1a;
  font-weight: 700;
}

:deep(.summary-content) em {
  color: #444;
  font-style: italic;
  font-weight: 500;
}

:deep(.summary-content) a {
  color: #333;
  text-decoration: none;
  border-bottom: 1px dotted #666;
  transition: all 0.3s ease;
}

:deep(.summary-content) a:hover {
  color: #1a1a1a;
  border-bottom-style: solid;
  background: rgba(0, 0, 0, 0.05);
  padding: 2px 4px;
  border-radius: 4px;
}

/* 特殊内容块样式 */
:deep(.summary-content) .highlight-box {
  background: linear-gradient(135deg, 
    rgba(168, 184, 154, 0.1), 
    rgba(212, 181, 176, 0.1));
  border: 1px solid var(--morandi-gray-400);
  border-radius: 12px;
  padding: 20px;
  margin: 20px 0;
  position: relative;
}

:deep(.summary-content) .highlight-box::before {
  content: "⭐";
  position: absolute;
  top: -8px;
  left: 16px;
  background: white;
  padding: 4px 8px;
  border-radius: 12px;
  font-size: 14px;
  box-shadow: 0 2px 4px var(--morandi-shadow-medium);
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
  
  .sidebar.collapsed {
    width: 60px;
  }
  
  .right-panel {
    width: 320px;
  }
  
  .right-panel.expanded {
    width: 520px;
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
  
  .sidebar.collapsed {
    width: 100%;
    max-height: 80px;
  }
  
  .sidebar.collapsed .sidebar-header {
    padding: 16px;
    justify-content: center;
  }
  
  .right-panel {
    width: 100%;
    order: 3;
  }
  
  .right-panel.expanded {
    width: 100%;
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