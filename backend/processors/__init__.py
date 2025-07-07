"""
处理器模块
包含Whisper转录处理器和Summary分析处理器
"""

# 导入可能会在运行时需要的模块
# 由于处理器主要作为独立子进程运行，这里只做基本的模块标识

__all__ = [
    "whisper_processor",
    "summary_processor"
] 