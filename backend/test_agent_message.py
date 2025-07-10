#!/usr/bin/env python3
"""
模拟前端向后端发送agent_message类型的JSON并检查响应
"""

import asyncio
import json
import requests
import websockets
import uuid
from datetime import datetime

async def test_agent_message():
    """测试agent_message功能"""
    
    print("开始测试agent_message功能...")
    print("=" * 60)
    
    # 1. 创建会话
    print("1. 创建新会话...")
    try:
        response = requests.post("http://localhost:8000/api/sessions")
        if response.status_code == 200:
            session_data = response.json()
            session_id = session_data["session_id"]
            print(f"✅ 会话创建成功: {session_id}")
        else:
            print(f"❌ 会话创建失败: {response.status_code}")
            return
    except Exception as e:
        print(f"❌ 创建会话失败: {e}")
        return
    
    # 2. 连接WebSocket
    print(f"\n2. 连接WebSocket...")
    try:
        uri = f"ws://localhost:8000/ws/{session_id}"
        websocket = await websockets.connect(uri)
        print(f"✅ WebSocket连接成功: {uri}")
        
        # 等待连接确认
        connection_msg = await websocket.recv()
        connection_data = json.loads(connection_msg)
        print(f"连接确认: {connection_data}")
        
    except Exception as e:
        print(f"❌ WebSocket连接失败: {e}")
        return
    
    # 3. 发送agent_message
    print(f"\n3. 发送agent_message...")
    try:
        agent_message = {
            "type": "agent_message",
            "data": {
                "content": "请告诉我当前时间"
            },
            "timestamp": datetime.now().isoformat()
        }
        
        print(f"发送消息: {json.dumps(agent_message, ensure_ascii=False, indent=2)}")
        await websocket.send(json.dumps(agent_message))
        print("✅ agent_message发送成功")
        
    except Exception as e:
        print(f"❌ 发送agent_message失败: {e}")
        await websocket.close()
        return
    
    # 4. 等待响应
    print(f"\n4. 等待响应...")
    try:
        # 设置超时时间
        response = await asyncio.wait_for(websocket.recv(), timeout=30.0)
        response_data = json.loads(response)
        print(f"收到响应: {json.dumps(response_data, ensure_ascii=False, indent=2)}")
        
        # 检查响应类型
        if response_data.get("type") == "agent_response":
            print("✅ 收到agent_response类型的响应")
            agent_data = response_data.get("data", {})
            if agent_data.get("success"):
                print(f"✅ Agent处理成功")
                print(f"响应内容: {agent_data.get('response', '')[:200]}...")
            else:
                print(f"❌ Agent处理失败: {agent_data.get('error')}")
        else:
            print(f"⚠️ 收到其他类型的响应: {response_data.get('type')}")
            
    except asyncio.TimeoutError:
        print("❌ 等待响应超时")
    except Exception as e:
        print(f"❌ 接收响应失败: {e}")
    
    # 5. 发送第二个agent_message测试记忆功能
    print(f"\n5. 发送第二个agent_message测试记忆功能...")
    try:
        agent_message2 = {
            "type": "agent_message",
            "data": {
                "content": "请总结一下我们刚才的对话"
            },
            "timestamp": datetime.now().isoformat()
        }
        
        print(f"发送消息: {json.dumps(agent_message2, ensure_ascii=False, indent=2)}")
        await websocket.send(json.dumps(agent_message2))
        print("✅ 第二个agent_message发送成功")
        
        # 等待响应
        response2 = await asyncio.wait_for(websocket.recv(), timeout=30.0)
        response_data2 = json.loads(response2)
        print(f"收到响应: {json.dumps(response_data2, ensure_ascii=False, indent=2)}")
        
        if response_data2.get("type") == "agent_response":
            agent_data2 = response_data2.get("data", {})
            if agent_data2.get("success"):
                print(f"✅ 第二个Agent处理成功")
                print(f"响应内容: {agent_data2.get('response', '')[:200]}...")
            else:
                print(f"❌ 第二个Agent处理失败: {agent_data2.get('error')}")
                
    except asyncio.TimeoutError:
        print("❌ 等待第二个响应超时")
    except Exception as e:
        print(f"❌ 第二个消息处理失败: {e}")
    
    # 6. 关闭连接
    print(f"\n6. 关闭WebSocket连接...")
    try:
        await websocket.close()
        print("✅ WebSocket连接已关闭")
    except Exception as e:
        print(f"❌ 关闭连接失败: {e}")
    
    # 7. 检查会话状态
    print(f"\n7. 检查会话状态...")
    try:
        response = requests.get(f"http://localhost:8000/api/sessions/{session_id}")
        if response.status_code == 200:
            session_info = response.json()
            print(f"✅ 会话状态获取成功")
            print(f"会话信息: {json.dumps(session_info, ensure_ascii=False, indent=2)}")
        else:
            print(f"❌ 获取会话状态失败: {response.status_code}")
    except Exception as e:
        print(f"❌ 检查会话状态失败: {e}")
    
    print(f"\n✅ agent_message测试完成")

async def test_agent_message_with_existing_session(session_id: str):
    """使用现有会话测试agent_message功能"""
    
    print(f"使用现有会话测试agent_message功能...")
    print(f"会话ID: {session_id}")
    print("=" * 60)
    
    # 1. 检查会话是否存在
    print("1. 检查会话是否存在...")
    try:
        response = requests.get(f"http://localhost:8000/api/sessions/{session_id}")
        if response.status_code == 200:
            session_info = response.json()
            print(f"✅ 会话存在")
            print(f"会话信息: {json.dumps(session_info, ensure_ascii=False, indent=2)}")
        else:
            print(f"❌ 会话不存在: {response.status_code}")
            return
    except Exception as e:
        print(f"❌ 检查会话失败: {e}")
        return
    
    # 2. 连接WebSocket
    print(f"\n2. 连接WebSocket...")
    try:
        uri = f"ws://localhost:8000/ws/{session_id}"
        websocket = await websockets.connect(uri)
        print(f"✅ WebSocket连接成功: {uri}")
        
        # 等待连接确认
        connection_msg = await websocket.recv()
        connection_data = json.loads(connection_msg)
        print(f"连接确认: {connection_data}")
        
    except Exception as e:
        print(f"❌ WebSocket连接失败: {e}")
        return
    
    # 3. 发送agent_message
    print(f"\n3. 发送agent_message...")
    try:
        agent_message = {
            "type": "agent_message",
            "data": {
                "content": "请告诉我当前时间并总结一下会议内容"
            },
            "timestamp": datetime.now().isoformat()
        }
        
        print(f"发送消息: {json.dumps(agent_message, ensure_ascii=False, indent=2)}")
        await websocket.send(json.dumps(agent_message))
        print("✅ agent_message发送成功")
        
        # 等待响应
        response = await asyncio.wait_for(websocket.recv(), timeout=30.0)
        response_data = json.loads(response)
        print(f"收到响应: {json.dumps(response_data, ensure_ascii=False, indent=2)}")
        
        if response_data.get("type") == "agent_response":
            agent_data = response_data.get("data", {})
            if agent_data.get("success"):
                print(f"✅ Agent处理成功")
                print(f"响应内容: {agent_data.get('response', '')[:300]}...")
            else:
                print(f"❌ Agent处理失败: {agent_data.get('error')}")
        else:
            print(f"⚠️ 收到其他类型的响应: {response_data.get('type')}")
            
    except asyncio.TimeoutError:
        print("❌ 等待响应超时")
    except Exception as e:
        print(f"❌ 处理消息失败: {e}")
    
    # 4. 关闭连接
    print(f"\n4. 关闭WebSocket连接...")
    try:
        await websocket.close()
        print("✅ WebSocket连接已关闭")
    except Exception as e:
        print(f"❌ 关闭连接失败: {e}")
    
    print(f"\n✅ 现有会话agent_message测试完成")

if __name__ == "__main__":
    import sys
    
    print("开始测试agent_message功能...")
    print("请确保主服务正在运行: python main_service.py")
    
    async def run_tests():
        # 测试新会话
        await test_agent_message()
        
        # 如果提供了session_id参数，也测试现有会话
        if len(sys.argv) > 1:
            session_id = sys.argv[1]
            print(f"\n" + "="*60)
            await test_agent_message_with_existing_session(session_id)
    
    asyncio.run(run_tests())
    print("测试完成！") 