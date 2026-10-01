"""Boundary invariants for all API writers. Coordinates are longitude/latitude."""
from math import sin,cos,asin,sqrt,radians,isfinite

def cross(a,b,c):return (b['lon']-a['lon'])*(c['lat']-a['lat'])-(b['lat']-a['lat'])*(c['lon']-a['lon'])
def measures(p):
    radius=6371008.8
    area=perimeter=0
    for a,b in zip(p,p[1:]+p[:1]):
        area+=radians(b['lon']-a['lon'])*(2+sin(radians(a['lat']))+sin(radians(b['lat'])))
        x=sin(radians(b['lat']-a['lat'])/2)**2+cos(radians(a['lat']))*cos(radians(b['lat']))*sin(radians(b['lon']-a['lon'])/2)**2
        perimeter+=2*radius*asin(sqrt(min(1,max(0,x))))
    return abs(area*radius*radius/2),perimeter

def validate(p):
    if not isinstance(p,list) or not 3<=len(p)<=1000:raise ValueError('A boundary needs 3 to 1000 points')
    for a in p:
        if not isinstance(a,dict) or any(isinstance(a.get(k),bool) or not isinstance(a.get(k),(int,float)) or not isfinite(a[k]) for k in ('lat','lon')):raise ValueError('Invalid coordinate')
        if abs(a['lat'])>85 or abs(a['lon'])>180:raise ValueError('Coordinate out of range')
        if abs(a['lon']-p[0]['lon'])>180:raise ValueError('Date line boundaries are not supported')
    for i,a in enumerate(p):
        for b in p[i+1:]:
            if measures([a,b])[1]/2<.05:raise ValueError('Two boundary points overlap')
    for i,a in enumerate(p):
        b=p[(i+1)%len(p)]
        previous=p[(i-1)%len(p)]
        dx,dy=a['lon']-previous['lon'],a['lat']-previous['lat']
        ex,ey=b['lon']-a['lon'],b['lat']-a['lat']
        if abs(dx*ey-dy*ex)<1e-16 and dx*ex+dy*ey<0:raise ValueError('Boundary edges overlap')
        for j in range(i+1,len(p)):
            if j==i+1 or (i==0 and j==len(p)-1):continue
            c,d=p[j],p[(j+1)%len(p)]
            overlap=all(max(min(a[k],b[k]),min(c[k],d[k]))<=min(max(a[k],b[k]),max(c[k],d[k])) for k in ('lat','lon'))
            if overlap and cross(a,b,c)*cross(a,b,d)<=0 and cross(c,d,a)*cross(c,d,b)<=0:raise ValueError('The boundary crosses itself')
    if measures(p)[0]<1:raise ValueError('Boundary must enclose at least one square metre')

def contains(parent,child):
    validate(parent);validate(child)
    eps=1e-10
    def inside(q):
        result=False
        for a,b in zip(parent,parent[1:]+parent[:1]):
            dx,dy=b['lon']-a['lon'],b['lat']-a['lat']
            if abs(cross(a,b,q))<=eps*sqrt(dx*dx+dy*dy) and all(min(a[k],b[k])-eps<=q[k]<=max(a[k],b[k])+eps for k in ('lat','lon')):return True
            if (a['lat']>q['lat'])!=(b['lat']>q['lat']) and q['lon']<(b['lon']-a['lon'])*(q['lat']-a['lat'])/(b['lat']-a['lat'])+a['lon']:result=not result
        return result
    for a,b in zip(child,child[1:]+child[:1]):
        if not inside(a):raise ValueError('Every field point must be inside or on its farm boundary')
        dx,dy=b['lon']-a['lon'],b['lat']-a['lat'];ts=[0,1]
        for c,d in zip(parent,parent[1:]+parent[:1]):
            ex,ey=d['lon']-c['lon'],d['lat']-c['lat'];den=dx*ey-dy*ex
            if abs(den)>1e-20:
                t=((c['lon']-a['lon'])*ey-(c['lat']-a['lat'])*ex)/den
                u=((c['lon']-a['lon'])*dy-(c['lat']-a['lat'])*dx)/den
                if 0<=t<=1 and -eps<=u<=1+eps:ts.append(t)
            else:
                for q in (c,d):
                    t=((q['lon']-a['lon'])*dx+(q['lat']-a['lat'])*dy)/(dx*dx+dy*dy)
                    if 0<t<1:ts.append(t)
        ts.sort()
        for left,right in zip(ts,ts[1:]):
            t=(left+right)/2
            if not inside({'lat':a['lat']+dy*t,'lon':a['lon']+dx*t}):raise ValueError('A field edge crosses outside its farm boundary')
