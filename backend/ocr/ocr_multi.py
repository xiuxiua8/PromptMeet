import json
import sys
import os
from typing import List
from concurrent.futures import ThreadPoolExecutor, as_completed

from alibabacloud_ocr_api20210707.client import Client as ocr_api20210707Client
from alibabacloud_tea_openapi import models as open_api_models
from alibabacloud_darabonba_stream.client import Client as StreamClient
from alibabacloud_ocr_api20210707 import models as ocr_api_20210707_models
from alibabacloud_tea_util import models as util_models
from alibabacloud_tea_util.client import Client as UtilClient

# 设置环境变量（正式项目不推荐明文写入）
os.environ['ALIBABA_CLOUD_ACCESS_KEY_ID'] = 'LTAI5tC5v7gdUqgSDLCv5n4Y'
os.environ['ALIBABA_CLOUD_ACCESS_KEY_SECRET'] = 'LlBjt13L09s0Wh0u2LmCY49afYC2KA'

class Sample:
    def __init__(self):
        pass

    @staticmethod
    def create_client(
        access_key_id: str,
        access_key_secret: str,
    ) -> ocr_api20210707Client:
        config = open_api_models.Config(
            access_key_id=os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID'),
            access_key_secret=os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET'),
        )
        config.endpoint = 'ocr-api.cn-hangzhou.aliyuncs.com'
        return ocr_api20210707Client(config)


    @staticmethod
    def main(image_paths: List[str], max_workers: int = 10):
        client = Sample.create_client(
            os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID'),
            os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
        )

        def recognize(image_path):
            try:
                stream = StreamClient.read_from_file_path(image_path)
                request = ocr_api_20210707_models.RecognizeBasicRequest(body=stream)
                runtime = util_models.RuntimeOptions()
                response = client.recognize_basic_with_options(request, runtime)
                content = json.loads(response.body.to_map()['Data'])['content']
                return (os.path.basename(image_path), content)
            except Exception as e:
                return (os.path.basename(image_path), f"ERROR: {str(e)}")

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = [executor.submit(recognize, path) for path in image_paths]
            for future in as_completed(futures):
                filename, content = future.result()
                print(f"\n[{filename}]\n{content}")

    @staticmethod
    def get_all_image_paths(folder_path: str) -> List[str]:
        return [os.path.join(folder_path, f) for f in os.listdir(folder_path) if f.lower().endswith(('.png', '.jpg', '.jpeg'))]


if __name__ == '__main__':
    image_folder = './images'  # 改成你自己的文件夹路径
    image_list = Sample.get_all_image_paths(image_folder)
    print(f"将识别以下图片：{image_list}")
    Sample.main(image_list, max_workers=7)
    # 14张图片用1个线程大约是14张图片用7个线程的3倍时间
