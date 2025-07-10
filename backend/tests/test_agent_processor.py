import asyncio
import json
import pytest
from pathlib import Path
from agents.agent_processor import AgentProcessor
from langchain_core.messages import HumanMessage

@pytest.fixture
def processor():
    """测试用的处理器实例，预置初始对话"""
    proc = AgentProcessor()
    proc.memory.chat_memory.add_message(HumanMessage(content="初始问候"))
    return proc

@pytest.mark.asyncio
async def test_agent_processing_with_pipes(processor, tmp_path):
    """测试完整的管道通信流程"""
    session_id = "test_session_123"
    session_dir = tmp_path / "sessions" / session_id
    session_dir.mkdir(parents=True)
    
    ipc_input = session_dir / "agent_input.pipe"
    ipc_output = session_dir / "agent_output.pipe"
    ipc_input.touch()
    
    task = asyncio.create_task(processor.start(
        session_id=session_id,
        ipc_input=str(ipc_input),
        ipc_output=str(ipc_output),
        work_dir=str(session_dir)
    ))
    
    try:
        test_cases = [
            {"content": "现在几点", "expected_keywords": ["time", "当前时间"]},
            {"content": "总结这句话：AI很重要", "expected_keywords": ["summary", "摘要"]},
            {"content": "随便说点什么", "expected_response": True}
        ]
        
        for case in test_cases:
            with open(ipc_input, 'w', encoding='utf-8') as f:
                f.write(json.dumps({"content": case["content"]}))
            
            await asyncio.sleep(1)
            
            if ipc_output.exists():
                with open(ipc_output, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                    if lines:
                        response = json.loads(lines[-1])
                        print(f"测试响应: {response}")
                        assert response["success"] is True
                        assert "response" in response
                        
                        if "expected_keywords" in case:
                            assert any(keyword.lower() in response["response"].lower() 
                                      for keyword in case["expected_keywords"])
            
            open(ipc_output, 'w').close()
            
    finally:
        await processor.stop()
        task.cancel()

@pytest.mark.asyncio
async def test_tool_execution_directly(processor):
    """直接测试工具调用"""
    test_cases = [
        ("现在时间", ["time", "当前时间"]),
        ("生成摘要：这是一段测试文本", ["summary", "摘要"]),
        ("随便说点什么", True)
    ]
    
    for content, expected in test_cases:
        response = await processor.process_message({"content": content})
        print(f"工具测试响应: {response}")
        
        assert response["success"] is True
        assert "response" in response
        
        if isinstance(expected, list):
            assert any(keyword.lower() in response["response"].lower() 
                      for keyword in expected)
        else:
            assert isinstance(response["response"], str)

@pytest.mark.asyncio
async def test_conversation_flow(processor):
    """测试多轮对话"""
    messages = [
        "现在几点",
        "根据时间猜猜我在哪个时区",
        "谢谢"
    ]
    
    responses = []
    for msg in messages:
        response = await processor.process_message({"content": msg})
        responses.append(response)
        print(f"对话轮次: {msg} -> {response}")
        
        assert response["success"] is True
        assert "response" in response
        assert isinstance(response["response"], str)
    
    # 更宽松的响应验证
    assert ":" in responses[0]["response"]  # 检查时间格式
    assert responses[1]["response"] != responses[0]["response"]  # 确保两次响应不同
    assert any(word in responses[2]["response"] 
              for word in ["谢谢", "不客气", "欢迎"])  # 检查结束语

