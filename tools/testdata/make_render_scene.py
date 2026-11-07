#!/usr/bin/env python3
"""Synthetic 2D scene: blue background, two puppet meshes, rotated translucent layer."""
import importlib.util,json,math,struct,sys,zlib
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
  descriptor={'material':f'materials/{name}.json','cropoffset':'12 -7'}
  if puppet:
   descriptor['puppet']=f'models/{name}.mdl';w,h=map(int,size.split());write(descriptor['puppet'],mesh(name,w,h))
  write(f'models/{name}.json',descriptor)
  write(f'materials/{name}.json',{'passes':[{'shader':'genericimage4','blending':'translucent','textures':[name]}]})
  write(f'materials/{name}.png',png(color))
  # 静态 scene.json 的 angles 是弧度；表里仍按度数书写便于阅读。
  objects.append({'image':f'models/{name}.json','origin':origin,'size':size,'angles':'0 0 %.5f'%math.radians(angle),'alpha':alpha})
 for extra,color in [('white',(255,255,255,255)),('grey',(128,128,128,255))]:
  write(f'models/{extra}.json',{'material':f'materials/{extra}.json'})
  write(f'materials/{extra}.json',{'passes':[{'shader':'genericimage4','blending':'translucent','textures':[extra]}]})
  write(f'materials/{extra}.png',png(color))
 write('models/wide.json',{'material':'materials/wide.json'})
 write('materials/wide.json',{'passes':[{'shader':'genericimage4','blending':'translucent','textures':['wide']}]})
 write('models/unknown-shader.json',{'material':'materials/unknown-shader.json'})
 write_skinning_assets(root)
 write('materials/unknown-shader.json',{'passes':[{'shader':'genericimage9','blending':'translucent','textures':['white']}]})
 objects[1]['visible']={'user':'toggle','value':True}
 objects[1]['parent']=100
 objects[1]['origin']='30 40 0'
 objects[2]['scale']={'user':'scale','value':'1 1 1'}
 objects.append({'image':'models/does-not-exist.json','visible':False})
 objects.append({'image':'models/conditional-hidden.json','visible':{'user':'toggle','value':False}})
 objects.append({'image':'models/util/missing.json','visible':{'value':True,'user':{'condition':'1'}}})
 objects.append({'id':100,'origin':'10 0 0'})
 write('scene.json',{'general':{'orthogonalprojection':{'width':100,'height':80},'clearcolor':'0 0 0'},'objects':objects})
 (root/'scene.pkg').write_bytes(pkg.build_pkg(entries))
 (root/'project.json').write_text(json.dumps({'title':'合成多图层场景','type':'scene'}))
 return root

# ---------------------------------------------------------------------------
# MDLV0023 骨骼/蒙皮合成素材（供 PKD 的骨骼解析与默认姿态回归使用）
# 格式参考：公开的 MDLV 段落布局（MDLV 头 → 网格 → MDLS → MDLA）。本文件仅生成
# 测试数据，不含任何上游实现代码。
# ---------------------------------------------------------------------------

def _u32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def _i32(v): return struct.pack('<i', v)
def _f32(v): return struct.pack('<f', v)
def _cstr(s): return s.encode('utf-8') + b'\0'


def _mdlv(bones, frames, verts, indices, material='materials/skinned.json',
          bone_override_count=None, extra_padding=b'', flag_a=0):
    """构造一个最小的 MDLV0023：单网格、单材质、给定骨骼与一帧动画。"""
    import math
    mesh_flag = 0x0180000F           # pos|normal|tangent|uv|skin_blend|skin_weight
    stride = 80
    vbytes = bytearray()
    for (x, y, u, v, ids, weights) in verts:
        vbytes += struct.pack('<3f', x, y, 0.0)
        vbytes += struct.pack('<3f', 0.0, 0.0, 1.0)
        vbytes += struct.pack('<4f', 1.0, 0.0, 0.0, 1.0)
        for k in range(4):
            vbytes += _u32(ids[k] if k < len(ids) else 0)
        for k in range(4):
            vbytes += _f32(weights[k] if k < len(weights) else 0.0)
        vbytes += struct.pack('<2f', u, v)

    out = bytearray()
    out += b'MDLV0023' + b'\0'
    out += _u32(mesh_flag) + _u32(1) + _u32(1)
    out += _cstr(material)
    out += _u32(flag_a)              # flag_a
    if flag_a == 2:
        out += _u32(1)               # flag_a==2 时多一个 u32
    out += struct.pack('<6f', 0, 0, 0, 0, 0, 0)   # aabb
    out += _u32(mesh_flag) + _u32(len(vbytes))
    out += vbytes
    ibytes = b''.join(struct.pack('<3H', *tri) for tri in indices)
    out += _u32(len(ibytes)) + ibytes
    out += b'\0\0'                   # parts: unk_a=0, has_parts=0
    out += _u32(0)                   # masks: count=0

    # MDLS：end_offset 占位，稍后回填
    mdls_at = len(out)
    out += b'MDLS0004' + b'\0' + _u32(0)
    out += struct.pack('<H', bone_override_count or len(bones)) + struct.pack('<H', 0)
    for name, parent, mat in bones:
        out += _cstr(name) + _i32(1) + _u32(parent) + _u32(64)
        out += struct.pack('<16f', *mat)
        out += _cstr('{}')
    mdls_end = len(out)
    out[mdls_at + 9:mdls_at + 13] = _u32(mdls_end)

    # MDLA：单动画、单帧
    mdla_at = len(out)
    out += b'MDLA0006' + b'\0' + _u32(0)
    out += _u32(1)
    out += _i32(1) + _u32(0) + _cstr('测试动画') + _cstr('loop')
    out += _f32(30.0) + _i32(0) + _i32(0)
    out += _u32(len(frames))
    for frame in frames:
        out += _i32(0) + _u32(36)
        out += struct.pack('<9f', *frame)
    out += _u32(0)                   # trans_flag = 0
    out += b'\0'                     # blend curves absent
    out += b'\0'                     # v4 events absent
    out += struct.pack('<6f', 0, 0, 0, 0, 0, 0)   # mdla>=5 aabb
    out += b'\0'                     # mdla6 scalar curves absent
    out += _u32(0)                   # events
    mdla_end = len(out)
    out[mdla_at + 9:mdla_at + 13] = _u32(mdla_end)
    out += extra_padding
    return bytes(out)


def _identity(tx=0.0, ty=0.0):
    return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]


def write_skinning_assets(root):
    """生成骨骼/蒙皮回归所需的模型与材质（供 scene-semantics 使用）。"""
    root = Path(root)
    entries = []
    def write(path, data):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    quad_uv = [(0, 0), (1, 0), (1, 1), (0, 1)]
    indices = [(0, 1, 2), (0, 2, 3)]

    def quad(half, center=(0.0, 0.0), ids=(1, 0, 0, 0), weights=(1.0, 0.0, 0.0, 0.0)):
        x, y = center
        return [(x - half, y - half, quad_uv[0][0], quad_uv[0][1], list(ids), list(weights)),
                (x + half, y - half, quad_uv[1][0], quad_uv[1][1], list(ids), list(weights)),
                (x + half, y + half, quad_uv[2][0], quad_uv[2][1], list(ids), list(weights)),
                (x - half, y + half, quad_uv[3][0], quad_uv[3][1], list(ids), list(weights))]

    def rect(x0, y0, x1, y1, ids=(1, 0, 0, 0), weights=(1.0, 0.0, 0.0, 0.0)):
        """非对称矩形：旋转后位置会明显改变，便于像素断言。"""
        corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        return [(x, y, quad_uv[i][0], quad_uv[i][1], list(ids), list(weights))
                for i, (x, y) in enumerate(corners)]

    # 1) 正常：根骨骼在原点，子骨骼偏移 (50,0)，首帧把根旋转 90°（弧度）
    bones = [('root', 0xFFFFFFFF, _identity()), ('child', 0, _identity(50.0, 0.0))]
    frames = [[0.0, 0.0, 0.0, 0.0, 0.0, 1.5707963, 1.0, 1.0, 1.0],
              [50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]]
    write('models/skinned.json', json.dumps({'material': 'materials/skinned.json',
                                             'puppet': 'models/skinned.mdl'}).encode())
    write('models/skinned.mdl', _mdlv(bones, frames, rect(0.0, -10.0, 40.0, 10.0), indices))
    write('materials/skinned.json', json.dumps({'passes': [{'shader': 'genericimage4',
                                                            'blending': 'translucent',
                                                            'textures': ['skinned']}]}).encode())
    write('materials/skinned.png', png((255, 255, 255, 255)))

    # 1b) 首帧绕 X 轴 90°：XY 平面矩形在二维投影里塌陷成一条线
    frames_x = [[0.0, 0.0, 0.0, 1.5707963, 0.0, 0.0, 1.0, 1.0, 1.0],
                [50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]]
    write('models/skinned-xrot.json', json.dumps({'material': 'materials/skinned.json',
                                                  'puppet': 'models/skinned-xrot.mdl'}).encode())
    write('models/skinned-xrot.mdl', _mdlv(bones, frames_x, rect(0.0, -10.0, 40.0, 10.0), indices))

    # 1c) 首帧缩放 2 倍：矩形在 X/Y 两个方向放大
    frames_s = [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 2.0, 1.0],
                [50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]]
    write('models/skinned-scale.json', json.dumps({'material': 'materials/skinned.json',
                                                   'puppet': 'models/skinned-scale.mdl'}).encode())
    write('models/skinned-scale.mdl', _mdlv(bones, frames_s, rect(0.0, -10.0, 40.0, 10.0), indices))

    # 1d) flag_a == 2 分支（多一个 u32）仍应正常解析
    write('models/skinned-flaga2.json', json.dumps({'material': 'materials/skinned.json',
                                                    'puppet': 'models/skinned-flaga2.mdl'}).encode())
    write('models/skinned-flaga2.mdl', _mdlv(bones, frames, rect(0.0, -10.0, 40.0, 10.0), indices,
                                             flag_a=2))

    # 2) 权重归一：两个骨骼各 0.5，期望落在两者变换的中点
    bones2 = [('a', 0xFFFFFFFF, _identity()), ('b', 0, _identity())]
    frames2 = [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0],
               [60.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]]
    write('models/skinned-half.json', json.dumps({'material': 'materials/skinned.json',
                                                  'puppet': 'models/skinned-half.mdl'}).encode())
    # 未归一化权重 1.0/1.0：解析器应按总权重归一化后同样落在中点
    write('models/skinned-half.mdl', _mdlv(
        bones2, frames2, rect(-10.0, -10.0, 10.0, 10.0, ids=(0, 1, 0, 0), weights=(1.0, 1.0, 0.0, 0.0)),
        indices))

    # 3) 无效骨骼索引（越界）→ 必须回退原始顶点
    write('models/skinned-badbone.json', json.dumps({'material': 'materials/skinned.json',
                                                     'puppet': 'models/skinned-badbone.mdl'}).encode())
    write('models/skinned-badbone.mdl', _mdlv(
        bones, frames, rect(0.0, -10.0, 40.0, 10.0, ids=(9, 0, 0, 0), weights=(1.0, 0.0, 0.0, 0.0)), indices))

    # 4) 权重全 0 → 回退原始顶点
    write('models/skinned-zeroweight.json', json.dumps({'material': 'materials/skinned.json',
                                                        'puppet': 'models/skinned-zeroweight.mdl'}).encode())
    write('models/skinned-zeroweight.mdl', _mdlv(
        bones, frames, rect(0.0, -10.0, 40.0, 10.0, ids=(0, 0, 0, 0), weights=(0.0, 0.0, 0.0, 0.0)), indices))

    # 5) 父链循环：0↔1 → 解析器视为拓扑不可信，抛错并回退原始顶点
    cyc = [('a', 1, _identity()), ('b', 0, _identity(10.0, 0.0))]
    write('models/skinned-cycle.json', json.dumps({'material': 'materials/skinned.json',
                                                   'puppet': 'models/skinned-cycle.mdl'}).encode())
    write('models/skinned-cycle.mdl', _mdlv(cyc, frames, rect(0.0, -10.0, 40.0, 10.0), indices))

    # 6) 截断：只保留前 60% 字节 → 回退原始顶点
    full = _mdlv(bones, frames, rect(0.0, -10.0, 40.0, 10.0), indices)
    write('models/skinned-truncated.json', json.dumps({'material': 'materials/skinned.json',
                                                       'puppet': 'models/skinned-truncated.mdl'}).encode())
    write('models/skinned-truncated.mdl', full[: int(len(full) * 0.6)])

    # 7) 超限骨骼数：声明 5000 根骨骼 → 回退原始顶点
    write('models/skinned-oversize.json', json.dumps({'material': 'materials/skinned.json',
                                                      'puppet': 'models/skinned-oversize.mdl'}).encode())
    write('models/skinned-oversize.mdl', _mdlv(bones, frames, rect(0.0, -10.0, 40.0, 10.0), indices,
                                               bone_override_count=5000))
    return root


if __name__=='__main__':
 print(generate(sys.argv[1]))
