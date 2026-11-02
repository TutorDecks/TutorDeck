#!/usr/bin/env python3
"""Build assets/css/dark.css — the opt-in dark theme.

Light mode is never touched: every rule here is scoped to html[data-theme="dark"] (set by the
moon button, per device) and wrapped in @media screen so print/invoice output stays light.

How: read assets/css/app.css plus the <style> blocks of the signed-in pages, find each declaration
with a hard-coded colour (or a variable used in the "other" role, e.g. var(--navy) as a background),
and emit a dark counterpart with the same selector. Colours are mapped in OKLab: light surfaces
become dark surfaces (keeping their tint), dark text becomes light text, solid brand fills stay solid.
Re-run after changing colours:  python3 tools/build-dark.py
"""
import re, glob, colorsys, math, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The invoice "paper" (rendered to an image for parents) always stays light.
PAPER = re.compile(r'\.(invoice|inv-(head|biz|meta|to|table|total|pay|bank)|pn-(dot|h|sub|arrow))\b')
PAGES = ["home","calendar","planner","ledger","invoices","insights","students","student","exams","settings"]
P = 'html[data-theme="dark"]'

# ---- dark palette (variables) ----
VARS = {
  "--bg":"#0F1726", "--paper":"#172235", "--cream":"#173A37", "--line":"#2A3750",
  "--ink":"#E6EAF1", "--navy":"#E6EAF1", "--navy-2":"#C3CBD8", "--muted":"#9AA4B6",
  "--teal":"#3FB8A9", "--gold":"#3FB8A9", "--accent":"#3FB8A9", "--accent-ink":"#6ED0C3",
  "--accent-soft":"#14302F", "--owed":"#EE8A74", "--warn":"#E9A657", "--gold-2":"#E9A657",
  "--shadow":"0 1px 2px rgba(0,0,0,.35),0 8px 24px rgba(0,0,0,.28)",
}
# variables used as a solid fill (white text on top) keep a mid-tone in dark mode
VAR_AS_BG = {"navy":"#2E4166","ink":"#2E4166","navy-2":"#26385A","accent":"#12857A","teal":"#12857A",
             "gold":"#12857A","accent-ink":"#0F766E","owed":"#B4432F","warn":"#B45309","gold-2":"#B45309"}
# variables used as text that were meant to stay light (text on a navy fill)
VAR_AS_TEXT = {"cream":"#EEF6F4","line":"#C3CBD8","paper":"#FFFFFF","bg":"#FFFFFF"}
# exact surface colours with a fixed dark counterpart (cards stay lighter than the ground)
SURF = {"#ffffff":"#172235","#fff":"#172235","white":"#172235","#faf9f6":"#0F1726"}

def hex2rgb(h):
    h=h.lstrip('#')
    if len(h) in (3,4): h=''.join(c*2 for c in h)
    return tuple(int(h[i:i+2],16)/255 for i in (0,2,4)), (int(h[6:8],16)/255 if len(h)==8 else 1)
def lin(c): return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def unlin(c): return 12.92*c if c<=0.0031308 else 1.055*c**(1/2.4)-0.055
def to_lab(rgb):
    r,g,b=map(lin,rgb)
    l=0.4122214708*r+0.5363325363*g+0.0514459929*b; m=0.2119034982*r+0.6806995451*g+0.1073969566*b; s=0.0883024619*r+0.2817188376*g+0.6299787005*b
    l,m,s=[x**(1/3) for x in (l,m,s)]
    return (0.2104542553*l+0.7936177850*m-0.0040720468*s, 1.9779984951*l-2.4285922050*m+0.4505937099*s, 0.0259040371*l+0.7827717662*m-0.8086757660*s)
def from_lab(L,a,b):
    l=L+0.3963377774*a+0.2158037573*b; m=L-0.1055613458*a-0.0638541728*b; s=L-0.0894841775*a-1.2914855480*b
    l,m,s=l**3,m**3,s**3
    r=4.0767416621*l-3.3077115913*m+0.2309699292*s; g=-1.2684380046*l+2.6097574011*m-0.3413193965*s; bb=-0.0041960863*l-0.7034186168*m+1.7076147010*s
    return tuple(min(1,max(0,unlin(min(1,max(0,x))))) for x in (r,g,bb))
def hexout(rgb,a=1):
    h='#'+''.join('%02X'%round(x*255) for x in rgb)
    return h if a>=1 else 'rgba(%d,%d,%d,%s)'%(*[round(x*255) for x in rgb], ('%.3f'%a).rstrip('0').rstrip('.'))

def parse(tok):
    t=tok.lower()
    if t=='white': return (1,1,1),1
    if t=='black': return (0,0,0),1
    if t.startswith('#'): return hex2rgb(t)
    n=[float(x) for x in re.findall(r'[\d.]+',t)]
    return (n[0]/255,n[1]/255,n[2]/255),(n[3] if len(n)>3 else 1)

def map_col(tok, role):
    if tok.lower() in ('transparent','currentcolor','inherit'): return tok
    if role=="bg" and tok.lower() in SURF: return SURF[tok.lower()]
    rgb,a=parse(tok); L,A,B=to_lab(rgb); C=math.hypot(A,B); h=math.atan2(B,A)
    neutral = C<0.03 and role!="text"
    if neutral: h=NAVY_H                                  # warm greys → cool slate, to sit with the navy ground
    if role=="text":
        if L>=0.80: return tok                          # already light (text on a solid fill)
        L2=0.95-(L-0.2)*0.62; C2=C*1.05
    elif role=="shadow":
        if L<0.5: return hexout((0,0,0),min(1,a*2.2))     # darker, stronger shadows
        L2=0.30; C2=C*0.6
    else:   # bg / border
        if a>=0.3 and a<1 and L<0.35:                     # scrim behind sheets/modals: stays dark
            return hexout((0,0,0),min(0.8,a*1.3))
        if a<1 and L<0.6:                                 # translucent tint of a dark/brand colour
            return hexout(rgb if L>0.35 else from_lab(0.75,A,B), min(1,a*1.9))
        if a<1 and L>=0.8:                                # translucent white: frosted panel → dark glass; faint wash stays
            return hexout(hex2rgb('#172235')[0],max(a,0.86)) if a>=0.5 else tok
        if L<0.62:                                        # solid fill: keep, lift very dark ones
            if L>=0.38: return tok
            L2=0.42; C2=C
        else:
            L2=(0.245 if role=="bg" else 0.30)+(1-L)*1.25; C2=0.025 if neutral else C*1.6
    return hexout(from_lab(L2,C2*math.cos(h),C2*math.sin(h)),a)

_l=to_lab(hex2rgb('#172235')[0]); NAVY_H=math.atan2(_l[2],_l[1])
COL=re.compile(r'#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|\bwhite\b|\bblack\b|var\(--([a-z0-9-]+)\)')
def role_of(prop):
    p=prop.lower()
    if p in ('color','fill','stroke','caret-color','-webkit-text-fill-color','text-decoration-color','accent-color'): return 'text'
    if p.startswith('background'): return 'bg'
    if p in ('box-shadow','text-shadow','filter'): return 'shadow'
    if p.startswith('border') or p.startswith('outline') or p=='column-rule' or p.startswith('--'): return 'border'
    return None

def conv_decl(prop,val):
    role=role_of(prop)
    if not role: return None
    changed=[False]
    def sub(m):
        if m.group(1):
            v=m.group(1)
            if role=='bg' and v in VAR_AS_BG: changed[0]=True; return VAR_AS_BG[v]
            if role=='text' and v in VAR_AS_TEXT: changed[0]=True; return VAR_AS_TEXT[v]
            return m.group(0)
        tok=m.group(0)
        r=role
        if role=='shadow':
            # an inset/zero-blur shadow used as a hairline border maps like a border
            r='border' if re.match(r'\s*(inset\s+)?0 0 0 [\d.]', val) else 'shadow'
        new=map_col(tok,r)
        if new!=tok: changed[0]=True
        return new
    out=COL.sub(sub,val)
    return out if changed[0] else None

def rules(css):
    css=re.sub(r'/\*.*?\*/','',css,flags=re.S)
    res=[];stack=[];buf=''
    for ch in css:
        if ch=='{': stack.append(buf.strip()); buf=''
        elif ch=='}':
            if buf.strip() and stack and not any(s.startswith('@keyframes') or s.startswith('@font-face') for s in stack):
                res.append((tuple(stack[:-1]),stack[-1],buf.strip()))
            if stack: stack.pop()
            buf=''
        else: buf+=ch
    return res

def scope(sel):
    out=[]
    for s in sel.split(','):
        s=s.strip()
        if not s: continue
        if s.startswith(':root'): continue
        if s.startswith('html'): out.append(P+s[4:])
        else: out.append(P+' '+s)
    return ',\n'.join(out)

def build():
    srcs=[('app.css',open(os.path.join(ROOT,'assets/css/app.css')).read())]
    for p in PAGES:
        h=open(os.path.join(ROOT,p+'.html')).read()
        for st in re.findall(r'<style[^>]*>(.*?)</style>',h,re.S): srcs.append((p+'.html',st))
    out=['/* GENERATED by tools/build-dark.py — do not edit by hand; edit the script and re-run. */',
         '/* Opt-in dark theme: only applies when <html data-theme="dark">. Light mode is untouched. */',
         '@media screen {',
         P+'{color-scheme:dark;'+''.join('%s:%s;'%kv for kv in VARS.items())+'}',
         P+' body{background:var(--bg);color:var(--ink)}']
    appcss=re.sub(r'/\*.*?\*/','',open(os.path.join(ROOT,'assets/css/app.css')).read(),flags=re.S)
    root=re.search(r':root\{(.*?)\}',appcss,re.S).group(1)
    lightvars=';'.join(d.strip() for d in root.split(';') if d.strip().startswith('--') and d.split(':')[0].strip() in VARS)
    out.append(P+' .invoice{color-scheme:light;'+lightvars+';color:var(--ink)}')
    out.append(HAND)
    for name,css in srcs:
        chunk=[]
        for ctx,sel,body in rules(css):
            if sel.startswith('@') or not scope(sel) or PAPER.search(sel): continue
            decls=[]
            for d in re.split(r';(?![^(]*\))',body):
                if ':' not in d: continue
                prop,val=d.split(':',1); prop=prop.strip()
                if prop.startswith('--'): continue
                imp=' !important' if '!important' in val else ''
                val=val.replace('!important','').strip()
                nv=conv_decl(prop,val)
                if nv: decls.append('%s:%s%s'%(prop,nv,imp))
            if decls:
                r=scope(sel)+'{'+';'.join(decls)+'}'
                for c in reversed([c for c in ctx if c.startswith('@media') or c.startswith('@supports')]): r=c+'{'+r+'}'
                chunk.append(r)
        if chunk: out.append('/* from %s */'%name); out+=chunk
    out.append(INLINE)
    out.append('}')
    open(os.path.join(ROOT,'assets/css/dark.css'),'w').write('\n'.join(out)+'\n')

# Hand-tuned bits the generator can't infer (inline styles written by JS, SVG charts, invoice paper).
HAND = '''/* hand-tuned */
'''
INLINE = '''/* inline colours written by page scripts (calendar popover tags, student progress chart) */
html[data-theme="dark"] [style*="background:#F1EFEA"]{background:#243048!important}
html[data-theme="dark"] [style*="background:rgba(19,35,63,.10)"]{background:rgba(255,255,255,.08)!important}
html[data-theme="dark"] [style*="rgba(180,83,9,.18)"]{background:rgba(233,166,87,.18)!important;color:#F0B66E!important}
html[data-theme="dark"] [style*="color:#0B5D57"]{color:#6ED0C3!important}
html[data-theme="dark"] [style*="color:#8a2f22"]{color:#F19A86!important}
html[data-theme="dark"] [style*="rgba(15,118,110,.14)"],html[data-theme="dark"] [style*="rgba(15,118,110,.12)"]{background:rgba(63,184,169,.18)!important}
html[data-theme="dark"] [style*="rgba(180,67,47,.12)"]{background:rgba(238,138,116,.18)!important}
html[data-theme="dark"] svg [stroke="#E2DED5"]{stroke:#2A3750}
html[data-theme="dark"] svg [fill="#6F7480"],html[data-theme="dark"] svg [fill="#5E6676"]{fill:#9AA4B6}
html[data-theme="dark"] svg [fill="#13233F"]{fill:#E6EAF1}
html[data-theme="dark"] svg circle[stroke="#fff"]{stroke:#172235}
'''
if __name__=='__main__': build(); print('wrote assets/css/dark.css')
