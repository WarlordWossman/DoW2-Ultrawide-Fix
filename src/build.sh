#!/bin/sh
# Reproduces bin/DoW2_MainMenuUltrawide.asi byte-for-byte (needs GNU binutils + python3).
set -e
cd "$(dirname "$0")"
as --32 -o sec.o DoW2_MainMenuUltrawide.s
objcopy -O binary -j .text sec.o sec.bin
nm sec.o > syms.txt
python3 build_dll.py sec.bin DoW2_MainMenuUltrawide.asi syms.txt
sha256sum DoW2_MainMenuUltrawide.asi
rm -f sec.o sec.bin syms.txt
