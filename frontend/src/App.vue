<script>
import MarkdownIt from 'markdown-it';

export default {
  data() {
    return {
      isRunning:false,
      baseURL:'http://localhost:8000',
      wsbaseURL:'ws://localhost:8000',
      sessionid:'',
      message: '',
      activeTab: 'tab1',
      chatHistory: [
        { sender: 'lecturer1', time: '09:24 AM', content: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus laoreet rutrum lobortis. Etiam lobortis auctor velit tempus posuere. Vestibulum so' },
        { sender: 'lecturer2', time: '09:24 AM', content: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus laoreet rutrum lobortis. Etiam lobortis auctor velit tempus posuere. Vestibulum so' }
      ],
      data: {}, // 简化初始数据结构（根据后端返回调整）
      websocket: null, // 声明 websocket 变量，避免全局污染
      questions : new Array(),
      id : new Array(),
      receivedData: '',
      answer:'answer',
      summary:'会议结束后自动生成……',
      md : new MarkdownIt(),
      // 窗口选择相关
      availableWindows: [],
      selectedWindowId: null,
      showWindowSelection: false,
    };
  },
  computed: {
    // 计算属性将 Markdown 转换为 HTML
    renderedSummary() {
      return this.md.render(this.summary);
    },
  },
  methods: {
    async handleStartSession(){
      this.isRunning=true
      var url=`${this.baseURL}/api/sessions`
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
      const data = await response.json()
      this.sessionid=data.session_id
      this.websocket = new WebSocket(`${this.wsbaseURL}/ws/${this.sessionid}`);

      url=`${this.baseURL}/api/sessions/${this.sessionid}/start-recording`
      await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });
    },

    async handleStopSession(){
      this.isRunning=false
      var url=`${this.baseURL}/api/sessions/${this.sessionid}/stop-recording`
      await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
      });

      url=`${this.baseURL}/api/sessions/${this.sessionid}/generate-summary`
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

    async handleScreenshot(){
      // 首先获取可用窗口
      await this.getAvailableWindows();
      
      if (this.availableWindows.length === 0) {
        alert('未检测到会议窗口');
        return;
      }
      
      if (this.availableWindows.length === 1) {
        // 只有一个窗口，直接使用
        this.selectedWindowId = this.availableWindows[0].id;
        await this.performScreenshot();
      } else {
        // 多个窗口，显示选择界面
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
      
      // 关闭窗口选择界面
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
        this.websocket.send(JSON.stringify({
          input: this.message
        }));
        this.message = "";
      }
    },
    sendId(id) {
      this.websocket.send(JSON.stringify({
        input: id
      }));
    },

    ShowQuestion() {
        const num=this.receivedData.data.id;
        this.questions[num%3] = this.receivedData.data.content; // 存储后端数据
        this.id[num%3] = num;
    },
    ShowAnswer() {
      this.answer=this.receivedData.data.answer
    },
    ShowSummary() {
      this.summary=this.receivedData.data.summary_text
    },
    ShowHistory(){
      const chat={sender:this.receivedData.data.speaker, time:this.receivedData.timestamp, content:this.receivedData.data.text}
      this.chatHistory.push(chat)
    },
  },
  watch: {
    websocket(newVal, oldVal) {
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
        else{
          return
        }

      };
    }
  },
  mounted() {
    this.openTab('tab1');
  },
};
</script>

<template>
  <div class="main-layout">
    <div class="left-panel">
      <div class="controller-box">
        <div class="logo-title-row">
          <img src="./assets/xjtu.png" alt="Logo" class="logo-img" />
          <span class="app-title">PromptMeet智能会议助手</span>
          <span class="status-indicator" :class="{ running: isRunning, stopped: !isRunning }"></span>
        </div>
        <div class="button-row">
          <button class="start-btn" :disabled="isRunning" @click="handleStartSession">开始</button>
          <button class="stop-btn" :disabled="!isRunning" @click="handleStopSession">终止</button>
          <button class="screenshot-btn" :disabled="!isRunning" @click="handleScreenshot" style="margin-left:auto;">截图</button>
        </div>
      </div>
      <div class="chat-box">
        <div class="chat-display">
          <!-- 聊天内容显示区域 -->
          <template v-if="receivedData.length === 0">
            <div class="chat-welcome">
              <el-icon size="20"><ChatDotRound /></el-icon>
              我是XXX，很高兴见到你！
            </div>
          </template>
          <template v-else>
            <div v-for="(msg, idx) in receivedData" :key="idx"
              :class="['chat-message', msg.from === 'user' ? 'chat-message-right' : 'chat-message-left']">
              <span v-if="msg.from === 'user'">{{ msg }}</span>
              <span v-else>{{ msg }}</span>
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
body, html {
  height: 100vh;
  margin: 0;
}
.main-layout {
  display: flex;
  width: 80vw;
  height: 97vh;
  margin: auto;
  min-height: 500px;
  /* background-color: #f9f9f9; */
  /* align-items: center; */
  justify-content: center;
}
.left-panel {
  display: flex;
  flex-direction: column;
  width: 45%;
  height: 100%;
  gap: 10px;
  margin: 0 0 0 40px;
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
.start-btn, .stop-btn, .screenshot-btn {
  padding: 6px 24px;
  font-size: 1rem;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.2s;
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
  margin: 24px 60px 24px 0;
  border-radius: 8px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.04);
  padding: 0 0 24px 0;
  box-sizing: border-box;
}
.nav-bar {
  display: flex;
  padding: 16px 0 0 24px;
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
  max-width: 100%;
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
</style>
