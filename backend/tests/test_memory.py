#!/usr/bin/env python3
"""
测试Agent记忆功能的脚本
"""

import asyncio
import json
import os
import tempfile
from pathlib import Path
from agents.agent_processor import AgentProcessor

async def test_memory_functionality():
    """测试记忆功能"""
    
    # 检查API密钥
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key or api_key == "your-openai-api-key-here":
        print("错误：请设置正确的OPENAI_API_KEY环境变量")
        print("您可以在.env文件中设置，或者在运行前设置环境变量")
        return
    
    # 创建临时工作目录
    with tempfile.TemporaryDirectory() as temp_dir:
        work_dir = Path(temp_dir)
        ipc_input = work_dir / "test_input.pipe"
        ipc_output = work_dir / "test_output.pipe"
        
        # 创建IPC文件
        ipc_input.touch()
        ipc_output.touch()
        
        print("初始化Agent处理器...")
        
        # 初始化Agent处理器
        processor = AgentProcessor()
        
        try:
            # 设置工作目录和IPC路径
            processor.session_id = "test_session"
            processor.ipc_input_path = ipc_input
            processor.ipc_output_path = ipc_output
            processor.work_dir = work_dir
            
            # 确保工作目录存在
            processor.work_dir.mkdir(parents=True, exist_ok=True)
            
            # 初始化记忆系统
            await processor._init_memory_system()
            
            print("✅ Agent处理器初始化完成")
            
            # 测试手动添加会议内容
            print("\n1. 测试手动添加会议内容...")
            test_content = """
            会议纪要：经济学基础讨论
            
            主要议题：
            1. 经济学的定义与范畴
            2. 微观经济学与宏观经济学的区别
            3. 稀缺性与机会成本
            
            重要结论：
            - 经济学是研究"选择"的学科
            - 微观经济学对个人决策更具指导意义
            - 机会成本需结合主观价值衡量
            """
            
            add_message = {
                "type": "add_content",
                "content": test_content
            }
            
            response = await processor.process_message(add_message)
            print(f"添加内容响应: {response.get('response', '')}")
            
            # 测试查询记忆
            print("\n2. 测试查询记忆...")
            query_message = {
                "type": "query_memory",
                "content": "什么是机会成本？"
            }
            
            response = await processor.process_message(query_message)
            print(f"查询响应: {response.get('response', '')}")
            
            # 测试刷新内容功能
            print("\n3. 测试刷新会议内容...")
            refresh_message = {
                "type": "refresh_content",
                "content": ""
            }
            
            response = await processor.process_message(refresh_message)
            print(f"刷新内容响应: {response.get('response', '')}")
            
            # 测试普通对话
            print("\n4. 测试普通对话...")
            try:
                chat_message = {
                    "type": "chat",
                    "content": "请解释一下微观经济学和宏观经济学的区别"
                }
                
                response = await processor.process_message(chat_message)
                print(f"对话响应: {response.get('response', '')[:100]}...")
            except Exception as e:
                print(f"对话测试失败: {e}")
                if 'response' in locals():
                    print(f"响应: {response}")
            
            # 获取记忆统计
            print("\n5. 记忆系统统计:")
            stats = processor.get_memory_stats()
            for key, value in stats.items():
                print(f"  {key}: {value}")
            
            print("\n✅ 所有测试完成！")
            
        except Exception as e:
            print(f"测试过程中出现错误: {e}")
            import traceback
            traceback.print_exc()
        finally:
            # 停止处理器
            await processor.stop()

async def test_http_integration():
    """测试HTTP集成功能"""
    print("\n" + "="*50)
    print("测试HTTP集成功能")
    print("="*50)
    
    # 检查主服务是否运行
    try:
        import requests
        response = requests.get("http://localhost:8000/health")
        if response.status_code == 200:
            print("✅ 主服务正在运行")
            health_data = response.json()
            print(f"  活跃会话数: {health_data.get('active_sessions', 0)}")
            print(f"  连接客户端数: {health_data.get('connected_clients', 0)}")
        else:
            print("❌ 主服务响应异常")
            return
    except Exception as e:
        print(f"❌ 无法连接到主服务: {e}")
        print("请确保主服务正在运行: python main_service.py")
        return
    
    # 测试创建会话
    print("\n创建测试会话...")
    try:
        response = requests.post("http://localhost:8000/api/sessions")
        if response.status_code == 200:
            session_data = response.json()
            session_id = session_data.get("session_id")
            print(f"✅ 创建会话成功: {session_id}")
            
            # 测试Agent处理器是否能加载会话内容
            processor = AgentProcessor()
            processor.session_id = session_id
            processor.api_base_url = "http://localhost:8000"
            
            await processor._load_session_content()
            print(f"✅ 会话内容加载测试完成")
            
        else:
            print("❌ 创建会话失败")
    except Exception as e:
        print(f"❌ 测试HTTP集成失败: {e}")

if __name__ == "__main__":
    print("开始测试Agent记忆功能...")
    print("请确保已设置正确的OPENAI_API_KEY环境变量")
    
    async def run_all_tests():
        await test_memory_functionality()
        await test_http_integration()
    
    asyncio.run(run_all_tests())
    print("测试完成！") 