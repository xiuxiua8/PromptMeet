#!/usr/bin/env python3
"""
调试Question进程状态
检查进程是否正常启动和运行
"""

import os
import json
import requests
from pathlib import Path

def check_question_process(session_id: str):
    """检查Question进程状态"""
    
    print(f"检查会话 {session_id} 的Question进程状态...")
    
    # 1. 检查进程状态
    print("\n1. 检查进程状态...")
    try:
        response = requests.get("http://localhost:8000/health")
        if response.status_code == 200:
            print("✅ 主服务运行正常")
        else:
            print(f"❌ 主服务异常: {response.status_code}")
            return
    except Exception as e:
        print(f"❌ 无法连接到主服务: {e}")
        return
    
    # 2. 检查会话数据
    print("\n2. 检查会话数据...")
    try:
        response = requests.get(f"http://localhost:8000/api/sessions/{session_id}")
        if response.status_code == 200:
            session_data = response.json()
            if session_data.get("success"):
                session = session_data["session"]
                transcript_segments = session.get("transcript_segments", [])
                print(f"✅ 会话存在，转录片段数: {len(transcript_segments)}")
                
                # 显示最近的几个转录片段
                print("\n最近的转录片段:")
                for i, segment in enumerate(transcript_segments[-5:], 1):
                    print(f"  {i}. {segment.get('text', '')[:50]}...")
            else:
                print(f"❌ 获取会话数据失败: {session_data}")
        else:
            print(f"❌ 会话不存在: {response.status_code}")
    except Exception as e:
        print(f"❌ 获取会话数据失败: {e}")
    
    # 3. 检查IPC文件
    print("\n3. 检查IPC文件...")
    work_dir = Path("temp_sessions") / session_id
    question_input = work_dir / "question_input.pipe"
    question_output = work_dir / "question_output.pipe"
    
    print(f"工作目录: {work_dir}")
    print(f"输入管道: {question_input} (存在: {question_input.exists()})")
    print(f"输出管道: {question_output} (存在: {question_output.exists()})")
    
    if question_input.exists():
        try:
            with open(question_input, 'r', encoding='utf-8') as f:
                content = f.read().strip()
                print(f"输入管道内容: {content}")
        except Exception as e:
            print(f"读取输入管道失败: {e}")
    
    if question_output.exists():
        try:
            with open(question_output, 'r', encoding='utf-8') as f:
                lines = f.readlines()
                print(f"输出管道行数: {len(lines)}")
                if lines:
                    print("最近的输出:")
                    for line in lines[-3:]:
                        print(f"  {line.strip()}")
        except Exception as e:
            print(f"读取输出管道失败: {e}")
    
    # 4. 检查进程文件
    print("\n4. 检查进程文件...")
    try:
        import psutil
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                cmdline = proc.info['cmdline']
                if cmdline and 'question_processor.py' in ' '.join(cmdline):
                    print(f"✅ 找到Question进程: PID={proc.info['pid']}")
                    print(f"   命令行: {' '.join(cmdline)}")
                    return
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        print("❌ 未找到Question进程")
    except ImportError:
        print("⚠️  psutil未安装，无法检查进程")
    
    # 5. 手动启动Question进程测试
    print("\n5. 手动启动Question进程测试...")
    try:
        import subprocess
        import sys
        
        cmd = [
            sys.executable,
            "processors/question_processor.py",
            "--session-id", session_id,
            "--ipc-input", str(question_input),
            "--ipc-output", str(question_output),
            "--work-dir", str(work_dir)
        ]
        
        print(f"执行命令: {' '.join(cmd)}")
        
        # 尝试运行几秒钟
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        
        import time
        time.sleep(3)
        
        # 检查输出
        output, _ = process.communicate(timeout=1)
        print(f"进程输出:\n{output}")
        
        process.terminate()
        
    except Exception as e:
        print(f"❌ 手动启动测试失败: {e}")

if __name__ == "__main__":
    import sys
    
    if len(sys.argv) > 1:
        session_id = sys.argv[1]
    else:
        # 获取最新的会话
        try:
            response = requests.get("http://localhost:8000/api/sessions")
            if response.status_code == 200:
                sessions = response.json()
                if sessions:
                    session_id = sessions[0]["session_id"]
                else:
                    print("❌ 没有找到会话")
                    sys.exit(1)
            else:
                print("❌ 无法获取会话列表")
                sys.exit(1)
        except Exception as e:
            print(f"❌ 获取会话列表失败: {e}")
            sys.exit(1)
    
    check_question_process(session_id) 