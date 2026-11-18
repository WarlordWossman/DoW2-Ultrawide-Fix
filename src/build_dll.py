"""Wrap a flat code/data blob into a minimal 32-bit PE DLL.

usage: build_dll.py <section.bin> <out.asi> <syms.txt from `nm`>

Layout: headers at file 0x000-0x3FF, one RWX section ".text" at RVA 0x1000 / file 0x400.
Entry point = symbol `dllmain`; import, IAT and base-relocation directories point at the
symbols `import_dir`, `iat`, `reloc_block` inside the blob. DYNAMIC_BASE|NX_COMPAT; the code
is position-independent so no relocation entries are needed. The PE checksum is filled in.
"""
import struct,sys
sec=open(sys.argv[1],'rb').read(); out=sys.argv[2]
sym={k:int(v,16) for v,k in (l.split()[0::2] for l in open(sys.argv[3]))}
FA,SA,RVA=0x200,0x1000,0x1000
raw=sec+b'\0'*((-len(sec))%FA)
hdr=bytearray(0x400)
hdr[0:2]=b'MZ'; struct.pack_into('<I',hdr,0x3c,0x80)
pe=0x80
hdr[pe:pe+4]=b'PE\0\0'
# COFF header
struct.pack_into('<HHIIIHH',hdr,pe+4,0x14c,1,0x67000000,0,0,0xE0,0x2102)
o=pe+24
struct.pack_into('<HBBIII',hdr,o,0x10b,9,0,len(raw),0,0)           # magic, linker, SizeOfCode, InitData, UninitData
struct.pack_into('<III',hdr,o+16,RVA+sym['dllmain'],RVA,RVA)        # EntryPoint, BaseOfCode, BaseOfData
struct.pack_into('<III',hdr,o+28,0x10000000,SA,FA)                  # ImageBase, SectionAlignment, FileAlignment
struct.pack_into('<HHHHHH',hdr,o+40,5,1,0,0,5,1)                    # OS 5.1, image 0.0, subsystem 5.1
struct.pack_into('<IIII',hdr,o+52,0,RVA+SA,0x400,0)                 # Win32Ver, SizeOfImage, SizeOfHeaders, CheckSum
struct.pack_into('<HH',hdr,o+68,2,0x0140)                           # GUI, DllCharacteristics: DYNAMIC_BASE|NX_COMPAT
struct.pack_into('<IIIIII',hdr,o+72,0x100000,0x1000,0x100000,0x1000,0,16)
dd=o+96
def setdd(i,rva,size): struct.pack_into('<II',hdr,dd+8*i,rva,size)
setdd(1,RVA+sym['import_dir'],40)
setdd(5,RVA+sym['reloc_block'],8)
setdd(12,RVA+sym['iat'],12)
sh=o+0xE0
hdr[sh:sh+8]=b'.text\0\0\0'
struct.pack_into('<IIIIIIHHI',hdr,sh+8,len(sec),RVA,len(raw),0x400,0,0,0,0,0xE0000020)
# checksum
img=bytearray(hdr+raw)
ck=o+64; s=0
for i in range(0,len(img),2):
    s+=img[i]|(img[i+1]<<8); s=(s&0xffff)+(s>>16)
s=(s&0xffff)+(s>>16)+len(img)
struct.pack_into('<I',img,ck,s)
open(out,'wb').write(img); print('wrote',out,len(img))
