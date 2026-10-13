"""Source-time cuts and smooth zoom plans shared by LuYing exports."""
import bisect, math

def retained_ranges(start, end, cuts, speed=1, preview=None):
    if not all(math.isfinite(x) for x in (start, end, speed)) or speed <= 0 or end <= start:
        raise ValueError('裁剪时间或速度无效')
    merged=[]
    for cut in sorted(cuts, key=lambda x: float(x['start'])):
        a,b=float(cut['start']),float(cut['end'])
        if not math.isfinite(a+b) or b<=a: raise ValueError('删除区间无效')
        a,b=max(start,a),min(end,b)
        if b<=a: continue
        if merged and a<=merged[-1][1]:merged[-1][1]=max(merged[-1][1],b)
        else:merged.append([a,b])
    ranges=[];cursor=start
    for a,b in merged:
        if a>cursor:ranges.append([cursor,a])
        cursor=max(cursor,b)
    if cursor<end:ranges.append([cursor,end])
    if preview is not None:
        budget=preview*speed;limited=[]
        for a,b in ranges:
            if budget<=0:break
            take=min(b-a,budget);limited.append([a,a+take]);budget-=take
        ranges=limited
    if not ranges:raise ValueError('所有画面都被删除，请保留至少一个片段')
    if len(ranges)>100:raise ValueError('当前最多支持 100 个保留片段')
    return ranges

def output_time(source, ranges, speed):
    elapsed=0
    for a,b in ranges:
        if a<=source<b:return (elapsed+source-a)/speed
        elapsed+=b-a
    return None

def read_events(data):
    raw=data if isinstance(data,list) else data.get('events',[])
    result=[]
    mw=data.get('width',1) if isinstance(data,dict) else 1
    mh=data.get('height',1) if isinstance(data,dict) else 1
    for item in raw:
        t=float(item.get('time',item.get('t',0)));x=float(item['x']);y=float(item['y'])
        if not all(math.isfinite(v) for v in (t,x,y)):continue
        if x>1 or y>1:x/=max(1,mw);y/=max(1,mh)
        result.append({'t':t,'x':max(0,min(1,x)),'y':max(0,min(1,y)), 'click':item.get('kind',item.get('type')) in ('click','mousedown') or bool(item.get('click',False))})
    return sorted(result,key=lambda e:e['t'])

def retime_events(events,ranges,speed):
    result=[];elapsed=0
    times=[e['t'] for e in events]
    for a,b in ranges:
        before=bisect.bisect_right(times,a)-1
        if before>=0:
            e=dict(events[before]);e.update(t=elapsed/speed,click=False);result.append(e)
        for e in events[bisect.bisect_left(times,a):bisect.bisect_left(times,b)]:
            e=dict(e);e['t']=(elapsed+e['t']-a)/speed;result.append(e)
        elapsed+=b-a
    return sorted(result,key=lambda e:e['t'])

def auto_scenes(events, duration, factor=1.65, hold=2.4):
    groups=[]
    for e in [e for e in events if e['click'] and 0<=e['t']<duration][:80]:
        if groups and e['t'] <= groups[-1]['last']+hold/2 and math.hypot(e['x']-groups[-1]['x'],e['y']-groups[-1]['y'])<=.25:
            g=groups[-1];g['last']=e['t'];g['count']+=1;g['x']+=(e['x']-g['x'])/g['count'];g['y']+=(e['y']-g['y'])/g['count']
        else:groups.append({'first':e['t'],'last':e['t'],'count':1,'x':e['x'],'y':e['y']})
    result=[]
    for g in groups:
        begin=max(0,g['first']-.35);end=min(duration,g['last']+hold/2)
        if result and begin<result[-1]['end']:
            boundary=(begin+result[-1]['end'])/2;result[-1]['end']=boundary;begin=boundary
        result.append({'start':begin,'end':end,'x':g['x'],'y':g['y'],'factor':factor})
    return result

def validate_scenes(scenes,duration):
    result=[]
    for s in sorted(scenes,key=lambda x:float(x['start'])):
        s={k:float(s[k]) for k in ('start','end','x','y','factor')}
        if not all(math.isfinite(v) for v in s.values()) or not (0<=s['start']<s['end']<=duration+.001 and 0<=s['x']<=1 and 0<=s['y']<=1 and 1<=s['factor']<=4):raise ValueError('缩放时间、焦点或倍率无效')
        if result and s['start']<result[-1]['end']-.001:raise ValueError('缩放区间不能重叠')
        result.append(s)
    if len(result)>80:raise ValueError('当前最多支持 80 个缩放区间')
    return result

def smooth(value):
    value=max(0,min(1,value));return value*value*(3-2*value)

def camera_frames(scenes,ranges,speed,fps,duration):
    """Sample source-time easing, then project onto the retained timeline."""
    # FFmpeg's fps filter has one continuous output clock across all cuts.
    count=max(1,math.ceil(duration*fps))
    # Evaluate at exact output frame times to avoid per-clip rounding drift.
    result=[];elapsed=0;piece=0;offsets=[]
    for a,b in ranges:offsets.append(elapsed);elapsed+=(b-a)/speed
    for n in range(count):
        t=n/fps
        while piece+1<len(ranges) and t>=offsets[piece+1]:piece+=1
        a,b=ranges[piece];source=min(b-1e-7,a+(t-offsets[piece])*speed)
        scene=next((s for s in scenes if s['start']<=source<s['end']),None)
        z=1.;x=y=0.
        if scene:
            fade=min(.45,(scene['end']-scene['start'])/2)
            strength=min(smooth((source-scene['start'])/fade),smooth((scene['end']-source)/fade))
            z=1+(scene['factor']-1)*strength
            x=max(0,min(1-1/z,scene['x']-.5/z));y=max(0,min(1-1/z,scene['y']-.5/z))
        result.append((z,x,y))
    return result

def expression(values,time='on'):
    """Linear interpolation between adaptively reduced, bounded control points."""
    if not values:return '0'
    tolerance=.001
    points=[(0,values[0])]
    def simplify(lo,hi):
        if hi-lo<=1:return
        span=hi-lo;worst=0;at=None
        for n in range(lo+1,hi):
            error=abs(values[n]-(values[lo]+(values[hi]-values[lo])*(n-lo)/span))
            if error>worst:worst=error;at=n
        if worst>tolerance and at is not None:
            simplify(lo,at);points.append((at,values[at]));simplify(at,hi)
    # Adapt precision to FFmpeg's expression budget instead of rejecting long clips.
    # Keep the normal 0.001 tolerance unless this actual trajectory exceeds it.
    while True:
        points=[(0,values[0])]
        for lo in range(0,len(values)-1,300):
            hi=min(len(values)-1,lo+300);simplify(lo,hi);points.append((hi,values[hi]))
        ordered=sorted(set(points));points=[]
        for point in ordered:
            points.append(point)
            while len(points)>=3:
                a,av=points[-3];b,bv=points[-2];c,cv=points[-1]
                if abs(bv-(av+(cv-av)*(b-a)/(c-a)))>1e-10:break
                points.pop(-2)
        if len(points)<=1200:break
        tolerance*=2
    def branch(lo,hi):
        if lo>=hi:return f'{points[lo][1]:.6f}'
        if hi-lo==1:
            a,av=points[lo];b,bv=points[hi]
            return f'({av:.6f}+({bv-av:.6f})*clip(({time}-{a})/{b-a},0,1))'
        mid=(lo+hi)//2
        return f'if(lt({time},{points[mid][0]}),{branch(lo,mid)},{branch(mid,hi)})'
    return branch(0,len(points)-1)

def montage_filter(index,kind,ranges,speed,label):
    if len(ranges)==1:
        a,b=ranges[0]
        return [f'[{index}]'+(f'trim=start={a}:end={b},setpts=(PTS-STARTPTS)/{speed}' if kind=='v' else f'atrim=start={a}:end={b},asetpts=PTS-STARTPTS')+f'[{label}]']
    split='split' if kind=='v' else 'asplit';trim='trim' if kind=='v' else 'atrim';pts='setpts' if kind=='v' else 'asetpts'
    filters=[f'[{index}]{split}={len(ranges)}'+''.join(f'[{label}in{n}]' for n in range(len(ranges)))]
    for n,(a,b) in enumerate(ranges):filters.append(f'[{label}in{n}]{trim}=start={a}:end={b},{pts}=PTS-STARTPTS[{label}part{n}]')
    joined=f'{label}joined' if kind=='v' else label
    filters.append(''.join(f'[{label}part{n}]' for n in range(len(ranges)))+f'concat=n={len(ranges)}:v={int(kind=="v")}:a={int(kind=="a")}[{joined}]')
    if kind=='v':filters.append(f'[{joined}]setpts=PTS/{speed}[{label}]')
    return filters
