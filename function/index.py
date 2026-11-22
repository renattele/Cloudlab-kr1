"""Функция архивирования: скачивает файл по URL, упаковывает в ZIP,
кладёт в Object Storage под ключом <uuid_v7>.zip и записывает архив в YDB.
"""

import json
import os
import secrets
import shutil
import tempfile
import time
import urllib.request
import uuid
import zipfile
from pathlib import PurePosixPath

import boto3
from botocore.config import Config

# В стандартной библиотеке uuid.uuid7() появился только в Python 3.14,
# а в Cloud Functions максимальный runtime — python312;
def uuid7() -> uuid.UUID:
    """UUID версии 7 (RFC 9562): 48 бит Unix-времени в мс, версия, вариант, случайные биты."""
    ms = time.time_ns() // 1_000_000
    value = (ms & (1 << 48) - 1) << 80 | secrets.randbits(80)
    value = value & ~(0xF << 76) | 0x7 << 76  # версия 7
    value = value & ~(0x3 << 62) | 0x2 << 62  # вариант RFC 9562
    return uuid.UUID(int=value)


s3 = boto3.client(
    "s3",
    endpoint_url="https://storage.yandexcloud.net",
    config=Config(request_checksum_calculation="when_required", response_checksum_validation="when_required"),
)
table = boto3.resource(
    "dynamodb",
    endpoint_url=os.environ["DOCAPI_ENDPOINT"],
    config=Config(retries={"max_attempts": 10, "mode": "standard"}),
).Table(os.environ["TABLE"])


def archive(name: str, url: str) -> str:
    key = f"{uuid7()}.zip"
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "src"), os.path.join(tmp, "dst.zip")
        with urllib.request.urlopen(url, timeout=300) as resp, open(src, "wb") as f:
            shutil.copyfileobj(resp, f)
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(src, arcname=PurePosixPath(name).name or "file")
        s3.upload_file(dst, os.environ["BUCKET"], key, ExtraArgs={"ContentType": "application/zip"})
    table.put_item(Item={"key": key, "name": name, "url": url})
    return key


def handler(event, context):
    # Триггер передаёт ровно одно сообщение; любое исключение оставит его в очереди,
    # и после 1-й неудачной попытки оно уйдёт в очередь необработанных заданий.
    for message in event["messages"]:
        task = json.loads(message["details"]["message"]["body"])
        key = archive(task["name"], task["url"])
        print(json.dumps({"key": key, "name": task["name"], "url": task["url"]}, ensure_ascii=False))
    return {"statusCode": 200}
