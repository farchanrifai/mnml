import json,time,socket,threading,subprocess,statistics,re,os
from pathlib import Path
app=subprocess.Popen(['/Applications/mnml Test.app/Contents/MacOS/mnml'],env={**os.environ,'MNML_PROBE':'copy','MNML_MEASURE':'1'},stdout=open('/tmp/mnml-sheets-qa/run4-app.log','w'),stderr=subprocess.STDOUT,start_new_session=True);Path('/tmp/mnml-sheets-qa/pid').write_text(str(app.pid));time.sleep(3)
OUT=Path('/tmp/mnml-sheets-qa/run4');OUT.mkdir(exist_ok=True);sock=str(Path.home()/'Library/Application Support/mnml (copy)/bench.sock');pid=int(Path('/tmp/mnml-sheets-qa/pid').read_text())
def call(verb,**kw):
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(40);s.connect(sock);s.sendall((json.dumps({'do':verb,**kw})+'\n').encode());raw=b''
  while b'\n' not in raw:
   x=s.recv(65536)
   if not x:raise RuntimeError('closed socket')
   raw+=x
 r=json.loads(raw.split(b'\n')[0]);assert 'error' not in r,(verb,r);return r
initial=call('tabs')['tabs'];original=next(t['id'] for t in initial if t['active']);baseids={t['id'] for t in initial};sheet=next(t['url'] for t in initial if 'docs.google.com/spreadsheets/' in t['url']);drive=next(t['url'] for t in initial if 'drive.google.com/' in t['url']);page='https://en.wikipedia.org/wiki/Japan';sidebar=call('probe')['sidebar'];created=[];phase='setup';stop=threading.Event();latencies={};resources=[];recoveries=[];result={'pid':pid,'initialTabs':len(initial),'memoryProfile':'balanced (default key absent)','levels':[],'loadChecks':[]}
def js(tab,source):return call('eval',id=tab,js=source)['value']
def ready(tab,kind):
 code='JSON.stringify({ready:document.readyState,grid:!!document.querySelector("#waffle-grid-container"),toolbar:!!document.querySelector("#docs-toolbar"),canvas:document.querySelectorAll("canvas").length,login:!!document.querySelector("input[type=email]"),hidden:document.hidden})'
 end=time.monotonic()+25
 while True:
  try:state=json.loads(js(tab,code))
  except Exception as e:
   if time.monotonic()>end:raise
   time.sleep(.5);continue
  loaded=state['grid'] and state['toolbar'] if kind=='sheets' else state['ready']=='complete'
  if loaded or time.monotonic()>end:state['loaded']=bool(loaded);return state
  time.sleep(.4)
def foreground():
 p=call('probe');return {k:p[k] for k in ['appActive','windowKey','windowVisible']}
def stats(v):return {'count':len(v),'medianMs':statistics.median(v),'p95Ms':sorted(v)[int((len(v)-1)*.95)],'maxMs':max(v),'over250ms':sum(x>250 for x in v)} if v else {}
def monitor():
 while not stop.is_set():
  p=phase;t=time.perf_counter()
  try:
   probe=call('probe')
   if not all(probe[k] for k in ['appActive','windowKey','windowVisible']):
    recoveries.append({'phase':p,'time':time.time()});call('windows',action='front',n=1);continue
  except Exception:break
  ms=(time.perf_counter()-t)*1000
  if phase==p:
   latencies.setdefault(p,[]).append(ms)
   if ms>250:print('SLOW',p,round(ms,2),time.time(),flush=True)
  time.sleep(.1)
threading.Thread(target=monitor,daemon=True).start()
def resource(name):
 global phase
 old=phase;phase='instrumentation';time.sleep(.2)
 tabs=call('tabs')['tabs'];ids={pid}|{t['process'] for t in tabs if t['process']>0}
 rows=subprocess.check_output(['ps','-axo','pid=,rss=,%cpu='],text=True);selected=[]
 for line in rows.splitlines():
  parts=line.split()
  if len(parts)==3 and int(parts[0]) in ids:selected.append({'pid':int(parts[0]),'rssMiB':int(parts[1])/1024,'cpuPercent':float(parts[2])})
 vm=subprocess.run(['vmmap','-summary',str(pid)],text=True,capture_output=True).stdout;(OUT/(name+'-app-vmmap.txt')).write_text(vm)
 m=re.search(r'Physical footprint:\s*(.*)',vm)
 res={'phase':name,'appPhysicalFootprint':m.group(1) if m else 'unavailable','processes':selected,'appAndKnownWebContentRSSMiB':sum(x['rssMiB'] for x in selected),'uniqueWebContentProcesses':len(ids)-1,'tabCount':len(tabs),'asleep':sum(t['asleep'] for t in tabs),'hollow':sum(t['hollow'] for t in tabs)};phase=old;return res
try:
 call('windows',action='front',n=1);assert all(foreground().values()),foreground();result['baseline']=resource('baseline')
 for target in [40]:
  phase=f'load-{target}'
  while len(created)<target:
   n=len(created);kind=['sheets','sheets','sheets','drive','page'][n%5];url={'sheets':sheet,'drive':drive,'page':page}[kind]
   before={t['id'] for t in call('tabs')['tabs']};start=time.perf_counter();call('windows',action='link',url=url);tabs=call('tabs')['tabs'];new=[t for t in tabs if t['id'] not in before];assert len(new)==1,new
   tab=new[0];created.append({'id':tab['id'],'kind':kind});(OUT/'created.json').write_text(json.dumps(created));state=ready(tab['id'],kind);result['loadChecks'].append({'n':n+1,'kind':kind,'seconds':time.perf_counter()-start,'state':state,'normalTab':not tab['bench']});print('OPEN',n+1,kind,state['loaded'],flush=True)
   if kind=='sheets' and not state['loaded']:raise RuntimeError('Sheets editor did not load')
  nativeSample=subprocess.Popen(['sample',str(pid),'110','5','-file',str(OUT/'sleep-sample.txt')],stdout=open(OUT/'sample.log','w'),stderr=subprocess.STDOUT);phase=f'idle-{target}';time.sleep(10);level={'addedTabs':target,'mix':{k:sum(t['kind']==k for t in created) for k in ['sheets','drive','page']},'foregroundBefore':foreground(),'memory':resource(f'level-{target}'),'switches':[]}
  phase=f'switch-{target}'
  for item in (created[:5]+created[-5:])*2:
   start=time.perf_counter();call('select',id=item['id']);level['switches'].append((time.perf_counter()-start)*1000);time.sleep(.15)
  level['switches']=stats(level['switches']);call('select',id=created[-3]['id']);call('windows',action='front',n=1)
  phase=f'ask-{target}';widths=[]
  for _ in range(8):
   call('press',code=14,chars='e',mods=['cmd']);p=call('probe');widths.append(p.get('activePageFrame',[0,0,0])[2]);time.sleep(.1)
  level['askPageWidths']=widths;result['levels'].append(level);(OUT/'results.json').write_text(json.dumps(result,indent=2))
  phase=f'sidebar-{target}'
  for n in range(12):call('ui',sidebar=n%2==0);time.sleep(.15)
  call('ui',sidebar=sidebar)
  phase=f'typing-{target}';call('windows',action='front',n=1);typed=call('field',text='sheets responsiveness',type=True);level['typing']=stats([x[1] for x in typed.get('ms',[])]);call('press',code=53,chars='\x1b',mods=[])
  level['foregroundAfter']=foreground();(OUT/'results.json').write_text(json.dumps(result,indent=2));print('LEVEL',target,json.dumps(level),flush=True)
 phase='soak-40';time.sleep(75);result['afterSoak']=resource('soak-40');print('SOAK',json.dumps(result['afterSoak']),flush=True)
 # Exercise ordinary sleep protections on an untouched background Sheet.
 victim=next(t for t in created if t['kind']=='sheets');result['sleep']=call('sleep',id=victim['id']);call('select',id=victim['id']);result['wake']=ready(victim['id'],'sheets');print('SLEEP',result['sleep'],'WAKE',result['wake'],flush=True)
except Exception as e:
 result['error']=str(e);print('ERROR',e,flush=True)
finally:
 phase='cleanup';call('ui',sidebar=sidebar);call('press',code=53,chars='\x1b',mods=[])
 for item in reversed(created):
  if item['id'] not in {t['id'] for t in call('tabs')['tabs']}:continue
  call('select',id=item['id']);call('press',code=13,chars='w',mods=['cmd'])
  if item['id'] in {t['id'] for t in call('tabs')['tabs']}:result.setdefault('cleanupErrors',[]).append(item['id']);break
 call('select',id=original);phase='settle';time.sleep(20);result['finalMemory']=resource('final');stop.set();result['appExitAtCompletion']=app.poll();result['focusRecoveries']=recoveries;result['latencies']={k:stats(v) for k,v in latencies.items() if k!='instrumentation'};result['remainingOriginalTabs']=len([t for t in call('tabs')['tabs'] if t['id'] in baseids]);result['remainingCreatedTabs']=len([t for t in call('tabs')['tabs'] if t['id'] not in baseids]);(OUT/'results.json').write_text(json.dumps(result,indent=2));print('DONE',result.get('error'),result['finalMemory'],flush=True)
