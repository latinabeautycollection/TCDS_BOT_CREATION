#!/usr/bin/env python3
import argparse,fcntl,json,os,socket,sys,time,uuid
from pathlib import Path
def main():
 a=argparse.ArgumentParser();a.add_argument('--root',required=True,type=Path);a.add_argument('--max-queue-bytes',type=int,default=2147483648);a.add_argument('--max-event-bytes',type=int,default=1048576);x=a.parse_args();r=x.root.resolve(strict=True);raw=sys.stdin.buffer.read(x.max_event_bytes+1)
 if len(raw)>x.max_event_bytes:raise SystemExit(19)
 e=json.loads(raw);e.setdefault('eventId',str(uuid.uuid4()));e.setdefault('receivedAtUtc',time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()));e.setdefault('host',socket.gethostname());q=r/'logs/telemetry/spool';q.mkdir(parents=True,exist_ok=True,mode=0o750);total=sum(p.stat().st_size for p in q.glob('*.jsonl'))
 m=r/'logs/telemetry/metrics.prom';m.parent.mkdir(parents=True,exist_ok=True)
 if total>=x.max_queue_bytes:
  d=r/'logs/telemetry/dead-letter';d.mkdir(parents=True,exist_ok=True,mode=0o750);p=d/(str(uuid.uuid4())+'.json');p.write_bytes(raw);os.chmod(p,0o640);m.write_text('tcds_telemetry_dropped_total 1\n');raise SystemExit(20)
 b=time.strftime('%Y%m%dT%H',time.gmtime());p=q/(b+'.jsonl');l=r/'state/locks'/('telemetry-'+b+'.lock');l.parent.mkdir(parents=True,exist_ok=True);fd=os.open(l,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o640)
 try:
  fcntl.flock(fd,fcntl.LOCK_EX);o=os.open(p,os.O_APPEND|os.O_CREAT|os.O_WRONLY|os.O_NOFOLLOW,0o640);os.write(o,(json.dumps(e,separators=(',',':'))+'\n').encode());os.close(o)
 finally:os.close(fd)
 m.write_text(f'tcds_telemetry_queue_bytes {total+len(raw)}\ntcds_telemetry_dropped_total 0\n');os.chmod(m,0o640);print(json.dumps({'status':'QUEUED','eventId':e['eventId']}))
if __name__=='__main__':main()
