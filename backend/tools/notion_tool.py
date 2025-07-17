"""
Notion文档工具
"""
import requests
import json
from typing import Dict, Any, List, Optional
try:
    # 尝试相对导入（在工具管理器中使用）
    from .base import BaseTool, ToolResult
    from ..config import settings
except ImportError:
    # 如果相对导入失败，使用绝对导入（在独立测试中使用）
    from tools.base import BaseTool, ToolResult
    from config import settings


class NotionTool(BaseTool):
    """Notion文档工具"""
    
    def __init__(self):
        super().__init__(
            name="notion",
            description="管理Notion文档，包括搜索、创建、更新页面和查询数据库"
        )
        self.base_url = "https://api.notion.com/v1"
        self.headers = {
            "Authorization": f"Bearer {settings.NOTION_API_KEY}",
            "Content-Type": "application/json",
            "Notion-Version": "2022-06-28"
        }
    
    async def execute(self, action: str, **parameters) -> ToolResult:
        """执行Notion操作"""
        try:
            if not settings.NOTION_API_KEY:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error="Notion API密钥未配置，请在.env文件中设置NOTION_API_KEY"
                )
            
            if action == "search":
                return await self._search(**parameters)
            elif action == "create_page":
                return await self._create_page(**parameters)
            elif action == "get_page":
                return await self._get_page(**parameters)
            elif action == "update_page":
                return await self._update_page(**parameters)
            elif action == "query_database":
                return await self._query_database(**parameters)
            elif action == "create_database":
                return await self._create_database(**parameters)
            else:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"不支持的操作: {action}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"执行Notion操作失败: {str(e)}"
            )
    
    async def _search(self, query: str = "", filter_type: Optional[str] = None) -> ToolResult:
        """搜索Notion页面和数据库"""
        try:
            url = f"{self.base_url}/search"
            payload = {
                "query": query,
                "page_size": 10
            }
            
            if filter_type:
                payload["filter"] = {
                    "property": "object",
                    "value": filter_type  # "page" 或 "database"
                }
            
            response = requests.post(url, headers=self.headers, json=payload, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                results = []
                for item in data.get("results", []):
                    item_info = {
                        "id": item["id"],
                        "type": item["object"],
                        "url": item.get("url", ""),
                        "created_time": item.get("created_time", ""),
                        "last_edited_time": item.get("last_edited_time", "")
                    }
                    
                    # 获取标题
                    if item["object"] == "page":
                        properties = item.get("properties", {})
                        for prop_name, prop_value in properties.items():
                            if prop_value.get("type") == "title":
                                title_texts = prop_value.get("title", [])
                                if title_texts:
                                    item_info["title"] = title_texts[0].get("plain_text", "")
                                break
                    elif item["object"] == "database":
                        title_texts = item.get("title", [])
                        if title_texts:
                            item_info["title"] = title_texts[0].get("plain_text", "")
                    
                    results.append(item_info)
                
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "query": query,
                        "total_results": len(results),
                        "results": results
                    }
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"搜索失败: {response.status_code} - {response.text}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"搜索操作失败: {str(e)}"
            )
    
    async def _get_page(self, page_id: str) -> ToolResult:
        """获取页面内容"""
        try:
            # 获取页面信息
            page_url = f"{self.base_url}/pages/{page_id}"
            page_response = requests.get(page_url, headers=self.headers, timeout=10)
            
            if page_response.status_code != 200:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"获取页面失败: {page_response.status_code} - {page_response.text}"
                )
            
            page_data = page_response.json()
            
            # 获取页面内容块
            blocks_url = f"{self.base_url}/blocks/{page_id}/children"
            blocks_response = requests.get(blocks_url, headers=self.headers, timeout=10)
            
            blocks_data = blocks_response.json() if blocks_response.status_code == 200 else {"results": []}
            
            # 提取文本内容
            content_text = self._extract_text_from_blocks(blocks_data.get("results", []))
            
            return ToolResult(
                tool_name=self.name,
                result={
                    "page_id": page_id,
                    "title": self._get_page_title(page_data),
                    "url": page_data.get("url", ""),
                    "created_time": page_data.get("created_time", ""),
                    "last_edited_time": page_data.get("last_edited_time", ""),
                    "content": content_text,
                    "properties": page_data.get("properties", {})
                }
            )
            
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"获取页面内容失败: {str(e)}"
            )
    
    async def _create_page(self, parent_id: str, title: str, content: Optional[str] = None) -> ToolResult:
        """创建新页面"""
        try:
            url = f"{self.base_url}/pages"
            
            payload = {
                "parent": {
                    "page_id": parent_id
                },
                "properties": {
                    "title": {
                        "title": [
                            {
                                "text": {
                                    "content": title
                                }
                            }
                        ]
                    }
                }
            }
            
            # 如果有内容，添加子块
            if content:
                payload["children"] = [
                    {
                        "object": "block",
                        "type": "paragraph",
                        "paragraph": {
                            "rich_text": [
                                {
                                    "type": "text",
                                    "text": {
                                        "content": content
                                    }
                                }
                            ]
                        }
                    }
                ]
            
            response = requests.post(url, headers=self.headers, json=payload, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "page_id": data["id"],
                        "title": title,
                        "url": data.get("url", ""),
                        "created_time": data.get("created_time", "")
                    }
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"创建页面失败: {response.status_code} - {response.text}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"创建页面操作失败: {str(e)}"
            )
    
    async def _update_page(self, page_id: str, **properties) -> ToolResult:
        """更新页面属性"""
        try:
            url = f"{self.base_url}/pages/{page_id}"
            
            payload = {
                "properties": properties
            }
            
            response = requests.patch(url, headers=self.headers, json=payload, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "page_id": page_id,
                        "last_edited_time": data.get("last_edited_time", ""),
                        "properties": data.get("properties", {})
                    }
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"更新页面失败: {response.status_code} - {response.text}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"更新页面操作失败: {str(e)}"
            )
    
    async def _query_database(self, database_id: str, filter_conditions: Optional[Dict] = None, sorts: Optional[List] = None) -> ToolResult:
        """查询数据库"""
        try:
            url = f"{self.base_url}/databases/{database_id}/query"
            
            payload = {
                "page_size": 10
            }
            
            if filter_conditions:
                payload["filter"] = filter_conditions
            
            if sorts:
                payload["sorts"] = sorts
            
            response = requests.post(url, headers=self.headers, json=payload, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                results = []
                
                for item in data.get("results", []):
                    item_info = {
                        "id": item["id"],
                        "url": item.get("url", ""),
                        "created_time": item.get("created_time", ""),
                        "last_edited_time": item.get("last_edited_time", ""),
                        "properties": {}
                    }
                    
                    # 提取属性值
                    for prop_name, prop_value in item.get("properties", {}).items():
                        item_info["properties"][prop_name] = self._extract_property_value(prop_value)
                    
                    results.append(item_info)
                
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "database_id": database_id,
                        "total_results": len(results),
                        "results": results
                    }
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"查询数据库失败: {response.status_code} - {response.text}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"查询数据库操作失败: {str(e)}"
            )
    
    async def _create_database(self, parent_id: str, title: str, properties: Dict) -> ToolResult:
        """创建数据库"""
        try:
            url = f"{self.base_url}/databases"
            
            payload = {
                "parent": {
                    "type": "page_id",
                    "page_id": parent_id
                },
                "title": [
                    {
                        "type": "text",
                        "text": {
                            "content": title
                        }
                    }
                ],
                "properties": properties
            }
            
            response = requests.post(url, headers=self.headers, json=payload, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                return ToolResult(
                    tool_name=self.name,
                    result={
                        "database_id": data["id"],
                        "title": title,
                        "url": data.get("url", ""),
                        "created_time": data.get("created_time", "")
                    }
                )
            else:
                return ToolResult(
                    tool_name=self.name,
                    success=False,
                    error=f"创建数据库失败: {response.status_code} - {response.text}"
                )
                
        except Exception as e:
            return ToolResult(
                tool_name=self.name,
                success=False,
                error=f"创建数据库操作失败: {str(e)}"
            )
    
    def _extract_text_from_blocks(self, blocks: List[Dict]) -> str:
        """从块中提取文本内容"""
        text_content = []
        
        for block in blocks:
            block_type = block.get("type", "")
            block_data = block.get(block_type, {})
            
            if "rich_text" in block_data:
                for text_item in block_data["rich_text"]:
                    if text_item.get("type") == "text":
                        text_content.append(text_item["text"]["content"])
        
        return "\n".join(text_content)
    
    def _get_page_title(self, page_data: Dict) -> str:
        """获取页面标题"""
        properties = page_data.get("properties", {})
        for prop_name, prop_value in properties.items():
            if prop_value.get("type") == "title":
                title_texts = prop_value.get("title", [])
                if title_texts:
                    return title_texts[0].get("plain_text", "")
        return "无标题"
    
    def _extract_property_value(self, prop_data: Dict) -> Any:
        """提取属性值"""
        prop_type = prop_data.get("type", "")
        
        if prop_type == "title":
            texts = prop_data.get("title", [])
            return texts[0].get("plain_text", "") if texts else ""
        elif prop_type == "rich_text":
            texts = prop_data.get("rich_text", [])
            return texts[0].get("plain_text", "") if texts else ""
        elif prop_type == "number":
            return prop_data.get("number")
        elif prop_type == "select":
            select_data = prop_data.get("select")
            return select_data.get("name") if select_data else None
        elif prop_type == "multi_select":
            multi_select_data = prop_data.get("multi_select", [])
            return [item.get("name") for item in multi_select_data]
        elif prop_type == "date":
            date_data = prop_data.get("date")
            return date_data.get("start") if date_data else None
        elif prop_type == "checkbox":
            return prop_data.get("checkbox", False)
        elif prop_type == "url":
            return prop_data.get("url")
        elif prop_type == "email":
            return prop_data.get("email")
        elif prop_type == "phone_number":
            return prop_data.get("phone_number")
        else:
            return str(prop_data) 