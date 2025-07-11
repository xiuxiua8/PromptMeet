import json
import asyncio
from typing import AsyncIterator, List, Dict, Optional
from collections import OrderedDict
from langchain.prompts import PromptTemplate, ChatPromptTemplate
from langchain_openai import ChatOpenAI
from langchain_core.output_parsers import StrOutputParser
import os

class QuestionQueue:
    """线程安全的问题队列"""
    def __init__(self):
        self.questions = OrderedDict()
        self.next_id = 1
        self.lock = asyncio.Lock()  # 异步锁
    
    async def add_question(self, question: str) -> int:
        async with self.lock:
            self.questions[self.next_id] = question
            self.next_id += 1
            return self.next_id - 1
    
    async def get_question(self, question_id: int) -> Optional[str]:
        async with self.lock:
            return self.questions.get(question_id, None)
    
    async def display_questions(self) -> str:
        async with self.lock:
            return "\n".join(f"{qid}. {qtext}" for qid, qtext in self.questions.items())

class QAGenerator:
    def __init__(self, buffer_size: int = 5):
        self.llm = ChatOpenAI(
            openai_api_key=os.getenv("OPENAI_API_KEY"),
            model="gpt-3.5-turbo",
            temperature=0.3,
            streaming=True
        )
        self.buffer_size = buffer_size
        self.segment_buffer = []
        self.question_queue = QuestionQueue()
        self.stop_flag = False  # 控制线程停止

    async def generate_questions_from_buffer(self):
        """从缓冲区生成问题并加入队列"""
        if not self.segment_buffer:
            return
        
        combined_text = "\n".join(self.segment_buffer)
        
        prompt_template = """
请根据以下文本生成1个与技术相关的问题（以序号开头如1.xxx）：
文本：{text}
生成问题：
        """
        chain = (
            PromptTemplate(template=prompt_template, input_variables=["text"])
            | self.llm
            | StrOutputParser()
        )
        
        try:
            questions_text = await chain.ainvoke({"text": combined_text})
            
            generated_questions = []
            for line in questions_text.split("\n"):
                line = line.strip()
                if not line or '.' not in line:
                    continue
                question = line[line.index('.')+1:].strip()
                if question:
                    qid = await self.question_queue.add_question(question)
                    generated_questions.append({"id": qid, "question": question})
                    print(f"[系统] 新问题已加入队列 (ID: {qid}): {question}")
            
            return generated_questions
            
        except Exception as e:
            print(f"[系统] 生成问题失败: {e}")
            return []

    async def question_generator(self, segments: AsyncIterator[str]):
        """问题生成线程"""
        async for segment in segments:
            if self.stop_flag:
                break
            self.segment_buffer.append(segment)
            if len(self.segment_buffer) >= self.buffer_size:
                await self.generate_questions_from_buffer()
                self.segment_buffer.clear()
        
        # 处理剩余内容
        if not self.stop_flag and self.segment_buffer:
            await self.generate_questions_from_buffer()
        
        print("\n[系统] 问题生成完成！输入问题ID开始提问（输入q退出）")

    async def answer_processor(self):
        """问题回答线程"""
        while not self.stop_flag:
            try:
                user_input = await asyncio.get_event_loop().run_in_executor(
                    None, 
                    lambda: input("\n请输入问题ID（或输入q退出）: ")
                )
                
                if user_input.lower() == 'q':
                    self.stop_flag = True
                    break
                
                if not user_input.isdigit():
                    print("⚠️ 请输入数字ID")
                    continue
                
                question_id = int(user_input)
                question = await self.question_queue.get_question(question_id)
                
                if not question:
                    print(f"⚠️ 问题ID {question_id} 不存在")
                    continue
                
                print(f"\n[问题 {question_id}] {question}")
                print("[回答] ", end="", flush=True)
                
                prompt_template = "请直接回答以下问题：\n问题：{question}"
                chain = (
                    ChatPromptTemplate.from_template(prompt_template)
                    | self.llm
                    | StrOutputParser()
                )
                
                async for chunk in chain.astream({"question": question}):
                    print(chunk, end="", flush=True)
                print("\n" + "-"*50)
                
            except Exception as e:
                print(f"❌ 处理出错: {str(e)}")

async def load_json_stream(file_path: str) -> AsyncIterator[str]:
    """流式加载JSON文件"""
    with open(file_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    for segment in data['segments']:
        yield segment['text']

async def main():
    qa_gen = QAGenerator(buffer_size=3)  # 测试用较小的缓冲区
    
    # 启动双线程
    segments = load_json_stream("testvideo_simplified.json")
    gen_task = asyncio.create_task(qa_gen.question_generator(segments))
    answer_task = asyncio.create_task(qa_gen.answer_processor())
    
    # 等待任一任务完成
    done, pending = await asyncio.wait(
        [gen_task, answer_task],
        return_when=asyncio.FIRST_COMPLETED
    )
    
    # 清理
    qa_gen.stop_flag = True
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)
    
    # 最终问题列表
    print("\n" + "="*50)
    print("最终问题列表:")
    print(await qa_gen.question_queue.display_questions())

if __name__ == "__main__":
    asyncio.run(main())
