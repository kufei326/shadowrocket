import os
import urllib.parse
from time import sleep
from pathlib import Path
import requests
import json
from datetime import datetime, timedelta

import pytz
from typing import Any, List, Dict, Tuple, Optional

from app.core.event import eventmanager, Event
from app.schemas.types import EventType
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from app.log import logger
from app.plugins import _PluginBase
from app.core.config import settings

class AlistStrm(_PluginBase):
    plugin_name = "AlistStrm"
    plugin_desc = "生成 Alist 云盘视频的 Strm 文件"
    plugin_icon = "https://raw.githubusercontent.com/thsrite/MoviePilot-Plugins/main/icons/create.png"
    plugin_version = "1.0"
    plugin_author = "kufei326"
    author_url = "https://github.com/kufei326"
    plugin_config_prefix = "aliststrm_"
    plugin_order = 26
    auth_level = 1

    _enabled: bool = False
    _cron: Optional[str] = None
    _onlyonce: bool = False
    _download_subtitle: bool = False

    _liststrm_confs: Optional[List[str]] = None

    _try_max: int = 15

    _video_formats: Tuple[str, ...] = ('.mp4', '.avi', '.rmvb', '.wmv', '.mov', '.mkv', '.flv', '.ts', '.webm', '.iso', '.mpg', '.m2ts')
    _subtitle_formats: Tuple[str, ...] = ('.ass', '.srt', '.ssa', '.sub')

    # 定时器
    _scheduler: Optional[BackgroundScheduler] = None

    def init_plugin(self, config: Optional[Dict[str, Any]] = None):
  
        if config:
            self._enabled = config.get("enabled")
            self._cron = config.get("cron")
            self._onlyonce = config.get("onlyonce")
            self._download_subtitle = config.get("download_subtitle")
            self._liststrm_confs = config.get("liststrm_confs").split("\n")

        # 停止现有任务
        self.stop_service()

        if self._enabled or self._onlyonce:
            # 定时服务
            self._scheduler = BackgroundScheduler(timezone=settings.TZ)

            # 运行一次定时服务
            if self._onlyonce:
                logger.info("AutoFilm执行服务启动，立即运行一次")
                self._scheduler.add_job(func=self.scan, trigger='date',
                                        run_date=datetime.now(tz=pytz.timezone(settings.TZ)) + timedelta(seconds=3),
                                        name="AutoFilm单次执行")
                # 关闭一次性开关
                self._onlyonce = False

            # 周期运行
            if self._cron:
                try:
                    self._scheduler.add_job(func=self.scan,
                                            trigger=CronTrigger.from_crontab(self._cron),
                                            name="云盘监控生成")
                except Exception as err:
                    logger.error(f"定时任务配置错误：{err}")
                    # 推送实时消息
                    self.systemmessage.put(f"执行周期配置错误：{err}")

            # 启动任务
            if self._scheduler.get_jobs():
                self._scheduler.print_jobs()
                self._scheduler.start()

    @eventmanager.register(EventType.PluginAction)
    def scan(self, event: Optional[Event] = None):
        """
        扫描
        """
        if not self._enabled:
            logger.error("aliststrm插件未开启")
            return
        if not self._liststrm_confs:
            logger.error("未获取到可用目录监控配置，请检查")
            return

        if event:
            event_data = event.event_data
            if not event_data or event_data.get("action") != "alist_strm":
                return
            logger.info("aliststrm收到命令，开始生成Alist云盘Strm文件 ...")
            self.post_message(channel=event.event_data.get("channel"),
                              title="aliststrm开始生成strm ...",
                              userid=event.event_data.get("user"))

        logger.info("AutoFilm生成Strm任务开始")
        
        # 生成strm文件
        for aliststrm_conf in self._liststrm_confs:
            # 格式 Webdav服务器地址:账号:密码:本地目录:根目录
            if not aliststrm_conf:
                continue
            if str(aliststrm_conf).count("#") == 4:
                alist_url = str(aliststrm_conf).split("#")[0]
                alist_user = str(aliststrm_conf).split("#")[1]
                alist_password = str(aliststrm_conf).split("#")[2]
                local_path = str(aliststrm_conf).split("#")[3]
                root_path = str(aliststrm_conf).split("#")[4]
            else:
                logger.error(f"{aliststrm_conf} 格式错误")
                continue

            # 生成strm文件
            self.__generate_strm(alist_url, alist_user, alist_password, local_path, root_path)

        logger.info("云盘strm生成任务完成")
        if event:
            self.post_message(channel=event.event_data.get("channel"),
                              title="云盘strm生成任务完成！",
                              userid=event.event_data.get("user"))
    def __generate_strm(self, webdav_url:str, webdav_account:str, webdav_password:str, local_path:str, root_path:str):
        """
        生成Strm文件
        """
        pass

    def __update_config(self):
        """
        更新配置
        """
        self.update_config({
            "enabled": self._enabled,
            "onlyonce": self._onlyonce,
            "cron": self._cron,
            "download_subtitle": self._download_subtitle,
            "liststrm_confs": "\n".join(self._liststrm_confs) if self._liststrm_confs else ""
        })

    def get_state(self) -> bool:
        return self._enabled

    @staticmethod
    def get_command() -> List[Dict[str, Any]]:
        """
        定义远程控制命令
        :return: 命令关键字、事件、描述、附带数据
        """
        return [{
            "cmd": "/alist_strm",
            "event": EventType.PluginAction,
            "desc": "Alist云盘Strm文件生成",
            "category": "",
            "data": {
                "action": "alist_strm"
            }
        }]

    def get_service(self) -> List[Dict[str, Any]]:
        """
        注册插件公共服务
        [{
            "id": "服务ID",
            "name": "服务名称",
            "trigger": "触发器：cron/interval/date/CronTrigger.from_crontab()",
            "func": self.xxx,
            "kwargs": {} # 定时器参数
        }]
        """
        if self._enabled and self._cron:
            return [{
                "id": "AlistStrm",
                "name": "Alist云盘strm文件生成服务",
                "trigger": CronTrigger.from_crontab(self._cron),
                "func": self.scan,
                "kwargs": {}
            }]
        return []

    def get_api(self) -> List[Dict[str, Any]]:
        pass

    def get_form(self) -> Tuple[List[dict], Dict[str, Any]]:
        """
        拼装插件配置页面，需要返回两块数据：1、页面配置；2、数据结构
        """
        return [
            {
                'component': 'VForm',
                'content': [
                    {
                        'component': 'VRow',
                        'content': [
                            {
                                'component': 'VCol',
                                'props': {
                                    'cols': 12,
                                    'md': 4
                                },
                                'content': [
                                    {
                                        'component': 'VSwitch',
                                        'props': {
                                            'model': 'enabled',
                                            'label': '启用插件',
                                        }
                                    }
                                ]
                            },
                            {
                                'component': 'VCol',
                                'props': {
                                    'cols': 12,
                                    'md': 4
                                },
                                'content': [
                                    {
                                        'component': 'VSwitch',
                                        'props': {
                                            'model': 'onlyonce',
                                            'label': '立即运行一次',
                                        }
                                    }
                                ]
                            },
                            {
                                'component': 'VCol',
                                'props': {
                                    'cols': 12,
                                    'md': 4
                                },
                                'content': [
                                    {
                                        'component': 'VSwitch',
                                        'props': {
                                            'model': 'download_subtitle',
                                            'label': '下载字幕',
                                        }
                                    }
                                ]
                            }
                        ]
                    },
                    {
                        'component': 'VRow',
                        'content': [
                            {
                                'component': 'VCol',
                                'props': {
                                    'cols': 12,
                                    'md': 6
                                },
                                'content': [
                                    {
                                        'component': 'VTextField',
                                        'props': {
                                            'model': 'cron',
                                            'label': '生成周期',
                                            'placeholder': '0 0 * * *'
                                        }
                                    }
                                ]
                            }
                        ]
                    },
                    {
                        'component': 'VRow',
                        'content': [
                            {
                                'component': 'VCol',
                                'props': {
                                    'cols': 12
                                },
                                'content': [
                                    {
                                        'component': 'VTextarea',
                                        'props': {
                                            'model': 'liststrm_confs',
                                            'label': 'aliststrm配置文件',
                                            'rows': 5,
                                            'placeholder': 'alist服务器地址#账号#密码#本地目录#alist开始目录'
                                        }
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ], {
            "enabled": False,
            "cron": "",
            "onlyonce": False,
            "download_subtitle": False,
            "liststrm_confs": ""
        }

    def get_page(self) -> List[dict]:
        pass

    def stop_service(self):
        """
        退出插件
        """
        try:
            if self._scheduler:
                self._scheduler.remove_all_jobs()
                if self._scheduler.running:
                    self._scheduler.shutdown()
                self._scheduler = None
        except Exception as e:
            logger.error(f"退出插件失败：{str(e)}")
