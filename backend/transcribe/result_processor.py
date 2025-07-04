# result_processor.py
import json
from typing import Dict, List, Optional
from datetime import timedelta
from pathlib import Path

class WhisperResultProcessor:  
    """Whisper转写结果处理器"""
    
    def __init__(self, keep_words: bool = False):
        self.keep_words = keep_words
    
    def _format_time(self, seconds: float) -> str:
        return str(timedelta(seconds=seconds))
    
    def simplify(self, whisper_result: Dict) -> Dict:
        simplified = {
            "text": whisper_result["text"],
            "segments": []
        }
        
        for seg in whisper_result.get("segments", []):
            new_seg = {
                "start": seg["start"],
                "end": seg["end"],
                "text": seg["text"].strip()
            }
            if self.keep_words and "words" in seg:
                new_seg["words"] = seg["words"]
            simplified["segments"].append(new_seg)
        
        return simplified
    
    def save(self, data: Dict, output_path: str) -> None:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

# 测试代码
if __name__ == "__main__":
    processor = WhisperResultProcessor()
    test_data = {"text": "test", "segments": [{"start": 0, "end": 1, "text": "test"}]}
    processor.save(processor.simplify(test_data), "test_output.json")