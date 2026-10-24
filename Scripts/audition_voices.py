#!/usr/bin/env python3
"""Generate three real, local Qwen3-TTS auditions of the same French passage."""
import os,json,time,pathlib,argparse
parser=argparse.ArgumentParser()
parser.add_argument('--memory-check',action='store_true',help='Profile bounded-cache, chunked decoding separately from the three auditions')
args=parser.parse_args()
ROOT=pathlib.Path(__file__).resolve().parent.parent
os.environ.setdefault('HF_HOME',str(ROOT/'.build/hf-cache'))
os.environ.setdefault('XDG_CACHE_HOME',str(ROOT/'.build/cache'))
os.environ.setdefault('HF_HUB_DISABLE_TELEMETRY','1')
from huggingface_hub import snapshot_download
repo='mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit'
revision='f35faf19b0cc2160865af64ecf0f22f83d335135'
model_dir=ROOT/'.build/models/Qwen3-TTS-1.7B-CustomVoice-4bit'
print('Downloading pinned model locally…',flush=True)
snapshot_download(repo,revision=revision,local_dir=model_dir,allow_patterns=['*.json','*.txt','*.safetensors','speech_tokenizer/*'],max_workers=4)
print('Loading local inference engine…',flush=True)
import mlx.core as mx
if args.memory_check:
 mx.set_cache_limit(64 * 1024 * 1024)
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model
model=load_model(str(model_dir))
mx.clear_cache()
load_peak=mx.get_peak_memory()/1e9
text='La pluie venait de s’arrêter. Camille poussa doucement la porte du jardin. Une silhouette l’attendait près de la fontaine. « Tu es revenu ? » demanda-t-elle, sans oser y croire. L’homme sourit. « Je t’avais promis de retrouver le chemin. » Alors, pour la première fois depuis longtemps, elle se sentit chez elle.'
styles={
 '01-chaleureuse': 'Read in French as a warm, intimate audiobook narrator. Gentle emotional depth, fluid phrasing, unhurried natural pauses. Convey quiet wonder in the question, a reassuring smile in the reply, and warmth in the final sentence. Subtle acting, never exaggerated.',
 '02-sobre': 'Read in French with a natural, clear, understated delivery. Calm and conversational, neutral but alive. Respect punctuation and questions with subtle pitch variation. No theatrical acting, no exaggerated emotion, no sing-song delivery.',
 '03-theatrale': 'Perform in French as an expressive dramatic storyteller. Build suspense before the silhouette. Give the question genuine surprised disbelief, the reply a warm reassuring smile, and the final line a feeling of relief. Vary rhythm, pitch and intensity, with deliberate dramatic pauses. Speak clearly without shouting.'
}
folder=ROOT/('.build/memory-check' if args.memory_check else 'AudioDemos');folder.mkdir(exist_ok=True)
metadata={'model':repo,'revision':revision,'text':text,'speaker':'Ryan','language':'French','host':'Mac; not a measurement on iPhone','load_peak_memory_gb':load_peak,'stream':args.memory_check,'runs':[]}
if args.memory_check:
 styles={name:instruction for name,instruction in styles.items() if name=='01-chaleureuse'}
for name,instruct in styles.items():
 print('Generating '+name,flush=True)
 mx.random.seed(42)
 mx.reset_peak_memory()
 started=time.monotonic()
 chunks=[];rate=24000
 for result in model.generate_custom_voice(text=text,speaker='Ryan',language='French',instruct=instruct,max_tokens=1400,temperature=0.75,top_k=50,top_p=0.95,repetition_penalty=1.05,stream=args.memory_check,streaming_interval=1.5):
  chunks.append(np.array(result.audio));rate=result.sample_rate
 samples=np.concatenate(chunks)
 path=folder/(name+'.wav');sf.write(path,samples,rate,subtype='PCM_16')
 run={'file':path.name,'instruction':instruct,'seconds':len(samples)/rate,'generation_seconds':time.monotonic()-started,'peak_memory_gb':mx.get_peak_memory()/1e9,'active_memory_gb':mx.get_active_memory()/1e9}
 metadata['runs'].append(run)
 (folder/'auditions.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2))
 print(json.dumps(run,ensure_ascii=False),flush=True)
 mx.clear_cache()
print('All three auditions generated locally.',flush=True)
