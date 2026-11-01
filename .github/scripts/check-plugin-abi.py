"""Inspect final APK DEX definitions without executing application or plugin code."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile

REQUIRED = [
    'okhttp3.OkHttpClient', 'okhttp3.OkHttpClient$Builder',
    'okhttp3.Request', 'okhttp3.Request$Builder',
    'okhttp3.Response', 'okhttp3.Response$Builder',
    'okhttp3.HttpUrl', 'okhttp3.Headers', 'okhttp3.Headers$Builder',
    'okhttp3.RequestBody', 'okhttp3.ResponseBody', 'okhttp3.MediaType',
    'okhttp3.Call', 'okhttp3.Callback', 'okhttp3.Interceptor',
    'okhttp3.WebSocket', 'okhttp3.WebSocketListener',
    'okio.Buffer', 'okio.ByteString', 'okio.BufferedSource', 'okio.BufferedSink',
    'okio.Source', 'okio.Sink', 'okio.Okio',
    'com.google.gson.Gson', 'com.google.gson.GsonBuilder',
    'com.google.gson.JsonObject', 'com.google.gson.JsonArray',
    'com.google.gson.reflect.TypeToken',
    'org.jsoup.Jsoup', 'org.jsoup.nodes.Document', 'org.jsoup.nodes.Element',
    'org.jsoup.select.Elements', 'kotlin.jvm.internal.Intrinsics', 'kotlin.Unit',
    'com.github.catvod.crawler.Spider',
]


def class_definitions(data):
    if not data.startswith(b'dex\n') or len(data) < 112:
        raise ValueError('Unsupported DEX header')
    strings_count, strings_offset = struct.unpack_from('<II', data, 56)
    types_count, types_offset = struct.unpack_from('<II', data, 64)
    classes_count, classes_offset = struct.unpack_from('<II', data, 96)
    for count, offset, width in [(strings_count, strings_offset, 4),
                                 (types_count, types_offset, 4),
                                 (classes_count, classes_offset, 32)]:
        if offset + count * width > len(data):
            raise ValueError('DEX table extends outside file')
    names = set()
    for index in range(classes_count):
        type_id = struct.unpack_from('<I', data, classes_offset + index * 32)[0]
        if type_id >= types_count:
            raise ValueError('Invalid class type ID')
        string_id = struct.unpack_from('<I', data, types_offset + type_id * 4)[0]
        if string_id >= strings_count:
            raise ValueError('Invalid descriptor string ID')
        offset = struct.unpack_from('<I', data, strings_offset + string_id * 4)[0]
        for _ in range(5):
            byte = data[offset]
            offset += 1
            if byte < 128:
                break
        else:
            raise ValueError('Invalid descriptor length')
        end = data.index(b'\0', offset)
        descriptor = data[offset:end].decode('utf-8', errors='replace')
        if descriptor.startswith('L') and descriptor.endswith(';'):
            names.add(descriptor[1:-1].replace('/', '.'))
    return names


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    definitions = set()
    dex_files = []
    with zipfile.ZipFile(args.apk) as apk:
        for entry in apk.infolist():
            if entry.filename.startswith('classes') and entry.filename.endswith('.dex') and '/' not in entry.filename:
                if entry.file_size > 128 * 1024 * 1024:
                    raise ValueError('DEX exceeds inspection limit')
                definitions.update(class_definitions(apk.read(entry)))
                dex_files.append(entry.filename)
    missing = [name for name in REQUIRED if name not in definitions]
    with args.apk.open('rb') as handle:
        digest = hashlib.file_digest(handle, 'sha256').hexdigest()
    report = {'apk': args.apk.name, 'sha256': digest, 'dexFiles': dex_files,
              'definedClasses': len(definitions), 'requiredClasses': len(REQUIRED),
              'missing': missing, 'passed': bool(dex_files) and not missing}
    output = json.dumps(report, ensure_ascii=False, indent=2)
    print(output)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output + '\n', encoding='utf-8')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
