#!/usr/bin/env python3
"""
测试修改后的Agent处理器记忆功能
"""

import asyncio
import tempfile
import os
import json
from pathlib import Path
from agents.agent_processor import AgentProcessor

async def test_agent_memory(session_id: str = None):
    """测试Agent记忆功能"""
    
    # 检查API密钥
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key or api_key == "your-openai-api-key-here":
        print("错误：请设置正确的OPENAI_API_KEY环境变量")
        return
    
    # 如果没有提供session_id，使用默认的
    if not session_id:
        session_id = "4fe7d5db-e965-45be-850b-755b047736df"
    
    print(f"测试Agent记忆功能")
    print(f"会话ID: {session_id}")
    print("=" * 60)
    
    # 创建临时工作目录
    with tempfile.TemporaryDirectory() as temp_dir:
        work_dir = Path(temp_dir)
        ipc_input = work_dir / "agent_input.pipe"
        ipc_output = work_dir / "agent_output.pipe"
        
        # 创建IPC文件
        ipc_input.touch()
        ipc_output.touch()
        
        print("1. 初始化AgentProcessor...")
        
        # 初始化AgentProcessor
        agent_processor = AgentProcessor(session_id)
        agent_processor.ipc_input_path = ipc_input
        agent_processor.ipc_output_path = ipc_output
        agent_processor.api_base_url = "http://localhost:8000"
        
        try:
            # 2. 启动Agent处理器
            print(f"\n2. 启动AgentProcessor...")
            await agent_processor.start()
            print("✅ AgentProcessor启动成功")
            
            # 3. 测试IPC命令格式（message命令）
            print(f"\n3. 测试IPC命令格式...")
            ipc_message = {
                "command": "message",
                "session_id": session_id,
                "params": {
                    "content": "请总结一下会议的关键信息"
                }
            }
            response = await agent_processor.process_message(ipc_message)
            print(f"IPC命令响应: {response.get('success')}")
            if response.get('success'):
                print(f"响应内容预览: {response.get('response', '')[:200]}...")
            else:
                print(f"错误: {response.get('error')}")
            
            # 4. 测试普通对话格式
            print(f"\n4. 测试普通对话格式...")
            chat_message = {
                "type": "chat",
                "content": "请告诉我会议的主要内容"
            }
            response = await agent_processor.process_message(chat_message)
            print(f"普通对话响应: {response.get('success')}")
            if response.get('success'):
                print(f"响应内容预览: {response.get('response', '')[:200]}...")
            else:
                print(f"错误: {response.get('error')}")
            
            # 5. 测试添加内容到记忆
            print(f"\n5. 测试添加内容到记忆...")
            add_content_message = {
                "type": "add_content",
                "content": "会议讨论了项目进度，需要在下周完成第一阶段开发。"
            }
            response = await agent_processor.process_message(add_content_message)
            print(f"添加内容响应: {response.get('success')}")
            if response.get('success'):
                print(f"响应: {response.get('response')}")
            
            # 6. 测试查询记忆
            print(f"\n6. 测试查询记忆...")
            query_message = {
                "type": "query_memory", 
                "content": "项目进度如何？"
            }
            response = await agent_processor.process_message(query_message)
            print(f"查询记忆响应: {response.get('success')}")
            if response.get('success'):
                print(f"记忆查询结果: {response.get('response')}")
            
            # 7. 测试刷新内容
            print(f"\n7. 测试刷新内容...")
            refresh_message = {
                "type": "refresh_content",
                "content": ""
            }
            response = await agent_processor.process_message(refresh_message)
            print(f"刷新内容响应: {response.get('success')}")
            if response.get('success'):
                print(f"响应: {response.get('response')}")
            
            # 8. 停止Agent处理器
            print(f"\n8. 停止AgentProcessor...")
            await agent_processor.stop()
            print("✅ AgentProcessor停止成功")
            
            print(f"\n✅ Agent记忆功能测试完成")
            
        except Exception as e:
            print(f"❌ 测试过程中出现错误: {e}")
            import traceback
            traceback.print_exc()

if __name__ == "__main__":
    import sys
    
    # 如果提供了session_id参数，使用它
    session_id = sys.argv[1] if len(sys.argv) > 1 else None
    
    print("开始测试Agent记忆功能...")
    print("请确保主服务正在运行: python main_service.py")
    
    asyncio.run(test_agent_memory(session_id))
    print("测试完成！") 