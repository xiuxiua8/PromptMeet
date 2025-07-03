# video_to_simplified_json.py
import os
import json
import argparse
from datetime import datetime
from audio_preprocessing import AudioPreprocessor
from whisper_transcribe import AudioTranscriber
from result_processor import WhisperResultProcessor
from types import SimpleNamespace

def main():
    '''
    # 创建解析器
    parser = argparse.ArgumentParser(description='视频转简化JSON处理流程')
    parser.add_argument('input_video', type=str, help='输入视频文件路径')
    parser.add_argument('--output_dir', type=str, default='output', help='输出目录路径')
    parser.add_argument('--start', type=float, default=None, help='截取开始时间(秒)')
    parser.add_argument('--end', type=float, default=None, help='截取结束时间(秒)')
    parser.add_argument('--denoise', action='store_true', help='是否启用降噪处理')
    parser.add_argument('--keep_words', action='store_true', help='是否保留单词级时间戳')
    parser.add_argument('--model', type=str, default='whisper-1', help='Whisper模型版本')
    args = parser.parse_args()
    '''
    # 硬编码
    args = SimpleNamespace(
        input_video="C:/Users/杨玉鹏/Desktop/project/1.mp4",
        output_dir="output",
        start=None,
        end=None,
        denoise=True,
        keep_words=False,
        model="whisper-1"
    )
    
    # 创建输出目录
    os.makedirs(args.output_dir, exist_ok=True)
    
    # 生成带时间戳的文件名前缀
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    base_name = f"{timestamp}_{os.path.splitext(os.path.basename(args.input_video))[0]}"
    
    # 初始化日志
    log_file = os.path.join(args.output_dir, f"{base_name}_process.log")
    print(f"处理日志将保存到: {os.path.abspath(log_file)}")
    print(f"开始处理视频: {os.path.basename(args.input_video)}")
    
    # 1. 音频预处理
    print("\n===== 步骤1: 音频预处理 =====")
    audio_processor = AudioPreprocessor(output_dir=args.output_dir)
    try:
        clean_audio_path, audio_meta = audio_processor.preprocess_audio(
            input_path=args.input_video,
            output_name=f"{base_name}_clean_audio",
            start_time=args.start,
            end_time=args.end,
            denoise=args.denoise
        )
        print(f"✔ 音频预处理完成! 保存路径: {clean_audio_path}")
        print(f"音频时长: {audio_meta.get('duration', 0):.2f}秒")
    except Exception as e:
        print(f"✖ 音频预处理失败: {str(e)}")
        return
    
    # 2. 语音转写
    print("\n===== 步骤2: 语音转写 =====")
    transcriber = AudioTranscriber()
    try:
        raw_result = transcriber.transcribe_audio(
            file_path=clean_audio_path,
            model=args.model,
            keep_words=args.keep_words
        )
        if not raw_result:
            print("✖ 语音转写失败")
            return
        
        # 保存原始转写结果
        raw_json_path = os.path.join(args.output_dir, f"{base_name}_raw.json")
        transcriber.save_results(raw_result, raw_json_path)
        print(f"✔ 语音转写完成! 原始结果保存到: {raw_json_path}")
        print(f"识别语言: {raw_result.get('language', '未知')}")
    except Exception as e:
        print(f"✖ 语音转写失败: {str(e)}")
        return
    
    # 3. 结果后处理
    print("\n===== 步骤3: 结果后处理 =====")
    result_processor = WhisperResultProcessor(keep_words=args.keep_words)
    try:
        simplified = result_processor.simplify(raw_result)
        
        # 保存简化结果
        simplified_path = os.path.join(args.output_dir, f"{base_name}_simplified.json")
        result_processor.save(simplified, simplified_path)
        
        print(f"✔ 结果处理完成! 简化结果保存到: {simplified_path}")
        print(f"总分段数: {len(simplified.get('segments', []))}")
        if args.keep_words:
            word_count = sum(len(seg.get('words', [])) for seg in simplified['segments'])
            print(f"单词级时间戳: {word_count}个单词")
    except Exception as e:
        print(f"✖ 结果处理失败: {str(e)}")
        return
    
    print("\n===== 处理完成! =====")
    print(f"最终结果: {simplified_path}")

if __name__ == "__main__":
    main()