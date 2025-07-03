import os
import json
import requests
import time
import math
import tempfile
from typing import Dict, Optional, List, Tuple
from pydub import AudioSegment

class AudioTranscriber:
    """语音转写工具类，严格按固定大小分块"""
    
    CHUNK_SIZE_MB = 10  # 每个分块的最大大小 (MB)
    CHUNK_DURATION_MS = 10 * 60 * 1000  # 10MB ≈ 10分钟音频（假设码率128kbps）
    
    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.getenv("OPENAI_API_KEY")
        if not self.api_key:
            raise ValueError("未设置OPENAI_API_KEY环境变量")
    
    def split_audio(self, file_path: str) -> List[Tuple[str, float]]:
        """严格按固定时长分割音频文件
        
        返回:
            list: 每个元素为 (分块文件路径, 分块开始时间) 的元组
        """
        audio = AudioSegment.from_file(file_path)
        total_duration_ms = len(audio)
        chunks = []
        
        # 计算需要分割的块数
        num_chunks = math.ceil(total_duration_ms / self.CHUNK_DURATION_MS)
        
        # 创建临时目录
        temp_dir = tempfile.mkdtemp()
        
        for i in range(num_chunks):
            start_ms = i * self.CHUNK_DURATION_MS
            end_ms = min((i + 1) * self.CHUNK_DURATION_MS, total_duration_ms)
            
            # 分割音频
            chunk = audio[start_ms:end_ms]
            chunk_path = os.path.join(temp_dir, f"chunk_{i+1}.wav")
            chunk.export(chunk_path, format="wav")
            
            chunks.append((chunk_path, start_ms / 1000.0))  # 转换为秒
        
        print(f"已将音频分割为 {len(chunks)} 个固定大小的分块，每块约 {self.CHUNK_DURATION_MS/1000} 秒")
        return chunks
    
    def transcribe_chunk(self, chunk_path: str, offset: float, model: str, keep_words: bool) -> Optional[Dict]:
        """转写单个音频分块"""
        url = "https://api.openai.com/v1/audio/transcriptions"
        headers = {
        "Authorization": f"Bearer {self.api_key}"
        }
        
        try:
            with open(chunk_path, "rb") as audio_file:
                files = {"file": (os.path.basename(chunk_path), audio_file, "audio/wav")}
                
                data = {
                    "model": model,
                    "response_format": "verbose_json",
                }
                
                if keep_words:
                    data["timestamp_granularities[]"] = ["word"]
                
                print(f"正在转写分块: {os.path.basename(chunk_path)} (偏移: {offset:.2f}秒)")
                start_time = time.time()
                
                response = requests.post(
                    url,
                    headers=headers,
                    data=data,
                    files=files,
                    timeout=120  # 增加超时时间
                )
                
                elapsed = time.time() - start_time
                print(f"分块转写完成，耗时: {elapsed:.2f}秒")
                
                if response.status_code != 200:
                    print(f"API错误 ({response.status_code}): {response.text}")
                    return None
                
                return response.json()
                
        except Exception as e:
            print(f"分块转写失败: {type(e).__name__}: {str(e)}")
            return None
    
    def adjust_timestamps(self, result: Dict, offset: float) -> Dict:
        """调整时间戳：添加偏移量"""
        if not result:
            return result
        
        # 调整整体时长
        if "duration" in result:
            result["duration"] += offset
        
        # 调整分段和单词时间戳
        if "segments" in result:
            for segment in result["segments"]:
                segment["start"] += offset
                segment["end"] += offset
                
                # 调整单词级时间戳
                if "words" in segment:
                    for word in segment["words"]:
                        word["start"] += offset
                        word["end"] += offset
        
        return result
    
    def merge_results(self, results: List[Dict]) -> Dict:
        """合并多个分块的转写结果"""
        if not results:
            return None
        
        # 初始化合并结果
        merged = {
            "text": "",
            "language": results[0].get("language", ""),
            "duration": 0.0,
            "segments": [],
            "words": []
        }
        
        # 合并所有结果
        for result in results:
            if not result:
                continue
                
            merged["text"] += result.get("text", "") + " "
            merged["duration"] = max(merged["duration"], result.get("duration", 0.0))
            
            if "segments" in result:
                merged["segments"].extend(result["segments"])
            
            # 收集所有单词
            for segment in result.get("segments", []):
                if "words" in segment:
                    merged["words"].extend(segment["words"])
        
        # 清理文本
        merged["text"] = merged["text"].strip()
        
        return merged
    
    def transcribe_audio(
        self,
        file_path: str,
        model: str = "whisper-1",
        keep_words: bool = False
    ) -> Optional[Dict]:
        """转写音频文件（支持大文件分块处理）
        
        参数:
            file_path: 音频文件路径
            model: Whisper模型版本
            keep_words: 是否保留单词级时间戳
            
        返回:
            dict: 转写结果
        """
        # 分割音频文件
        chunks = self.split_audio(file_path)
        all_results = []
        
        # 处理每个分块
        for chunk_path, offset in chunks:
            # 转写当前分块
            result = self.transcribe_chunk(chunk_path, offset, model, keep_words)
            
            # 调整时间戳
            if result:
                adjusted_result = self.adjust_timestamps(result, offset)
                all_results.append(adjusted_result)
            
            # 删除临时分块文件
            if chunk_path != file_path:
                try:
                    os.remove(chunk_path)
                except:
                    pass
        
        # 合并所有结果
        if not all_results:
            print("所有分块转写均失败")
            return None
        
        # 合并结果
        final_result = self.merge_results(all_results)
        
        # 添加合并信息
        final_result["chunks"] = len(chunks)
        final_result["original_file"] = file_path
        
        return final_result
    
    def save_results(self, data: Dict, filename: str) -> bool:
        """保存结果到文件"""
        try:
            os.makedirs(os.path.dirname(filename), exist_ok=True)
            with open(filename, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            print(f"结果已保存到 {os.path.abspath(filename)}")
            return True
        except Exception as e:
            print(f"保存失败: {str(e)}")
            return False