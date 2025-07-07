<template>
    <div class="min-h-screen bg-gray-50 p-6">
      <!-- 头部导航 -->
      <header class="mb-8">
        <div class="max-w-7xl mx-auto">
          <h1 class="text-3xl font-bold text-gray-900">PromptMeet 智能会议助手</h1>
          <p class="text-gray-600 mt-2">实时语音转录与智能摘要生成</p>
        </div>
      </header>
  
      <!-- 连接状态栏 -->
      <div v-if="connectionState.error" class="max-w-7xl mx-auto mb-6">
        <div class="bg-red-50 border border-red-200 rounded-lg p-4">
          <div class="flex items-center">
            <AlertCircle class="h-5 w-5 text-red-400 mr-2" />
            <span class="text-red-800">{{ connectionState.error }}</span>
          </div>
        </div>
      </div>
  
      <!-- 主要内容区域 -->
      <div class="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-3 gap-6">
        
        <!-- 左侧：控制面板 -->
        <div class="lg:col-span-1">
          <div class="bg-white rounded-lg shadow-sm border p-6">
            <h2 class="text-xl font-semibold text-gray-900 mb-6">会议控制</h2>
            
            <!-- 会话状态 -->
            <div class="mb-6">
              <div class="flex items-center justify-between mb-3">
                <span class="text-sm font-medium text-gray-700">连接状态</span>
                <div class="flex items-center">
                  <div 
                    :class="connectionState.wsConnected ? 'bg-green-400' : 'bg-red-400'"
                    class="w-2 h-2 rounded-full mr-2"
                  ></div>
                  <span class="text-sm text-gray-600">
                    {{ connectionState.wsConnected ? '已连接' : '未连接' }}
                  </span>
                </div>
              </div>
              
              <div v-if="currentSession" class="text-xs text-gray-500">
                会话 ID: {{ currentSession.session_id.slice(0, 8) }}...
              </div>
            </div>
  
            <!-- 控制按钮 -->
            <div class="space-y-3">
              <button
                @click="handleCreateSession"
                :disabled="isLoading || !!currentSession"
                class="w-full flex items-center justify-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <Play class="h-4 w-4 mr-2" />
                创建会话
              </button>
  
              <button
                @click="handleStartRecording"
                :disabled="isLoading || !currentSession || currentSession.is_recording"
                class="w-full flex items-center justify-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-green-600 hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <Mic class="h-4 w-4 mr-2" />
                开始录音
              </button>
  
              <button
                @click="handleStopRecording"
                :disabled="isLoading || !currentSession || !currentSession.is_recording"
                class="w-full flex items-center justify-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-red-600 hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <Square class="h-4 w-4 mr-2" />
                停止录音
              </button>
  
              <button
                @click="handleGenerateSummary"
                :disabled="isLoading || !currentSession || transcripts.length === 0"
                class="w-full flex items-center justify-center px-4 py-2 border border-transparent rounded-md shadow-sm text-sm font-medium text-white bg-purple-600 hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <FileText class="h-4 w-4 mr-2" />
                生成摘要
              </button>
            </div>
  
            <!-- 录音状态指示器 -->
            <div v-if="currentSession?.is_recording" class="mt-6 p-4 bg-red-50 rounded-lg">
              <div class="flex items-center">
                <div class="animate-pulse bg-red-500 rounded-full h-3 w-3 mr-2"></div>
                <span class="text-red-800 font-medium">正在录音...</span>
              </div>
              <div class="text-xs text-red-600 mt-1">
                已录制: {{ formatDuration(recordingDuration) }}
              </div>
            </div>
  
            <!-- 统计信息 -->
            <div v-if="currentSession" class="mt-6 pt-6 border-t border-gray-200">
              <h3 class="text-sm font-medium text-gray-700 mb-3">会话统计</h3>
              <div class="space-y-2 text-sm text-gray-600">
                <div class="flex justify-between">
                  <span>转录片段:</span>
                  <span>{{ transcripts.length }}</span>
                </div>
                <div class="flex justify-between">
                  <span>任务数量:</span>
                  <span>{{ summary?.tasks.length || 0 }}</span>
                </div>
                <div class="flex justify-between">
                  <span>关键点:</span>
                  <span>{{ summary?.key_points.length || 0 }}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
  
        <!-- 中间：实时转录 -->
        <div class="lg:col-span-1">
          <div class="bg-white rounded-lg shadow-sm border h-full">
            <div class="p-6 border-b border-gray-200">
              <h2 class="text-xl font-semibold text-gray-900">实时转录</h2>
            </div>
            <div class="p-6 h-96 overflow-y-auto">
              <div v-if="transcripts.length === 0" class="text-center text-gray-500 mt-8">
                <Mic class="h-12 w-12 mx-auto text-gray-400 mb-4" />
                <p>暂无转录内容</p>
                <p class="text-sm">开始录音后将显示实时转录结果</p>
              </div>
              <div v-else class="space-y-4">
                <div
                  v-for="segment in transcripts"
                  :key="segment.id"
                  class="p-3 bg-gray-50 rounded-lg"
                >
                  <div class="text-sm text-gray-500 mb-1">
                    {{ formatTime(segment.timestamp) }}
                    <span v-if="segment.confidence" class="ml-2">
                      置信度: {{ Math.round(segment.confidence * 100) }}%
                    </span>
                  </div>
                  <p class="text-gray-900">{{ segment.text }}</p>
                </div>
              </div>
            </div>
          </div>
        </div>
  
        <!-- 右侧：摘要和任务 -->
        <div class="lg:col-span-1">
          <div class="bg-white rounded-lg shadow-sm border h-full">
            <div class="p-6 border-b border-gray-200">
              <h2 class="text-xl font-semibold text-gray-900">会议摘要</h2>
            </div>
            <div class="p-6 h-96 overflow-y-auto">
              <div v-if="!summary" class="text-center text-gray-500 mt-8">
                <FileText class="h-12 w-12 mx-auto text-gray-400 mb-4" />
                <p>暂无摘要内容</p>
                <p class="text-sm">录音结束后可生成智能摘要</p>
              </div>
              <div v-else class="space-y-6">
                <!-- 摘要文本 -->
                <div>
                  <h3 class="text-lg font-medium text-gray-900 mb-2">会议总结</h3>
                  <p class="text-gray-700 whitespace-pre-wrap">{{ summary.summary_text }}</p>
                </div>
  
                <!-- 关键要点 -->
                <div v-if="summary.key_points.length > 0">
                  <h3 class="text-lg font-medium text-gray-900 mb-2">关键要点</h3>
                  <ul class="space-y-1">
                    <li
                      v-for="point in summary.key_points"
                      :key="point"
                      class="flex items-start"
                    >
                      <CheckCircle class="h-4 w-4 text-green-500 mt-1 mr-2 flex-shrink-0" />
                      <span class="text-gray-700">{{ point }}</span>
                    </li>
                  </ul>
                </div>
  
                <!-- 决策内容 -->
                <div v-if="summary.decisions.length > 0">
                  <h3 class="text-lg font-medium text-gray-900 mb-2">决策内容</h3>
                  <ul class="space-y-1">
                    <li
                      v-for="decision in summary.decisions"
                      :key="decision"
                      class="flex items-start"
                    >
                      <AlertCircle class="h-4 w-4 text-blue-500 mt-1 mr-2 flex-shrink-0" />
                      <span class="text-gray-700">{{ decision }}</span>
                    </li>
                  </ul>
                </div>
  
                <!-- 任务列表 -->
                <div v-if="summary.tasks.length > 0">
                  <h3 class="text-lg font-medium text-gray-900 mb-2">任务清单</h3>
                  <div class="space-y-3">
                    <div
                      v-for="task in summary.tasks"
                      :key="task.task"
                      class="p-3 border border-gray-200 rounded-lg"
                    >
                      <div class="flex items-start justify-between">
                        <div class="flex-1">
                          <p class="font-medium text-gray-900">{{ task.task }}</p>
                          <p v-if="task.describe" class="text-sm text-gray-600 mt-1">
                            {{ task.describe }}
                          </p>
                        </div>
                        <span
                          :class="{
                            'bg-red-100 text-red-800': task.priority === 'high',
                            'bg-yellow-100 text-yellow-800': task.priority === 'medium',
                            'bg-green-100 text-green-800': task.priority === 'low'
                          }"
                          class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium"
                        >
                          {{ task.priority === 'high' ? '高' : task.priority === 'medium' ? '中' : '低' }}
                        </span>
                      </div>
                      <div v-if="task.deadline || task.assignee" class="flex items-center justify-between mt-2 text-xs text-gray-500">
                        <span v-if="task.assignee">负责人: {{ task.assignee }}</span>
                        <span v-if="task.deadline">截止: {{ task.deadline }}</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </template>
  
  <script setup lang="ts">
  import { onMounted, onUnmounted, ref, computed } from 'vue'
  import { 
    useSession, 
    useAPI, 
    MessageType, 
    type TranscriptSegment, 
    type MeetingSummary, 
    type SessionState 
  } from '../services/api-client'
  
  // 图标组件 (需要安装 lucide-vue-next)
  import { 
    Play, 
    Mic, 
    Square, 
    FileText, 
    CheckCircle, 
    AlertCircle 
  } from 'lucide-vue-next'
  
  // 组合式API
  const { connectionState } = useAPI()
  const {
    currentSession,
    transcripts,
    summary,
    isLoading,
    createSession,
    startRecording,
    stopRecording,
    generateSummary,
    setupWebSocketListeners
  } = useSession()
  
  // 录音时长计算
  const recordingStartTime = ref<Date | null>(null)
  const recordingDuration = ref(0)
  let durationInterval: number | null = null
  
  // 计算录音时长
  const updateRecordingDuration = () => {
    if (recordingStartTime.value) {
      recordingDuration.value = Math.floor((Date.now() - recordingStartTime.value.getTime()) / 1000)
    }
  }
  
  // 事件处理函数
  const handleCreateSession = async () => {
    try {
      const response = await createSession()
      if (response.success) {
        console.log('会话创建成功:', response.session_id)
      }
    } catch (error) {
      console.error('创建会话失败:', error)
    }
  }
  
  const handleStartRecording = async () => {
    try {
      const response = await startRecording()
      if (response.success) {
        recordingStartTime.value = new Date()
        durationInterval = setInterval(updateRecordingDuration, 1000)
        console.log('录音开始')
      }
    } catch (error) {
      console.error('开始录音失败:', error)
    }
  }
  
  const handleStopRecording = async () => {
    try {
      const response = await stopRecording()
      if (response.success) {
        recordingStartTime.value = null
        if (durationInterval) {
          clearInterval(durationInterval)
          durationInterval = null
        }
        console.log('录音停止')
      }
    } catch (error) {
      console.error('停止录音失败:', error)
    }
  }
  
  const handleGenerateSummary = async () => {
    try {
      const response = await generateSummary()
      if (response.success) {
        console.log('摘要生成请求已发送')
      }
    } catch (error) {
      console.error('生成摘要失败:', error)
    }
  }
  
  // 工具函数
  const formatTime = (timestamp: string) => {
    return new Date(timestamp).toLocaleTimeString('zh-CN', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    })
  }
  
  const formatDuration = (seconds: number) => {
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60
    
    if (hours > 0) {
      return `${hours}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`
    } else {
      return `${minutes}:${secs.toString().padStart(2, '0')}`
    }
  }
  
  // 生命周期
  onMounted(() => {
    // 设置WebSocket事件监听
    setupWebSocketListeners()
    
    console.log('MeetingDashboard 组件已挂载')
  })
  
  onUnmounted(() => {
    // 清理定时器
    if (durationInterval) {
      clearInterval(durationInterval)
    }
  })
  </script>
  
  <style scoped>
  /* 自定义样式 */
  .animate-pulse {
    animation: pulse 2s infinite;
  }
  
  @keyframes pulse {
    0%, 100% {
      opacity: 1;
    }
    50% {
      opacity: 0.5;
    }
  }
  </style>