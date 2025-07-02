import React from 'react';
import './App.css';

function App() {
  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white shadow">
        <div className="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
          <h1 className="text-3xl font-bold text-gray-900">
            PromptMeet
          </h1>
          <p className="text-gray-600 mt-2">
            智能化实时会议纪要与日程同步系统
          </p>
        </div>
      </header>
      
      <main className="max-w-7xl mx-auto py-6 sm:px-6 lg:px-8">
        <div className="px-4 py-6 sm:px-0">
          <div className="border-4 border-dashed border-gray-200 rounded-lg h-96 flex items-center justify-center">
            <div className="text-center">
              <h2 className="text-2xl font-semibold text-gray-700 mb-4">
                欢迎使用 PromptMeet
              </h2>
              <p className="text-gray-500">
                项目基础架构已就绪，开始构建您的AI会议助手吧！
              </p>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}

export default App; 