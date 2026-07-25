import os
import json
import requests
import time
import wave
import threading
import queue
import sounddevice as sd
import soundfile as sf
import numpy as np
from datetime import datetime
from dotenv import load_dotenv
import sys
from scipy.signal import resample_poly  # 使用更好的重采样方法

# 加载环境变量
load_dotenv()

# 配置参数
API_KEY = os.getenv("OPENAI_API_KEY")
if not API_KEY:
    raise ValueError("请在.env文件中设置OPENAI_API_KEY")

SAMPLE_RATE = 16000  # Whisper要求的采样率
CHUNK_SIZE = 1024  # 每次读取的音频块大小
SEGMENT_DURATION = 10.0  # 每5秒自动提交一次音频（秒）
OUTPUT_FILE = "conversation_log.txt"
AUDIO_SAVE_DIR = "recordings"
MODEL = "whisper-1"


class SystemAudioRecorder:
    def __init__(self):
        self.is_recording = False
        self.last_submit_time = time.time()
        self.audio_counter = 1
        self.audio_queue = queue.Queue()
        self.current_frames = []
        self.device_id = None

        # 初始化目录和文件
        os.makedirs(AUDIO_SAVE_DIR, exist_ok=True)
        with open(OUTPUT_FILE, "a", encoding="utf-8") as f:
            f.write(
                f"\n\n===== 新会话开始于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} =====\n"
            )

        # 查找合适的扬声器设备
        self._find_speaker_device()

    def _find_speaker_device(self):
        """查找系统扬声器设备"""
        print("可用的音频设备:")
        devices = sd.query_devices()
        hostapis = sd.query_hostapis()

        input_devices = []  # 存储所有有输入通道的设备

        for i, dev in enumerate(devices):
            # 获取主机API名称
            hostapi_name = (
                hostapis[dev["hostapi"]]["name"]
                if dev["hostapi"] < len(hostapis)
                else "Unknown"
            )

            print(
                f"{i}: {dev['name']} (输入通道: {dev['max_input_channels']}, 输出通道: {dev['max_output_channels']}, API: {hostapi_name})"
            )

            # 收集所有有输入通道的设备
            if dev["max_input_channels"] > 0:
                input_devices.append((i, dev))

            # 根据操作系统和设备名称选择设备
            if sys.platform == "win32":
                # Windows: 寻找"立体声混音"或类似设备
                if (
                    "mix" in dev["name"].lower()
                    or "stereo" in dev["name"].lower()
                    or "混音" in dev["name"]
                ):
                    if dev["max_input_channels"] > 0:
                        self.device_id = i
                        print(f"✅ 找到扬声器设备: {dev['name']}")
                        return
            elif sys.platform == "darwin":
                # macOS: 优先查找BlackHole或Soundflower
                if (
                    "blackhole" in dev["name"].lower()
                    or "soundflower" in dev["name"].lower()
                ):
                    if dev["max_input_channels"] > 0:
                        self.device_id = i
                        print(f"✅ 找到虚拟音频设备: {dev['name']}")
                        return
            elif sys.platform.startswith("linux"):
                # Linux: 使用pulse的monitor设备
                if "monitor" in dev["name"].lower():
                    if dev["max_input_channels"] > 0:
                        self.device_id = i
                        print(f"✅ 找到扬声器设备: {dev['name']}")
                        return

        # 如果没找到专用设备，提供选择
        if not input_devices:
            print("❌ 未找到任何输入设备")
            raise RuntimeError("找不到可用的音频设备")

        print("\n⚠️ 未找到专用系统音频设备")
        if sys.platform == "darwin":
            print("💡 要录制系统音频，建议安装BlackHole:")
            print("   brew install blackhole-2ch")
            print("   然后重启系统")

        print(f"\n可用的输入设备:")
        for idx, (device_id, dev) in enumerate(input_devices):
            print(f"  {idx}: {dev['name']} (设备ID: {device_id})")

        # 自动选择第一个输入设备，或让用户选择
        try:
            choice = input(
                f"\n请选择设备 (0-{len(input_devices)-1}, 回车使用默认): "
            ).strip()
            if choice == "":
                selected_idx = 0
            else:
                selected_idx = int(choice)

            if 0 <= selected_idx < len(input_devices):
                self.device_id = input_devices[selected_idx][0]
                selected_device = input_devices[selected_idx][1]
                print(f"✅ 使用设备: {selected_device['name']}")
            else:
                raise ValueError("选择超出范围")

        except (ValueError, KeyboardInterrupt):
            # 使用默认设备
            self.device_id = input_devices[0][0]
            selected_device = input_devices[0][1]
            print(f"🔸 使用默认设备: {selected_device['name']}")

        if self.device_id is None:
            raise RuntimeError("找不到可用的音频设备")

    def _audio_callback(self, indata, frames, time, status):
        """音频数据回调函数"""
        if status:
            print(f"音频流状态: {status}")

        # 将音频数据放入队列
        self.audio_queue.put(indata.copy())

    def start_recording(self):
        """开始录制系统音频并自动提交"""
        self.is_recording = True

        # 获取设备信息
        device_info = sd.query_devices(self.device_id)
        print(f"设备信息: {device_info}")

        # 使用设备支持的最高采样率，但不超过48000
        sample_rate = int(min(device_info["default_samplerate"], 48000))
        channels = min(2, device_info["max_input_channels"])
        print(f"使用采样率: {sample_rate}Hz, 通道数: {channels}")

        # 开始录制
        self.stream = sd.InputStream(
            device=self.device_id,
            channels=channels,
            samplerate=sample_rate,
            blocksize=CHUNK_SIZE,
            callback=self._audio_callback,
        )

        self.stream.start()
        print(f"🔊 开始录制系统音频")

        try:
            while self.is_recording:
                # 从队列获取音频数据
                try:
                    audio_data = self.audio_queue.get(timeout=0.1)
                    self.current_frames.append(audio_data)
                except queue.Empty:
                    pass

                # 定时检查是否到达提交间隔
                current_time = time.time()
                if current_time - self.last_submit_time >= SEGMENT_DURATION:
                    self._submit_audio_segment(sample_rate, channels)
                    self.last_submit_time = current_time
        except KeyboardInterrupt:
            print("录制被中断")
        except Exception as e:
            print(f"录制错误: {str(e)}")
        finally:
            self.stream.stop()
            self.stream.close()
            # 提交剩余的音频数据
            if self.current_frames:
                self._submit_audio_segment(sample_rate, channels)
            print("⏹️ 录音已停止")

    def _submit_audio_segment(self, sample_rate: int, channels: int):
        """提交当前音频片段到API"""
        if not self.current_frames:
            return

        # 保存临时音频文件
        filename = os.path.join(AUDIO_SAVE_DIR, f"segment_{self.audio_counter}.wav")
        self.audio_counter += 1

        try:
            # 合并所有音频帧
            audio_data = np.vstack(self.current_frames)

            # 转换为单声道
            if channels > 1:
                audio_data = np.mean(audio_data, axis=1)

            # 如果采样率不是16000，进行重采样
            if sample_rate != SAMPLE_RATE:
                # 计算重采样比例
                gcd = np.gcd(sample_rate, SAMPLE_RATE)
                up = SAMPLE_RATE // gcd
                down = sample_rate // gcd

                # 使用更可靠的重采样方法
                audio_data = resample_poly(audio_data, up, down)

            # 保存音频文件
            sf.write(filename, audio_data, SAMPLE_RATE)
            print(f"✅ 音频片段保存成功: {filename}")
        except Exception as e:
            print(f"保存音频文件失败: {str(e)}")
            return
        finally:
            # 重置缓冲区
            self.current_frames = []

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
            except:
                pass


def main():
    recorder = SystemAudioRecorder()

    try:
        print("=" * 50)
        print("Whisper API 系统音频实时识别系统")
        print(f"采样率: {SAMPLE_RATE}Hz | 自动提交间隔: {SEGMENT_DURATION}秒")
        print(f"音频保存目录: {os.path.abspath(AUDIO_SAVE_DIR)}")
        print(f"文本输出文件: {os.path.abspath(OUTPUT_FILE)}")
        print("=" * 50)
        print("程序将开始录制系统音频，按 Ctrl+C 停止...")

        # 启动录音
        recorder.start_recording()

    except KeyboardInterrupt:
        print("\n接收到停止信号...")
    except Exception as e:
        print(f"程序错误: {str(e)}")
    finally:
        print(f"转录结果已保存至: {OUTPUT_FILE}")
        print("程序退出")


if __name__ == "__main__":
    main()
