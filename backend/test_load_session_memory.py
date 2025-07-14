#!/usr/bin/env python3
"""
测试从现有会话加载内容到memory的脚本
"""

import asyncio
import tempfile
import os
from pathlib import Path
from agents.agent_processor import AgentProcessor

async def test_load_session_memory(session_id: str = None):
    """测试从现有会话加载内容到memory"""
    
    # 检查API密钥
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key or api_key == "your-openai-api-key-here":
        print("错误：请设置正确的OPENAI_API_KEY环境变量")
        return
    
    # 如果没有提供session_id，使用默认的
    if not session_id:
        session_id = "649c0119-98e6-445e-bb13-5296fbc4db68"
    
    print(f"测试从会话 {session_id} 加载内容到memory...")
    print("=" * 60)
    
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
            processor.session_id = session_id
            processor.ipc_input_path = ipc_input
            processor.ipc_output_path = ipc_output
            processor.work_dir = work_dir
            processor.api_base_url = "http://localhost:8000"
            
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
            
            # 检查加载结果
            content_count = len(processor.meeting_content)
            print(f"✅ 会话内容加载完成，共加载 {content_count} 个内容片段")
            
            if content_count > 0:
                print("\n加载的内容片段:")
                for i, content in enumerate(processor.meeting_content, 1):
                    print(f"  片段 {i}: {content[:80]}...")
                
                # 测试查询记忆
                print("\n测试查询记忆...")
                query_result = await processor._query_memory("请总结一下会议的主要内容")
                print(f"查询结果: {query_result[:200]}...")
                
            else:
                print("\n❌ 没有加载到任何内容片段")
                print("可能的原因:")
                print("1. 会话中没有转录数据")
                print("2. 会话中没有摘要数据")
                print("3. API响应格式不正确")
                print("4. 主服务未运行")
            
            # 获取记忆统计
            print("\n记忆系统统计:")
            stats = processor.get_memory_stats()
            for key, value in stats.items():
                print(f"  {key}: {value}")
            
            print(f"\n✅ 会话内容加载测试完成")
            
        except Exception as e:
            print(f"❌ 测试过程中出现错误: {e}")
            import traceback
            traceback.print_exc()
        finally:
            # 停止处理器
            await processor.stop()

if __name__ == "__main__":
    import sys
    
    # 如果提供了session_id参数，使用它
    session_id = sys.argv[1] if len(sys.argv) > 1 else None
    
    print("开始测试从现有会话加载内容到memory...")
    print("请确保主服务正在运行: python main_service.py")
    
    asyncio.run(test_load_session_memory(session_id))
    print("测试完成！") 