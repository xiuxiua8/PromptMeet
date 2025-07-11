<template>
  <div class="controller-box">
    <div class="logo-title-row">
      <img src="../assets/xjtu.png" alt="Logo" class="logo-img" />
      <span class="app-title">PromptMeet智能会议助手</span>
      <span class="status-indicator" :class="{ running: isRunning, stopped: !isRunning }"></span>
    </div>
    <div class="button-row">
      <button class="start-btn" :disabled="isRunning" @click="startSession">开始</button>
      <button class="stop-btn" :disabled="!isRunning" @click="stopSession">终止</button>
    </div>
  </div>
</template>

<script setup>
import { ref } from 'vue'
function startSession() {
  isRunning.value = true
}
function stopSession() {
  isRunning.value = false
}
</script>

<style scoped>
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
.start-btn, .stop-btn {
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
</style>