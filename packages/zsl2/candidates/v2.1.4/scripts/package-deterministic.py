#!/usr/bin/env python3
from pathlib import Path
from zipfile import ZipFile,ZipInfo,ZIP_DEFLATED
import sys
root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd().resolve()
out=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else root.with_suffix('.zip')
files=[p for p in root.rglob('*') if p.is_file() and not any(x in p.parts for x in ('node_modules','dist','.git'))]
with ZipFile(out,'w',ZIP_DEFLATED,compresslevel=9) as z:
    for p in sorted(files,key=lambda x:x.relative_to(root).as_posix()):
        rel=(root.name+'/'+p.relative_to(root).as_posix())
        info=ZipInfo(rel,date_time=(1980,1,1,0,0,0));info.compress_type=ZIP_DEFLATED;info.external_attr=(0o100644<<16)
        z.writestr(info,p.read_bytes())
print(out)
