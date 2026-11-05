# Bakes a texture-mapped Kenney OBJ into a flat-color OBJ our parser
# understands: every face's UV centroid is sampled in the pack's
# colormap/texture PNG and emitted as a dedicated usemtl with a real
# Kd color. Run:  python tool/bake_kenney.py <in.obj> <out.obj>
import sys, os
from PIL import Image


def load_obj(path):
    verts, uvs, faces = [], [], []  # faces: (mtl, [(vi, ti), ...])
    cur = 'default'
    for ln in open(path, encoding='utf-8', errors='replace'):
        p = ln.split()
        if not p:
            continue
        if p[0] == 'v':
            verts.append(tuple(map(float, p[1:4])))
        elif p[0] == 'vt':
            uvs.append(tuple(map(float, p[1:3])))
        elif p[0] == 'usemtl':
            cur = p[1]
        elif p[0] == 'f':
            idx = []
            for t in p[1:]:
                w = t.split('/')
                vi = int(w[0]); vi = vi - 1 if vi > 0 else len(verts) + vi
                ti = -1
                if len(w) > 1 and w[1]:
                    ti = int(w[1]); ti = ti - 1 if ti > 0 else len(uvs) + ti
                idx.append((vi, ti))
            faces.append((cur, idx))
    return verts, uvs, faces


def sample(img, uvs, idx):
    if not idx or any(t < 0 for _, t in idx):
        return None
    u = sum(uvs[t][0] for _, t in idx) / len(idx)
    v = sum(uvs[t][1] for _, t in idx) / len(idx)
    w, h = img.size
    x = min(w - 1, max(0, int((u % 1.0) * w)))
    y = min(h - 1, max(0, int((v % 1.0) * h)))
    return img.getpixel((x, y))[:3]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    tex = os.path.join(os.path.dirname(src), 'Textures', 'colormap.png')
    if not os.path.exists(tex):
        for f in os.listdir(os.path.join(os.path.dirname(src), 'Textures')):
            if f.endswith('.png'):
                tex = os.path.join(os.path.dirname(src), 'Textures', f); break
    img = Image.open(tex).convert('RGB')
    verts, uvs, faces = load_obj(src)

    # group faces by the color their UVs sample
    groups, order = {}, []
    for mtl, idx in faces:
        c = sample(img, uvs, idx) or (200, 200, 200)
        if c not in groups:
            groups[c] = []
            order.append(c)
        groups[c].append(idx)

    mtl_path = dst[:-4] + '.mtl'
    with open(dst, 'w') as o:
        o.write('# baked from ' + os.path.basename(src) + '\n')
        o.write('mtllib ' + os.path.basename(mtl_path) + '\n')
        for v in verts:
            o.write(f'v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n')
        for ci, c in enumerate(order):
            o.write(f'usemtl bake{ci}\n')
            for idx in groups[c]:
                o.write('f ' + ' '.join(str(i + 1) for i, _ in idx) + '\n')
    with open(mtl_path, 'w') as o:
        for ci, c in enumerate(order):
            o.write(f'newmtl bake{ci}\nKd {c[0]/255:.4f} {c[1]/255:.4f} {c[2]/255:.4f}\n')
    print(f'{os.path.basename(dst)}: {len(verts)}v {len(faces)}f -> {len(order)} colors')


if __name__ == '__main__':
    main()
