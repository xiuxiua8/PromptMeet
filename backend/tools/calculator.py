"""
计算器工具
"""
import math
from typing import Dict, Any
from .base import BaseTool, ToolResult


class CalculatorTool(BaseTool):
    """数学计算器工具"""
    
    def __init__(self):
        super().__init__(
            name="calculator",
            description="数学计算器，支持基本运算"
        )
    
    async def execute(self, expression: str) -> ToolResult:
        """执行数学计算"""
        try:
            # 安全地评估数学表达式
            allowed_names = {
                'abs': abs, 'round': round, 'min': min, 'max': max,
                'sum': sum, 'pow': pow, 'sqrt': math.sqrt,
                'sin': math.sin, 'cos': math.cos, 'tan': math.tan,
                'log': math.log, 'log10': math.log10, 'exp': math.exp,
                'pi': math.pi, 'e': math.e
            }
            
            # 清理表达式，只允许安全的字符
            safe_expr = ''.join(c for c in expression if c.isdigit() or c in '+-*/.() ')
            
            # 使用eval但限制在安全的命名空间中
            result = eval(safe_expr, {"__builtins__": {}}, allowed_names)
            
            return ToolResult(
                tool_name=self.name,
                result={
                    "expression": expression,
                    "result": result,
                    "type": "number"
                },
                success=True
            )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "expression": expression,
                    "error": f"计算错误: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            ) 