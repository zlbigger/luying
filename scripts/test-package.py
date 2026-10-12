import pathlib,subprocess,os,json,time,signal,hashlib,sys,tempfile,atexit,shutil
app=pathlib.Path(sys.argv[1]).resolve()
tools=app/'Contents/Resources/Tools';tmp=pathlib.Path(tempfile.mkdtemp(prefix='luying-package-test-'));atexit.register(shutil.rmtree,tmp)
env={'PATH':'/usr/bin:/bin','HOME':str(pathlib.Path.home())}
ff=str(tools/'ffmpeg');probe=str(tools/'ffprobe');export=str(tools/'exporter/exporter')
subprocess.run([ff,'-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=15','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','3','-c:v','h264_videotoolbox','-allow_sw','1','-pix_fmt','yuv420p','-c:a','aac',str(tmp/'input.mp4')],env=env,check=True)
(tmp/'captions.srt').write_text('1\n00:00:00,000 --> 00:00:02,500\n录映字幕测试 Test\n')
(tmp/'mouse.json').write_text(json.dumps({'events':[{'time':i/300,'x':.4,'y':.5,'kind':'click' if i==200 else 'move'} for i in range(800)]}))
common=[export,str(tmp/'input.mp4'),'OUTPUT','--ffmpeg',ff,'--subtitle-renderer',str(tools/'subtitles'),'--encoder','h264_videotoolbox','--width','320','--fps','15','--padding','16']
for fmt in ['mp4','gif']:
 args=common.copy();args[2]=str(tmp/('output.'+fmt));args+=['--start','.25','--end','2.75','--speed','2','--mouse',str(tmp/'mouse.json'),'--captions',str(tmp/'captions.srt'),'--webcam',str(tmp/'input.mp4'),'--denoise']
 result=subprocess.run(args,env=env,capture_output=True,text=True)
 assert result.returncode==0,result.stderr[-2000:]
 events=[json.loads(x) for x in result.stdout.splitlines() if x.startswith('{')]
 assert any(x.get('phase')=='encoding' for x in events),events
 assert any(x.get('phase')=='completed' for x in events),events
 data=json.loads(subprocess.check_output([probe,'-v','error','-show_format','-show_streams','-of','json',args[2]],env=env))
 assert abs(float(data['format']['duration'])-1.25)<.2,data
 print('PASS isolated package',fmt)
# Cancel while encoding: preserve an existing destination and remove partial output.
out=tmp/'preserved.mp4';out.write_bytes(b'old export stays');before=out.read_bytes()
args=common.copy();args[2]=str(out);args[args.index('--width')+1]='1920';args[args.index('--fps')+1]='60';args+=['--speed','.1']
child=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
for line in child.stdout:
 if '"phase": "encoding"' in line: child.send_signal(signal.SIGINT);break
assert child.wait(timeout=15)==130
assert out.read_bytes()==before
assert not list(tmp.glob('.*.partial*'))
print('PASS cancellation preserves destination and cleans partial file')
# Failed export also preserves the existing destination.
args=common.copy();args[1]=str(tmp/'missing.mov');args[2]=str(out)
assert subprocess.run(args,env=env,capture_output=True).returncode!=0
assert out.read_bytes()==before
print('PASS failure preserves destination')
