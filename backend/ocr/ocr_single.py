# pip install alibabacloud_ocr_api20210707 alibabacloud_tea_openapi alibabacloud_tea_util alibabacloud_darabonba_stream

import json
import sys
 
from typing import List
 
from alibabacloud_ocr_api20210707.client import Client as ocr_api20210707Client
from alibabacloud_tea_openapi import models as open_api_models
from alibabacloud_darabonba_stream.client import Client as StreamClient
from alibabacloud_ocr_api20210707 import models as ocr_api_20210707_models
from alibabacloud_tea_util import models as util_models
from alibabacloud_tea_util.client import Client as UtilClient
 
 
import os
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
        """
        使用AK&SK初始化账号Client
        @param access_key_id:
        @param access_key_secret:
        @return: Client
        @throws Exception
        """
        config = open_api_models.Config(
          # 创建AccessKey ID和AccessKey Secret，请参考https://help.aliyun.com/document_detail/175144.html
          # 如果您用的是RAM用户的AccessKey，还需要为RAM用户授予权限AliyunVIAPIFullAccess，请参考https://help.aliyun.com/document_detail/145025.html
          # 从环境变量读取配置的AccessKey ID和AccessKey Secret。运行代码示例前必须先配置环境变量。
          access_key_id=os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID'),
          access_key_secret=os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET'),
        )
        config.endpoint = f'ocr-api.cn-hangzhou.aliyuncs.com'
        return ocr_api20210707Client(config)
 
    @staticmethod
    def main(
        args: List[str],
    ) -> None:
        # 工程代码泄露可能会导致AccessKey泄露，并威胁账号下所有资源的安全性。以下代码示例仅供参考，建议使用更安全的 STS 方式，更多鉴权访问方式请参见：https://help.aliyun.com/document_detail/378659.html
        client = Sample.create_client(
            os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID'),
            os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
        )
        # 需要安装额外的依赖库，直接点击下载完整工程即可看到所有依赖。
        body_stream = StreamClient.read_from_file_path('./images/test_ocr_0.png')
        recognize_basic_request = ocr_api_20210707_models.RecognizeBasicRequest(
            body=body_stream,
        )
        runtime = util_models.RuntimeOptions()
        try:
            # 复制代码运行请自行打印 API 的返回值
            ret = client.recognize_basic_with_options(recognize_basic_request, runtime)
            print(json.loads(ret.body.to_map()['Data'])['content'])
        except Exception as error:
            # 如有需要，请打印 error
            UtilClient.assert_as_string(error.message)
            print(error)
 
    @staticmethod
    async def main_async(
        args: List[str],
    ) -> None:
        # 工程代码泄露可能会导致AccessKey泄露，并威胁账号下所有资源的安全性。以下代码示例仅供参考，建议使用更安全的 STS 方式，更多鉴权访问方式请参见：https://help.aliyun.com/document_detail/378659.html
        client = Sample.create_client(
            os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_ID'),
            os.environ.get('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
        )
        # 需要安装额外的依赖库，直接点击下载完整工程即可看到所有依赖。
        body_stream = StreamClient.read_from_file_path('./test_ocr_0.png')
        recognize_basic_request = ocr_api_20210707_models.RecognizeBasicRequest(
            body=body_stream
        )
        runtime = util_models.RuntimeOptions()
        try:
            # 复制代码运行请自行打印 API 的返回值
            await client.recognize_basic_with_options_async(recognize_basic_request, runtime)
        except Exception as error:
            # 如有需要，请打印 error
            UtilClient.assert_as_string(error.message)
 
if __name__ == '__main__':
    Sample.main(sys.argv[1:])