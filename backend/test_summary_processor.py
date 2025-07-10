#!/usr/bin/env python3
"""
测试summary_processor.py功能的脚本
"""

import asyncio
import tempfile
import os
import json
import requests
from pathlib import Path
from processors.summary_processor import SummaryProcessor
from models.data_models import IPCCommand

async def test_summary_processor(session_id: str = None):
    """测试summary_processor功能"""
    
    # 检查API密钥
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key or api_key == "your-openai-api-key-here":
        print("错误：请设置正确的OPENAI_API_KEY环境变量")
        return
    
    # 如果没有提供session_id，使用默认的
    if not session_id:
        session_id = "4fe7d5db-e965-45be-850b-755b047736df"
    
    print(f"测试summary_processor功能")
    print(f"会话ID: {session_id}")
    print("=" * 60)
    
    # 创建临时工作目录
    with tempfile.TemporaryDirectory() as temp_dir:
        work_dir = Path(temp_dir)
        ipc_input = work_dir / "summary_input.pipe"
        ipc_output = work_dir / "summary_output.pipe"
        
        # 创建IPC文件
        ipc_input.touch()
        ipc_output.touch()
        
        print("1. 初始化SummaryProcessor...")
        
        # 初始化SummaryProcessor
        processor = SummaryProcessor()
        processor.current_session_id = session_id
        processor.ipc_input_file = ipc_input
        processor.ipc_output_file = ipc_output
        processor.work_dir = work_dir
        
        try:
            # 2. 测试启动处理器
            print(f"\n2. 启动SummaryProcessor...")
            await processor.start_processing(session_id)
            print("✅ SummaryProcessor启动成功")
            
            # 3. 测试从服务器获取会话数据
            print(f"\n3. 从服务器获取会话数据...")
            try:
                response = requests.get(f"http://localhost:8000/api/sessions/{session_id}")
                if response.status_code == 200:
                    session_data = response.json()
                    if session_data.get("success"):
                        session = session_data["session"]
                        transcript_segments = session.get("transcript_segments", [])
                        
                        print(f"✅ 获取会话数据成功")
                        print(f"  转录片段数量: {len(transcript_segments)}")
                        
                        if transcript_segments:
                            # 4. 合并转录文本
                            print(f"\n4. 合并转录文本...")
                            transcript_text = ""
                            for segment in transcript_segments:
                                transcript_text += segment.get("text", "") + "\n"
                            
                            if transcript_text.strip():
                                print(f"  转录文本长度: {len(transcript_text)}")
                                print(f"  转录文本预览: {transcript_text[:100]}...")
                                
                                # 5. 测试处理转录文本
                                print(f"\n5. 测试处理转录文本...")
                                result = await processor.process_transcript(transcript_text)
                                
                                if result["success"]:
                                    print("✅ 转录文本处理成功")
                                    summary = result["summary"]
                                    
                                    print(f"  摘要文本: {summary.get('summary_text', '')[:100]}...")
                                    print(f"  任务数量: {len(summary.get('tasks', []))}")
                                    print(f"  关键点数量: {len(summary.get('key_points', []))}")
                                    print(f"  决定数量: {len(summary.get('decisions', []))}")
                                    
                                    # 显示任务详情
                                    tasks = summary.get('tasks', [])
                                    if tasks:
                                        print(f"\n  任务详情:")
                                        for i, task in enumerate(tasks, 1):
                                            print(f"    任务 {i}: {task.get('task', '')} - {task.get('describe', '')}")
                                    
                                    # 显示关键点
                                    key_points = summary.get('key_points', [])
                                    if key_points:
                                        print(f"\n  关键点:")
                                        for i, point in enumerate(key_points, 1):
                                            print(f"    要点 {i}: {point}")
                                    
                                    # 显示决定
                                    decisions = summary.get('decisions', [])
                                    if decisions:
                                        print(f"\n  决定:")
                                        for i, decision in enumerate(decisions, 1):
                                            print(f"    决定 {i}: {decision}")
                                    
                                    # 6. 测试IPC命令处理
                                    print(f"\n6. 测试IPC命令处理...")
                                    
                                    # 测试status命令
                                    status_command = IPCCommand(
                                        command="status",
                                        session_id=session_id,
                                        params={}
                                    )
                                    status_response = await processor.handle_command(status_command)
                                    print(f"  状态命令响应: {status_response.success}")
                                    
                                    # 测试process命令
                                    process_command = IPCCommand(
                                        command="process",
                                        session_id=session_id,
                                        params={"transcript_text": "这是一个测试转录文本。"}
                                    )
                                    process_response = await processor.handle_command(process_command)
                                    print(f"  处理命令响应: {process_response.success}")
                                    
                                    # 7. 测试Agent记忆功能
                                    print(f"\n7. 测试Agent记忆功能...")
                                    from agents.agent_processor import AgentProcessor
                                    
                                    # 初始化AgentProcessor
                                    agent_processor = AgentProcessor(session_id)
                                    agent_processor.ipc_input_path = work_dir / "agent_input.pipe"
                                    agent_processor.ipc_output_path = work_dir / "agent_output.pipe"
                                    agent_processor.api_base_url = "http://localhost:8000"
                                    
                                    # 创建IPC文件
                                    agent_processor.ipc_input_path.touch()
                                    agent_processor.ipc_output_path.touch()
                                    
                                    # 启动Agent处理器
                                    await agent_processor.start()
                                    
                                    # 测试IPC命令格式
                                    print(f"  测试IPC命令格式...")
                                    ipc_message = {
                                        "command": "message",
                                        "session_id": session_id,
                                        "params": {
                                            "content": "请总结一下会议的关键信息"
                                        }
                                    }
                                    response = await agent_processor.process_message(ipc_message)
                                    print(f"  IPC命令响应: {response.get('success')}")
                                    if response.get('success'):
                                        print(f"  响应内容预览: {response.get('response', '')[:100]}...")
                                    
                                    # 测试普通对话格式
                                    print(f"  测试普通对话格式...")
                                    chat_message = {
                                        "type": "chat",
                                        "content": "请告诉我会议的主要内容"
                                    }
                                    response = await agent_processor.process_message(chat_message)
                                    print(f"  普通对话响应: {response.get('success')}")
                                    if response.get('success'):
                                        print(f"  响应内容预览: {response.get('response', '')[:100]}...")
                                    
                                    # 停止Agent处理器
                                    await agent_processor.stop()
                                    
                                else:
                                    print(f"❌ 转录文本处理失败: {result.get('error')}")
                            else:
                                print("❌ 转录文本为空")
                        else:
                            print("❌ 没有转录片段")
                            
                            # 7. 测试空转录文本的处理
                            print(f"\n7. 测试空转录文本的处理...")
                            empty_result = await processor.process_transcript("")
                            print(f"  空文本处理结果: {empty_result['success']}")
                            
                    else:
                        print(f"❌ 获取会话数据失败: {session_data}")
                else:
                    print(f"❌ API请求失败: {response.status_code}")
                    print(f"响应内容: {response.text}")
            except Exception as e:
                print(f"❌ 获取会话数据失败: {e}")
                import traceback
                traceback.print_exc()
            
            # 8. 测试停止处理器
            print(f"\n8. 停止SummaryProcessor...")
            await processor.stop_processing()
            print("✅ SummaryProcessor停止成功")
            
            print(f"\n✅ summary_processor功能测试完成")
            
        except Exception as e:
            print(f"❌ 测试过程中出现错误: {e}")
            import traceback
            traceback.print_exc()

async def test_summary_processor_with_sample_data():
    """使用示例数据测试summary_processor"""
    print(f"\n使用示例数据测试summary_processor...")
    print("=" * 60)
    
    # 创建临时工作目录
    with tempfile.TemporaryDirectory() as temp_dir:
        work_dir = Path(temp_dir)
        ipc_input = work_dir / "summary_input.pipe"
        ipc_output = work_dir / "summary_output.pipe"
        
        # 创建IPC文件
        ipc_input.touch()
        ipc_output.touch()
        
        # 初始化SummaryProcessor
        processor = SummaryProcessor()
        processor.current_session_id = "test_session"
        processor.ipc_input_file = ipc_input
        processor.ipc_output_file = ipc_output
        processor.work_dir = work_dir
        
        try:
            await processor.start_processing("test_session")
            
            # 测试示例转录文本
            sample_transcript = """
            大家好，欢迎参加今天的项目进度会议。
            目前项目进展顺利，我们已经完成了第一阶段的所有任务。
            关于技术架构，我们决定采用微服务架构，这样可以提高系统的可扩展性。
            我们需要在下周完成用户界面的设计，然后开始前端开发工作。
            另外，我们还需要讨论一下数据库的设计方案。
            """
            
            print(f"测试示例转录文本: {sample_transcript[:100]}...")
            
            result = await processor.process_transcript(sample_transcript)
            
            if result["success"]:
                print("✅ 示例文本处理成功")
                summary = result["summary"]
                print(f"摘要: {summary.get('summary_text', '')[:200]}...")
                print(f"任务数: {len(summary.get('tasks', []))}")
                print(f"关键点数: {len(summary.get('key_points', []))}")
            else:
                print(f"❌ 示例文本处理失败: {result.get('error')}")
            
            await processor.stop_processing()
            
        except Exception as e:
            print(f"❌ 示例数据测试失败: {e}")
            import traceback
            traceback.print_exc()

if __name__ == "__main__":
    import sys
    
    # 如果提供了session_id参数，使用它
    session_id = sys.argv[1] if len(sys.argv) > 1 else None
    
    print("开始测试summary_processor功能...")
    print("请确保主服务正在运行: python main_service.py")
    
    async def run_all_tests():
        # 测试真实会话数据
        await test_summary_processor(session_id)
        # 测试示例数据
        await test_summary_processor_with_sample_data()
    
    asyncio.run(run_all_tests())
    print("测试完成！") 