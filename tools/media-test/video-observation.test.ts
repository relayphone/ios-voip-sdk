import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessVideo, VideoObservation, hostVideoBoundary, type VideoSourceReceipt } from './video-observation.ts';
import { videoLuma, type VideoMarker } from './video-marker.ts';
const fixture='01234567-89ab-cdef-0123-456789abcdef';
function setup() {
  let now=0;const observer=new VideoObservation({fixture,direction:0,epoch:1,participant:'app',publication:'video'},()=>now);
  const source:VideoSourceReceipt={participant:'app',publication:'video',clockID:'native',generated:[],pacingTaskJoined:true,postStopCaptureRejects:1,skippedTicks:0,rejectedSubmissions:0};
  const frame=(counter:number,time=now*1000)=>{const marker:VideoMarker={fixture,direction:0,epoch:1,counter,sourceTimeUs:time};source.generated.push(marker);const bytes=new Uint8Array(160*120*3/2).fill(128);bytes.set(videoLuma(marker));observer.receive(bytes,160,120,BigInt(time));};
  for(let i=0;i<25;i++){now=i*100;observer.tick();frame(i);}
  now=2500;observer.tick();source.stoppedAtUs=2500000;source.finalCounter=24;source.finalEpoch=1;observer.record('unpublished');
  for(let i=26;i<=34;i++){now=i*100;observer.tick();}
  const options={participant:'app',publication:'video',nativeAnchorMs:0,nativeBoundaryMs:2500,bracket:{clockID:'native',hostClockID:observer.clockID,nativeMs:0,sentMs:0,receivedMs:0},terminal:{clockID:'native',hostClockID:observer.clockID,nativeMs:2500,sentMs:2500,receivedMs:2500}};
  return {observer,source,options,frame,setTime:(t:number)=>{now=t;}};
}
test('real pixel observations require advancing identities, whole windows, clock brackets and lifecycle', () => {
  const f=setup(),r=assessVideo(f.observer.receipt(),f.source,f.options);
  assert.equal(r.onPassed,true);assert.equal(r.offPassed,true);assert.deepEqual(r.windows,[10,10]);
  assert.deepEqual(hostVideoBoundary(100,{clockID:'native',hostClockID:'host',nativeMs:110,sentMs:200,receivedMs:240}),{earliest:190,latest:230});
  assert.throws(()=>assessVideo(f.observer.receipt(),f.source,{...f.options,publication:'foreign'}));
  assert.throws(()=>assessVideo(f.observer.receipt(),f.source,{...f.options,bracket:{...f.options.bracket,hostClockID:'foreign'}}));
  assert.throws(()=>assessVideo(f.observer.receipt(),{...f.source,clockID:'foreign'},f.options));
});
test('duplicates and content-free callbacks never repair a frozen stream', () => {
  const f=setup(),receipt=f.observer.receipt();receipt.arrivals=Array.from({length:25},(_,i)=>({...receipt.arrivals[0]!,atMs:i*100}));
  const r=assessVideo(receipt,f.source,f.options);assert.equal(r.onPassed,false);assert.equal(r.duplicate,24);
  const blank=new Uint8Array(96).fill(128);blank.fill(0,0,64);f.observer.receive(blank,8,8,0n);
  assert.equal(assessVideo(f.observer.receipt(),f.source,f.options).contentFree,1);
});
test('post-boundary source, unreadable real image and missed observer coverage fail', () => {
  const f=setup();f.frame(25,2600000);const late=assessVideo(f.observer.receipt(),f.source,f.options);
  assert.equal(late.offPassed,false);assert.equal(late.postBoundary,1);
  const corrupt=setup(),pixels=new Uint8Array(160*120*3/2).fill(128);pixels.set(videoLuma(corrupt.source.generated[0]!));pixels.fill(128,0,160*8);corrupt.observer.receive(pixels,160,120,0n);
  assert.equal(assessVideo(corrupt.observer.receipt(),corrupt.source,corrupt.options).offPassed,false);
  const missing=setup();missing.setTime(5000);assert.equal(assessVideo(missing.observer.receipt(),missing.source,missing.options).healthy,false);
  const lifecycle=setup(),receipt=lifecycle.observer.receipt();receipt.events=receipt.events.filter(e=>e.kind!=='unpublished');
  assert.equal(assessVideo(receipt,lifecycle.source,lifecycle.options).offPassed,false);
});
test('bounded rows preserve overflow and snapshots cannot mutate the recorder', () => {
  const f=setup(),before=f.observer.receipt();for(let i=0;i<4097;i++)f.observer.tick();
  assert.equal(before.overflow,false);assert.equal(f.observer.receipt().overflow,true);
  before.scope.epoch=2;assert.equal(f.observer.scope.epoch,1);
  assert.equal(assessVideo(f.observer.receipt(),f.source,f.options).onPassed,false);
});

test('confirmed terminal time cannot move to later source stop or a caller-supplied foreign ledger', () => {
  const f=setup();f.source.stoppedAtUs=3000000;
  f.source.generated.push({...f.source.generated.at(-1)!,counter:25,sourceTimeUs:2600000});f.source.finalCounter=25;
  const r=assessVideo(f.observer.receipt(),f.source,{...f.options,terminal:{...f.options.terminal,nativeMs:3000,sentMs:3000,receivedMs:3000}});
  assert.equal(r.offPassed,false);assert.equal(r.sourceStopLagMs,500);
  assert.throws(()=>assessVideo(f.observer.receipt(),{...f.source,publication:'other'},f.options));
  assert.throws(()=>assessVideo(f.observer.receipt(),f.source,{...f.options,nativeBoundaryMs:undefined}));
});
test('wrong epoch, low-rate windows and a long freeze cannot qualify', () => {
  const foreign=setup(),marker={...foreign.source.generated[0]!,epoch:2};
  const bytes=new Uint8Array(160*120*3/2).fill(128);bytes.set(videoLuma(marker));foreign.observer.receive(bytes,160,120,0n);
  assert.equal(assessVideo(foreign.observer.receipt(),foreign.source,foreign.options).foreign,1);
  const low=setup(),sparse=low.observer.receipt();sparse.arrivals=sparse.arrivals.filter((_,i)=>i%5===0);
  assert.equal(assessVideo(sparse,low.source,low.options).onPassed,false);
  const frozen=setup(),receipt=frozen.observer.receipt(),times=[0,100,200,1900,1950,1990];
  receipt.arrivals=times.map((atMs,i)=>({...receipt.arrivals[i]!,atMs}));
  const result=assessVideo(receipt,frozen.source,frozen.options);
  assert.deepEqual(result.windows,[3,3]);assert.ok(result.gapMs>1600);assert.equal(result.onPassed,false);
});
