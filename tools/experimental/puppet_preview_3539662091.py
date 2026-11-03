#!/usr/bin/env python3
"""实验：绘制壁纸 3539662091 的 puppet 静态姿态，不适用于其他场景。

用法：python3 puppet_preview_3539662091.py <puppet.mdl> <sheet.png> <输出.png>
需要 Pillow 和 NumPy。场景尺寸、坐标和缩放取自该壁纸的 scene.json。
"""
import struct,sys,math
from PIL import Image,ImageDraw
import numpy as np
if len(sys.argv) != 4:
    sys.exit(__doc__)
mdl,texture,out=sys.argv[1:]
b=open(mdl,'rb').read(); assert b[:8] == b'MDLV0023'
o=b.index(b'\0',21)+29; tag,n=struct.unpack_from('<II',b,o); assert tag==0x180000f and n%80==0
v=o+8; count=n//80; io=v+n; size=struct.unpack_from('<I',b,io)[0]; assert size%6==0 and io+4+size<=len(b)
vertices=[]
for i in range(count):
 p=v+i*80; x,y,z=struct.unpack_from('<3f',b,p); u,w=struct.unpack_from('<2f',b,p+72); vertices.append((x,y,u,w))
indices=struct.iter_unpack('<HHH',b[io+4:io+4+size]); im=Image.open(texture).convert('RGBA'); W,H=1616,974
canvas=Image.new('RGBA',(W,H),(179,179,179,255)); done=0
for abc in indices:
 if max(abc)>=count: raise ValueError('invalid index')
 vs=[vertices[i] for i in abc]
 dst=[((407.60498 + .39787*x)*2,(487-228.23868-.39787*y)*2) for x,y,u,w in vs]
 src=[(u*im.width,w*im.height) for x,y,u,w in vs]
 l=max(0,math.floor(min(x for x,y in dst))); t=max(0,math.floor(min(y for x,y in dst))); r=min(W,math.ceil(max(x for x,y in dst))+1); bot=min(H,math.ceil(max(y for x,y in dst))+1)
 if r<=l or bot<=t: continue
 matrix=np.array([[x,y,1] for x,y in dst]); det=np.linalg.det(matrix)
 if abs(det)<1e-5: continue
 abcuv=np.linalg.solve(matrix,np.array(src)); a,b0=abcuv[:,0],abcuv[:,1]
 coeff=(a[0],a[1],a[0]*l+a[1]*t+a[2],b0[0],b0[1],b0[0]*l+b0[1]*t+b0[2])
 tile=im.transform((r-l,bot-t),Image.Transform.AFFINE,coeff,resample=Image.Resampling.BILINEAR)
 mask=Image.new('L',(r-l,bot-t),0);ImageDraw.Draw(mask).polygon([(x-l,y-t) for x,y in dst],fill=255)
 tile.putalpha(Image.composite(tile.getchannel('A'),Image.new('L',tile.size,0),mask)); canvas.alpha_composite(tile,(l,t));done+=1
canvas.save(out);print('triangles',done,'output',out)
