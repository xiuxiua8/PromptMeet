from langchain_core.documents import Document
from langchain_openai import OpenAIEmbeddings, OpenAI
from langchain_community.vectorstores import FAISS
from langchain.chains import ConversationalRetrievalChain
from langchain.memory import ConversationBufferMemory

# 1. 生成随机会议纪要（与之前相同）
def generate_meeting_summary():
    summary = f"""
    ### **会议内容总结**  

#### **1. 主要讨论议题（合并相似内容）**  
- **经济学的定义与范畴**：  
  - 经济学不仅关注宏观问题（如国家政策、利率调整），也研究微观个体行为（如个人、家庭、企业的选择）。  
  - 澄清误解：经济学并非研究“如何赚钱”，而是研究“稀缺资源下的选择”。  
- **微观经济学与宏观经济学的区别**：  
  - 微观经济学：聚焦个体决策（如消费、生产），更贴近日常生活。  
  - 宏观经济学：研究整体经济运行（如GDP、失业率）。  
- **稀缺性与机会成本**：  
  - 资源有限而欲望无限，所有决策都需取舍（“鱼与熊掌不可兼得”）。  
  - 机会成本的核心：选择某选项时，所放弃的其他最佳替代方案的收益（如富人选择飞机而非火车，因时间成本更高）。  

#### **2. 重要结论或决定**  
- 经济学是研究“选择”的学科，其核心逻辑是**在稀缺条件下权衡成本与收益**。  
- **微观经济学**对个人决策更具指导意义，掌握其基础概念（如机会成本）可优化日常生活选择。  
- 机会成本的衡量需结合主观价值（如时间对穷人和富人的差异），而非仅看客观价格。  

#### **3. 我的待办事项**  
- 无特定任务。  

---  
**备注**：会议内容本质为经济学科普，强调微观经济学的实用性，尤其是通过“机会成本”理解日常决策逻辑。

关键要点
**经济学的定义与范畴**：
经济学不仅关注宏观问题（如国家政策、利率调整），也研究微观个体行为（如个人、家庭、企业的选择）。
澄清误解：经济学并非研究“如何赚钱”，而是研究“稀缺资源下的选择”。
**微观经济学与宏观经济学的区别**：
宏观经济学：研究整体经济运行（如GDP、失业率）。
**稀缺性与机会成本**：
机会成本的核心：选择某选项时，所放弃的其他最佳替代方案的收益（如富人选择飞机而非火车，因时间成本更高）。
经济学是研究“选择”的学科，其核心逻辑是**在稀缺条件下权衡成本与收益**。
机会成本的衡量需结合主观价值（如时间对穷人和富人的差异），而非仅看客观价格。
无特定任务。
决策内容
微观经济学：聚焦个体决策（如消费、生产），更贴近日常生活。
资源有限而欲望无限，所有决策都需取舍（“鱼与熊掌不可兼得”）。
**微观经济学**对个人决策更具指导意义，掌握其基础概念（如机会成本）可优化日常生活选择。
    """
    return summary

# 2. 初始化问答系统
def init_qa_system():
    # 生成会议内容
    meeting_content = generate_meeting_summary()
    print("\n生成的会议纪要：\n" + "="*50)
    print(meeting_content)
    print("="*50 + "\n")
    
    # 创建向量数据库
    documents = [Document(page_content=meeting_content)]
    db = FAISS.from_documents(documents, OpenAIEmbeddings())
    
    # 配置记忆系统
    memory = ConversationBufferMemory(
        memory_key="chat_history",
        return_messages=True,
        output_key='answer'
    )
    
    # 构建问答链
    qa = ConversationalRetrievalChain.from_llm(
        llm=OpenAI(temperature=0.3),
        retriever=db.as_retriever(),
        memory=memory,
        return_source_documents=True
    )
    return qa

# 3. 交互式问答主循环
def interactive_qa(qa_system):
    print("请输入您的问题（输入'退出'结束问答）：")
    while True:
        question = input("\n您的问题：").strip()
        if question.lower() in ['退出', 'exit', 'quit']:
            break
            
        # 执行问答
        result = qa_system.invoke({"question": question})
        
        # 显示答案和来源
        print(f"\n答案：{result['answer']}")

# 主程序
if __name__ == "__main__":
    # 设置OpenAI API密钥（替换为您的实际密钥）
    import os
    os.environ["OPENAI_API_KEY"] = "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"  # 请替换
    
    # 初始化系统
    qa = init_qa_system()
    
    # 开始交互
    interactive_qa(qa)
    print("\n问答会话已结束。")
