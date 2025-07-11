<script setup>
import { ref } from 'vue'
// 聊天相关逻辑
const chatInput = ref('')
const chatMessages = ref([])
const recommendTexts = ref([])

// 模拟后端API获取推荐文字
setTimeout(() => {
  recommendTexts.value = [
    '这是推荐内容一，点击可快速输入',
    '这是推荐内容二，点击可快速输入',
    '这是推荐内容三，点击可快速输入'
  ]
}, 1000)

function sendMessage() {
  const text = chatInput.value.trim()
  if (text) {
    chatMessages.value.push({ text, from: 'user' })
    chatInput.value = ''
    // 滚动到底部
    setTimeout(() => {
      const display = document.querySelector('.chat-display')
      if (display) display.scrollTop = display.scrollHeight
    }, 0)
    // 模拟服务端回复
    setTimeout(() => {
      chatMessages.value.push({ text: '这是AI的回复：' + text, from: 'ai' })
      setTimeout(() => {
        const display = document.querySelector('.chat-display')
        if (display) display.scrollTop = display.scrollHeight
      }, 0)
    }, 800)
  }
}

function onInputKeydown(e) {
  if (e.key === 'Enter') {
    sendMessage()
  }
}

function handleRecommendClick(text) {
  chatInput.value = text
}
</script>

<template>
  <div class="chat-box">
    <div class="chat-display">
      <!-- 聊天内容显示区域 -->
      <template v-if="chatMessages.length === 0">
        <div class="chat-welcome">
          <el-icon size="20"><ChatDotRound /></el-icon>
          我是XXX，很高兴见到你！
        </div>
      </template>
      <template v-else>
        <div v-for="(msg, idx) in chatMessages" :key="idx"
          :class="['chat-message', msg.from === 'user' ? 'chat-message-right' : 'chat-message-left']">
          <span v-if="msg.from === 'user'">{{ msg.text }}</span>
          <span v-else>{{ msg.text }}</span>
        </div>
      </template>
    </div>
    <div v-if="recommendTexts.length" class="recommend-bar">
      <button v-for="(txt, i) in recommendTexts" :key="i" class="recommend-btn" @click="handleRecommendClick(txt)" :title="txt">{{ txt }}</button>
    </div>
    <div class="chat-input">
      <input type="text" v-model="chatInput" placeholder="请输入内容..." @keydown="onInputKeydown" />
      <button @click="sendMessage">发送</button>
    </div>
  </div>
</template>

<style scoped>
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
</style>