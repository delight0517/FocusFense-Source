// @feature: youtube-hourly-budget — isolated extension-layer module.
// @reference: docs/YOUTUBE_HOURLY_BUDGET.md (reference-only, original code).
// Firefox background window loads core first through manifest.json.
{
  let queue=Promise.resolve();
  const receipts=new Map();
  chrome.runtime.onMessage.addListener((message,sender,reply)=>{
    if(message?.type!=='focusfense.youtubeBudget')return;
    let youtube=false;
    try{const u=new URL(sender.url);youtube=u.protocol==='https:'&&(u.hostname==='youtube.com'||u.hostname.endsWith('.youtube.com'))&&sender.frameId===0;}catch{}
    const options=sender.url===chrome.runtime.getURL('options.html')&&sender.id===chrome.runtime.id;
    if(!youtube&&!options){reply({ok:false,error:'invalid_sender'});return;}
    queue=queue.catch(()=>{}).then(async()=>{
      const now=Date.now();
      const data=await chrome.storage.local.get(['ffYoutubeBudgetConfig','ffYoutubeBudgetIntervals','ffFirefoxHourly10V1','ffYoutubeBudgetLastPlaybackAt','ffYoutubeKeywordBudgetConfig','ffYoutubeKeywordIntervals','ffYoutubeKeyword10V1','youtubeBudgetExemptions','focusfenseLocale']);
      let config=data.ffYoutubeBudgetConfig||{enabled:false,minutes:10};
      // @feature: firefox-hourly-budget — user requested recent60 minutes /10 minutes.
      // Apply once on deployment; later explicit option changes remain intact.
      if(!data.ffFirefoxHourly10V1){
        config={enabled:true,minutes:10,period:'hourly'};
        await chrome.storage.local.set({ffYoutubeBudgetConfig:config,ffFirefoxHourly10V1:now});
      }
      if(options&&message.config){
        const period=message.config.period||'hourly';
        if(!['daily','hourly'].includes(period)||typeof message.config.enabled!=='boolean'||!Number.isInteger(message.config.minutes)||message.config.minutes<1||message.config.minutes>(period==='daily'?1440:60))throw Error('invalid viewing allowance');
        config={enabled:message.config.enabled,minutes:message.config.minutes,period};
        await chrome.storage.local.set({ffYoutubeBudgetConfig:config});
      }
      let keywordConfig=data.ffYoutubeKeywordBudgetConfig||{enabled:false,minutes:10,keywords:['마인크래프트','minecraft','게임','gaming','game']};
      if(options&&message.keywordConfig){
        const k=message.keywordConfig;
        if(typeof k.enabled!=='boolean'||!Number.isInteger(k.minutes)||k.minutes<1||k.minutes>60||!Array.isArray(k.keywords)||k.keywords.length>50||k.keywords.some(v=>typeof v!=='string'||!v.trim()||v.length>80))throw Error('invalid keyword allowance');
        keywordConfig={enabled:k.enabled,minutes:k.minutes,keywords:[...new Set(k.keywords.map(v=>v.trim()))]};
        await chrome.storage.local.set({ffYoutubeKeywordBudgetConfig:keywordConfig,ffYoutubeKeyword10V1:now});
      }else if(!data.ffYoutubeKeyword10V1){
        await chrome.storage.local.set({ffYoutubeKeywordBudgetConfig:keywordConfig,ffYoutubeKeyword10V1:now});
      }
      const {protectionEnabled}=await chrome.storage.local.get({protectionEnabled:false});
      const enabled=config.enabled===true&&protectionEnabled===true;
      const keywordEnabled=keywordConfig.enabled===true&&protectionEnabled===true;
      const matches=FocusFenseYoutubeBudget.matchedKeywords(message.metadata,keywordConfig.keywords);
      let context={};
      // @incident: youtube-spa-stale-sender — sender.url retains the original document URL after SPA navigation.
      if(youtube){try{
        const tab=await chrome.tabs.get(sender.tab.id);
        const currentUrl=new URL(tab.url);
        if(currentUrl.protocol==='https:'&&(currentUrl.hostname==='youtube.com'||currentUrl.hostname.endsWith('.youtube.com'))){
          context={videoId:currentUrl.searchParams.get('v'),host:currentUrl.hostname};
        }
      }catch{} }
      const exemption=youtube?FocusFenseYoutubeBudget.matchedExemption(message.metadata,data.youtubeBudgetExemptions,context):null;
      const exempt=!!exemption;
      let elapsed=0,keywordElapsed=0;
      if(youtube){
        const key=sender.tab.id;
        const prev=receipts.get(key);
        if(prev&&prev.instance===message.instance&&message.seq>prev.seq&&!prev.exempt&&!exempt&&prev.videoId===message.metadata?.videoId){
          const duration=Math.min(Number(message.elapsedMs)||0,now-prev.at,5000);
          if(enabled)elapsed=duration;
          if(keywordEnabled&&matches.length&&prev.matched&&prev.videoId===message.metadata?.videoId)keywordElapsed=duration;
        }
        receipts.set(key,{at:now,seq:message.seq,instance:message.instance,matched:matches.length>0,videoId:message.metadata?.videoId,exempt});
      }
      const period=config.period||'hourly';
      const state=FocusFenseYoutubeBudget.update(data.ffYoutubeBudgetIntervals||[],now,elapsed,config.minutes,period);
      const lastPlaybackAt=elapsed>0?now:data.ffYoutubeBudgetLastPlaybackAt||null;
      const keywordState=FocusFenseYoutubeBudget.update(data.ffYoutubeKeywordIntervals||[],now,keywordElapsed,keywordConfig.minutes,'hourly');
      const keywordBlocked=!exempt&&keywordEnabled&&matches.length>0&&keywordState.blocked;
      const totalBlocked=!exempt&&enabled&&state.blocked;
      const relevant=[...(totalBlocked?[state]:[]),...(keywordBlocked?[keywordState]:[])];
      const nextAvailableAt=relevant.length?Math.max(...relevant.map(s=>s.nextAvailableAt||now)):null;
      const fullyRestoredAt=relevant.length?Math.max(...relevant.map(s=>s.fullyRestoredAt||now)):null;
      const requestedLocale=String(data.focusfenseLocale||'en').toLowerCase().split(/[-_]/)[0];
      const locale=['en','ja','zh','ko','he','ar'].includes(requestedLocale)?requestedLocale:'en';
      await chrome.storage.local.set({ffYoutubeBudgetIntervals:state.intervals,ffYoutubeBudgetLastPlaybackAt:lastPlaybackAt,ffYoutubeKeywordIntervals:keywordState.intervals});
      reply({ok:true,locale,nextAvailableAt,fullyRestoredAt,enabled,config,usedMs:state.usedMs,remainingMs:state.remainingMs,exempt,exemption,blocked:(!exempt&&enabled&&state.blocked)||keywordBlocked,blockedBy:!exempt&&enabled&&state.blocked?'total':keywordBlocked?'keyword':null,keywordConfig,keywordEnabled,keywordUsedMs:keywordState.usedMs,keywordRemainingMs:keywordState.remainingMs,matchedKeywords:matches,metadataAvailable:message.metadata?.verified===true,scope:'browser-profile',period,resetAt:state.resetAt,lastPlaybackAt,observedSince:data.ffFirefoxHourly10V1||now,windowMinutes:period==='daily'?null:60});
    }).catch(e=>reply({ok:false,error:String(e.message)}));
    return true;
  });
  chrome.tabs.onRemoved.addListener(id=>receipts.delete(id));
}
