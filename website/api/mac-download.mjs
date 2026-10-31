import {downloadHandler, newestReleaseAsset} from '../lib/release-download.mjs';
export const newestMacDownload = releases => newestReleaseAsset(releases,'mac')?.url || null;
export default downloadHandler('mac');
