import os
import logging
import numpy as np
from typing import Optional, Tuple
from moviepy import AudioFileClip
import noisereduce as nr
import soundfile as sf
from tqdm import tqdm
from pathlib import Path

# 配置日志
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class AudioPreprocessor:
    """音频预处理工具类，支持降噪、格式转换和时间截取"""
    
    DEFAULT_SR = 16000  # 默认采样率
    CHUNK_DURATION = 10  # 分块时长(秒)
    NOISE_SAMPLE_DURATION = 0.5  # 噪声采样时长(秒)
    
    def __init__(self, output_dir: str = "processed_audio"):
        """
        初始化音频预处理器
        
        参数:
            output_dir: 输出目录路径
        """
        self.output_dir = output_dir
        os.makedirs(self.output_dir, exist_ok=True)
        logger.info(f"音频预处理器初始化完成，输出目录: {os.path.abspath(self.output_dir)}")
        
    def _validate_input(self, input_path: str, start_time: Optional[float], end_time: Optional[float]):
        """验证输入参数有效性"""
        if not os.path.exists(input_path):
            raise FileNotFoundError(f"输入文件不存在: {input_path}")
            
        if start_time is not None and end_time is not None and start_time >= end_time:
            raise ValueError("开始时间必须小于结束时间")

    def _extract_audio_segment(self, audio: AudioFileClip, start: Optional[float], end: Optional[float]) -> AudioFileClip:
        """提取音频片段"""
        if start is not None or end is not None:
            start = max(0, start) if start is not None else 0
            end = min(audio.duration, end) if end is not None else audio.duration
            logger.info(f"截取音频片段: {start:.2f}s 到 {end:.2f}s")
            return audio.subclipped(start, end)
        return audio
    
    def _get_noise_sample(self, audio_data: np.ndarray, sr: int) -> np.ndarray:
        """从音频开头获取噪声样本"""
        noise_samples = min(int(self.NOISE_SAMPLE_DURATION * sr), len(audio_data))
        return audio_data[:noise_samples]
    
    def _process_chunk(self, chunk: np.ndarray, noise_sample: np.ndarray, sr: int) -> np.ndarray:
        """处理单个音频块"""
        return nr.reduce_noise(
            y=chunk,
            y_noise=noise_sample,
            sr=sr,
            stationary=False,
            prop_decrease=0.7,
            n_fft=512
        )
    
    def preprocess_audio(
        self,
        input_path: str,
        output_name: str = "processed",
        start_time: Optional[float] = None,
        end_time: Optional[float] = None,
        denoise: bool = True,
        target_sr: int = DEFAULT_SR
    ) -> Tuple[str, dict]:
        """
        音频预处理主函数
        
        参数:
            input_path: 输入文件路径
            output_name: 输出文件名(不含扩展名)
            start_time: 开始时间(秒)
            end_time: 结束时间(秒)
            denoise: 是否降噪
            target_sr: 目标采样率
            
        返回:
            tuple: (输出文件路径, 元数据字典)
            
        异常:
            可能抛出各种处理异常
        """
        # 验证输入
        self._validate_input(input_path, start_time, end_time)
        
        # 准备输出路径
        output_path = os.path.join(self.output_dir, f"{output_name}.wav")
        temp_path = os.path.join(self.output_dir, "temp_audio.wav")
        metadata = {
            'input_file': os.path.basename(input_path),
            'output_file': os.path.basename(output_path),
            'processing_steps': [],
            'parameters': {
                'start_time': start_time,
                'end_time': end_time,
                'denoise': denoise,
                'target_sr': target_sr
            }
        }

        try:
            logger.info(f"开始处理音频: {os.path.basename(input_path)}")
            
            # 步骤1: 读取并截取音频
            with AudioFileClip(input_path) as audio:
                original_duration = audio.duration
                audio = self._extract_audio_segment(audio, start_time, end_time)
                metadata['duration'] = audio.duration
                metadata['original_duration'] = original_duration
                metadata['processing_steps'].append('time_cut')
                
                # 步骤2: 降噪或直接导出
                if denoise:
                    logger.info("开始降噪处理...")
                    
                    # 先导出临时文件供降噪处理
                    audio.write_audiofile(temp_path, fps=target_sr, codec="pcm_s16le")
                    metadata['processing_steps'].append('temp_export')
                    
                    # 读取音频数据
                    audio_data, sr = sf.read(temp_path, dtype='float32')
                    os.remove(temp_path)
                    
                    # 转换为单声道
                    if audio_data.ndim > 1:
                        audio_data = np.mean(audio_data, axis=1)
                        metadata['processing_steps'].append('convert_to_mono')
                    
                    # 获取噪声样本
                    noise_sample = self._get_noise_sample(audio_data, sr)
                    
                    # 分块降噪处理
                    chunk_size = self.CHUNK_DURATION * sr
                    processed = []
                    for i in tqdm(range(0, len(audio_data), chunk_size), 
                                 desc="降噪处理", unit="chunk"):
                        chunk = audio_data[i:i+chunk_size]
                        clean_chunk = self._process_chunk(chunk, noise_sample, sr)
                        processed.append(clean_chunk)
                    
                    # 保存最终结果
                    audio_clean = np.concatenate(processed)
                    sf.write(output_path, audio_clean, sr)
                    metadata['processing_steps'].append('denoise')
                else:
                    logger.info("直接导出音频(无降噪)...")
                    audio.write_audiofile(output_path, fps=target_sr, codec="pcm_s16le")
                    metadata['processing_steps'].append('direct_export')
                
                logger.info(f"音频处理完成: {os.path.basename(output_path)}")
                return output_path, metadata
                
        except Exception as e:
            logger.error(f"音频处理失败: {str(e)}")
            
            # 清理临时文件
            if os.path.exists(temp_path):
                try:
                    os.remove(temp_path)
                except:
                    pass
            
            # 重新抛出异常
            raise

# 使用示例
if __name__ == "__main__":
    # 初始化预处理器
    processor = AudioPreprocessor(output_dir="test_output")
    
    # 示例处理
    try:
        output_path, meta = processor.preprocess_audio(
            input_path="sample.mp4",
            output_name="clean_audio",
            start_time=10,
            end_time=60,
            denoise=True
        )
        
        print("\n处理结果:")
        print(f"输出文件: {output_path}")
        print("处理元数据:")
        print(json.dumps(meta, indent=2))
        
    except Exception as e:
        print(f"处理失败: {str(e)}")