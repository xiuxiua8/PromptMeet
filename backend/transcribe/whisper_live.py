import os
import requests
import time
import wave
import pyaudio
import threading
from datetime import datetime
from dotenv import load_dotenv

# 加载环境变量
load_dotenv()

# 配置参数
API_KEY = os.getenv("OPENAI_API_KEY")
if not API_KEY:
    raise ValueError("请在.env文件中设置OPENAI_API_KEY")

SAMPLE_RATE = 16000  # Whisper要求的采样率 u
CHUNK_SIZE = 1024  # 每次读取的音频块大小
SEGMENT_DURATION = 5.0  # 每5秒自动提交一次音频（秒）
OUTPUT_FILE = "conversation_log.txt"
AUDIO_SAVE_DIR = "recordings"
MODEL = "whisper-1"


class AudioRecorder:
    def __init__(self):
        self.audio = pyaudio.PyAudio()
        self.stream = None
        self.frames = []
        self.is_recording = False
        self.last_submit_time = time.time()
        self.audio_counter = 1

        # 初始化目录和文件
        os.makedirs(AUDIO_SAVE_DIR, exist_ok=True)
        with open(OUTPUT_FILE, "a", encoding="utf-8") as f:
            f.write(
                f"\n\n===== 新会话开始于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} =====\n"
            )

    def start_recording(self):
        """开始录音并自动提交"""
        self.is_recording = True
        self.stream = self.audio.open(
            format=pyaudio.paInt16,
            channels=1,
            rate=SAMPLE_RATE,
            input=True,
            frames_per_buffer=CHUNK_SIZE,
        )
        print("🎤 麦克风已开启，开始自动录音和转录...")

        while self.is_recording:
            # 持续读取音频数据
            data = self.stream.read(CHUNK_SIZE, exception_on_overflow=False)
            self.frames.append(data)

            # 定时检查是否到达提交间隔
            current_time = time.time()
            if current_time - self.last_submit_time >= SEGMENT_DURATION:
                self._submit_audio_segment()
                self.last_submit_time = current_time

            time.sleep(0.01)  # 轻微延迟避免CPU过载

    def _submit_audio_segment(self):
        """提交当前音频片段到API"""
        if not self.frames:
            return

        # 保存临时音频文件
        filename = os.path.join(AUDIO_SAVE_DIR, f"segment_{self.audio_counter}.wav")
        self.audio_counter += 1

        with wave.open(filename, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(self.audio.get_sample_size(pyaudio.paInt16))
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(b"".join(self.frames))

        # 重置缓冲区
        self.frames = []

        # 在后台线程中处理API请求
        threading.Thread(
            target=self._transcribe_and_save, args=(filename,), daemon=True
        ).start()

    def _transcribe_and_save(self, filename: str):
        """调用API并保存结果"""
        try:
            # 调用Whisper API
            url = "https://api.openai.com/v1/audio/transcriptions"
            headers = {"Authorization": f"Bearer {API_KEY}"}

            with open(filename, "rb") as audio_file:
                response = requests.post(
                    url,
                    headers=headers,
                    files={"file": audio_file},
                    data={"model": MODEL},
                    timeout=30,
                )

            if response.status_code == 200:
                result = response.json()
                text = result.get("text", "").strip()
                if text:
                    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    output = f"[{timestamp}] {text}"
                    print(f"\n🔊 识别结果: {output}")

                    # 保存到日志文件
                    with open(OUTPUT_FILE, "a", encoding="utf-8") as f:
                        f.write(output + "\n")
            else:
                print(f"API错误: {response.status_code} - {response.text}")

        except Exception as e:
            print(f"转录失败: {str(e)}")
        finally:
            # 删除临时文件
            try:
                os.remove(filename)
            except Exception:
                pass

    def stop(self):
        """停止录音并提交最后片段"""
        if self.is_recording:
            self.is_recording = False
            if self.stream:
                self.stream.stop_stream()
                self.stream.close()

            # 提交剩余的音频数据
            if self.frames:
                self._submit_audio_segment()

            print("⏹️ 录音已停止")


def main():
    recorder = AudioRecorder()

    try:
        print("=" * 50)
        print("Whisper API 实时语音识别系统")
        print(f"采样率: {SAMPLE_RATE}Hz | 自动提交间隔: {SEGMENT_DURATION}秒")
        print(f"音频保存目录: {os.path.abspath(AUDIO_SAVE_DIR)}")
        print(f"文本输出文件: {os.path.abspath(OUTPUT_FILE)}")
        print("=" * 50)
        print("程序将自动开始录音，按 Ctrl+C 停止...")

        # 启动录音
        recorder.start_recording()

    except KeyboardInterrupt:
        print("\n接收到停止信号...")
    finally:
        recorder.stop()
        print(f"对话已保存至: {OUTPUT_FILE}")
        print("程序退出")


if __name__ == "__main__":
    main()
