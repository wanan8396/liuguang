"""Render the repository-owned vector mark to Android and Flutter icon assets."""
from pathlib import Path
import math
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1536
OUTER = 'M 340,225 C 316,211 282,226 282,259 L 282,754 C 282,790 320,808 351,790 L 784,540 C 814,523 814,484 784,467 Z'
INNER = 'M 416,392 L 416,625 L 618,508 Z'
TAIL = 'M 282,611 L 416,534 L 416,622 L 282,699 Z'


def bezier(a, b, c, d, count=40):
    return [((1-t)**3*a[0]+3*(1-t)**2*t*b[0]+3*(1-t)*t*t*c[0]+t**3*d[0],
             (1-t)**3*a[1]+3*(1-t)**2*t*b[1]+3*(1-t)*t*t*c[1]+t**3*d[1])
            for t in [i/count for i in range(1,count+1)]]


def draw_mark(size):
    scale = size/1024
    p = [(340,225)] + bezier((340,225),(316,211),(282,226),(282,259))
    p += [(282,754)] + bezier((282,754),(282,790),(320,808),(351,790))
    p += [(784,540)] + bezier((784,540),(814,523),(814,484),(784,467))
    mask = Image.new('L',(size,size))
    pen = ImageDraw.Draw(mask)
    pen.polygon([(x*scale,y*scale) for x,y in p],fill=255)
    pen.polygon([(416*scale,392*scale),(416*scale,625*scale),(618*scale,508*scale)],fill=0)
    layer = Image.new('RGBA',(size,size))
    grad = ImageDraw.Draw(layer)
    stops = [(0.2,(110,251,225)),(0.49,(63,205,242)),(0.79,(104,117,248))]
    for y in range(size):
        t = y/size
        lo,hi = (stops[0],stops[1]) if t<0.49 else (stops[1],stops[2])
        k=max(0,min(1,(t-lo[0])/(hi[0]-lo[0])))
        color=tuple(round(a+(b-a)*k) for a,b in zip(lo[1],hi[1]))
        grad.line((0,y,size,y),fill=color+(255,))
    layer.putalpha(mask)
    # A white folded edge separates the light ribbon from its trailing face.
    pen = ImageDraw.Draw(layer)
    pen.polygon([(282*scale,611*scale),(416*scale,534*scale),(416*scale,561*scale),(282*scale,638*scale)],fill=(191,252,253,255))
    return layer


def main():
    brand=ROOT/'assets/brand';brand.mkdir(parents=True,exist_ok=True)
    res=ROOT/'android/app/src/main/res'
    canvas=Image.new('RGBA',(SIZE,SIZE))
    d=ImageDraw.Draw(canvas)
    for y in range(SIZE):
        t=y/SIZE
        d.line((0,y,SIZE,y),fill=(round(18-10*t),round(44-20*t),round(78-29*t),255))
    canvas.alpha_composite(draw_mark(SIZE))
    mask=Image.new('L',(SIZE,SIZE));ImageDraw.Draw(mask).rounded_rectangle((0,0,SIZE-1,SIZE-1),radius=SIZE*0.225,fill=255)
    canvas.putalpha(mask)
    canvas.resize((1024,1024),Image.Resampling.LANCZOS).save(brand/'liuguang-icon.png')
    canvas.resize((256,256),Image.Resampling.LANCZOS).save(brand/'liuguang-mark.png')
    for density,px in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
        directory=res/f'mipmap-{density}';directory.mkdir(exist_ok=True)
        canvas.resize((px,px),Image.Resampling.LANCZOS).save(directory/'ic_launcher.png')
    svg=f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="bg" x2="0" y2="1"><stop stop-color="#122c4e"/><stop offset="1" stop-color="#081831"/></linearGradient>
<linearGradient id="light" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#6efbe1"/><stop offset=".5" stop-color="#3fcdf2"/><stop offset="1" stop-color="#6875f8"/></linearGradient></defs>
<rect width="1024" height="1024" rx="230" fill="url(#bg)"/>
<path d="{OUTER} {INNER}" fill-rule="evenodd" fill="url(#light)"/>
<path d="M282 611 L416 534 L416 561 L282 638 Z" fill="#bffcfD"/></svg>'''
    (brand/'liuguang-icon.svg').write_text(svg,encoding='utf-8')
    vector=f'''<vector xmlns:android="http://schemas.android.com/apk/res/android" xmlns:aapt="http://schemas.android.com/aapt" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">
<group android:pivotX="512" android:pivotY="512" android:scaleX="0.78" android:scaleY="0.78">
<path android:pathData="{OUTER} {INNER}" android:fillType="evenOdd">
<aapt:attr name="android:fillColor"><gradient android:startX="300" android:startY="220" android:endX="600" android:endY="790" android:type="linear"><item android:offset="0" android:color="#6EFBE1"/><item android:offset="0.5" android:color="#3FCDF2"/><item android:offset="1" android:color="#6875F8"/></gradient></aapt:attr>
</path><path android:pathData="M282 611 L416 534 L416 561 L282 638 Z" android:fillColor="#BFFCFD"/>
</group></vector>'''
    (res/'drawable/ic_launcher_foreground.xml').write_text(vector,encoding='utf-8')
    mono=f'''<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024"><group android:pivotX="512" android:pivotY="512" android:scaleX="0.78" android:scaleY="0.78"><path android:pathData="{OUTER} {INNER}" android:fillType="evenOdd" android:fillColor="#FFFFFF"/></group></vector>'''
    (res/'drawable/ic_launcher_monochrome.xml').write_text(mono,encoding='utf-8')
    for version in ['v26','v33']:
        directory=res/f'mipmap-anydpi-{version}';directory.mkdir(exist_ok=True)
        mono_tag='<monochrome android:drawable="@drawable/ic_launcher_monochrome"/>' if version=='v33' else ''
        (directory/'ic_launcher.xml').write_text(f'<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/launcher_background"/><foreground android:drawable="@drawable/ic_launcher_foreground"/>{mono_tag}</adaptive-icon>',encoding='utf-8')
    (res/'values/launcher_colors.xml').write_text('<resources><color name="launcher_background">#102542</color></resources>',encoding='utf-8')
    print(brand/'liuguang-icon.png')


if __name__=='__main__':
    main()
