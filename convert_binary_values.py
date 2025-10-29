#!/usr/bin/env python3
r"""Convert binary strings with '\xNN...' to 0xNN... hex literals in SQL"""

import sys
import re

def convert_to_hex(match):
    r"""Convert quoted string with \xNN sequences and/or binary data to 0xNN..."""
    quoted_value = match.group(0)  # Includes quotes
    value = match.group(1)  # Content without quotes

    # Check if contains \x sequences or non-printable characters
    if '\\x' not in value and all(ord(c) >= 32 and ord(c) < 127 or c in '\t\n\r' for c in value):
        return quoted_value  # Regular string, keep as is

    # Convert entire value to hex
    hex_result = []
    i = 0
    while i < len(value):
        if i + 3 < len(value) and value[i:i+2] == '\\x':
            # Extract hex digits
            hex_chars = value[i+2:i+4]
            if all(c in '0123456789abcdefABCDEF' for c in hex_chars):
                hex_result.append(hex_chars)
                i += 4
                continue
        # Convert character to hex
        hex_result.append(format(ord(value[i]), '02x'))
        i += 1

    if hex_result:
        # Use X'...' format for binary data (MySQL hex string literal)
        return "X'" + ''.join(hex_result).upper() + "'"
    return quoted_value

# Read as binary
for line_bytes in sys.stdin.buffer:
    line = line_bytes.decode('latin-1')  # Preserve all bytes

    # Find quoted strings and convert those with binary data
    line = re.sub(r"'([^']*(?:\\'[^']*)*)'", convert_to_hex, line)

    sys.stdout.buffer.write(line.encode('latin-1'))
