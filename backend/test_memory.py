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
            chat_message = {
                "type": "chat",
                "content": "请解释一下微观经济学和宏观经济学的区别"
            }
            
            response = await processor.process_message(chat_message)
            print(f"对话响应: {response.get('response', '')}")
            
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
    """测试HTTP集成功能 - 从现有会话读取内容"""
    print("\n" + "="*50)
    print("测试HTTP集成功能 - 从现有会话读取内容")
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
    
    # 使用你提供的会话ID
    session_id = "4fe7d5db-e965-45be-850b-755b047736df"  # 你可以修改这个ID
    print(f"\n使用现有会话: {session_id}")
    
    try:
        # 测试Agent处理器是否能加载会话内容
        processor = AgentProcessor()
        processor.session_id = session_id
        processor.api_base_url = "http://localhost:8000"
        
        # 初始化记忆系统
        with tempfile.TemporaryDirectory() as temp_dir:
            work_dir = Path(temp_dir)
            ipc_input = work_dir / "test_input.pipe"
            ipc_output = work_dir / "test_output.pipe"
            
            # 创建IPC文件
            ipc_input.touch()
            ipc_output.touch()
            
            processor.ipc_input_path = ipc_input
            processor.ipc_output_path = ipc_output
            processor.work_dir = work_dir
            
            # 确保工作目录存在
            processor.work_dir.mkdir(parents=True, exist_ok=True)
            
            # 初始化记忆系统
            await processor._init_memory_system()
            print("✅ 记忆系统初始化完成")
            
            # 从服务器加载会话内容 - 使用summary_processor的逻辑
            print(f"\n从服务器获取会话 {session_id} 的数据...")
            try:
                import requests
                response = requests.get(f"http://localhost:8000/api/sessions/{session_id}")
                if response.status_code == 200:
                    session_data = response.json()
                    if session_data.get("success"):
                        session = session_data["session"]
                        transcript_segments = session.get("transcript_segments", [])
                        
                        print(f"✅ 获取会话数据成功")
                        print(f"  转录片段数量: {len(transcript_segments)}")
                        
                        # 合并转录文本
                        if transcript_segments:
                            transcript_text = ""
                            for segment in transcript_segments:
                                transcript_text += segment.get("text", "") + "\n"
                            
                            if transcript_text.strip():
                                print(f"  转录文本长度: {len(transcript_text)}")
                                # 添加到记忆系统
                                await processor._add_meeting_content(transcript_text)
                                print(f"✅ 转录文本已添加到记忆系统")
                            else:
                                print("❌ 转录文本为空")
                        else:
                            print("❌ 没有转录片段")
                        
                        # 获取摘要内容
                        current_summary = session.get("current_summary")
                        if current_summary:
                            print(f"✅ 找到摘要数据")
                            summary_text = current_summary.get("summary_text", "")
                            if summary_text.strip():
                                print(f"  摘要文本长度: {len(summary_text)}")
                                await processor._add_meeting_content(summary_text)
                                print(f"✅ 摘要文本已添加到记忆系统")
                            
                            # 添加任务项
                            tasks = current_summary.get("tasks", [])
                            if tasks:
                                tasks_text = "待办事项:\n"
                                for i, task in enumerate(tasks, 1):
                                    tasks_text += f"{i}. {task.get('describe', task.get('task', ''))}\n"
                                await processor._add_meeting_content(tasks_text)
                                print(f"✅ 任务项已添加到记忆系统 ({len(tasks)} 个任务)")
                            
                            # 添加关键点
                            key_points = current_summary.get("key_points", [])
                            if key_points:
                                points_text = "关键要点:\n"
                                for i, point in enumerate(key_points, 1):
                                    points_text += f"{i}. {point}\n"
                                await processor._add_meeting_content(points_text)
                                print(f"✅ 关键点已添加到记忆系统 ({len(key_points)} 个要点)")
                        else:
                            print("❌ 没有摘要数据")
                        
                        print(f"✅ 会话内容加载完成，当前内容片段数: {len(processor.meeting_content)}")
                    else:
                        print(f"❌ 获取会话数据失败: {session_data}")
                else:
                    print(f"❌ API请求失败: {response.status_code}")
                    print(f"响应内容: {response.text}")
            except Exception as e:
                print(f"❌ 获取会话数据失败: {e}")
                import traceback
                traceback.print_exc()
            
            # 显示加载的内容
            if processor.meeting_content:
                print("\n加载的内容片段:")
                for i, content in enumerate(processor.meeting_content, 1):
                    print(f"  片段 {i}: {content[:100]}...")
            else:
                print("\n❌ 没有加载到任何内容片段")
                print("可能的原因:")
                print("1. 会话中没有转录数据")
                print("2. 会话中没有摘要数据")
                print("3. API响应格式不正确")
            
            # 获取记忆统计
            print("\n记忆系统统计:")
            stats = processor.get_memory_stats()
            for key, value in stats.items():
                print(f"  {key}: {value}")
            
        print(f"✅ 会话内容加载测试完成")
        
    except Exception as e:
        print(f"❌ 测试HTTP集成失败: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    print("开始测试Agent记忆功能...")
    print("请确保已设置正确的OPENAI_API_KEY环境变量")
    
    async def run_all_tests():
        # 先测试基础记忆功能
        # await test_memory_functionality()
        # 再测试从服务器读取现有会话内容
        await test_http_integration()
    
    asyncio.run(run_all_tests())
    print("测试完成！")