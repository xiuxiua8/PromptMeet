import os
import re
import json
import time
import logging
import argparse
from typing import List
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
import pyautogui
import platform
from datetime import datetime

# 根据操作系统选择窗口管理库
if platform.system() == "Darwin":  # macOS
    try:
        import pygetwindow as gw
    except (ImportError, AttributeError):
        gw = None

    # macOS原生解决方案
    try:
        from Quartz import (
            CGWindowListCopyWindowInfo,
            kCGNullWindowID,
            kCGWindowListOptionOnScreenOnly,
        )

        macos_native = True
    except ImportError:
        macos_native = False

elif platform.system() == "Windows":
    import pygetwindow as gw

    macos_native = False
else:  # Linux
    try:
        import pygetwindow as gw
    except ImportError:
        gw = None
    macos_native = False
from dotenv import load_dotenv

from alibabacloud_ocr_api20210707.client import Client as ocr_api20210707Client
from alibabacloud_tea_openapi import models as open_api_models
from alibabacloud_darabonba_stream.client import Client as StreamClient
from alibabacloud_ocr_api20210707 import models as ocr_api_20210707_models
from alibabacloud_tea_util import models as util_models
from alibabacloud_tea_util.client import Client as UtilClient

# 环境变量配置 - 从项目根目录加载环境变量
project_root = Path(__file__).parent.parent.parent
env_path = project_root / ".env"
load_dotenv(env_path)

# 日志配置
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# 记录系统状态
if platform.system() == "Darwin":
    if gw:
        logger.info("pygetwindow可用")
    else:
        logger.warning("pygetwindow不可用或版本过低，在macOS上将使用替代方案")

    if macos_native:
        logger.info("macOS原生窗口API可用")
    else:
        logger.warning(
            "macOS原生窗口API不可用，请安装: pip install pyobjc-framework-Quartz"
        )
elif platform.system() == "Windows":
    logger.info("Windows平台，使用pygetwindow")
else:
    logger.info(f"其他平台: {platform.system()}")


def get_macos_windows():
    """获取macOS上的窗口信息"""
    try:
        from Quartz import (
            CGWindowListCopyWindowInfo,
            kCGNullWindowID,
            kCGWindowListOptionOnScreenOnly,
        )

        windows = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly, kCGNullWindowID
        )
        target_dict = {}
        meeting_keywords = [
            "腾讯会议",
            "Zoom Workplace",
            "Zoom",
            "Microsoft Teams",
            "钉钉",
            "飞书",
            "Meeting",
        ]

        for window in windows:
            window_name = window.get("kCGWindowName", "")
            owner_name = window.get("kCGWindowOwnerName", "")
            window_layer = window.get("kCGWindowLayer", 0)

            # 检查窗口名称或应用名称是否包含会议关键词
            if any(keyword in window_name for keyword in meeting_keywords) or any(
                keyword in owner_name for keyword in meeting_keywords
            ):

                window_id = window.get("kCGWindowNumber", 0)
                bounds = window.get("kCGWindowBounds", {})

                # 创建一个简化的窗口对象，包含更多信息
                mock_window = {
                    "title": window_name or f"{owner_name} Window",
                    "bounds": bounds,
                    "owner": owner_name,
                    "window_id": window_id,
                    "layer": window_layer,
                    "type": "macos_native",
                    "raw_window_info": window,  # 保存原始窗口信息用于截图
                }
                target_dict[window_id] = mock_window
                logger.info(
                    f"发现会议窗口: {window_name} ({owner_name}) - 图层: {window_layer}"
                )

        return target_dict if target_dict else None
    except Exception as e:
        logger.error(f"macOS原生窗口API调用失败: {e}")
        return None


def activate_macos_app(app_name):
    """激活macOS应用到前台"""
    try:
        import subprocess

        # 使用osascript激活应用
        script = f'tell application "{app_name}" to activate'
        subprocess.run(["osascript", "-e", script], check=True, capture_output=True)
        logger.info(f"成功激活应用: {app_name}")
        return True
    except Exception as e:
        logger.warning(f"激活应用失败 {app_name}: {e}")
        return False


def capture_macos_window(window_info):
    """使用macOS原生API截取特定窗口"""
    try:
        from Quartz import (
            CGWindowListCreateImage,
            CGWindowListCreateImageFromArray,
            kCGWindowListOptionIncludingWindow,
            kCGWindowListExcludeDesktopElements,
            kCGWindowImageDefault,
            kCGNullWindowID,
        )
        import Quartz
        from PIL import Image
        import numpy as np

        window_id = window_info.get("window_id")
        if not window_id:
            return None

        # 方法1: 尝试截取单个窗口
        try:
            # 创建窗口ID数组
            window_array = [window_id]

            # 截取指定窗口
            image = CGWindowListCreateImageFromArray(
                Quartz.CGRectNull, window_array, kCGWindowImageDefault  # 截取整个窗口
            )

            if image:
                # 转换CGImage到PIL Image
                width = Quartz.CGImageGetWidth(image)
                height = Quartz.CGImageGetHeight(image)

                if width > 0 and height > 0:
                    # 获取图像数据
                    data_provider = Quartz.CGImageGetDataProvider(image)
                    data = Quartz.CGDataProviderCopyData(data_provider)

                    # 转换为numpy数组然后转为PIL图像
                    bytes_per_row = Quartz.CGImageGetBytesPerRow(image)
                    data_np = np.frombuffer(data, dtype=np.uint8)

                    # 重新塑形为图像
                    if len(data_np) >= height * bytes_per_row:
                        image_array = data_np[: height * bytes_per_row].reshape(
                            (height, bytes_per_row // 4, 4)
                        )
                        # BGRA -> RGB
                        image_array = image_array[:, :, [2, 1, 0]]

                        # 创建PIL图像
                        pil_image = Image.fromarray(image_array[:, :width, :])
                        return pil_image

        except Exception as e:
            logger.warning(f"方法1截图失败: {e}")

        # 方法2: 如果方法1失败，尝试使用窗口位置信息进行区域截图
        bounds = window_info.get("bounds", {})
        if bounds:
            x = int(bounds.get("X", 0))
            y = int(bounds.get("Y", 0))
            width = int(bounds.get("Width", 0))
            height = int(bounds.get("Height", 0))

            if width > 0 and height > 0:
                # 尝试激活应用到前台
                app_name = window_info.get("owner", "")
                if app_name:
                    activate_macos_app(app_name)
                    time.sleep(1)  # 等待窗口显示

                # 使用pyautogui进行区域截图
                screenshot = pyautogui.screenshot(region=(x, y, width, height))
                return screenshot

    except Exception as e:
        logger.error(f"macOS窗口截图失败: {e}")

    return None


def get_meeting_windows():
    """获取会议窗口，支持跨平台"""
    # 首先尝试macOS原生方案
    if platform.system() == "Darwin" and macos_native:
        result = get_macos_windows()
        if result:
            return result

    # 然后尝试pygetwindow
    if gw is not None:
        try:
            windows = gw.getAllWindows()
            target_dict = {}

            for win in windows:
                title = win.title.strip()
                # 支持更多会议软件
                meeting_keywords = [
                    "腾讯会议",
                    "Zoom Workplace",
                    "Zoom",
                    "Microsoft Teams",
                    "钉钉",
                    "飞书",
                    "会议",
                ]

                if any(keyword in title for keyword in meeting_keywords):
                    # 使用窗口对象本身作为键，而不是hWnd（macOS可能没有）
                    window_id = getattr(win, "_hWnd", id(win))
                    target_dict[window_id] = win
                    logger.info(f"发现会议窗口: {title}")

            return target_dict if target_dict else None
        except Exception as e:
            logger.error(f"获取窗口列表失败: {e}")

    # 最后使用fallback方案
    logger.info("使用fallback方案，将截取整个屏幕")
    return {"fullscreen": {"title": "全屏截图", "type": "fallback"}}


def clean_title(title):
    """清理窗口标题，生成合适的文件名"""
    if not title:
        return "unknown"

    if "腾讯会议" or "会议" in title:
        return "tencent_meeting"
    elif "Zoom Workplace" in title or "Zoom" in title:
        return "zoom"
    elif "Microsoft Teams" in title or "Teams" in title:
        return "teams"
    elif "钉钉" in title:
        return "dingtalk"
    elif "飞书" in title:
        return "feishu"
    else:
        # 移除特殊字符，保留字母数字和下划线
        cleaned = re.sub(r"[^a-zA-Z0-9_\u4e00-\u9fff]", "_", title.strip())
        return cleaned[:30]  # 限制长度


def take_screenshots(window_dict, folder="screen_shot") -> List[str]:
    """截取窗口截图，支持fallback模式"""
    os.makedirs(folder, exist_ok=True)
    image_paths = []
    print("当前窗口数:", len(window_dict))
    for k in window_dict:
        print("窗口key:", k)
        print("窗口值:", window_dict[k])

    for hwnd, window in window_dict.items():
        # 处理fallback情况
        if isinstance(window, dict) and window.get("type") == "fallback":
            logger.info("使用全屏截图模式")
            filename = os.path.join(folder, "screenshot_fullscreen.png")
            screenshot = pyautogui.screenshot()
            screenshot.save(filename)
            logger.info(f"全屏截图已保存为 {filename}")
            image_paths.append(filename)
            continue

        # 处理macOS原生窗口
        if isinstance(window, dict) and window.get("type") == "macos_native":
            try:
                title = window.get("title", "Unknown")
                tag = clean_title(title)
                filename = os.path.join(folder, f"screenshot_{tag}.png")

                logger.info(f"尝试截取macOS窗口: {title}")

                # 使用新的窗口级截图功能
                screenshot = capture_macos_window(window)

                if screenshot:
                    screenshot.save(filename)
                    logger.info(f"macOS窗口级截图成功: {filename}")
                    image_paths.append(filename)
                else:
                    # 如果窗口级截图失败，尝试传统方法
                    logger.warning(f"窗口级截图失败，尝试传统方法: {title}")
                    bounds = window.get("bounds", {})

                    if bounds:
                        # 尝试激活应用
                        app_name = window.get("owner", "")
                        if app_name:
                            activate_macos_app(app_name)
                            time.sleep(1.5)  # 增加等待时间

                        x = int(bounds.get("X", 0))
                        y = int(bounds.get("Y", 0))
                        width = int(bounds.get("Width", 0))
                        height = int(bounds.get("Height", 0))

                        # 添加一些边距避免截取到窗口边框
                        padding = 10
                        region = (
                            x + padding,
                            y + padding,
                            width - 2 * padding,
                            height - 2 * padding,
                        )

                        screenshot = pyautogui.screenshot(region=region)
                        screenshot.save(filename)
                        logger.info(f"macOS传统截图已保存: {filename}")
                        image_paths.append(filename)
                    else:
                        # 没有位置信息，使用全屏截图
                        filename = os.path.join(
                            folder, f"screenshot_fullscreen_{tag}.png"
                        )
                        screenshot = pyautogui.screenshot()
                        screenshot.save(filename)
                        logger.info(f"macOS全屏截图已保存: {filename}")
                        image_paths.append(filename)
                continue

            except Exception as e:
                logger.error(f"macOS截图失败: {e}")
                # fallback到全屏截图
                tag = clean_title(title if "title" in locals() else "fallback")
                filename = os.path.join(folder, f"screenshot_macos_fallback_{tag}.png")
                screenshot = pyautogui.screenshot()
                screenshot.save(filename)
                logger.info(f"macOS fallback截图已保存: {filename}")
                image_paths.append(filename)
                continue

        # 正常的窗口处理
        try:
            title = window.title.strip()
            if hasattr(window, "isMinimized") and window.isMinimized:
                window.restore()
                time.sleep(0.5)

            if hasattr(window, "activate"):
                try:
                    window.activate()
                    time.sleep(2)
                except Exception as e:
                    logger.warning(f"无法激活窗口 {title}: {e}")

            # 获取窗口位置和大小
            if hasattr(window, "left") and hasattr(window, "top"):
                left, top = window.left, window.top
                width, height = window.width, window.height

                padding_ratio = 0.025  # 截掉边缘 5%
                new_left = left + int(width * padding_ratio)
                new_top = top + int(height * padding_ratio)
                new_width = int(width * (1 - 2 * padding_ratio))
                new_height = int(height * (1 - 2 * padding_ratio))

                tag = clean_title(title)
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                filename = os.path.join(folder, f"screenshot_{tag}_{timestamp}.png")
                screenshot = pyautogui.screenshot(
                    region=(new_left, new_top, new_width, new_height)
                )
                screenshot.save(filename)
                logger.info(f"截图已保存为 {filename}")
                image_paths.append(filename)

                if hasattr(window, "minimize"):
                    window.minimize()
            else:
                # 无法获取窗口位置，使用全屏截图
                logger.warning(f"无法获取窗口 {title} 的位置信息，使用全屏截图")
                filename = os.path.join(
                    folder, f"screenshot_fullscreen_{clean_title(title)}.png"
                )
                screenshot = pyautogui.screenshot()
                screenshot.save(filename)
                logger.info(f"全屏截图已保存为 {filename}")
                image_paths.append(filename)

        except Exception as e:
            logger.error(f"截图窗口时出错: {e}")
            # 出错时使用全屏截图作为fallback
            filename = os.path.join(folder, "screenshot_fallback.png")
            screenshot = pyautogui.screenshot()
            screenshot.save(filename)
            logger.info(f"fallback截图已保存为 {filename}")
            image_paths.append(filename)

    return image_paths


def create_ocr_client() -> ocr_api20210707Client:
    """创建阿里云OCR客户端"""
    access_key_id = os.getenv("ALIBABA_CLOUD_ACCESS_KEY_ID")
    access_key_secret = os.getenv("ALIBABA_CLOUD_ACCESS_KEY_SECRET")

    if not access_key_id or not access_key_secret:
        raise ValueError(
            "请在.env文件中配置ALIBABA_CLOUD_ACCESS_KEY_ID和ALIBABA_CLOUD_ACCESS_KEY_SECRET"
        )

    config = open_api_models.Config(
        access_key_id=access_key_id,
        access_key_secret=access_key_secret,
        endpoint="ocr-api.cn-hangzhou.aliyuncs.com",
    )
    return ocr_api20210707Client(config)


def recognize_ocr_batch(image_paths: List[str], max_workers: int = 5) -> List[dict]:
    client = create_ocr_client()

    def recognize(index, image_path):
        try:
            stream = StreamClient.read_from_file_path(image_path)
            request = ocr_api_20210707_models.RecognizeBasicRequest(body=stream)
            runtime = util_models.RuntimeOptions()
            response = client.recognize_basic_with_options(request, runtime)
            data = json.loads(response.body.to_map()["Data"])
            content = data.get("content", "")
            words_info = data.get("prism_wordsInfo", [])
            return {
                "index": index,
                "filename": os.path.basename(image_path),
                "content": content,
                "total_word_count": len(words_info),
                "words": [
                    {"word": w.get("word", ""), "prob": w.get("prob", 0)}
                    for w in words_info
                ],
            }
        except Exception as e:
            logger.error(f"OCR失败: {e}")
            return {
                "index": index,
                "filename": os.path.basename(image_path),
                "content": f"ERROR: {str(e)}",
                "total_word_count": 0,
                "words": [],
            }

    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [
            executor.submit(recognize, idx, path)
            for idx, path in enumerate(image_paths)
        ]
        for future in as_completed(futures):
            results.append(future.result())
    return sorted(results, key=lambda x: x["index"])


def write_result_to_pipe(output_path: str, session_id: str, res: dict):
    payload = {
        "type": "ocr_result",
        "data": {
            "session_id": session_id,
            "text": res["content"],
            #"words": res["words"],  # [{"word": ..., "prob": ...}]
            "image_file": os.path.join("screen_shot", res["filename"]),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    try:
        with open(output_path, "a", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
            f.write("\n")
            f.flush()
    except Exception as e:
        logger.error(f"写入 pipe 失败: {e}")


def get_specific_window(window_id: str):
    """根据窗口ID获取特定窗口"""
    window_dict = get_meeting_windows()
    if not window_dict:
        return None

    # 查找指定的窗口ID
    for wid, window in window_dict.items():
        if str(wid) == window_id:
            return {wid: window}

    logger.warning(f"未找到窗口ID: {window_id}")
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipc-output", required=True)
    parser.add_argument("--session-id", required=False)
    parser.add_argument("--ipc-input", required=False)
    parser.add_argument("--work-dir", required=False)
    parser.add_argument("--window-id", required=False, help="指定要截图的窗口ID")
    args = parser.parse_args()

    pipe_path = args.ipc_output
    session_id = args.session_id or "unknown-session"
    window_id = args.window_id

    # 如果指定了窗口ID，只处理该窗口
    if window_id:
        logger.info(f"处理指定窗口: {window_id}")
        window_dict = get_specific_window(window_id)
        if not window_dict:
            msg = {
                "type": "transcript",
                "data": {
                    "session_id": session_id,
                    "text": f"未找到指定的窗口ID: {window_id}",
                    #"words": [],
                    "image_file": None,
                    "timestamp": datetime.utcnow().isoformat(),
                },
                "timestamp": datetime.utcnow().isoformat(),
            }
            write_result_to_pipe(pipe_path, session_id, msg["data"])
            exit(0)
    else:
        # 处理所有会议窗口
        logger.info("处理所有会议窗口")
        window_dict = get_meeting_windows()
        if not window_dict:
            msg = {
                "type": "transcript",
                "data": {
                    "session_id": session_id,
                    "text": "未检测到会议窗口。",
                    #"words": [],
                    "image_file": None,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                },
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            write_result_to_pipe(pipe_path, session_id, msg["data"])
            exit(0)

    logger.info("正在截图会议窗口...")
    captured_paths = take_screenshots(window_dict, folder="screen_shot")

    logger.info("正在调用 OCR 识别文字...")
    results = recognize_ocr_batch(captured_paths, max_workers=5)

    if not results:
        msg = {
            "type": "transcript",
            "data": {
                "session_id": session_id,
                "text": "未识别到任何图像文字内容。",
                #"words": [],
                "image_file": None,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            },
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        write_result_to_pipe(pipe_path, session_id, msg["data"])
    else:
        for res in results:
            logger.info(f"OCR识别完成: {res['filename']}")
            write_result_to_pipe(pipe_path, session_id, res)

    logger.info("全部完成！")
