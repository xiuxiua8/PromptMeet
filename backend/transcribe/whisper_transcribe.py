import os
import json
import requests
import time
import math
import threading
from typing import Dict, Optional, List, Tuple
from pydub import AudioSegment
import tempfile
from queue import Queue

class AudioTranscriber:
    """支持多线程分块转写的语音转写工具类（含分块独立计时）"""
    
    def __init__(self, api_key: Optional[str] = None, chunk_size: int = 300, max_workers: int = 4):
        self.api_key = api_key or os.getenv("OPENAI_API_KEY")
        if not self.api_key:
            raise ValueError("未设置OPENAI_API_KEY环境变量")
        self.chunk_size = chunk_size
        self.max_workers = max_workers
        self.result_queue = Queue()
        self.lock = threading.Lock()
        self.completed_chunks = 0
        self.chunk_times = {}  # 存储每个分块的耗时 {chunk_name: time}
    
    def _format_time(self, seconds: float) -> str:
        """格式化时间显示"""
        if seconds < 1:
            return f"{seconds*1000:.0f}毫秒"
        return f"{seconds:.2f}秒"

    def _split_audio(self, file_path: str) -> List[Tuple[str, float]]:
        """分割音频文件（显示每个分块时间范围）"""
        audio = AudioSegment.from_file(file_path)
        total_duration_sec = len(audio) / 1000
        
        if total_duration_sec <= self.chunk_size:
            print(f"🔍 直接处理完整文件 | 时长: {self._format_time(total_duration_sec)}")
            return [(file_path, 0.0)]

        chunks = []
        temp_dir = tempfile.mkdtemp()
        num_chunks = math.ceil(total_duration_sec / self.chunk_size)
        
        for i in range(num_chunks):
            start_sec = i * self.chunk_size
            end_sec = min((i + 1) * self.chunk_size, total_duration_sec)
            chunk = audio[start_sec*1000 : end_sec*1000]
            chunk_path = os.path.join(temp_dir, f"chunk_{i+1}.wav")
            chunk.export(chunk_path, format="wav")
            chunks.append((chunk_path, start_sec))
            print(f"✂️ 分块 {i+1}/{num_chunks} | 时间范围: {start_sec:.1f}s-{end_sec:.1f}s")
        
        return chunks
    
    def _transcribe_chunk(self, chunk_path: str, offset: float, model: str, keep_words: bool):
        """转写单个分块（强制显示每个分块耗时）"""
        chunk_name = os.path.basename(chunk_path)
        start_time = time.time()
        
        try:
            url = "https://api.openai.com/v1/audio/transcriptions"
            headers = {"Authorization": f"Bearer {self.api_key}"}
            with open(chunk_path, "rb") as audio_file:
                files = {"file": (chunk_name, audio_file, "audio/wav")}
                data = {"model": model, "response_format": "verbose_json"}
                if keep_words:
                    data["timestamp_granularities[]"] = ["word"]
                
                response = requests.post(url, headers=headers, data=data, files=files, timeout=120)
                elapsed = time.time() - start_time
                
                if response.status_code == 200:
                    result = response.json()
                    # 调整时间戳偏移
                    for segment in result.get("segments", []):
                        segment["start"] += offset
                        segment["end"] += offset
                        if "words" in segment:
                            for word in segment["words"]:
                                word["start"] += offset
                                word["end"] += offset
                    
                    with self.lock:
                        self.result_queue.put(result)
                        self.completed_chunks += 1
                        self.chunk_times[chunk_name] = elapsed
                        print(
                            f"✅ {chunk_name} 完成 | "
                            f"耗时: {self._format_time(elapsed)} | "
                            f"进度: {self.completed_chunks}/{self.total_chunks}"
                        )
                else:
                    print(f"❌ {chunk_name} 失败 | 状态码: {response.status_code}")
        except Exception as e:
            print(f"❌ {chunk_name} 异常 | {type(e).__name__}: {str(e)}")
        finally:
            try:
                os.remove(chunk_path)
            except:
                pass
    
    def transcribe_audio(self, file_path: str, model: str = "whisper-1", keep_words: bool = False) -> Optional[Dict]:
        """执行多线程转写（显示每个分块独立耗时）"""
        global_start = time.time()
        chunks = self._split_audio(file_path)
        self.total_chunks = len(chunks)
        self.completed_chunks = 0
        self.chunk_times.clear()
        
        if not chunks:
            return None

        print(
            f"\n⏱️ 开始转写 | 分块数: {self.total_chunks} | "
            f"线程数: {self.max_workers} | "
            f"预估总时长: {self._format_time(self.total_chunks * 2)} (基于2秒/分块预估)"
        )

        # 启动转写线程
        threads = []
        for chunk_path, offset in chunks:
            while threading.active_count() > self.max_workers:
                time.sleep(0.1)
            
            t = threading.Thread(
                target=self._transcribe_chunk,
                args=(chunk_path, offset, model, keep_words),
                daemon=True
            )
            t.start()
            threads.append(t)

        # 等待完成
        for t in threads:
            t.join()
        
        # 打印详细耗时报告
        total_elapsed = time.time() - global_start
        print("\n📊 分块耗时统计:")
        for chunk, elapsed in self.chunk_times.items():
            print(f"  - {chunk}: {self._format_time(elapsed)}")
        
        print(
            f"\n✅ 全部完成 | 总耗时: {self._format_time(total_elapsed)} | "
            f"实际速度: {total_elapsed/self.total_chunks:.2f}秒/分块"
        )
        return self._merge_results()
    

    def _merge_results(self) -> Dict:
        """合并所有分块结果"""
        merged = {"text": "", "language": None, "duration": 0.0, "segments": []}
        
        while not self.result_queue.empty():
            result = self.result_queue.get()
            if not merged["language"] and "language" in result:
                merged["language"] = result["language"]
            
            merged["text"] += result.get("text", "") + " "
            merged["duration"] = max(merged["duration"], result.get("duration", 0.0))
            merged["segments"].extend(result.get("segments", []))
        
        merged["segments"].sort(key=lambda x: x["start"])
        merged["text"] = merged["text"].strip()
        return merged
    
    def save_results(self, data: Dict, filename: str) -> bool:
        """保存结果到文件"""
        try:
            os.makedirs(os.path.dirname(filename), exist_ok=True)
            with open(filename, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            return True
        except Exception as e:
            print(f"❌ 结果保存失败: {str(e)}")
            return False