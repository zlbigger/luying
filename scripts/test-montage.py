"""Verify cuts, captions, audio, webcam and zoom using only bundled tools."""
import pathlib,sys,tempfile,subprocess,json,atexit,shutil,struct,math
app=pathlib.Path(sys.argv[1]).resolve();tools=app/'Contents/Resources/Tools'
tmp=pathlib.Path(tempfile.mkdtemp(prefix='luying-montage-'));atexit.register(shutil.rmtree,tmp)
env={'PATH':'/usr/bin:/bin'};ff=str(tools/'ffmpeg');fp=str(tools/'ffprobe');ex=str(tools/'exporter/exporter')
subprocess.run([ff,'-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=red:s=320x180:r=30:d=2','-f','lavfi','-i','color=c=green:s=320x180:r=30:d=2','-f','lavfi','-i','color=c=blue:s=320x180:r=30:d=2','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2','-f','lavfi','-i','sine=frequency=880:sample_rate=48000:duration=2','-f','lavfi','-i','sine=frequency=220:sample_rate=48000:duration=2','-filter_complex','[0:v][3:a][1:v][4:a][2:v][5:a]concat=n=3:v=1:a=1[v][a]','-map','[v]','-map','[a]','-c:v','h264_videotoolbox','-allow_sw','1','-pix_fmt','yuv420p','-c:a','aac',str(tmp/'input.mp4')],check=True,env=env)
(tmp/'captions.srt').write_text('1\n00:00:02,000 --> 00:00:04,000\nCUT THIS\n\n2\n00:00:04,000 --> 00:00:06,000\n留下字幕 Keep\n')
(tmp/'trace.json').write_text(json.dumps({'events':[{'time':t,'x':.8,'y':.3,'kind':'click'} for t in [1,1.3,3,5]]}))
for speed,fmt in [(1,'mp4'),(2,'mp4'),(1,'gif')]:
 output=tmp/f'out-{speed}.{fmt}'
 command=[ex,str(tmp/'input.mp4'),str(output),'--ffmpeg',ff,'--subtitle-renderer',str(tools/'subtitles'),'--encoder','h264_videotoolbox','--width','320','--padding','16','--fps','30','--speed',str(speed),'--cuts-json','[{"start":2,"end":4}]','--captions',str(tmp/'captions.srt'),'--mouse',str(tmp/'trace.json'),'--webcam',str(tmp/'input.mp4'),'--denoise']
 result=subprocess.run(command,env=env,capture_output=True,text=True);assert result.returncode==0,result.stderr[-3000:]
 info=json.loads(subprocess.check_output([fp,'-v','error','-show_format','-show_streams','-of','json',str(output)],env=env))
 assert abs(float(info['format']['duration'])-4/speed)<.12,info
 summary=json.loads(result.stdout.splitlines()[-1]);assert summary['clicks']==3,summary
 for t,color in [(.5/speed,'red'),(2.5/speed,'blue')]:
  raw=subprocess.check_output([ff,'-v','error','-ss',str(t),'-i',str(output),'-vf','crop=1:1:160:50,format=rgb24','-frames:v','1','-f','rawvideo','-'],env=env)
  assert len(raw)==3
  assert raw[0]>raw[2]+80 if color=='red' else raw[2]>raw[0]+80,(color,list(raw))
 if fmt=='mp4':
  assert any(s['codec_type']=='audio' for s in info['streams'])
  for center,expected in [(0.8/speed,440),(2.8/speed,220)]:
   raw=subprocess.check_output([ff,'-v','error','-ss',str(center),'-i',str(output),'-t','0.1','-vn','-ac','1','-ar','8000','-f','f32le','-'],env=env)
   values=struct.unpack('<'+str(len(raw)//4)+'f',raw)
   def energy(hz):return sum(v*math.cos(2*math.pi*hz*n/8000) for n,v in enumerate(values))**2+sum(v*math.sin(2*math.pi*hz*n/8000) for n,v in enumerate(values))**2
   selfreq=max([220,440,880],key=energy);assert selfreq==expected,(center,expected,selfreq)
 print('PASS montage',fmt,'speed',speed,'duration, deleted clicks, colors and compositing')
# Explicit editable zoom plan and retained-duration preview.
result=subprocess.run([ex,str(tmp/'input.mp4'),str(tmp/'preview.mp4'),'--ffmpeg',ff,'--subtitle-renderer',str(tools/'subtitles'),'--encoder','h264_videotoolbox','--width','320','--padding','16','--fps','30','--cuts-json','[{"start":2,"end":4}]','--preview-duration','2.5','--zoom-scenes-json','[{"start":0.5,"end":1.7,"x":0.7,"y":0.3,"factor":2}]'],env=env,capture_output=True,text=True)
assert result.returncode==0,result.stderr[-2000:]
info=json.loads(subprocess.check_output([fp,'-v','error','-show_format','-of','json',str(tmp/'preview.mp4')],env=env));assert abs(float(info['format']['duration'])-2.5)<.1,info
print('PASS explicit zoom plan and preview across cuts')

(tmp/'deleted-only.srt').write_text('1\n00:00:02,000 --> 00:00:04,000\nRemoved caption\n')
command=[ex,str(tmp/'input.mp4'),str(tmp/'no-captions.mp4'),'--ffmpeg',ff,'--subtitle-renderer',str(tools/'subtitles'),'--encoder','h264_videotoolbox','--width','320','--padding','16','--cuts-json','[{"start":2,"end":4}]','--captions',str(tmp/'deleted-only.srt')]
result=subprocess.run(command,env=env,capture_output=True,text=True);assert result.returncode==0,result.stderr[-1000:]
print('PASS all captions deleted does not block export')
