import { ref, reactive } from 'vue'

// 基础配置
const API_BASE_URL = 'http://localhost:8000'
const WS_BASE_URL = 'ws://localhost:8000'

// 响应式状态
export const connectionState = reactive({
  wsConnected: false,
  currentSessionId: null as string | null,
  isRecording: false,
  error: null as string | null
})

// 数据类型定义
export interface TranscriptSegment {
  id: string
  text: string
  timestamp: string
  confidence: number
  speaker?: string
}

export interface TaskItem {
  task: string
  deadline?: string
  describe: string
  priority: string
  assignee?: string
  status: string
}

export interface MeetingSummary {
  session_id: string
  summary_text: string
  tasks: TaskItem[]
  key_points: string[]
  decisions: string[]
  generated_at: string
}

export interface SessionState {
  session_id: string
  is_recording: boolean
  start_time: string
  transcript_segments: TranscriptSegment[]
  current_summary?: MeetingSummary
}

// WebSocket消息类型
export enum MessageType {
  AUDIO_START = 'audio_start',
  AUDIO_STOP = 'audio_stop',
  AUDIO_TRANSCRIPT = 'audio_transcript',
  SUMMARY_GENERATED = 'summary_generated',
  TASK_EXTRACTED = 'task_extracted',
  PROGRESS_UPDATE = 'progress_update',
  ERROR = 'error'
}

export interface WebSocketMessage {
  type: MessageType
  data: any
  timestamp: string
  session_id: string
}

// HTTP API 客户端
class APIClient {
  private baseURL: string

  constructor(baseURL: string = API_BASE_URL) {
    this.baseURL = baseURL
  }

  private async request<T>(
    endpoint: string, 
    options: RequestInit = {}
  ): Promise<T> {
    const url = `${this.baseURL}${endpoint}`
    
    const response = await fetch(url, {
      headers: {
        'Content-Type': 'application/json',
        ...options.headers
      },
      ...options
    })

    if (!response.ok) {
      const error = await response.text()
      throw new Error(`API Error: ${response.status} - ${error}`)
    }

    return response.json()
  }

  // 会话管理
  async createSession(): Promise<{ success: boolean; session_id: string; message: string }> {
    return this.request('/api/sessions', { method: 'POST' })
  }

  async getSession(sessionId: string): Promise<{ success: boolean; session: SessionState }> {
    return this.request(`/api/sessions/${sessionId}`)
  }

  async deleteSession(sessionId: string): Promise<{ success: boolean; message: string }> {
    return this.request(`/api/sessions/${sessionId}`, { method: 'DELETE' })
  }

  // 录音控制
  async startRecording(sessionId: string): Promise<{ success: boolean; message: string }> {
    return this.request(`/api/sessions/${sessionId}/start-recording`, { method: 'POST' })
  }

  async stopRecording(sessionId: string): Promise<{ success: boolean; message: string }> {
    return this.request(`/api/sessions/${sessionId}/stop-recording`, { method: 'POST' })
  }

  // 摘要生成
  async generateSummary(sessionId: string): Promise<{ success: boolean; message: string }> {
    return this.request(`/api/sessions/${sessionId}/generate-summary`, { method: 'POST' })
  }

  // 健康检查
  async healthCheck(): Promise<any> {
    return this.request('/health')
  }
}

// WebSocket 客户端
class WebSocketClient {
  private ws: WebSocket | null = null
  private sessionId: string | null = null
  private messageHandlers: Map<MessageType, ((data: any) => void)[]> = new Map()
  private reconnectAttempts = 0
  private maxReconnectAttempts = 5
  private reconnectDelay = 1000

  constructor() {
    // 初始化消息处理器映射
    Object.values(MessageType).forEach(type => {
      this.messageHandlers.set(type, [])
    })
  }

  connect(sessionId: string): Promise<void> {
    return new Promise((resolve, reject) => {
      try {
        this.sessionId = sessionId
        this.ws = new WebSocket(`${WS_BASE_URL}/ws/${sessionId}`)

        this.ws.onopen = () => {
          console.log(`WebSocket connected for session: ${sessionId}`)
          connectionState.wsConnected = true
          connectionState.currentSessionId = sessionId
          connectionState.error = null
          this.reconnectAttempts = 0
          resolve()
        }

        this.ws.onmessage = (event) => {
          try {
            const message: WebSocketMessage = JSON.parse(event.data)
            this.handleMessage(message)
          } catch (error) {
            console.error('Failed to parse WebSocket message:', error)
          }
        }

        this.ws.onclose = () => {
          console.log('WebSocket disconnected')
          connectionState.wsConnected = false
          this.attemptReconnect()
        }

        this.ws.onerror = (error) => {
          console.error('WebSocket error:', error)
          connectionState.error = 'WebSocket connection error'
          reject(error)
        }

      } catch (error) {
        reject(error)
      }
    })
  }

  disconnect() {
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
    connectionState.wsConnected = false
    connectionState.currentSessionId = null
  }

  private handleMessage(message: WebSocketMessage) {
    const handlers = this.messageHandlers.get(message.type)
    if (handlers) {
      handlers.forEach(handler => {
        try {
          handler(message.data)
        } catch (error) {
          console.error(`Error in message handler for ${message.type}:`, error)
        }
      })
    }
  }

  private attemptReconnect() {
    if (this.reconnectAttempts < this.maxReconnectAttempts && this.sessionId) {
      this.reconnectAttempts++
      console.log(`Attempting to reconnect... (${this.reconnectAttempts}/${this.maxReconnectAttempts})`)
      
      setTimeout(() => {
        if (this.sessionId) {
          this.connect(this.sessionId)
        }
      }, this.reconnectDelay * this.reconnectAttempts)
    } else {
      console.error('Max reconnection attempts reached')
      connectionState.error = 'Failed to reconnect to server'
    }
  }

  // 事件监听器
  on(messageType: MessageType, handler: (data: any) => void) {
    const handlers = this.messageHandlers.get(messageType)
    if (handlers) {
      handlers.push(handler)
    }
  }

  off(messageType: MessageType, handler: (data: any) => void) {
    const handlers = this.messageHandlers.get(messageType)
    if (handlers) {
      const index = handlers.indexOf(handler)
      if (index > -1) {
        handlers.splice(index, 1)
      }
    }
  }

  // 发送消息
  send(message: any) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(message))
    } else {
      console.error('WebSocket is not connected')
    }
  }
}

// 导出单例实例
export const apiClient = new APIClient()
export const wsClient = new WebSocketClient()

// 便捷的组合API
export function useAPI() {
  return {
    apiClient,
    wsClient,
    connectionState
  }
}

// 会话管理组合式API
export function useSession() {
  const currentSession = ref<SessionState | null>(null)
  const transcripts = ref<TranscriptSegment[]>([])
  const summary = ref<MeetingSummary | null>(null)
  const isLoading = ref(false)

  const createSession = async () => {
    try {
      isLoading.value = true
      const response = await apiClient.createSession()
      if (response.success) {
        await wsClient.connect(response.session_id)
        
        // 获取会话详情
        const sessionResponse = await apiClient.getSession(response.session_id)
        if (sessionResponse.success) {
          currentSession.value = sessionResponse.session
          connectionState.currentSessionId = response.session_id
        }
      }
      return response
    } finally {
      isLoading.value = false
    }
  }

  const startRecording = async () => {
    if (!currentSession.value) return

    try {
      isLoading.value = true
      const response = await apiClient.startRecording(currentSession.value.session_id)
      if (response.success && currentSession.value) {
        currentSession.value.is_recording = true
        connectionState.isRecording = true
      }
      return response
    } finally {
      isLoading.value = false
    }
  }

  const stopRecording = async () => {
    if (!currentSession.value) return

    try {
      isLoading.value = true
      const response = await apiClient.stopRecording(currentSession.value.session_id)
      if (response.success && currentSession.value) {
        currentSession.value.is_recording = false
        connectionState.isRecording = false
      }
      return response
    } finally {
      isLoading.value = false
    }
  }

  const generateSummary = async () => {
    if (!currentSession.value) return

    try {
      isLoading.value = true
      return await apiClient.generateSummary(currentSession.value.session_id)
    } finally {
      isLoading.value = false
    }
  }

  // 设置WebSocket事件监听
  const setupWebSocketListeners = () => {
    wsClient.on(MessageType.AUDIO_TRANSCRIPT, (data: TranscriptSegment) => {
      transcripts.value.push(data)
      if (currentSession.value) {
        currentSession.value.transcript_segments.push(data)
      }
    })

    wsClient.on(MessageType.SUMMARY_GENERATED, (data: MeetingSummary) => {
      summary.value = data
      if (currentSession.value) {
        currentSession.value.current_summary = data
      }
    })

    wsClient.on(MessageType.ERROR, (data: any) => {
      console.error('WebSocket error:', data)
      connectionState.error = data.message || 'Unknown error'
    })
  }

  return {
    currentSession,
    transcripts,
    summary,
    isLoading,
    createSession,
    startRecording,
    stopRecording,
    generateSummary,
    setupWebSocketListeners
  }
}