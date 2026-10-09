import { createBrowserProtocol } from './browser-protocol.js';

import { createAdaptivePlayoutPolicy } from './receiver-playout.js';
export { createAdaptivePlayoutPolicy };

// This function is served as an ES module. Keep all browser dependencies inside
// it so the Worker needs neither a UI framework nor a separate asset deployment.
export function browserMain(protocolFactory, playoutFactory) {
  const wire = protocolFactory(), playout = playoutFactory(), $ = id => document.getElementById(id);
  const video = $('screen'), status = $('status'), surface = $('surface'), shot = $('snapshot'), fallback = $('fallback');
  const aiCommand = $('aiCommand'), aiExecute = $('aiExecute'), aiTargets = $('aiTargets'), aiResult = $('aiResult');
  const phoneTargets = $('phoneTargets'), screenInfo = $('screenInfo');
  const query = new URLSearchParams(location.search);
  let aiView = query.get('view') !== 'live', displayedObservationId = null, controllerReady = false;
  const linkValue = query.has('session') ? `${query.get('session')}.${query.get('access')}${query.get('client') ? '.' + query.get('client') : ''}` : location.hash.slice(1);
  const match = linkValue.match(/^([a-f0-9]{64})\.([A-Za-z0-9_-]{43})(?:\.([a-f0-9-]{36}))?$/);
  let stopped = false, ws, pc, control, liveControl, hello, sequence = 0n, after = 0;
  let remoteId, localId, localReady = false, localCandidates = [], remoteCandidates =  --- TRUNCATED --- 46,463 chars