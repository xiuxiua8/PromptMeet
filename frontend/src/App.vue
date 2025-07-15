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

<template>
  <div class="main-layout">
    <!-- 历史会议侧边栏，放在最左侧 -->
    <div class="sidebar">
      <div class="history-sidebar"
        v-for="session in historySession"
        :key="session.session_id"
        :class="['history-session-item']"
        @click="gainSession(session.session_id)"
      >
        {{ session.key_points[0]}}
      </div>
    </div>
    <div class="left-panel">
      <div class="controller-box">
        <div class="logo-title-row">
          <img src="./assets/xjtu.png" alt="Logo" class="logo-img" />
          <span class="app-title">PromptMeet智能会议助手</span>
          <span class="status-indicator" :class="{ running: isRunning, stopped: !isRunning }"></span>
        </div>
        <div class="button-row">
          <button class="start-btn" :class="{ running: isRunning }" @click="handleStart">
            {{ isRunning ? '结束' : '开始' }}
          </button>
          <button class="record-btn" :disabled="!isRunning" :class="{ recording: isRecording }" @click="handleRecord">
            {{ isRecording ? '停止' : '录音' }}
          </button>
          <button class="screenshot-btn" :disabled="!isRunning" @click="handleScreenshot" style="margin-left:auto;">截图</button>
          <button class="stop-btn" :disabled="!isRunning" @click="handleCreateSummary">生成摘要</button>
          <button class="save-btn" :disabled="!isRunning" @click="saveSession">保存</button>
        </div>
      </div>
      <div class="chat-box">
        <div class="chat-display" ref="chatDisplay">
          <!-- 聊天内容显示区域 -->
          <template v-if="qa.length === 0">
            <div class="chat-welcome">
              <el-icon size="20"><ChatDotRound /></el-icon>
              我是XXX，很高兴见到你！
            </div>
          </template>
          <template v-else>
            <div v-for="(msg, idx) in qa" :key="idx"
              :class="['chat-message', msg.from === 'user' ? 'chat-message-right' : 'chat-message-left']">
              <span v-if="msg.from === 'user'">{{ msg.content }}</span>
              <span v-else>{{ msg.content }}</span>
            </div>
          </template>
        </div>
        <div v-if="questions.length" class="recommend-bar">
          <button v-for="(txt, i) in questions" :key="i" class="recommend-btn" @click="handleRecommendClick(txt)" :title="txt">{{ txt }}</button>
        </div>
        <div class="chat-input">
          <input type="text" v-model="message" placeholder="请输入内容..." @keydown="onInputKeydown" />
          <button @click="sendMessage">发送</button>
        </div>
      </div>
    </div>
    <div class="right-panel">
      <div class="nav-bar">
        <button :class="{ active: activeTab === 'tab1' }" @click="activeTab = 'tab1'">记录</button>
        <button :class="{ active: activeTab === 'tab2' }" @click="activeTab = 'tab2'">总结</button>
      </div>
      <div class="tab-content" v-if="activeTab === 'tab1'">
        <el-timeline style="max-width:475px">
          <el-timeline-item v-for="(msg, index) in chatHistory" :key="index" :timestamp="msg.time" placement="top">
            <el-card>
              <p>{{ msg.content }}</p>
            </el-card>
          </el-timeline-item>
        </el-timeline>
      </div>
      <div class="tab-content" v-else>
        <div class="summary">
          <p v-html="renderedSummary"></p>
        </div>
      </div>
    </div>
    <!-- 窗口选择模态框 -->
    <div v-if="showWindowSelection" class="window-selection-modal">
      <div class="modal-overlay" @click="cancelWindowSelection"></div>
      <div class="modal-content">
        <div class="modal-header">
          <h3>选择要截图的窗口</h3>
          <button class="close-btn" @click="cancelWindowSelection">×</button>
        </div>
        <div class="modal-body">
          <div class="window-list">
            <div 
              v-for="window in availableWindows" 
              :key="window.id"
              class="window-item"
              @click="selectWindow(window.id)"
            >
              <div class="window-icon">🖼️</div>
              <div class="window-info">
                <div class="window-title">{{ window.title }}</div>
                <div class="window-type">{{ window.type === 'window' ? '应用窗口' : window.type }}</div>
              </div>
            </div>
          </div>
        </div>
        <div class="modal-footer">
          <button class="cancel-btn" @click="cancelWindowSelection">取消</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
html, body, #app {
  height: 95vh;
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}
.main-layout {
  display: flex;
  width: 98vw;
  height: 95vh;
  min-height: 0;
  min-width: 0;
  justify-content: flex-start;
}
.sidebar {
  width: 150px;
  background: #f3f6fa;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.04);
  display: flex;
  flex-direction: column;
  align-items: stretch;
  height: 95vh;
  min-height: 0;
}
.history-sidebar {
  margin-top: 20px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 0 12px;
}
.left-panel {
  display: flex;
  flex-direction: column;
  width: 42%;
  height: 98vh;
  min-height: 0;
  gap: 10px;
  margin-left: 20px;
  padding: 24px 24px 24px 24px;
  box-sizing: border-box;
}
.controller-box {
  flex: 0 0 auto;
  background: #fff;
  margin-bottom: 6px;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.04);
  padding: 18px 24px 18px 24px;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  min-height: 120px;
  max-height: 330px;
  justify-content: center;
}
.logo-title-row {
  display: flex;
  align-items: center;
  gap: 16px;
  margin-bottom: 18px;
}
.logo-img {
  width: 50px;
  height: 50px;
}
.app-title {
  font-size: 1.7rem;
  font-weight: bold;
  color: #222;
}
.status-indicator {
  width: 16px;
  height: 16px;
  border-radius: 100%;
  margin-left: 16px;
  border: 2px solid #ccc;
  background: #f44336;
  transition: background 0.3s;
}
.status-indicator.running {
  background: #4caf50;
  border-color: #ffffff;
}
.status-indicator.stopped {
  background: #f44336;
  border-color: #ffffff;
}
.button-row {
  display: flex;
  gap: 16px;
}
.start-btn, .stop-btn, .save-btn, .screenshot-btn {
  padding: 6px 24px;
  font-size: 1rem;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.2s;
}
.screenshot-btn {
  background: #409eff;
  color: #fff;
}
.screenshot-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
.screenshot-btn:hover {
  background: #1f8fff
}
.screenshot-btn:disabled:hover {
  background: #bdbdbd !important;
  cursor: not-allowed;
}
.screenshot-btn {
  background: #409eff;
  color: #fff;
}
.screenshot-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
.screenshot-btn:hover {
  background: #1f8fff
}
.screenshot-btn:disabled:hover {
  background: #bdbdbd !important;
  cursor: not-allowed;
}
.start-btn {
  background: #4caf50;
  color: #fff;
}
.start-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
.stop-btn {
  background: #f44336;
  color: #fff;
}
.stop-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
.end-session-btn {
  background: #ff5722;
  color: #fff;
}
.end-session-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
.end-session-btn:hover {
  background: #e64a19;
}
.end-session-btn:disabled:hover {
  background: #bdbdbd !important;
  cursor: not-allowed;
}
.chat-box {
  flex: 1 1 0;
  display: flex;
  flex-direction: column;
  background: #eeeeee;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.04);
  padding: 12px;
  min-height: 240px;
}
.recommend-bar {
  display: flex;
  gap: 6px;
  justify-content: flex-start;
}
.recommend-btn {
  background: #f4f8fb;
  border: 1px solid #f4f8fb;
  color: #888888;
  border-radius: 16px;
  padding: 4px 6px;
  font-size: 12px;
  cursor: pointer;
  max-width: 33%;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.recommend-btn:hover {
  background: #e6f4ff;
}
.chat-display {
  flex: 1 1 0;
  overflow-y: overlay; /* 优先使用 overlay，不占用内容宽度 */
  border-bottom: 1px solid #eee;
  padding-bottom: 8px;
  padding-right: 8px;
  box-sizing: border-box;
}
/* Webkit 浏览器自定义滚动条样式 */
.chat-display::-webkit-scrollbar {
  width: 4px;
  background: transparent;
}
.chat-display::-webkit-scrollbar-thumb {
  background: rgba(0,0,0,0.15);
  border-radius: 4px;
}
.chat-message {
  margin-bottom: 8px;
  color: #333;
  word-break: break-all;
}
.chat-message-right {
  text-align: right;
  color: #333;
  /* 让内容靠右 */
  display: flex;
  justify-content: flex-end;
}
.chat-message-right > span {
  display: inline-block;
  background: #d6edff;
  color: #333;
  border-radius: 12px;
  padding: 3px 8px;
  max-width: 80%;
  box-shadow: 0 1px 4px rgba(64,158,255,0.06);
  font-size: 15px;
  text-align: left;
  border: 1px solid #d6edff;
}
.chat-message-left {
  text-align: left;
  color: #333;
  display: flex;
  justify-content: flex-start;
}
.chat-message-left > span {
  display: inline-block;
  background: none;
  color: #333;
  border-radius: 0;
  padding: 0;
  font-size: 15px;
  max-width: 80%;
  box-shadow: none;
  text-align: left;
  border: none;
}
.chat-input {
  display: flex;
  gap: 4px;
  margin-top: 4px;
}
.chat-input input {
  flex: 1;
  padding: 6px;
  border: 1px solid #ccc;
  border-radius: 4px;
}
.chat-input button {
  padding: 6px 16px;
  background: #409eff;
  color: #fff;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}
.chat-welcome {
  color: #000000;
  font-size: 24px;
  text-align: center;
  margin-top: 80px;
  margin-bottom: 40px;
}
.right-panel {
  flex: 1 1 0;
  display: flex;
  flex-direction: column;
  background: #eeeeee;
  margin: 24px 80px 24px 0;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.04);
  padding: 0 0 24px 0;
  box-sizing: border-box;
  height: 91vh;
  min-height: 0;
  overflow: hidden;
}
.nav-bar {
  display: flex;
  justify-content: flex-start;
  align-items: center;
  padding: 16px 16px 0 16px;
  border-bottom: 1px solid #dddddd;
}
.nav-bar button {
  background: none;
  border: none;
  padding: 8px 20px;
  font-size: 16px;
  cursor: pointer;
  border-radius: 4px 4px 0 0;
  color: #666;
}
.nav-bar button.active {
  background: #409eff;
  color: #fff;
}
.tab-content {
  flex: 1 1 0;
  padding: 10px 24px 0 0;
  /* background-color: #409eff; */
  overflow-y: overlay;
}
.tab-content::-webkit-scrollbar {
  width: 4px;
  background: transparent;
}
.tab-content::-webkit-scrollbar-thumb {
  background: rgba(0,0,0,0.15);
  border-radius: 4px;
}
.summary {
  padding-left: 45px;
  padding-right: 20px;
}
.summary p {
  word-break: break-all;
  /* white-space: pre-wrap; */
  /* 可选：限制最大宽度，防止撑大容器 */
  max-width: 100%;
}
.record-btn {
  background: #ff9800;
  color: #fff;
  padding: 6px 24px;
  font-size: 1rem;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.2s;
}
.record-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
.record-btn.recording {
  background: #d32f2f;
  color: #fff;
  box-shadow: 0 0 8px #d32f2f;
}
.save-btn {
  background: #0eb64c;
  color: #fff;
}
.save-btn:disabled {
  background: #bdbdbd;
  cursor: not-allowed;
}
/* 窗口选择模态框样式 */
.window-selection-modal {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 1000;
  display: flex;
  align-items: center;
  justify-content: center;
}

.modal-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.5);
}

.modal-content {
  position: relative;
  background: white;
  border-radius: 8px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
  min-width: 400px;
  max-width: 600px;
  max-height: 80vh;
  overflow: hidden;
}

.modal-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 20px;
  border-bottom: 1px solid #eee;
}

.modal-header h3 {
  margin: 0;
  font-size: 18px;
  color: #333;
}

.close-btn {
  background: none;
  border: none;
  font-size: 24px;
  cursor: pointer;
  color: #999;
  padding: 0;
  width: 24px;
  height: 24px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.close-btn:hover {
  color: #666;
}

.modal-body {
  padding: 20px;
  max-height: 400px;
  overflow-y: auto;
}

.window-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.window-item {
  display: flex;
  align-items: center;
  padding: 12px 16px;
  border: 1px solid #eee;
  border-radius: 6px;
  cursor: pointer;
  transition: all 0.2s;
}

.window-item:hover {
  border-color: #409eff;
  background: #f0f8ff;
}

.window-icon {
  font-size: 20px;
  margin-right: 12px;
  flex-shrink: 0;
}

.window-info {
  flex: 1;
}

.window-title {
  font-size: 16px;
  font-weight: 500;
  color: #333;
  margin-bottom: 4px;
}

.window-type {
  font-size: 12px;
  color: #666;
}

.modal-footer {
  padding: 16px 20px;
  border-top: 1px solid #eee;
  display: flex;
  justify-content: flex-end;
}

.cancel-btn {
  padding: 8px 16px;
  background: #f5f5f5;
  color: #666;
  border: 1px solid #ddd;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.2s;
}

.cancel-btn:hover {
  background: #e8e8e8;
}
.history-sidebar {
  width: 70%;
  margin-bottom: 16px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.history-session-item {
  padding: 8px 12px;
  border-radius: 4px;
  cursor: pointer;
  background: #f5f5f5;
  color: #333;
  transition: background 0.2s, color 0.2s;
  font-size: 15px;
}
.history-session-item.active {
  background: #409eff;
  color: #fff;
}
.history-session-item:hover {
  background: #e6f4ff;
}
.start-btn.running {
  background: #f44336;
  color: #fff;
  box-shadow: 0 0 8px #f44336;
}
</style>
