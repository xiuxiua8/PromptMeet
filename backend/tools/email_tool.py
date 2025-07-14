"""
邮件发送工具
"""
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import Header
import datetime
from typing import Dict, Any
from .base import BaseTool, ToolResult


class EmailTool(BaseTool):
    """邮件发送工具"""
    
    def __init__(self):
        super().__init__(
            name="email",
            description="发送QQ邮箱邮件"
        )
    
    async def execute(self, 
                     sender: str = None,
                     auth_code: str = None,
                     recipient: str = None,
                     subject: str = None,
                     content: str = None) -> ToolResult:
        """执行邮件发送"""
        try:
            # 验证必需参数
            if not all([sender, auth_code, recipient, subject, content]):
                missing_params = []
                if not sender: missing_params.append("sender")
                if not auth_code: missing_params.append("auth_code")
                if not recipient: missing_params.append("recipient")
                if not subject: missing_params.append("subject")
                if not content: missing_params.append("content")
                
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "error": f"缺少必需参数: {', '.join(missing_params)}",
                        "type": "parameter_error"
                    },
                    success=False,
                    error=f"缺少必需参数: {', '.join(missing_params)}"
                )
            
            print(f"开始发送邮件...")
            print(f"发件人: {sender}")
            print(f"收件人: {recipient}")
            print(f"主题: {subject}")
            
            # 创建邮件对象
            message = MIMEMultipart()
            
            # 按照RFC标准设置邮件头部
            sender_name = sender.split('@')[0]  # 从邮箱地址提取用户名作为发件人名称
            message['From'] = f"{sender_name} <{sender}>"  # 发件人
            message['To'] = recipient  # 收件人
            message['Subject'] = Header(subject, 'utf-8')  # 主题
            
            # 添加邮件正文
            message.attach(MIMEText(content, 'plain', 'utf-8'))
            
            print("正在连接QQ邮箱SMTP服务器...")
            # 连接QQ邮箱SMTP服务器, 端口465
            smtp_obj = smtplib.SMTP_SSL("smtp.qq.com", 465)
            
            print("正在登录邮箱...")
            # 登录邮箱
            smtp_obj.login(sender, auth_code)
            
            print("正在发送邮件...")
            # 发送邮件
            smtp_obj.sendmail(sender, recipient, message.as_string())
            
            print("正在关闭连接...")
            # 关闭连接
            smtp_obj.quit()
            
            print("邮件发送完成！")
            
            return ToolResult(
                tool_name=self.name,
                result={
                    "sender": sender,
                    "recipient": recipient,
                    "subject": subject,
                    "content": content,
                    "send_time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    "status": "success",
                    "type": "email"
                },
                success=True
            )
            
        except smtplib.SMTPException as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "sender": sender,
                    "recipient": recipient,
                    "subject": subject,
                    "error": f"邮件发送失败: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            )
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                result={
                    "error": f"邮件发送异常: {str(e)}",
                    "type": "error"
                },
                success=False,
                error=str(e)
            ) 