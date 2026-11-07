#!/usr/bin/env python3
"""Pack GCC-generated firmware_multi3.bin and 3x 784 image bytes into CPU BRAM COE/MIF."""
import argparse, json, re, struct
from pathlib import Path

RAM_BYTES = 65536
IMAGE_ADDR = 0x1000
IMAGE_STRIDE = 0x0400
RESULT_ADDR, DONE_ADDR = 0x2000, 0x200C
MLP_BASE = 0x10000000
MAGIC = 0x600D0003

def signed(v, bits):
    v &= (1 << bits)-1
    return v-(1 << bits) if v & (1 << (bits-1)) else v

def read_coe(path):
    txt = re.sub(r';[^\n]*$', ';', Path(path).read_text(), flags=re.M)
    radix = int(re.search(r'memory_initialization_radix\s*=\s*(\d+)', txt, re.I)[1])
    body = re.search(r'memory_initialization_vector\s*=\s*(.*?);', txt, re.I|re.S)[1]
    return [int(x.strip(), radix) for x in body.split(',') if x.strip()]

def image_bytes(path):
    if not path: return bytes((i*37 + i//28*11) % 256 for i in range(784))
    p=Path(path)
    if p.suffix.lower()=='.bin': data=p.read_bytes()
    elif p.suffix.lower() in ('.txt','.csv'):
        values=[int(x,0) for x in re.split(r'[,\s]+',p.read_text().strip())]
        data=bytes(values)
    elif p.with_suffix('.bin').exists():
        data=p.with_suffix('.bin').read_bytes()
    else:
        from PIL import Image
        im=Image.open(p).convert('L')
        if im.size!=(28,28): raise ValueError('Image must be exactly 28x28; no implicit resize/invert.')
        data=im.tobytes()
    if len(data)!=784: raise ValueError('Expected exactly 784 unsigned pixel bytes')
    return data

def reference(pixels, words):
    def w(addr,high): return signed(words[addr]>>(16*high),16)
    x=[(p*32768+127)//255 for p in pixels]
    h=[]
    for j in range(64):
        a=sum(x[i]*w((i//2)*64+j,i%2) for i in range(784))
        a=signed(a+signed(words[25088+j],32),44)
        h.append(signed(max(0,a)>>14,32))
    logits=[]
    for k in range(10):
        a=sum(h[j]*w(25152+(j//2)*10+k,j%2) for j in range(64))
        a=signed(a+signed(words[25472+k],32),56)
        logits.append(signed(a>>14,32))
    return h,logits,max(range(10),key=lambda k:logits[k])

def write_mem(path,words,width=8):
    path.write_text(''.join(f'{v & ((1<<(width*4))-1):0{width}x}\n' for v in words))

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--firmware',required=True,help='Raw binary produced by RISC-V objcopy')
    ap.add_argument('--image',nargs='*',help='3 28x28 grayscale images')
    ap.add_argument('--weights',required=True,help='Existing packed weight COE')
    ap.add_argument('--out',default='build_multi3')
    args=ap.parse_args(); out=Path(args.out); out.mkdir(parents=True,exist_ok=True)
    img_paths = args.image if args.image else [
        '../image/img_106.jpg',
        '../image/img_107.jpg',
        '../image/img_114.jpg'
    ]
    if len(img_paths) != 3:
        raise ValueError(f'Expected 3 images, got {len(img_paths)}')
    pixels_list = [image_bytes(p) for p in img_paths]
    weights=read_coe(args.weights)
    firmware=Path(args.firmware).read_bytes()
    if not firmware or len(firmware)>IMAGE_ADDR:
        raise ValueError('Firmware must be nonempty and fit below image address 0x1000')
    ram=bytearray(RAM_BYTES)
    ram[:len(firmware)]=firmware
    for idx, px in enumerate(pixels_list):
        base = IMAGE_ADDR + idx * IMAGE_STRIDE
        ram[base:base+784] = px
    words=struct.unpack('<16384I',ram)
    (out/'bram_cpu_multi3.coe').write_text('memory_initialization_radix=16;\nmemory_initialization_vector=\n'+',\n'.join(f'{w:08X}' for w in words)+';\n')
    (out/'final_wrapper_blk_mem_gen_0_0.mif').write_text(''.join(f'{w:032b}\n' for w in words))
    write_mem(out/'bram_cpu_multi3.mem',words)
    all_results = []
    all_logits = []
    for idx, px in enumerate(pixels_list):
        _,logits,result=reference(px,weights)
        all_logits.append(logits)
        all_results.append(result)
    (out/'manifest_multi3.json').write_text(json.dumps(dict(
        firmware=str(args.firmware),
        images=[str(p) for p in img_paths],
        image_addresses=[IMAGE_ADDR + i * IMAGE_STRIDE for i in range(3)],
        result_addresses=[RESULT_ADDR + i * 4 for i in range(3)],
        done_address=DONE_ADDR,
        expected_classes=all_results,
        logits_per_image=all_logits
    ),indent=2))
    print(f'Created {out}/bram_cpu_multi3.coe (16384 x 32 bits), reference classes = {all_results}')

if __name__=='__main__': main()
