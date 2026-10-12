#!/usr/bin/env python3
"""Local FFmpeg video compositor for LuYing. No paid services."""
import argparse, json, math, os, re, shutil, struct, subprocess, tempfile, zlib, signal, sys, uuid
from pathlib import Path
from timeline import retained_ranges, read_events, retime_events, auto_scenes, validate_scenes, camera_frames, expression, montage_filter

def png(path,w,h,pixel):
    raw=b''.join(b'\0'+b''.join(bytes(pixel(x,y)) for x in range(w)) for y in range(h))
    png_raw(path,w,h,raw)

def png_raw(path,w,h,raw):
    def chunk(kind,data): return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))

def event(**values):
    print(json.dumps({'luying': True, **values}, ensure_ascii=False), flush=True)

def run(argv, duration):
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, text=True)
    try:
        for line in child.stdout:
            key, _, value = line.strip().partition('=')
            if key == 'out_time_us':
                try: event(phase='encoding', progress=min(.99, max(0, int(value)/1_000_000/duration)))
                except ValueError: pass
        if child.wait(): raise RuntimeError('媒体编码失败，请查看诊断信息')
    finally:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()

def interrupted(signum, frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)

def probe(ffmpeg,path):
    tool=str(Path(ffmpeg).with_name('ffprobe'))
    return json.loads(subprocess.check_output([tool,'-v','error','-show_streams','-show_format','-of','json',str(path)]))

def main():
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument('input',type=Path);p.add_argument('output',type=Path,help='MP4 or GIF destination')
    p.add_argument('--ffmpeg',default=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg')
    p.add_argument('--subtitle-renderer',type=Path,help='Precompiled native subtitle renderer')
    p.add_argument('--encoder',choices=['libx264','h264_videotoolbox'],default='libx264')
    p.add_argument('--start',type=float,default=0,help='Trim start in source seconds')
    p.add_argument('--end',type=float,help='Trim end in source seconds')
    p.add_argument('--cuts-json',default='[]',help='Deleted source intervals as JSON')
    p.add_argument('--zoom-scenes-json',help='Editable source-time zoom scenes as JSON')
    p.add_argument('--preview-duration',type=float,help='Limit retained output duration')
    p.add_argument('--speed',type=float,default=1)
    p.add_argument('--aspect',choices=['original','source','16:9','9:16','1:1','4:3'],default='16:9')
    p.add_argument('--width',type=int,default=1920);p.add_argument('--height',type=int,help='Overrides aspect preset')
    p.add_argument('--padding',type=int,default=80);p.add_argument('--radius',type=int,default=24)
    p.add_argument('--background-image',type=Path,help='Image background, scaled to cover the output frame')
    p.add_argument('--music',type=Path,help='Loop background music in output timeline')
    p.add_argument('--music-volume',type=float,default=.15,help='Music gain; 0–2')
    p.add_argument('--denoise',action='store_true',help='Apply ordinary FFT noise reduction to recorded audio')
    p.add_argument('--background',default='#18233f,#7849b8',help='Two gradient colors, comma separated')
    p.add_argument('--fps',type=int,default=30);p.add_argument('--quality',type=int,default=20,help='H.264 CRF: lower is better')
    p.add_argument('--mouse',type=Path,help='JSON events with source time, normalized x/y, kind=move/click; pixel positions require top-level width/height')
    p.add_argument('--auto-zoom',action='store_true',help='Enable click zoom (already enabled by default; use --zoom 1 to disable)')
    p.add_argument('--no-clicks',action='store_true',help='Hide click rings while retaining auto zoom')
    p.add_argument('--zoom',type=float,default=1.65,help='Click zoom factor; 1 disables zoom')
    p.add_argument('--zoom-duration',type=float,default=2.4)
    p.add_argument('--cursor-size',type=int,default=18,help='Synthetic cursor dot size; 0 hides dot')
    p.add_argument('--webcam',type=Path,help='Optional synchronized webcam video, placed bottom right')
    p.add_argument('--captions',type=Path,help='SRT in source timeline; trimmed and retimed with the video')
    p.add_argument('--captions-source-timeline',action='store_true',help='Explicit source timeline (the default)')
    p.add_argument('--captions-output-timeline',action='store_true',help='SRT timestamps already refer to exported output timeline')
    p.add_argument('--mute',action='store_true');p.add_argument('--no-shadow',action='store_true')
    a=p.parse_args()
    if a.speed<=0 or a.fps<=0 or a.width<64 or a.padding<0 or a.start<0: p.error('speed/fps/width must be positive; start/padding nonnegative')
    if a.zoom<1 or a.zoom>4 or a.zoom_duration<=0: p.error('zoom must be 1–4 and zoom duration positive')
    if a.output.suffix.lower() not in ('.mp4','.gif'): p.error('output extension must be .mp4 or .gif')
    if a.input.resolve()==a.output.resolve(): p.error('input and output must be different files')
    if not 0<=a.music_volume<=2:p.error('music volume must be 0–2')
    for asset in (a.music,a.background_image,a.webcam,a.captions):
        if asset and not asset.is_file():p.error(f'asset does not exist: {asset}')
    native_subtitles=False
    if a.captions:
        available=subprocess.check_output([a.ffmpeg,'-hide_banner','-filters'],stderr=subprocess.DEVNULL,text=True)
        native_subtitles=' subtitles ' in available
        if not native_subtitles and not a.subtitle_renderer and not shutil.which('swift'):p.error('captions require Swift/AppKit on macOS or a libass-enabled ffmpeg')
    info=probe(a.ffmpeg,a.input);v=next((s for s in info['streams'] if s['codec_type']=='video'),None)
    if not v:p.error('input has no video stream')
    duration=float(info['format']['duration']);end=min(a.end if a.end is not None else duration,duration)
    if end<=a.start:p.error('end must be greater than start and inside source duration')
    ranges=retained_ranges(a.start,end,json.loads(a.cuts_json),a.speed,a.preview_duration)
    out_duration=sum(b-a for a,b in ranges)/a.speed
    if a.aspect=='original':
        a.padding=0;a.radius=0;a.no_shadow=True
        a.background_image=None
        a.width=v['width'] if a.preview_duration is None else min(a.width,v['width'])
        a.height=round(a.width*v['height']/v['width'])
    w=a.width//2*2
    ratio=v['width']/v['height'] if a.aspect in ('source','original') else float(a.aspect.split(':')[0])/float(a.aspect.split(':')[1])
    h=(a.height or round(w/ratio))//2*2
    availw,availh=w-2*a.padding,h-2*a.padding
    if min(availw,availh)<32:p.error('padding leaves no room for video')
    scale=min(availw/v['width'],availh/v['height']);cw=int(v['width']*scale)//2*2;ch=int(v['height']*scale)//2*2
    ox,oy=(w-cw)//2,(h-ch)//2
    source_events=read_events(json.loads(a.mouse.read_text())) if a.mouse else []
    events=retime_events(source_events,ranges,a.speed)
    clicks=[e for e in events if e['click']][:80]
    if len(events)>800:events=events[::math.ceil(len(events)/800)]
    scenes=validate_scenes(json.loads(a.zoom_scenes_json),duration) if a.zoom_scenes_json is not None else auto_scenes(source_events,duration,a.zoom,a.zoom_duration)
    frames=camera_frames(scenes,ranges,a.speed,a.fps,out_duration) if scenes and a.zoom>1 else []
    zx=expression([f[0] for f in frames]);cx=expression([f[1] for f in frames]);cy=expression([f[2] for f in frames])
    def position(axis,time='t'):
        def branch(lo,hi):
            if lo==hi:return f'{events[lo][axis]:.6f}'
            mid=(lo+hi+1)//2
            return f'if(lt({time},{events[mid]["t"]:.4f}),{branch(lo,mid-1)},{branch(mid,hi)})'
        return branch(0,len(events)-1) if events else '0.5'
    event(phase='preparing', progress=0)
    with tempfile.TemporaryDirectory(prefix='openscreen-export-') as temp:
        tmp=Path(temp);colors=a.background.split(',')
        try:rgb=[tuple(bytes.fromhex(c.lstrip('#'))) for c in colors];assert len(rgb)==2 and all(len(c)==3 for c in rgb)
        except Exception:p.error('background must be two #RRGGBB colors')
        direct_canvas = a.aspect == 'original'
        cmd=[a.ffmpeg,'-hide_banner','-y','-i',str(a.input)]
        if not direct_canvas:
            # A smooth gradient does not require a full output-resolution bitmap.
            png(tmp/'bg.png',256,256,lambda x,y:tuple(round(rgb[0][k]*(1-(x/256+y/256)/2)+rgb[1][k]*(x/256+y/256)/2) for k in range(3))+(255,))
            cmd+=['-loop','1','-framerate',str(a.fps),'-i',str(a.background_image or tmp/'bg.png')]
        idx=1 if direct_canvas else 2
        subtitle_path=a.captions
        if a.captions and not a.captions_output_timeline:
            def srt_seconds(value):
                hours,minutes,seconds=value.replace(',', '.').split(':')
                return int(hours)*3600+int(minutes)*60+float(seconds)
            def srt_time(value):
                value=max(0,round(value*1000));hours,value=divmod(value,3600000);minutes,value=divmod(value,60000);seconds,milliseconds=divmod(value,1000)
                return f'{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}'
            rewritten=[]
            for block in re.split(r'\n\s*\n',a.captions.read_text(encoding='utf-8-sig').replace('\r\n','\n').strip()):
                lines=block.splitlines();timing=next((n for n,line in enumerate(lines) if '-->' in line),None)
                if timing is None:continue
                begin,finish=lines[timing].split('-->',1);begin=srt_seconds(begin.strip());finish=srt_seconds(finish.strip().split()[0])
                elapsed=0
                for left,right in ranges:
                    lo,hi=max(left,begin),min(right,finish)
                    if hi>lo:rewritten.append(f'{len(rewritten)+1}\n{srt_time((elapsed+lo-left)/a.speed)} --> {srt_time((elapsed+hi-left)/a.speed)}\n'+'\n'.join(lines[timing+1:]))
                    elapsed+=right-left
            if rewritten:
                subtitle_path=tmp/'retimed.srt';subtitle_path.write_text('\n\n'.join(rewritten)+'\n')
            else:subtitle_path=None
        filters=montage_filter('0:v','v',ranges,a.speed,'screenJoin')
        filters.append(f'[screenJoin]fps={a.fps},scale={cw}:{ch}[screen0]')
        screen='screen0'
        if frames:
            filters.append(f"[{screen}]zoompan=z='{zx}':x='iw*({cx})':y='ih*({cy})':d=1:s={cw}x{ch}:fps={a.fps}[zoomed]");screen='zoomed'
        r=min(a.radius,cw//2,ch//2)
        if r>0:
            # Only the corner pixels differ; build a static alpha mask once.
            def mask_pixel(x,y):
                dx=max(r-x,0)+max(x-(cw-r-1),0)
                dy=max(r-y,0)+max(y-(ch-r-1),0)
                alpha=255 if dx*dx+dy*dy<=r*r else 0
                return (255,255,255,alpha)
            opaque=b'\xff\xff\xff\xff'
            rows=[]
            for y in range(ch):
                if r<=y<ch-r: row=opaque*cw
                else: row=b''.join(bytes(mask_pixel(x,y)) for x in range(r))+opaque*(cw-2*r)+b''.join(bytes(mask_pixel(x,y)) for x in range(cw-r,cw))
                rows.append(b'\0'+row)
            png_raw(tmp/'mask.png',cw,ch,b''.join(rows))
            cmd+=['-loop','1','-framerate',str(a.fps),'-i',str(tmp/'mask.png')]
            filters.append(f'[{idx}:v]alphaextract[mask]');idx+=1
            filters.append(f'[{screen}][mask]alphamerge=shortest=1[rounded]');screen='rounded'
        if direct_canvas:
            last=screen
        else:
            filters.append(f'[1:v]scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},setpts=PTS-STARTPTS'+('' if a.no_shadow else f',drawbox=x={ox+12}:y={oy+16}:w={cw}:h={ch}:color=black@0.28:t=fill')+'[bg]')
            filters.append(f'[bg][{screen}]overlay=x={ox}:y={oy}:shortest=1[composite]');last='composite'
        def displayed(axis):
            coordinate=position(axis)
            if not frames:return coordinate
            zoom=zx.replace('on',f'(t*{a.fps})');crop=(cx if axis=='x' else cy).replace('on',f'(t*{a.fps})')
            return f'(({coordinate})-({crop}))*({zoom})'
        if events and a.cursor_size>0:
            size=a.cursor_size
            png(tmp/'cursor.png',size,size,lambda x,y:(255,255,255,255 if (x-size/2)**2+(y-size/2)**2<(size/2-1)**2 else 0))
            cmd+=['-loop','1','-framerate',str(a.fps),'-i',str(tmp/'cursor.png')]
            filters.append(f"[{last}][{idx}:v]overlay=x='{ox}+{cw}*({displayed('x')})-{size/2}':y='{oy}+{ch}*({displayed('y')})-{size/2}':shortest=1[cursor]");last='cursor';idx+=1
        if clicks and not a.no_clicks:
            png(tmp/'ring.png',64,64,lambda x,y:(255,209,69,220 if 24**2<(x-32)**2+(y-32)**2<29**2 else 0))
            cmd+=['-loop','1','-framerate',str(a.fps),'-i',str(tmp/'ring.png')]
            enables='+'.join(f'between(t,{e["t"]:.4f},{e["t"]+.32:.4f})' for e in clicks)
            filters.append(f"[{last}][{idx}:v]overlay=x='{ox}+{cw}*({displayed('x')})-32':y='{oy}+{ch}*({displayed('y')})-32':enable='{enables}':shortest=1[clicks]");last='clicks';idx+=1
        if a.webcam:
            cmd+=['-i',str(a.webcam)]
            filters+=montage_filter(f'{idx}:v','v',ranges,a.speed,'camJoin')
            filters.append(f'[camJoin]scale={max(64,w//5//2*2)}:-2[cam]')
            filters.append(f'[{last}][cam]overlay=x=W-w-32:y=H-h-32:eof_action=pass[webcam]');last='webcam';idx+=1
        if subtitle_path and native_subtitles:
            escaped=str(subtitle_path.resolve()).replace('\\','\\\\').replace(':','\\:').replace("'","\\'")
            filters.append(f"[{last}]subtitles=filename='{escaped}'[captioned]");last='captioned'
        if subtitle_path and not native_subtitles:
            def timestamp(value):
                hours,minutes,seconds=value.replace(',', '.').split(':')
                return int(hours)*3600+int(minutes)*60+float(seconds)
            cues=[]
            for block in re.split(r'\n\s*\n',subtitle_path.read_text(encoding='utf-8-sig').replace('\r\n','\n').strip()):
                lines=block.splitlines()
                timing=next((n for n,line in enumerate(lines) if '-->' in line),None)
                if timing is None:continue
                start,endtime=lines[timing].split('-->',1)
                start=timestamp(start.strip());endtime=timestamp(endtime.strip().split()[0])
                text=re.sub(r'<[^>]+>','', '\n'.join(lines[timing+1:]))
                if text and endtime>start and start<out_duration:
                    cues.append({'text':text,'start':max(0,start),'end':min(out_duration,endtime),'path':str(tmp/f'caption-{len(cues)}.png')})
            manifest=tmp/'captions.json';manifest.write_text(json.dumps(cues))
            subtitle_height=max(100,h//4)
            renderer=[str(a.subtitle_renderer)] if a.subtitle_renderer else ['swift',str(Path(__file__).with_name('subtitles.swift'))]
            subprocess.run(renderer+[str(manifest),str(w),str(subtitle_height)],check=True)
            for n,cue in enumerate(cues):
                cmd+=['-loop','1','-framerate',str(a.fps),'-i',cue['path']]
                label=f'caption{n}'
                filters.append(f"[{last}][{idx}:v]overlay=x=0:y=H-h-24:enable='between(t,{cue['start']},{cue['end']})':shortest=1[{label}]")
                last=label;idx+=1
        hasaudio=not a.mute and a.output.suffix.lower()!='.gif' and (a.music is not None or any(s['codec_type']=='audio' for s in info['streams']))
        if hasaudio:
            speed=a.speed;tempos=[]
            while speed>2:tempos.append('atempo=2');speed/=2
            while speed<.5:tempos.append('atempo=0.5');speed/=.5
            tempos.append(f'atempo={speed}')
            audio_streams=[s for s in info['streams'] if s['codec_type']=='audio']
            labels=[]
            for n,stream in enumerate(audio_streams):
                label=f'audio{n}';labels.append(label)
                filters+=montage_filter(f'0:{stream["index"]}','a',ranges,a.speed,label+'Join')
                filters.append(f'[{label}Join]'+','.join(tempos)+(',afftdn=nf=-25' if a.denoise else '')+f'[{label}]')
            if a.music:
                music_info=probe(a.ffmpeg,a.music)
                if not any(s['codec_type']=='audio' for s in music_info['streams']):p.error('music file contains no audio stream')
                cmd+=['-stream_loop','-1','-i',str(a.music)]
                filters.append(f'[{idx}:a]atrim=duration={out_duration},asetpts=PTS-STARTPTS,volume={a.music_volume}[music]');labels.append('music');idx+=1
            filters.append(''.join(f'[{label}]' for label in labels)+f'amix=inputs={len(labels)}:duration=longest:normalize=0,alimiter=limit=0.95[audio]')
        if a.output.suffix.lower()=='.gif':
            filters.append(f'[{last}]split[palettein][gifin]');filters.append('[palettein]palettegen[palette]');filters.append('[gifin][palette]paletteuse[final]');last='final'
        a.output.parent.mkdir(parents=True,exist_ok=True)
        script=tmp/'filters.txt';script.write_text(';\n'.join(filters))
        cmd+=['-filter_complex_script',str(script),'-map',f'[{last}]']
        if hasaudio and a.output.suffix.lower()!='.gif':cmd+=['-map','[audio]','-c:a','aac','-b:a','192k']
        if a.output.suffix.lower()!='.gif':
            cmd+=['-c:v',a.encoder]
            cmd+=['-preset','medium','-crf',str(a.quality)] if a.encoder=='libx264' else ['-allow_sw','1','-b:v','0','-q:v',str(max(1,min(100,100-a.quality*2)))]
            cmd+=['-pix_fmt','yuv420p','-movflags','+faststart']
        partial=a.output.with_name('.'+a.output.stem+'-'+uuid.uuid4().hex+'.partial'+a.output.suffix)
        cmd+=['-progress','pipe:1','-nostats','-loglevel','warning','-t',str(out_duration),str(partial)]
        try:
            run(cmd,out_duration)
            summary=probe(a.ffmpeg,partial)
            if not any(s['codec_type']=='video' for s in summary['streams']):raise RuntimeError('导出文件没有视频轨道')
            os.replace(partial,a.output)
        finally:
            partial.unlink(missing_ok=True)
        event(phase='completed', progress=1)
        print(json.dumps({'output':str(a.output.resolve()),'duration':summary['format'].get('duration'),'dimensions':[w,h],'mouse_events':len(events),'clicks':len(clicks)},ensure_ascii=False))
if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:
        event(phase='cancelled'); raise SystemExit(130)
    except (ValueError,RuntimeError,FileNotFoundError,subprocess.CalledProcessError) as exc:raise SystemExit(str(exc))
