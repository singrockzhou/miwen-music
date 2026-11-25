# -*- coding: utf-8 -*-
"""
生成 SACD ISO 文本解码所需的字符集转换表（任务 35：ISO 标题编码 GB2312/Shift-JIS）。

输出 entry/src/main/cpp/types/charset_tables.h：
  - kSjisPairs[]  : Shift-JIS 双字节 → Unicode 码点，按 Shift-JIS 码位升序（二分查找）
  - kGbkPairs[]   : GB2312 双字节 → Unicode 码点，按 GB 码位升序
表由 Python codecs（权威映射）生成，与运行时探测逻辑配套：
探测顺序 UTF-16BOM > ASCII > 合法UTF-8 > Shift-JIS(严格+含双字节) > GB2312(严格) > Latin-1。
"""
import codecs
import os

def utf8_of(cp):
    return cp

def gen_sjis():
    pairs = []
    # Shift-JIS 双字节区：lead 0x81-0x9F, 0xE0-0xEF；trail 0x40-0xFC（除 0x7F）
    leads = list(range(0x81, 0xA0)) + list(range(0xE0, 0xF0))
    for lead in leads:
        for trail in range(0x40, 0xFD):
            if trail == 0x7F:
                continue
            b = bytes([lead, trail])
            try:
                s = b.decode('cp932')
            except UnicodeDecodeError:
                continue
            if len(s) != 1:
                continue
            cp = ord(s)
            # 映射到 Windows 特殊字符的（NEC/IBM 扩展区）保留——真机 ISO 里罕见但合法
            pairs.append((lead, trail, cp))
    pairs.sort()
    return pairs

def gen_gbk2312():
    # 严格 GB2312：lead 0xA1-0xF7，trail 0xA1-0xFE
    pairs = []
    for lead in range(0xA1, 0xF8):
        for trail in range(0xA1, 0xFF):
            b = bytes([lead, trail])
            try:
                s = b.decode('gb2312')
            except UnicodeDecodeError:
                continue
            if len(s) != 1:
                continue
            pairs.append((lead, trail, ord(s)))
    pairs.sort()
    return pairs

def emit(pairs, name, comment):
    lines = []
    lines.append(f'// {comment}')
    lines.append(f'static const uint16_t {name}[] = {{')
    row = []
    for lead, trail, cp in pairs:
        row.append('0x%02X%02X,0x%04X' % (lead, trail, cp))
        if len(row) == 4:
            lines.append('    ' + ', '.join(row) + ',')
            row = []
    if row:
        lines.append('    ' + ', '.join(row) + ',')
    lines.append('};')
    lines.append(f'static constexpr int {name}_N = {len(pairs)};')
    return '\n'.join(lines)

sjis = gen_sjis()
gb = gen_gbk2312()

header = '''/**
 * charset_tables.h —— SACD ISO 文本字符集转换表（由 tools/dsd_material/gen_charset_tables.py 生成，勿手改）
 *
 * 每项两个 uint16：{ShiftJIS码位LE拼接, Unicode码点}，按码位升序，运行时二分。
 * 覆盖 Shift-JIS(cp932) 全双字节区与 GB2312 全双字节区。
 */
#ifndef MIWEN_CHARSET_TABLES_H
#define MIWEN_CHARSET_TABLES_H

#include <cstdint>

''' + emit(sjis, 'kSjisPairs', f'Shift-JIS 双字节映射（{len(sjis)} 项）') + '\n\n' + \
    emit(gb, 'kGbkPairs', f'GB2312 双字节映射（{len(gb)} 项）') + '''

#endif  // MIWEN_CHARSET_TABLES_H
'''

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
out = os.path.join(root, 'entry', 'src', 'main', 'cpp', 'types', 'charset_tables.h')
with open(out, 'w', encoding='utf-8', newline='\n') as f:
    f.write(header)
print('sjis pairs:', len(sjis), 'gb pairs:', len(gb), '->', out)
