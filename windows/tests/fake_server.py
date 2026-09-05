import json
import sys
initialized=False
for line in sys.stdin:
    msg=json.loads(line)
    method=msg.get('method')
    if method=='initialized':
        initialized=True
        continue
    if method=='timeout':
        continue
    result={}
    if method=='account/rateLimits/read':
        assert initialized
        result={'accountId':'fake','rateLimits':{'primary':{'usedPercent':20,
            'windowDurationMins':300,'resetsAt':1900000000}}}
    print(json.dumps({'id':msg['id'],'result':result}),flush=True)
