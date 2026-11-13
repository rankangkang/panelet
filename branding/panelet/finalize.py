from pathlib import Path
import subprocess, zipfile, xml.etree.ElementTree as ET
p=Path(__file__).resolve().parent
black='#171717'
def glyph(color=black):
 return f'<g fill="{color}"><path d="M8 8H44V30H28V72H8Z"/><path d="M72 72H36V50H52V8H72Z"/></g>'
def svg(body,w=80,h=80):
 return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img"><title>Panelet — Interlock</title>{body}</svg>'
def write(n,body,w=80,h=80): (p/n).write_text(svg(body,w,h))
def icon(light=False):
 return f'<rect x="64" y="64" width="896" height="896" rx="194" fill="{ "#F7F7F7" if light else black }"/><g transform="translate(216 212) scale(7.4)">{glyph(black if light else "#FFFFFF")}</g>'
write('logo.svg',glyph())
write('logo-white.svg',glyph('#FFFFFF'))
write('app-icon.svg',icon(),1024,1024)
write('app-icon-light.svg',icon(True),1024,1024)
# Derive both halves from one pixel-aligned path to preserve 180-degree symmetry.
menu_half = 'M2 2H10V7H7V16H2Z'
write('menu-template.svg',f'<g fill="#000000"><path d="{menu_half}"/><path d="{menu_half}" transform="rotate(180 9 9)"/></g>',18,18)
write('wordmark.svg',f'<g transform="translate(4 4) scale(1.1)">{glyph()}</g><text x="114" y="70" font-family="Helvetica Neue,Arial,sans-serif" font-size="68" font-weight="500" letter-spacing="-2" fill="{black}">Panelet</text>',405,100)
board='<rect width="1200" height="650" fill="#F7F7F5"/>'
board+='<text x="64" y="61" font-family="Helvetica Neue,Arial,sans-serif" font-size="16" letter-spacing="2" fill="#777">PANELET / INTERLOCK</text>'
board+=f'<g transform="translate(48 116) scale(.34)">{icon()}</g>'
board+=f'<g transform="translate(445 171) scale(1.15)">{glyph()}</g>'
board+='<text x="569" y="244" font-family="Helvetica Neue,Arial,sans-serif" font-size="78" font-weight="500" letter-spacing="-3" fill="#171717">Panelet</text>'
board+='<text x="458" y="321" font-family="PingFang SC,sans-serif" font-size="25" fill="#171717">独立使用，合为一体。</text>'
board+='<text x="458" y="367" font-family="Helvetica Neue,Arial,sans-serif" font-size="21" fill="#777">One screen. More room.</text>'
board+='<path d="M64 502H1136" stroke="#DDD"/>'
for x,s in [(80,18),(148,24),(224,32),(312,48)]:
 board+=f'<g transform="translate({x} {557-s/2}) scale({s/80})">{glyph()}</g><text x="{x}" y="608" font-family="Helvetica Neue,Arial,sans-serif" font-size="12" fill="#777">{s}px</text>'
board+='<text x="764" y="565" font-family="Helvetica Neue,Arial,sans-serif" font-size="13" letter-spacing="1" fill="#777">GRAPHITE + WHITE</text>'
board+='<rect x="1020" y="537" width="36" height="36" fill="#171717"/><rect x="1074" y="537" width="36" height="36" fill="#FFF" stroke="#DDD"/>'
write('preview.svg',board,1200,650)
for name in ['app-icon','app-icon-light','wordmark','preview']:
 subprocess.run(['rsvg-convert',str(p/(name+'.svg')),'-o',str(p/(name+'.png'))],check=True)
for name in ['logo','logo-white']:
 subprocess.run(['rsvg-convert','-w','1024','-h','1024',str(p/(name+'.svg')),'-o',str(p/(name+'.png'))],check=True)
for scale in [1,2]:
 suffix='@2x' if scale==2 else ''
 subprocess.run(['rsvg-convert','-w',str(18*scale),'-h',str(18*scale),str(p/'menu-template.svg'),'-o',str(p/f'menu-template{suffix}.png')],check=True)
iconset=p/'Panelet.iconset';iconset.mkdir(exist_ok=True)
for size in [16,32,128,256,512]:
 for scale in [1,2]:
  suffix='@2x' if scale==2 else ''
  subprocess.run(['rsvg-convert','-w',str(size*scale),'-h',str(size*scale),str(p/'app-icon.svg'),'-o',str(iconset/f'icon_{size}x{size}{suffix}.png')],check=True)
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(p/'Panelet.icns')],check=True)
for file in p.glob('*.svg'): ET.parse(file)
print('Final Interlock assets exported and SVGs validated')
