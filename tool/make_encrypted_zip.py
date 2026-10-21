"""生成一个**真实**的 ZipCrypto 加密 zip，用于 inkScroll 的真机测试。

为什么用 Python 自己拼 zip：环境里没有 7-Zip / WinRAR，而 Python 标准库
`zipfile` **只能解密、不能加密** ZipCrypto。所以要自己按 PKWARE 规范
写出加密 zip —— 好处是这份加密实现和 Dart 侧的解密实现**互相独立**，
交叉验证才有意义（自己写的加密配自己写的解密，等于自证）。

生成后用 `zipfile` 带密码读回来校验，确保它是一个标准工具可识别的
加密压缩包。
"""

import io
import os
import struct
import time
import zipfile
import zlib

from PIL import Image, ImageDraw

PASSWORD = b"manga123"
OUT = os.path.join(os.environ["TEMP"], "enczip")
os.makedirs(OUT, exist_ok=True)


# ── ZipCrypto ────────────────────────────────────────────────────────────
class ZipCrypto:
    def __init__(self, password: bytes):
        self.k0 = 0x12345678
        self.k1 = 0x23456789
        self.k2 = 0x34567890
        for b in password:
            self._update(b)

    @staticmethod
    def _crc32(crc, b):
        # 单字节 CRC32（与标准表等价）
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
        return crc & 0xFFFFFFFF

    def _update(self, b):
        self.k0 = self._crc32(self.k0, b)
        self.k1 = ((self.k1 + (self.k0 & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        self.k2 = self._crc32(self.k2, (self.k1 >> 24) & 0xFF)

    def _stream(self):
        temp = (self.k2 | 2) & 0xFFFF
        return ((temp * (temp ^ 1)) >> 8) & 0xFF

    def encrypt(self, data: bytes) -> bytes:
        out = bytearray(len(data))
        for i, p in enumerate(data):
            out[i] = p ^ self._stream()
            self._update(p)
        return bytes(out)


def build_encrypted_zip(entries, password: bytes) -> bytes:
    """entries: [(name, data)]；全部用 DEFLATE + ZipCrypto 加密。"""
    local_parts = []
    central_parts = []
    offset = 0
    dos_time = 0x6000  # 任意非零时间
    dos_date = 0x5A21

    for name, raw in entries:
        name_b = name.encode("utf-8")
        comp = zlib.compressobj(9, zlib.DEFLATED, -15)
        compressed = comp.compress(raw) + comp.flush()
        crc = zlib.crc32(raw) & 0xFFFFFFFF

        # 12 字节加密头：最后两字节按传统做法放 CRC 高位
        # （WinZip 用 CRC 高 16 位；部分实现用 DOS 时间 —— 两者都兼容）
        header = bytes(11) + bytes([(crc >> 24) & 0xFF])
        crypto = ZipCrypto(password)
        encrypted = crypto.encrypt(header + compressed)
        csize = len(encrypted)
        usize = len(raw)

        # 通用标志：bit0 = 加密，bit3 = 有数据描述符（这里不用）
        flags = 0x0001
        method = 8

        local = struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50, 20, flags, method, dos_time, dos_date,
            crc, csize, usize, len(name_b), 0,
        ) + name_b + encrypted
        local_parts.append(local)

        central = struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50, 20, 20, flags, method, dos_time, dos_date,
            crc, csize, usize, len(name_b), 0, 0, 0, 0,
            0, offset,
        ) + name_b
        central_parts.append(central)
        offset += len(local)

    body = b"".join(local_parts)
    cd = b"".join(central_parts)
    eocd = struct.pack(
        "<IHHHHIIH",
        0x06054B50, 0, 0, len(entries), len(entries), len(cd), len(body), 0,
    )
    return body + cd + eocd


# ── 造 3 张测试图 ────────────────────────────────────────────────────────
def make_page(idx, color):
    img = Image.new("RGB", (720, 1080), color)
    d = ImageDraw.Draw(img)
    d.rectangle([80, 200, 640, 320], fill="white")
    d.text((110, 240), f"Encrypted Zip - Page {idx}/3", fill="black")
    d.text((110, 420), "If you can read this, ZipCrypto works.", fill="black")
    d.ellipse([120, 600, 420, 900], fill="#3355dd")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


entries = [(f"page{i}.png", make_page(i, c)) for i, c in
           [(1, "#ffd166"), (2, "#06d6a0"), (3, "#ef476f")]]

zip_bytes = build_encrypted_zip(entries, PASSWORD)
zip_path = os.path.join(OUT, "encrypted-comic.zip")
with open(zip_path, "wb") as f:
    f.write(zip_bytes)

print(f"生成: {zip_path}  ({len(zip_bytes)} 字节)")

# ── 用标准库交叉验证：能否带密码读回 ─────────────────────────────────────
with zipfile.ZipFile(zip_path) as zf:
    names = zf.namelist()
    print("条目:", names)
    ok = True
    for i, (name, raw) in enumerate(entries, 1):
        got = zf.read(name, pwd=PASSWORD)
        same = got == raw
        ok = ok and same
        print(f"  {name}: 解密后 {len(got)} 字节，与原文一致={same}")
    # 错误密码必须失败
    try:
        zf.read(names[0], pwd=b"wrong-pass")
        print("  ✗ 错误密码竟然成功了？")
        ok = False
    except Exception as e:
        print(f"  ✓ 错误密码被拒绝: {type(e).__name__}")

print("交叉验证:", "通过" if ok else "失败")
