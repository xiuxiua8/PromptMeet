"""
翻译工具 - 使用 MyMemory 免费API
"""
import requests
from typing import Dict, Any
from .base import BaseTool, ToolResult


class TranslatorTool(BaseTool):
    """文本翻译工具"""
    
    def __init__(self):
        super().__init__(
            name="translate",
            description="文本翻译（使用MyMemory免费API）"
        )
    
    async def execute(self, text: str, target_lang: str = "en") -> ToolResult:
        """执行文本翻译"""
        try:
            # 语言代码映射
            lang_mapping = {
                "zh": "zh-CN", "zh-cn": "zh-CN", "chinese": "zh-CN",
                "en": "en", "english": "en",
                "ja": "ja", "japanese": "ja",
                "ko": "ko", "korean": "ko",
                "fr": "fr", "french": "fr",
                "de": "de", "german": "de",
                "es": "es", "spanish": "es",
                "ru": "ru", "russian": "ru",
                "ar": "ar", "arabic": "ar",
                "hi": "hi", "hindi": "hi",
                "pt": "pt", "portuguese": "pt",
                "it": "it", "italian": "it"
            }
            
            # 标准化语言代码
            target_lang = target_lang.lower()
            if target_lang in lang_mapping:
                target_lang = lang_mapping[target_lang]
            
            # 检测源语言（自动检测）
            # 根据目标语言智能选择源语言
            if target_lang.lower() in ["zh", "zh-cn", "chinese"]:
                source_lang = "en"  # 如果目标是中文，源语言设为英文
            else:
                source_lang = "zh-CN"  # 如果目标是其他语言，源语言设为中文
            
            # 使用 MyMemory 免费翻译API
            url = "https://api.mymemory.translated.net/get"
            params = {
                "q": text,
                "langpair": f"{source_lang}|{target_lang}",
                "de": "your-email@domain.com"  # 可选，用于提高限制
            }
            
            response = requests.get(url, params=params, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                
                if data.get("responseStatus") == 200:
                    translated_text = data["responseData"]["translatedText"]
                    
                    # 安全地获取检测到的语言信息
                    detected_lang = source_lang  # 默认使用我们设置的源语言
                    confidence = 0
                    
                    # 如果API返回了检测到的语言信息，则使用它
                    if "detectedLanguage" in data["responseData"]:
                        detected_lang = data["responseData"]["detectedLanguage"].get("language", source_lang)
                        confidence = data["responseData"]["detectedLanguage"].get("confidence", 0)
                    
                    return ToolResult(
                        tool_name=self.name,
                        result={
                            "original_text": text,
                            "translated_text": translated_text,
                            "source_language": detected_lang,
                            "target_language": target_lang,
                            "confidence": confidence,
                            "type": "translation"
                        },
                        success=True
                    )
                else:
                    return ToolResult(
                        tool_name=self.name,
                        result={
                            "text": text,
                            "error": f"翻译失败: {data.get('responseDetails', '未知错误')}",
                            "type": "error"
                        },
                        success=False,
                        error=f"翻译失败: {data.get('responseDetails', '未知错误')}"
                    )
            else:
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "text": text,
                        "error": f"翻译请求失败: {response.status_code}",
                        "type": "error"
                    },
                    success=False,
                    error=f"翻译请求失败: {response.status_code}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "text": text,
                    "error": f"翻译错误: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            ) 