#!/usr/bin/env python3
"""Pack GCC-generated firmware.bin and 784 image bytes into CPU BRAM COE.
This script does not generate or encode instructions.
Python standard library; Pillow needed only for PNG/JPG inputs.
"""
import argparse, json, re, struct
from pathlib import Path

RAM_BYTES = 65536
IMAGE_ADDR = 0x1000
RESULT_ADDR, DONE_ADDR = 0x2000, 0x2004
MLP_BASE = 0x10000000
MAGIC = 0x600D0001

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
    else:
        from PIL import Image
        im=Image.open(p).convert('L')
        if im.size!=(28,28): raise ValueError('Image must be exactly 28x28; no implicit resize/invert.')
        data=im.tobytes()
    if len(data)!=784: raise ValueError('Expected exactly 784 unsigned pixel bytes')
    return data

def reference(pixels, words):
    """Intended signed Q15/Q14 algorithm; independent of DUT FSM.
    Deliberately does not emulate unsigned-expression bugs in RTL.
    """
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
    ap.add_argument('--image',help='28x28 grayscale image, 784-byte .bin, or decimal .txt/.csv')
    ap.add_argument('--weights',required=True,help='Existing packed weight COE; never modified')
    ap.add_argument('--out',default='generated')
    args=ap.parse_args(); out=Path(args.out); out.mkdir(parents=True,exist_ok=True)
    pixels=image_bytes(args.image); weights=read_coe(args.weights)
    if len(weights)<25482 or any(w<0 or w>0xffffffff for w in weights):
        raise ValueError('Weight memory requires at least 25482 unsigned 32-bit words')
    firmware=Path(args.firmware).read_bytes()
    if not firmware or len(firmware)>IMAGE_ADDR:
        raise ValueError('Firmware must be nonempty and fit below image address 0x1000')
    ram=bytearray(RAM_BYTES)
    ram[:len(firmware)]=firmware
    ram[IMAGE_ADDR:IMAGE_ADDR+784]=pixels
    words=struct.unpack('<16384I',ram)
    (out/'bram_cpu.coe').write_text('memory_initialization_radix=16;\nmemory_initialization_vector=\n'+',\n'.join(f'{w:08X}' for w in words)+';\n')
    write_mem(out/'bram_cpu.mem',words); write_mem(out/'image.mem',pixels,2)
    write_mem(out/'weights.mem',weights[:25482])
    h,logits,result=reference(pixels,weights)
    write_mem(out/'expected_hidden.mem',h); write_mem(out/'expected_logits.mem',logits)
    write_mem(out/'expected_result.mem',[result])
    (out/'manifest.json').write_text(json.dumps(dict(firmware=str(args.firmware),firmware_bytes=len(firmware),image=args.image or 'synthetic transport/arithmetic test; not an MNIST label',ram_bytes=RAM_BYTES,image_address=IMAGE_ADDR,result_address=RESULT_ADDR,done_address=DONE_ADDR,mmio_base=MLP_BASE,expected_class=result,logits=logits),indent=2))
    print(f'Created {out}/bram_cpu.coe (16384 x 32 bits), reference class = {result}')
if __name__=='__main__': main()
