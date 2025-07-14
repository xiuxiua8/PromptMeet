#!/usr/bin/env python3
"""
调试Question进程管道创建问题
"""

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from datetime import datetime

# 添加项目根目录到Python路径
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from backend.services.process_manager import ProcessManager
from backend.utils.ipc_utils import IPCCommand

async def debug_question_pipe_creation(session_id: str):
    """调试Question进程管道创建"""
    print(f"🔍 调试会话 {session_id} 的Question进程管道创建...")
    
    # 初始化服务
    process_manager = ProcessManager()
    
    try:
        await process_manager.initialize()
        
        # 1. 检查会话数据文件
        session_file = Path("temp_sessions") / session_id / "session.json"
        print(f"📁 会话文件: {session_file}")
        print(f"   文件存在: {session_file.exists()}")
        
        if session_file.exists():
            try:
                with open(session_file, 'r', encoding='utf-8') as f:
                    session_data = json.load(f)
                print(f"✅ 会话数据加载成功")
                print(f"   转录片段数: {len(session_data.get('transcript_segments', []))}")
                print(f"   会话状态: {session_data.get('is_recording', False)}")
            except Exception as e:
                print(f"❌ 加载会话数据失败: {e}")
        else:
            print("❌ 会话文件不存在")
            
            # 检查temp_sessions目录下的所有会话
            temp_dir = Path("temp_sessions")
            if temp_dir.exists():
                sessions = [d.name for d in temp_dir.iterdir() if d.is_dir()]
                print(f"📁 现有会话: {sessions}")
            else:
                print("❌ temp_sessions目录不存在")
        
        # 2. 检查工作目录
        work_dir = Path("temp_sessions") / session_id
        print(f"\n📁 工作目录: {work_dir}")
        print(f"   目录存在: {work_dir.exists()}")
        
        if not work_dir.exists():
            print("   创建工作目录...")
            work_dir.mkdir(parents=True, exist_ok=True)
        
        # 3. 检查管道文件路径
        ipc_input = work_dir / "question_input.pipe"
        ipc_output = work_dir / "question_output.pipe"
        
        print(f"📄 输入管道: {ipc_input}")
        print(f"📄 输出管道: {ipc_output}")
        
        # 4. 手动创建管道文件测试
        print("\n🔧 手动创建管道文件测试...")
        try:
            ipc_input.parent.mkdir(parents=True, exist_ok=True)
            ipc_input.touch()
            print(f"✅ 成功创建输入管道: {ipc_input}")
        except Exception as e:
            print(f"❌ 创建输入管道失败: {e}")
        
        try:
            ipc_output.touch()
            print(f"✅ 成功创建输出管道: {ipc_output}")
        except Exception as e:
            print(f"❌ 创建输出管道失败: {e}")
        
        # 5. 测试发送IPC命令
        print("\n📤 测试发送IPC命令...")
        try:
            command = IPCCommand(
                command="start",
                session_id=session_id,
                params={}
            )
            
            await process_manager._send_ipc_command(ipc_input, command)
            print("✅ IPC命令发送成功")
            
            # 检查文件内容
            if ipc_input.exists():
                with open(ipc_input, 'r', encoding='utf-8') as f:
                    content = f.read().strip()
                    print(f"📄 管道内容: {content}")
            
        except Exception as e:
            print(f"❌ 发送IPC命令失败: {e}")
        
        # 6. 尝试启动Question进程
        print("\n🚀 尝试启动Question进程...")
        try:
            process_id = await process_manager.start_question_process(session_id)
            print(f"✅ Question进程启动成功: {process_id}")
            
            # 等待一下让进程启动
            await asyncio.sleep(2)
            
            # 检查进程状态
            status = process_manager.get_process_status(session_id)
            print(f"📊 进程状态: {status}")
            
            # 检查管道文件是否被创建
            print(f"\n📄 启动后管道文件状态:")
            print(f"   输入管道存在: {ipc_input.exists()}")
            print(f"   输出管道存在: {ipc_output.exists()}")
            
            if ipc_input.exists():
                print(f"   输入管道大小: {ipc_input.stat().st_size} bytes")
            
            if ipc_output.exists():
                print(f"   输出管道大小: {ipc_output.stat().st_size} bytes")
            
            # 检查进程是否在运行
            if session_id in process_manager.question_processes:
                process = process_manager.question_processes[session_id]
                print(f"   进程PID: {process.pid}")
                print(f"   进程状态: {process.poll()}")
                
                if process.poll() is None:
                    print("   ✅ 进程正在运行")
                else:
                    print(f"   ❌ 进程已退出，返回码: {process.poll()}")
            else:
                print("   ❌ 进程未在管理器中找到")
            
        except Exception as e:
            print(f"❌ 启动Question进程失败: {e}")
            import traceback
            traceback.print_exc()
        
        # 7. 检查日志输出
        print("\n📋 检查最近的日志...")
        try:
            # 这里可以添加日志检查逻辑
            print("   日志检查功能待实现")
        except Exception as e:
            print(f"   检查日志失败: {e}")
        
    except Exception as e:
        print(f"❌ 调试过程出错: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        await process_manager.cleanup()

def main():
    if len(sys.argv) != 2:
        print("用法: python debug_question_pipe.py <session_id>")
        print("\n可用的会话ID:")
        temp_dir = Path("temp_sessions")
        if temp_dir.exists():
            sessions = [d.name for d in temp_dir.iterdir() if d.is_dir()]
            for session in sessions:
                print(f"  - {session}")
        sys.exit(1)
    
    session_id = sys.argv[1]
    
    print(f"🔍 开始调试Question进程管道创建问题")
    print(f"   会话ID: {session_id}")
    print(f"   时间: {datetime.now()}")
    print("=" * 60)
    
    asyncio.run(debug_question_pipe_creation(session_id))
    
    print("\n" + "=" * 60)
    print("🔍 调试完成")

if __name__ == "__main__":
    main() 