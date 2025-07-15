@echo off
chcp 65001 > nul
echo ================================
echo 一键启动PromptMeet前后端服务
echo ================================
echo.

echo 1. 启动后端服务...
start "后端服务" cmd /k "chcp 65001 > nul && echo 启动后端... && call conda activate my_env && cd backend && python main_service.py"
echo.

echo 2. 启动前端服务...
start "前端服务" cmd /k "chcp 65001 > nul && echo 启动前端... && cd frontend && npm run dev"
echo.

echo 3. 等待服务启动...
echo 正在等待服务启动，请稍候...
timeout /t 7 /nobreak > nul

echo.
echo 4. 自动打开浏览器...
start http://localhost:5173

echo ================================
echo 所有服务已启动！
echo 后端: http://localhost:8000
echo 前端: http://localhost:5173
echo 浏览器已自动打开前端页面
echo ================================
echo.
echo 如需关闭服务，请手动关闭对应窗口。
echo 按任意键退出本窗口...
@REM pause > nul 