// @feature: youtube-hourly-budget
// Event driven: no polling timer, subprocess or external telemetry.
(()=>{
  if(globalThis.__ffYoutubeBudgetStarted)return;
  globalThis.__ffYoutubeBudgetStarted=true;
  let instance=crypto.randomUUID();
  let exemptions=[];
  Promise.resolve(chrome.storage.local?.get({youtubeBudgetExemptions:[]})).then(data=>{exemptions=Array.isArray(data?.youtubeBudgetExemptions)?data.youtubeBudgetExemptions:[];}).catch(()=>{});
  let seq=0,previous=null,lastSent=0,busy=false,blocked=false,notice,navigating=false;
  function metadata(){
    try{
      const id=new URL(location.href).searchParams.get('v');
      const watch=document.querySelector('ytd-watch-flexy[video-id]');
      if(navigating||!id||watch?.getAttribute('video-id')!==id)return {verified:false};
      const title=watch.querySelector('h1.ytd-watch-metadata yt-formatted-string, #title h1 yt-formatted-string')?.textContent?.trim()||'';
      const channel=watch.querySelector('#owner #channel-name a')?.textContent?.trim()||'';
      const owner=watch.querySelector('#owner ytd-video-owner-renderer a[href], ytd-video-owner-renderer #channel-name a[href], #owner #channel-name a[href]');
      const identity=FocusFenseYoutubeBudget.ownerIdentity(owner?.href||owner?.getAttribute?.('href')||'');
      return {videoId:id,title:title.slice(0,1000),channel:channel.slice(0,1000),verified:!!title||!!identity,ownerVerified:!!identity,...(identity||{})};
    }catch{return {verified:false};}
  }
  globalThis.FocusFenseYoutubeBudgetCurrentMetadata=metadata;
  globalThis.FocusFenseYoutubeBudgetCurrentExemption=()=>{
    try{const url=new URL(location.href);return FocusFenseYoutubeBudget.matchedExemption(metadata(),exemptions,{videoId:url.searchParams.get('v'),host:url.hostname});}catch{return null;}
  };
  const noticeText={
    en:{hourly:'YouTube viewing allowance for the last 60 minutes is used.',daily:"Today's YouTube viewing allowance is used.",keyword:'The last 60 minutes’ allowance for keyword-matched videos is used. Other videos remain available.',next:'Next available',remaining:'Remaining',waiting:'Checking availability…'},
    ko:{hourly:'최근 60분의 YouTube 시청 한도를 사용했습니다.',daily:'오늘의 YouTube 시청 한도를 사용했습니다.',keyword:'키워드 영상의 최근 60분 시청 한도를 사용했습니다. 다른 영상은 시청할 수 있습니다.',next:'다음 시청 가능',remaining:'남은 시간',waiting:'시청 가능 여부 확인 중…'},
    ja:{hourly:'過去60分間のYouTube視聴上限に達しました。',daily:'本日のYouTube視聴上限に達しました。',keyword:'キーワード対象動画の過去60分間の視聴上限に達しました。他の動画は視聴できます。',next:'次に視聴可能',remaining:'残り',waiting:'視聴可否を確認中…'},
    zh:{hourly:'过去60分钟的YouTube观看额度已用完。',daily:'今天的YouTube观看额度已用完。',keyword:'关键词视频在过去60分钟的观看额度已用完。其他视频仍可观看。',next:'下次可观看时间',remaining:'剩余时间',waiting:'正在检查是否可观看…'},
    he:{hourly:'מכסת הצפייה ב־YouTube ב־60 הדקות האחרונות נוצלה.',daily:'מכסת הצפייה היומית ב־YouTube נוצלה.',keyword:'מכסת הסרטונים התואמים למילות המפתח ב־60 הדקות האחרונות נוצלה. סרטונים אחרים זמינים.',next:'הצפייה הבאה אפשרית',remaining:'זמן שנותר',waiting:'בודק זמינות…'},
    ar:{hourly:'تم استهلاك وقت مشاهدة YouTube خلال آخر 60 دقيقة.',daily:'تم استهلاك وقت مشاهدة YouTube لهذا اليوم.',keyword:'تم استهلاك وقت الفيديوهات المطابقة للكلمات خلال آخر 60 دقيقة. لا تزال الفيديوهات الأخرى متاحة.',next:'المشاهدة التالية متاحة',remaining:'الوقت المتبقي',waiting:'جارٍ التحقق من الإتاحة…'}
  };
  let noticeState=null,noticeTimer=null,expiryRefreshPending=false,retryAfter=0;
  function renderNotice(){
    if(!notice||!noticeState)return;
    const locale=noticeText[noticeState.locale]?noticeState.locale:'en';
    const text=noticeText[locale],at=noticeState.nextAvailableAt;
    const intro=noticeState.blockedBy==='keyword'?text.keyword:noticeState.period==='daily'?text.daily:text.hourly;
    let detail=text.waiting;
    if(Number.isFinite(at)){
      const seconds=Math.max(0,Math.ceil((at-Date.now())/1000));
      const clock=[Math.floor(seconds/3600),Math.floor(seconds%3600/60),seconds%60].map(v=>String(v).padStart(2,'0')).join(':');
      const date=new Intl.DateTimeFormat(locale,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit'}).format(at);
      detail=`${text.next}: ${date} · ${text.remaining}: ${clock}`;
    }
    const value=`FocusFense · ${intro} ${detail}`;
    // @incident: youtube-mutation-loop — unchanged banner text must not retrigger full-page content observers.
    if(notice.textContent!==value)notice.textContent=value;
    notice.dir=['he','ar'].includes(locale)?'rtl':'ltr';
  }
  function banner(show,result){
    if(!show){if(noticeTimer)clearInterval(noticeTimer);noticeTimer=null;noticeState=null;notice?.remove();notice=null;return;}
    noticeState=result;
    if(!notice?.isConnected){
      notice=document.createElement('div');notice.setAttribute('role','alert');
      notice.setAttribute('data-focusfense-budget-notice','1');
      Object.assign(notice.style,{position:'fixed',inset:'0 0 auto 0',zIndex:'2147483647',padding:'20px',background:'#17202a',color:'#fff',font:'16px sans-serif',textAlign:'center'});
      (document.body||document.documentElement).append(notice);
    }
    renderNotice();
    if(!noticeTimer){
      // UI countdown only while blocked: one notice text update/second, no DOM scan or network probe.
      // The sole deadline refresh asks the existing worker for zero-elapsed state; no autoplay.
      noticeTimer=setInterval(()=>{
        renderNotice();
        if(Number.isFinite(noticeState?.nextAvailableAt)&&Date.now()>=noticeState.nextAvailableAt&&Date.now()>=retryAfter&&!expiryRefreshPending){
          expiryRefreshPending=true;retryAfter=Date.now()+30000;
          refreshAvailability().finally(()=>{expiryRefreshPending=false;});
        }
      },1000);
    }
  }
  async function refreshAvailability(){
    try{
      const sentInstance=instance;
      const result=await chrome.runtime.sendMessage({type:'focusfense.youtubeBudget',instance:sentInstance,seq:++seq,elapsedMs:0,metadata:metadata()});
      if(sentInstance!==instance||!result?.ok)return;
      blocked=result.blocked;banner(blocked,result);
    }catch{}
  }
  async function sample(event){
    const video=event.target;
    if(!(video instanceof HTMLVideoElement))return;
    const reset=['seeking','seeked','ratechange','emptied','waiting','pause','ended'].includes(event.type);
    if(reset)previous=null;
    const now=performance.now();
    if(event.type==='timeupdate'&&now-lastSent<1000)return;
    if(busy){previous=null;return;}
    const ad=!!document.querySelector('.html5-video-player.ad-showing');
    const current={wall:now,position:video.currentTime,rate:video.playbackRate,video:location.pathname+location.search,playing:!reset&&!ad&&!video.paused&&!video.ended&&!video.seeking&&video.readyState>=3};
    const elapsedMs=FocusFenseYoutubeBudget.playbackMs(previous,current);
    previous=current;lastSent=now;busy=true;
    try{
      const sentInstance=instance;
      const result=await chrome.runtime.sendMessage({type:'focusfense.youtubeBudget',instance:sentInstance,seq:++seq,elapsedMs,metadata:metadata()});
      if(sentInstance!==instance)return;
      if(!result?.ok)return;
      blocked=result.blocked;
      if(blocked&&!video.paused)video.pause();
      banner(blocked,result);
    }catch{previous=null;}finally{busy=false;}
  }
  for(const type of ['timeupdate','playing','pause','ended','seeking','seeked','ratechange','emptied','waiting'])document.addEventListener(type,sample,true);
  document.addEventListener('yt-navigate-start',()=>{previous=null;navigating=true;instance=crypto.randomUUID();seq=0;blocked=false;banner(false);});
  document.addEventListener('yt-navigate-finish',()=>{previous=null;navigating=false;});
  chrome.storage.onChanged.addListener((changes,area)=>{
    if(area!=='local')return;
    if(changes.youtubeBudgetExemptions){exemptions=Array.isArray(changes.youtubeBudgetExemptions.newValue)?changes.youtubeBudgetExemptions.newValue:[];previous=null;}
    if(!changes.ffYoutubeBudgetConfig&&!changes.ffYoutubeKeywordBudgetConfig&&!changes.protectionEnabled&&!changes.youtubeBudgetExemptions&&!changes.focusfenseLocale)return;
    const video=document.querySelector('video');
    if(video)sample({target:video,type:'settings'});
  });
})();
