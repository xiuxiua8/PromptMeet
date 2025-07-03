<template>
  <div class="container">
    <!-- 左侧区域 -->
    <div class="left-section">
      <!-- 视频播放器 -->
      <div class="video-player">
        <video width="400" height="250" controls>
          <source src="" type="video/mp4">
          你的浏览器不支持 video 标签。
        </video>
      </div>
      <!-- 文本内容区域 -->
      <div class="text-content">
        <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus laoreet rutrum lobortis. Etiam lobortis
          auctor velit tempus posuere. Vestibulum so</p>
      </div>
      <!-- 输入框和按钮区域 -->
      <div class="input-btn-area">
        <div class="input-group">
          <input type="text" v-model="message" placeholder="Type a message...">
          <button class="send-btn" @click="sendMessage">Send</button>
        </div>
        <div class="vertical-buttons">
          <button class="btn-vertical">Button 1</button>
          <button class="btn-vertical">Button 2</button>
          <button class="btn-vertical">Button 3</button>
          <button class="btn-vertical">Button 4</button>
        </div>
      </div>
    </div>
    <!-- 右侧区域 -->
    <div class="right-section">
      <div class="tabs">
        <button class="tab" :class="{ active: activeTab === 'history' }" @click="openTab('history')">history</button>
        <button class="tab" :class="{ active: activeTab === 'summary' }" @click="openTab('summary')">summary</button>


      </div>
      <div id="history" class="tab-content" :class="{ active: activeTab === 'history' }">
        <div class="chat-message" v-for="(msg, index) in chatHistory" :key="index">
          <span class="sender">{{ msg.sender }} {{ msg.time }}</span>
          <p>{{ msg.content }}</p>
        </div>
      </div>
      <div id="summary" class="tab-content" :class="{ active: activeTab === 'summary' }">
        <p>Summary content will be here...</p>
      </div>
      <div id="tab3" class="tab-content" :class="{ active: activeTab === 'tab3' }">
        <p>Tab3 content will be here...</p>
      </div>
    </div>
  </div>
</template>

<script>
export default {
  data() {
    return {
      message: '',
      activeTab: 'history',
      chatHistory: [
        { sender: 'lecturer1', time: '09:24 AM', content: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus laoreet rutrum lobortis. Etiam lobortis auctor velit tempus posuere. Vestibulum so' },
        { sender: 'lecturer2', time: '09:24 AM', content: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus laoreet rutrum lobortis. Etiam lobortis auctor velit tempus posuere. Vestibulum so' }
      ]
    };
  },
  methods: {
    openTab(tabName) {
      this.activeTab = tabName;
    },
    sendMessage() {
      if (this.message.trim()) {
        const now = new Date();
        const timeString = now.getHours().toString().padStart(2, '0') + ':' + 
                           now.getMinutes().toString().padStart(2, '0');
        const newMessage = {
          sender: 'You',
          time: timeString,
          content: this.message
        };
        this.chatHistory.push(newMessage);
        this.message = '';
      }
    },
  },
  mounted() {
    this.openTab('history');
  }
};
</script>

<style scoped>
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  margin: 0;
  padding: 0;
  font-family: Arial, sans-serif;
}

.container {
  display: flex;
  width: 100%;
  padding: 20px;
  gap: 20px; /* 左右区域间距 */
}

.left-section {
  flex: 0 0 60%;
  display: flex;
  flex-direction: column;
  gap: 15px;
}

.video-player video {
  width: 100%;
  height: auto;
  border-radius: 5px;
}

.text-content {
  border: 1px solid #ddd;
  padding: 12px;
  border-radius: 5px;
  background-color: #f9f9f9;
  max-height: 120px;
  overflow-y: auto;
}

.input-btn-area {
  display: flex;
  gap: 10px;
  align-items: flex-start; /* 顶部对齐 */
}

.input-group {
  flex: 1;
  display: flex;
  max-width: calc(100% - 100px); /* 为按钮留出空间 */
}

.input-group input {
  flex: 1;
  padding: 8px 10px;
  border: 1px solid #ccc;
  border-radius: 4px 0 0 4px;
  font-size: 14px;
  height: 40px; /* 固定高度 */
}

.send-btn {
  padding: 8px 15px;
  background-color: #4CAF50;
  color: white;
  border: none;
  border-radius: 0 4px 4px 0;
  cursor: pointer;
  height: 40px; /* 固定高度 */
}

.vertical-buttons {
  display: flex;
  flex-direction: column;
  width: 80px; /* 按钮组宽度 */
}

.btn-vertical {
  padding: 10px 12px;
  background-color: #f0f0f0;
  border: 1px solid #ccc;
  cursor: pointer;
  text-align: center;
  white-space: nowrap;
  font-size: 14px;
}

.btn-vertical:not(:last-child) {
  border-bottom: none;
}

.btn-vertical:first-child {
  border-radius: 4px 4px 0 0;
}

.btn-vertical:last-child {
  border-radius: 0 0 4px 4px;
}

.btn-vertical:hover {
  background-color: #e0e0e0;
}

.right-section {
  flex: 0 0 35%; /* 稍微减小右侧区域宽度 */
  border: 1px solid #ccc;
  border-radius: 5px;
  padding: 15px;
  display: flex;
  flex-direction: column;
  gap: 15px;
  position: relative;
  background-color: white;
  box-shadow: 0 2px 5px rgba(0,0,0,0.1);
}

.tabs {
  display: flex;
  gap: 10px;
}

.tab {
  background-color: #f0f0f0;
  border: none;
  padding: 8px 12px;
  cursor: pointer;
  border-radius: 3px;
  font-size: 14px;
}

.tab.active {
  background-color: #ccc;
}

.close-btn {
  position: absolute;
  top: 15px;
  right: 15px;
  cursor: pointer;
  font-size: 18px;
  color: #666;
}

.tab-content {
  display: none;
  padding: 10px 0;
  max-height: calc(100vh - 150px);
  overflow-y: auto;
}

.tab-content.active {
  display: block;
}

.chat-message {
  margin-bottom: 15px;
  padding-bottom: 10px;
  border-bottom: 1px solid #eee;
}

.chat-message:last-child {
  border-bottom: none;
  margin-bottom: 0;
}

.sender {
  font-weight: bold;
  color: #333;
  display: block;
  margin-bottom: 5px;
}
</style>