#!/usr/bin/env python3
"""Synthetic 2D scene: blue background, two puppet meshes, rotated translucent layer."""
import importlib.util,json,struct,sys,zlib
from pathlib import Path
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('pkg',Path(__file__).with_name('make_test_pkg.py'))
pkg=importlib.util.module_from_spec(spec);spec.loader.exec_module(pkg)

def png(color):
 def chunk(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',8,8,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes(color)*8)*8))+chunk(b'IEND',b'')

def mesh(name,w,h):
 vertices=[]
 for x,y,u,v in [(-w/2,-h/2,0,1),(w/2,-h/2,1,1),(w/2,h/2,1,0),(-w/2,h/2,0,0)]:
  row=bytearray(80);struct.pack_into('<3f',row,0,x,y,0);struct.pack_into('<2f',row,72,u,v);vertices.append(row)
 body=b''.join(vertices);indices=struct.pack('<6H',0,1,2,0,2,3)
 return b'MDLV0023'+bytes(13)+f'materials/{name}.json'.encode()+b'\0'+bytes(28)+struct.pack('<II',0x0180000f,len(body))+body+struct.pack('<I',len(indices))+indices

def generate(root):
 root=Path(root);entries=[]
 def write(path,data):
  if not isinstance(data,bytes):data=json.dumps(data).encode()
  target=root/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);entries.append((path,data))
 objects=[]
 for name,color,origin,size,puppet,angle,alpha in [('background',(0,0,255,255),'50 40 0','100 80',False,0,1),('red',(255,0,0,255),'40 40 0','40 40',True,0,1),('green',(0,255,0,255),'60 40 0','20 40',True,90,.5)]:
  descriptor={'material':f'materials/{name}.json'}
  if puppet:
   descriptor['puppet']=f'models/{name}.mdl';w,h=map(int,size.split());write(descriptor['puppet'],mesh(name,w,h))
  write(f'models/{name}.json',descriptor)
  write(f'materials/{name}.json',{'passes':[{'shader':'genericimage4','blending':'translucent','textures':[name]}]})
  write(f'materials/{name}.png',png(color))
  objects.append({'image':f'models/{name}.json','origin':origin,'size':size,'angles':f'0 0 {angle}','alpha':alpha})
 objects.append({'image':'models/does-not-exist.json','visible':False})
 write('scene.json',{'general':{'orthogonalprojection':{'width':100,'height':80},'clearcolor':'0 0 0'},'objects':objects})
 (root/'scene.pkg').write_bytes(pkg.build_pkg(entries))
 (root/'project.json').write_text(json.dumps({'title':'合成多图层场景','type':'scene'}))
 return root
if __name__=='__main__':print(generate(sys.argv[1]))
