import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.header import Header
import datetime

def send_qq_email(sender, auth_code, recipient, subject, content):
    """
    使用QQ邮箱发送邮件
    
    参数:
        sender: 发件人邮箱(如: 12345678@qq.com)
        auth_code: QQ邮箱授权码
        recipient: 收件人邮箱
        subject: 邮件主题
        content: 邮件正文内容
    """
    # 创建邮件对象
    message = MIMEMultipart()
    
    # 按照RFC标准设置邮件头部
    sender_name = sender.split('@')[0]  # 从邮箱地址提取用户名作为发件人名称
    message['From'] = f"{sender_name} <{sender}>"  # 发件人
    message['To'] = recipient  # 收件人
    message['Subject'] = Header(subject, 'utf-8')  # 主题
    
    # 添加邮件正文
    message.attach(MIMEText(content, 'plain', 'utf-8'))
    
    try:
        # 连接QQ邮箱SMTP服务器, 端口465
        smtp_obj = smtplib.SMTP_SSL("smtp.qq.com", 465)
        # smtp_obj.set_debuglevel(1)  # 调试模式(可选)
        
        # 登录邮箱
        smtp_obj.login(sender, auth_code)
        
        # 发送邮件
        smtp_obj.sendmail(sender, recipient, message.as_string())
        print("邮件发送成功")
        return True
    except smtplib.SMTPException as e:
        print(f"邮件发送失败: {e}")
        return False
    finally:
        # 关闭连接
        if 'smtp_obj' in locals():
            smtp_obj.quit()

# 使用示例
if __name__ == "__main__":
    # 替换为你的信息
    sender_email = "3125193963@qq.com"  # 发件人QQ邮箱
    auth_code = "lfivvgwgtxtudhch"  # 不是QQ密码，是SMTP授权码
    recipient_email = "2984994383@qq.com"  # 收件人邮箱
    
    email_subject = "Python发送QQ邮件测试"
    email_content = """
    这是一封通过Python脚本使用QQ邮箱发送的测试邮件。
    
    当前时间: {time}
    发送者: {sender}
    接收者: {recipient}
    """.format(
        time=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        sender=sender_email,
        recipient=recipient_email
    )
    
    send_qq_email(
        sender=sender_email,
        auth_code=auth_code,
        recipient=recipient_email,
        subject=email_subject,
        content=email_content
    )
