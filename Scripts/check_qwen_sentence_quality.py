import os, pathlib, json, time, types, gc, unicodedata, re
ROOT=pathlib.Path.cwd()
os.environ['HF_HOME']=str(ROOT/'.build/hf-cache')
os.environ['HF_HUB_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model
mx.set_cache_limit(64*1024*1024)
model=load_model(str(ROOT/'.build/models/Qwen3-TTS-1.7B-CustomVoice-4bit'))
# Match the app's current full-history penalty and independent residual-codebook settings.
def sample(self,logits,temperature=.9,top_k=50,top_p=1.,repetition_penalty=1.,generated_tokens=None,suppress_tokens=None,min_p=0.,**kwargs):
    logits=logits[:,-1,:].astype(mx.float32); main=bool(suppress_tokens)
    if not main: temperature=.9;top_k=50;top_p=1.;min_p=0.
    if suppress_tokens: logits=mx.put_along_axis(logits,mx.array(suppress_tokens)[None,:],mx.array(-float('inf')),axis=-1)
    if generated_tokens and repetition_penalty!=1.:
        ids=mx.array(sorted(set(generated_tokens)),dtype=mx.int32)[None,:]; vals=mx.take_along_axis(logits,ids,axis=-1)
        logits=mx.put_along_axis(logits,ids,mx.where(vals<0,vals*repetition_penalty,vals/repetition_penalty),axis=-1)
    logits=logits/temperature
    eos=self.config.talker_config.codec_eos_token_id
    if main: eos_logit=logits[:,eos:eos+1]
    if top_k>0:
        idx=mx.argpartition(-logits,kth=top_k-1,axis=-1)[:,top_k:]
        logits=mx.put_along_axis(logits,idx,mx.array(-float('inf')),axis=-1)
    if main and variant!='filtered-end': logits=mx.put_along_axis(logits,mx.array([[eos]]),eos_logit,axis=-1)
    return mx.random.categorical(logits).reshape(1,1)
model._sample_token=types.MethodType(sample,model)
folder=ROOT/'AudioDemos/QwenSentenceQualityValidation';folder.mkdir(exist_ok=True)
current=json.loads((ROOT/'AudioDemos/QwenShortTextValidation/report.json').read_text())['runs'][0]['instruction']
concise='Narration expressive en français, fluide et clairement articulée, avec un rythme naturel.'
cases=[('subtitle','Un récit de mystère médiéval.'),('morning','Le soleil venait de se lever sur le port.'),('scalpel','À l’aide de son scalpel de précision, il gratta la surface dont la texture n’était d’aucune.')]
rows=[]
for seed in [740,741]:
    for case,text in cases:
        for variant in ['current','filtered-end','concise']:
            mx.random.seed(seed);start=time.monotonic();chunks=[]
            for result in model.generate_custom_voice(text=text,speaker='Serena',language='French',instruct=concise if variant=='concise' else current,max_tokens=500,temperature=.9,top_k=50,top_p=1,repetition_penalty=1.05,stream=True,streaming_interval=1.5):
                chunks.append(np.asarray(result.audio))
            samples=np.concatenate(chunks); name=f'{case}-{seed}-{variant}.wav'; sf.write(folder/name,samples,24000,subtype='FLOAT')
            row=dict(file=name,case=case,seed=seed,variant=variant,text=text,seconds=len(samples)/24000,generationSeconds=time.monotonic()-start,hitLimit=len(samples)>=500*1920)
            rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
            (folder/'report.json').write_text(json.dumps(dict(scope='Mac Python approximation; identical model and sampling policy, not proof of iPhone or perceptual quality. Synthetic examples only. No audio autoplay.',runs=rows),ensure_ascii=False,indent=2)+'\n')
del model;gc.collect();mx.clear_cache()
from mlx_audio.stt.utils import load_model as load_stt
asr=load_stt('mlx-community/whisper-small-asr-fp16')
def words(text):
    text=unicodedata.normalize('NFKD',text.lower())
    return re.findall(r'[a-z0-9]+',''.join(x for x in text if not unicodedata.combining(x)))
def edits(expected,actual):
    prev=list(range(len(actual)+1))
    for i,a in enumerate(expected,1):
        curr=[i]
        for j,b in enumerate(actual,1): curr.append(min(curr[-1]+1,prev[j]+1,prev[j-1]+(a!=b)))
        prev=curr
    return prev[-1]
for row in rows:
    result=asr.generate(str(folder/row['file']),language='fr',temperature=0,condition_on_previous_text=False,return_timestamps=True,sample_len=120,verbose=None)
    segments=[s['text'] for s in result.segments if s['start']<row['seconds'] and s['text'].strip() not in ('','...')]
    row['asrText']=''.join(segments).strip(); target=words(row['text']);row['wordErrorRate']=edits(target,words(row['asrText']))/len(target)
    print(json.dumps(row,ensure_ascii=False),flush=True)
    (folder/'report.json').write_text(json.dumps(dict(scope='Automatic blind transcription is a diagnostic, not proof of complete articulation, accent or perceptual quality. Mac Python approximation of app sampling. No audio played.',runs=rows),ensure_ascii=False,indent=2)+'\n')
