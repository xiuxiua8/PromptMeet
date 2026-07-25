"""兼容旧的桌面启动命令，实际始终复用 PromptMeet 主服务。"""

import os

os.environ.setdefault("PROMPTMEET_DESKTOP_MODE", "1")

from main_service import app  # noqa: E402


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
