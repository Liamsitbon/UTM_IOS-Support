#!/usr/bin/env python3
"""Check the exact patched ES1 transfer code against padded guest byte layouts."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="utm-es1-transfer-") as directory:
    root = Path(directory)
    subprocess.run(["git", "init", "-q", root], check=True)
    subprocess.run(["git", "apply", "--include=hw/arm/gles-ios-transfer.h",
                    repo / "patches/lighttouch/qemu-ios-apple-gles.patch"], cwd=root, check=True)
    source = root / "transfer.c"
    source.write_text('''
#include <assert.h>
#include "gles-ios-transfer.h"
int main(void) {
    /* Two RGBA texels per row, four bytes of guest-only row padding. */
    uint8_t rows[] = {1,2,3,4,5,6,7,8,99,99,99,99,9,10,11,12,13,14,15,16};
    const uint8_t expected[] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
    ltm_ios_pack_rows(rows,2,2,4,12);
    assert(memcmp(rows,expected,sizeof(expected))==0);
    ltm_ios_reverse_words(rows,2,2,8);
    const uint8_t reversed[] = {4,3,2,1,8,7,6,5,12,11,10,9,16,15,14,13};
    assert(memcmp(rows,reversed,sizeof(reversed))==0);
    /* Guest readback preserves padding and reverses only texels, not padding. */
    uint8_t padded[] = {1,2,3,4,77,77,77,77,5,6,7,8};
    const uint8_t padded_expected[] = {4,3,2,1,77,77,77,77,8,7,6,5};
    ltm_ios_reverse_words(padded,1,2,8);
    assert(memcmp(padded,padded_expected,sizeof(padded))==0);
    ltm_ios_pack_rows(rows,0,0,4,0);
    return 0;
}
''')
    binary = root / "transfer"
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                    "-I" + str(root / "hw/arm"), source, "-o", binary], check=True)
    subprocess.run([binary], check=True)
print("ES1 transfer layout and bounds checks passed")
