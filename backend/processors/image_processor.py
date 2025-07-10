import os
import re
import json
import time
import logging
import argparse
from typing import List
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
import pygetwindow as gw
import pyautogui
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
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


def get_meeting_windows():
    windows = gw.getAllWindows()
    target_dict = {}

    for win in windows:
        title = win.title.strip()
        #logger.info(f"窗口句柄 {win._hWnd}: {title}")
        if title == "腾讯会议" or title == "Zoom Workplace":
            target_dict[win._hWnd] = win
    #logger.info(f"识别到的会议窗口: {list(target_dict.keys())}")
    return target_dict if target_dict else None


def clean_title(title):
    if "腾讯会议" in title:
        return "tencent"
    elif "Zoom Workplace" in title or "Zoom" in title:
        return "zoom"
    else:
        return re.sub(r'[^a-zA-Z0-9]', '_', title.strip())[:30]


def take_screenshots(window_dict, folder="screen_shot") -> List[str]:
    os.makedirs(folder, exist_ok=True)
    image_paths = []

    for hwnd, window in window_dict.items():
        title = window.title.strip()
        if window.isMinimized:
            window.restore()
            time.sleep(0.5)
        try:
            window.activate()
            time.sleep(2)
        except Exception as e:
            logger.warning(f"无法激活窗口 {title}: {e}")

        left, top = window.left, window.top
        width, height = window.width, window.height
        
        padding_ratio = 0.05  # 截掉边缘 5%
        new_left = left + int(width * padding_ratio)
        new_top = top + int(height * padding_ratio)
        new_width = int(width * (1 - 2 * padding_ratio))
        new_height = int(height * (1 - 2 * padding_ratio))

        tag = clean_title(title)
        filename = os.path.join(folder, f"screenshot_{tag}.png")
        screenshot = pyautogui.screenshot(region=(new_left, new_top, new_width, new_height))
        screenshot.save(filename)
        logger.info(f"截图已保存为 {filename}")
        image_paths.append(filename)

        window.minimize()
    return image_paths


def create_ocr_client() -> ocr_api20210707Client:
    """创建阿里云OCR客户端"""
    access_key_id = os.getenv('ALIBABA_CLOUD_ACCESS_KEY_ID')
    access_key_secret = os.getenv('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
    
    if not access_key_id or not access_key_secret:
        raise ValueError("请在.env文件中配置ALIBABA_CLOUD_ACCESS_KEY_ID和ALIBABA_CLOUD_ACCESS_KEY_SECRET")
    
    config = open_api_models.Config(
        access_key_id=access_key_id,
        access_key_secret=access_key_secret,
        endpoint='ocr-api.cn-hangzhou.aliyuncs.com'
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
            data = json.loads(response.body.to_map()['Data'])
            content = data.get("content", "")
            words_info = data.get("prism_wordsInfo", [])
            return {
                "index": index,
                "filename": os.path.basename(image_path),
                "content": content,
                "total_word_count": len(words_info),
                "words": [{"word": w.get("word", ""), "prob": w.get("prob", 0)} for w in words_info]
            }
        except Exception as e:
            logger.error(f"OCR失败: {e}")
            return {
                "index": index,
                "filename": os.path.basename(image_path),
                "content": f"ERROR: {str(e)}",
                "total_word_count": 0,
                "words": []
            }

    results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(recognize, idx, path) for idx, path in enumerate(image_paths)]
        for future in as_completed(futures):
            results.append(future.result())
    return sorted(results, key=lambda x: x["index"])


def write_result_to_pipe(output_path: str, session_id: str, res: dict):
    payload = {
        "type": "ocr_result",
        "data": {
            "session_id": session_id,
            "text": res["content"],
            "words": res["words"],  # [{"word": ..., "prob": ...}]
            "image_file": os.path.join("screen_shot", res["filename"]),
            "timestamp": datetime.utcnow().isoformat()
        },
        "timestamp": datetime.utcnow().isoformat()
    }

    try:
        with open(output_path, 'a', encoding='utf-8') as f:
            json.dump(payload, f, ensure_ascii=False)
            f.write('\n')
            f.flush()
    except Exception as e:
        logger.error(f"写入 pipe 失败: {e}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--ipc-output', required=True)
    parser.add_argument('--session-id', required=False)
    parser.add_argument('--ipc-input', required=False)
    parser.add_argument('--work-dir', required=False)
    args = parser.parse_args()

    pipe_path = args.ipc_output
    session_id = args.session_id or "unknown-session"

    window_dict = get_meeting_windows()
    if not window_dict:
        msg = {
            "type": "transcript",
            "data": {
                "session_id": session_id,
                "text": "未检测到会议窗口。",
                "words": [],
                "image_file": None,
                "timestamp": datetime.utcnow().isoformat()
            },
            "timestamp": datetime.utcnow().isoformat()
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
                "words": [],
                "image_file": None,
                "timestamp": datetime.utcnow().isoformat()
            },
            "timestamp": datetime.utcnow().isoformat()
        }
        write_result_to_pipe(pipe_path, session_id, msg["data"])
    else:
        for res in results:
            logger.info(f"OCR识别完成: {res['filename']}")
            write_result_to_pipe(pipe_path, session_id, res)

    logger.info("全部完成！")