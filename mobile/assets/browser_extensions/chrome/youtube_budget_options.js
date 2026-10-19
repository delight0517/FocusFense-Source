// @feature: youtube-hourly-budget — local profile configuration, no history upload.
(()=>{
  const enabled=document.getElementById('ffBudgetEnabled'),minutes=document.getElementById('ffBudgetMinutes'),status=document.getElementById('ffBudgetStatus');
  const period=document.getElementById('ffBudgetPeriod');
  const keywordEnabled=document.getElementById('ffKeywordEnabled'),keywordMinutes=document.getElementById('ffKeywordMinutes'),keywordWords=document.getElementById('ffKeywordWords'),keywordStatus=document.getElementById('ffKeywordStatus');
  const request=config=>chrome.runtime.sendMessage({type:'focusfense.youtubeBudget',...(config?{config}:{})});
  request().then(r=>{if(!r?.ok)return;enabled.checked=r.config.enabled;minutes.value=r.config.minutes;period.value=r.config.period||'hourly';status.textContent=`${r.period==='daily'?'오늘':'최근 60분'}: ${Math.floor(r.usedMs/60000)}분 사용 · ${r.lastPlaybackAt?'최근 감지 '+new Date(r.lastPlaybackAt).toLocaleTimeString():'아직 재생 감지 없음'} · 이 프로필 기준`;});
  request().then(r=>{if(!r?.ok)return;keywordEnabled.checked=r.keywordConfig.enabled;keywordMinutes.value=r.keywordConfig.minutes;keywordWords.value=r.keywordConfig.keywords.join('\n');keywordStatus.textContent=`일치 영상 최근 60분: ${Math.floor(r.keywordUsedMs/60000)}분 사용 · 프로필별 계산`;});
  document.getElementById('save').addEventListener('click',async()=>{
    try{const r=await chrome.runtime.sendMessage({type:'focusfense.youtubeBudget',config:{enabled:enabled.checked,minutes:Number(minutes.value),period:period.value},keywordConfig:{enabled:keywordEnabled.checked,minutes:Number(keywordMinutes.value),keywords:keywordWords.value.split(/\r?\n/).map(v=>v.trim()).filter(Boolean)}});status.textContent=r.ok?'시청 한도 저장됨 · 영상 재생 시 적용':r.error;}catch{status.textContent='시청 한도 저장 실패';}
  });
})();
