<template>
  <el-timeline style="max-width:475px">
    <el-timeline-item v-for="(msg, index) in chatHistory" :key="index" :timestamp="msg.timestamp" placement="top">
      <el-card>
        <p>{{ msg.content }}</p>
      </el-card>
    </el-timeline-item>
  </el-timeline>
</template>

<script setup lang="ts">
import { ref } from 'vue'

// 定义聊天历史数据
const chatHistory = ref([
  {
    timestamp: '2024-01-01 10:00',
    content: '示例消息内容'
  }
])
</script>

<style scoped>

</style>
