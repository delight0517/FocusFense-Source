// @feature: youtube-hourly-budget
// @reference: LeechBlockNG (MPL-2.0), hourly allowance concept only; no copied code.
// @implementation: original FocusFense rolling-window interval accounting.
(function(root) {
  'use strict';
  const WINDOW = 3600000;
  function dayStart(now) {
    const date=new Date(now);
    return new Date(date.getFullYear(),date.getMonth(),date.getDate()).getTime();
  }
  function nextDay(now) {
    const date=new Date(now);
    return new Date(date.getFullYear(),date.getMonth(),date.getDate()+1).getTime();
  }
  function merge(intervals, now, cutoff=now-WINDOW) {
    const sorted = intervals.filter(p => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite))
      .map(([a,b]) => [Math.max(cutoff,a),Math.min(now,b)])
      .filter(([a,b])=>b>a).sort((a,b)=>a[0]-b[0]);
    const out=[];
    for(const p of sorted){const last=out[out.length-1];if(last&&p[0]<=last[1])last[1]=Math.max(last[1],p[1]);else out.push(p);}
    return out;
  }
  function update(intervals, now, elapsedMs, minutes, period='hourly') {
    const duration=Number.isFinite(elapsedMs)?Math.max(0,Math.min(5000,elapsedMs)):0;
    const next=merge([...intervals,...(duration>0?[[now-duration,now]]:[])],now,period==='daily'?dayStart(now):now-WINDOW);
    const usedMs=next.reduce((sum,[a,b])=>sum+b-a,0);
    const limitMs=(Number.isFinite(minutes)?Math.max(1,Math.min(period==='daily'?1440:60,minutes)):60)*60000;
    const blocked=usedMs>=limitMs;
    let nextAvailableAt=null;
    if(blocked){
      if(period==='daily')nextAvailableAt=nextDay(now);
      else {
        // Regain one usable second, not a misleading full-window reset.
        let toExpire=usedMs-limitMs+1000;
        for(const [a,b] of next){
          if(toExpire<=b-a){nextAvailableAt=a+toExpire+WINDOW;break;}
          toExpire-=b-a;
        }
      }
    }
    const fullyRestoredAt=next.length?(period==='daily'?nextDay(now):next[next.length-1][1]+WINDOW):null;
    return {intervals:next,usedMs,limitMs,remainingMs:Math.max(0,limitMs-usedMs),blocked,period,resetAt:period==='daily'?nextDay(now):null,nextAvailableAt,fullyRestoredAt};
  }
  // Media position validates playback, while wall time charges the budget.
  // Seeking, buffering, paused media and suspended-page gaps do not count.
  function playbackMs(previous,current) {
    if(!previous||!previous.playing||!current.playing||previous.video!==current.video)return 0;
    const wall=current.wall-previous.wall,media=current.position-previous.position;
    if(!(wall>0&&wall<=5000)||previous.rate!==current.rate)return 0;
    const expected=wall/1000*current.rate;
    return media>0&&Math.abs(media-expected)<=Math.max(.35,expected*.35)?wall:0;
  }
  // @feature: youtube-keyword-budget — deterministic metadata matching, not AI genre inference.
  function matchedKeywords(metadata, keywords) {
    if(!metadata||metadata.verified!==true)return [];
    const text=[metadata.title,metadata.channel].map(v=>String(v||'').slice(0,1000).normalize('NFKC').toLowerCase()).join(' ');
    return keywords.filter(k=>String(k).trim()&&text.includes(String(k).normalize('NFKC').trim().toLowerCase()));
  }
  // Channel exemptions use only a verified current-video owner, never titles,
  // recommendation links or a channel merely mentioned in the page.
  function ownerIdentity(value) {
    try {
      const url=new URL(value,'https://www.youtube.com');
      if(url.protocol!=='https:'||!['youtube.com','www.youtube.com','m.youtube.com'].includes(url.hostname))return null;
      const parts=url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
      if(parts.length===1&&parts[0].startsWith('@')&&parts[0].length>1)return {channelHandle:parts[0].slice(1)};
      if(parts.length===2&&parts[0]==='channel'&&/^UC[A-Za-z0-9_-]{20,30}$/.test(parts[1]))return {channelId:parts[1]};
    }catch{}
    return null;
  }
  function canonicalHandle(value) {
    if(typeof value!=='string')return '';
    try{return decodeURIComponent(value).normalize('NFKC').replace(/^@/,'').trim().toLowerCase();}catch{return '';}
  }
  function matchedExemption(metadata, rules, context) {
    if(!metadata||metadata.verified!==true||typeof metadata.videoId!=='string'||!metadata.videoId||metadata.videoId!==context?.videoId||!Array.isArray(rules))return null;
    for(const rule of rules.slice(0,1000)) {
      if(!rule||typeof rule.value!=='string'||!rule.value||rule.value.length>2048)continue;
      let matches=false;
      if(rule.kind==='videoId')matches=rule.value===metadata.videoId;
      if(rule.kind==='channelHandle')matches=metadata.ownerVerified===true&&!!canonicalHandle(metadata.channelHandle)&&canonicalHandle(rule.value)===canonicalHandle(metadata.channelHandle);
      if(rule.kind==='channelId')matches=metadata.ownerVerified===true&&typeof metadata.channelId==='string'&&!!metadata.channelId&&rule.value===metadata.channelId;
      if(rule.kind==='domain'){
        const domain=rule.value.toLowerCase().replace(/\.$/,'');
        const host=String(context.host||'').toLowerCase();
        matches=/^[a-z0-9.-]+$/.test(domain)&&!!domain&&(host===domain||host.endsWith('.'+domain));
      }
      if(matches)return {kind:rule.kind,value:rule.value};
    }
    return null;
  }
  root.FocusFenseYoutubeBudget={merge,update,playbackMs,dayStart,nextDay,matchedKeywords,ownerIdentity,canonicalHandle,matchedExemption};
})(globalThis);
