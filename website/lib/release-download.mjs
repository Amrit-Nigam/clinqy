const repository = 'Amrit-Nigam/clinqy';
const platforms = {
  mac: { files:{ default:'Clinqy.dmg' } },
  windows: { files:{ default:'Clinqy-windows-x64.zip', installer:'install.ps1' } },
};
export function newestReleaseAsset(releases, platform, kind='default') {
  const settings=platforms[platform], filename=settings?.files[kind];
  if (!filename || !Array.isArray(releases)) return null;
  const pattern=new RegExp(`^${platform}-v(\\d+)\\.(\\d+)\\.(\\d+)$`);
  const candidates=releases.flatMap(release=>{
    const match=pattern.exec(release.tag_name || '');
    if (!match || release.draft || release.prerelease) return [];
    const prefix=`https://github.com/${repository}/releases/download/${release.tag_name}/`;
    const required=Object.values(settings.files);
    if (!required.every(name=>release.assets?.some(asset=>asset.name===name && asset.browser_download_url?.startsWith(prefix)))) return [];
    const asset=release.assets.find(asset=>asset.name===filename);
    return [{ version:match.slice(1).join('.'), parts:match.slice(1).map(Number), url:asset.browser_download_url }];
  });
  candidates.sort((a,b)=>{
    for(let i=0;i<3;i++) if(a.parts[i]!==b.parts[i]) return b.parts[i]-a.parts[i];
    return 0;
  });
  const found=candidates[0];
  return found ? {version:found.version,url:found.url} : null;
}
export function downloadHandler(platform) {
  return async function handler(request,response) {
    if(!['GET','HEAD'].includes(request.method)) { response.writeHead(405,{Allow:'GET, HEAD'});response.end();return; }
    const query=new URL(request.url || '/', 'https://clinqy.vercel.app').searchParams;
    const kind=query.get('asset') || 'default', settings=platforms[platform], filename=settings?.files[kind];
    if(!filename) { response.writeHead(400);response.end('Unknown download asset');return; }
    let selected=null;
    const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),5000);
    try {
      const result=await fetch(`https://api.github.com/repos/${repository}/releases?per_page=100`,{
        headers:{Accept:'application/vnd.github+json','User-Agent':'Clinqy-Downloads'},signal:controller.signal,
      });
      if(result.ok) {
        const latest=newestReleaseAsset(await result.json(),platform,kind);
        if(latest) selected=latest;
      }
    } catch { /* A failed lookup must never silently downgrade an existing installation. */ }
    finally { clearTimeout(timeout); }
    if(!selected) {
      response.writeHead(503,{'Content-Type':'text/plain','Cache-Control':'no-store','Retry-After':'30'});
      response.end('Could not check the current release. Please retry shortly.');return;
    }
    const cache='public, s-maxage=300, stale-while-revalidate=3600';
    if(query.get('format')==='json') {
      response.writeHead(200,{'Content-Type':'application/json','Cache-Control':cache});
      response.end(JSON.stringify({platform,...selected}));
    } else {
      response.writeHead(302,{Location:selected.url,'Cache-Control':cache});response.end();
    }
  };
}
