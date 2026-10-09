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
  let remoteId, localId, localReady = false, localCandidates = [], remoteCandidates = new Map();
  let signalChain = Promise.resolve(), publishChain = Promise.resolve(), reconnectTimer, retry = 0;
  let busy = false, pending = null, pointer = null, lastFrameAt = 0, rendered = 0, videoReadyGeneration = -1;
  let lastStats, lastPresented = 0, telemetrySequence = 0n, telemetry;
  let videoReceiver = null, acceptedPlayoutTargetMs = null;
  let statsInFlight = false, mediaEpoch = 0;
  let observation, observationAt = 0, snapshotPending = false;
  const seenSignals = new Set();
  const timers = [], instanceId = crypto.randomUUID();
  let clientId;
  const message = text => { if (status.textContent !== text) status.textContent = text; };
  function invalidateControls() {
    hello = null; pointer = null; videoReadyGeneration = -1;
    lastStats = null; mediaEpoch++; playout.resetPresentation();
    if (pending) { clearTimeout(pending.timer); pending.reject(new Error('Connection changed; observe before trying again')); pending = null; }
    busy = snapshotPending;
  }
  function end(text) {
    stopped = true; clearTimeout(reconnectTimer); fallback.removeAttribute('src'); fallback.hidden = true; timers.forEach(clearInterval); invalidateControls();
    ws?.close(); pc?.close(); video.srcObject = null; shot.removeAttribute('src'); displayedObservationId = null; controllerReady = false; renderSemanticTargets(); message(text);
  }
  if (!match) { end('Open the complete link copied by Aaris Remote on your phone.'); return; }
  const [, sessionId, capability, linkClientId] = match;
  clientId = linkClientId || crypto.randomUUID();
  if (!linkClientId) {
    try {
      const key = `aaris-browser-${sessionId}`;
      clientId = sessionStorage.getItem(key) || clientId; sessionStorage.setItem(key, clientId);
    } catch { /* Legacy links still connect once when browser storage is unavailable. */ }
    // Canonicalize old two-part links immediately. Stateless/cloud browsers can
    // retain the upgraded URL and reclaim the same controller identity later.
    try { history.replaceState(null, '', query.has('session') ? `?session=${sessionId}&access=${capability}&client=${clientId}` : `#${sessionId}.${capability}.${clientId}`); } catch {}
  }
  const base = `/v1/sessions/${sessionId}`;
  async function api(action, data) {
    const response = await fetch(base + (action ? `/${action}` : ''), {
      method: data === undefined ? 'GET' : 'POST', cache: 'no-store', credentials: 'omit',
      headers: { Authorization: `Bearer ${capability}`, 'Content-Type': 'application/json', 'X-Aaris-Instance': instanceId },
      body: data === undefined ? undefined : JSON.stringify(data), signal: AbortSignal.timeout(12000)
    });
    const value = await response.json();
    if (!response.ok) {
      if ([401, 403, 410].includes(response.status)) end('This session ended. Create a new link on the phone.');
      if (value.error === 'controller_busy' || value.error === 'controller_replaced') end('This link is already open in another controller.');
      throw new Error(value.message || value.error || 'Connection unavailable');
    }
    return value;
  }
  function publish(kind, payload) {
    // Only signaling is queued. Input is never queued or replayed after failure.
    const operation = publishChain.then(() => { if (!stopped) return api('events', { kind, payload }); });
    publishChain = operation.catch(() => {}); return operation;
  }
  function short(packet) {
    if (control?.readyState === 'open' && control.bufferedAmount < 4096) control.send(packet);
  }
  function frame() {
    lastFrameAt = performance.now(); rendered++;
    if (fresh() && !busy) { fallback.hidden = true; video.hidden = false; message('Live • click the phone screen to control it'); }
    if (hello && hello.generation !== videoReadyGeneration) {
      short(wire.videoReady(hello)); videoReadyGeneration = hello.generation;
    }
  }
  if (video.requestVideoFrameCallback) {
    const onFrame = (now, metadata) => {
      if (stopped) return;
      frame();
      if (hello && !document.hidden) {
        const window = playout.present(metadata.expectedDisplayTime ?? now, metadata.presentedFrames);
        if (window) feedback(20, [window.intervalMs, window.frames, window.maxGapMs]);
      }
      video.requestVideoFrameCallback(onFrame);
    };
    video.requestVideoFrameCallback(onFrame);
  } else video.addEventListener('timeupdate', frame);
  function mediaFresh() {
    return !stopped && hello && control?.readyState === 'open' && video.readyState >= 2 &&
      performance.now() - lastFrameAt < 2500 && video.videoWidth > 0 && video.videoHeight > 0 &&
      Math.abs(video.videoWidth / video.videoHeight - hello.width / hello.height) < 0.04;
  }
  function fresh() { return !aiView && mediaFresh(); }
  async function act(action, args = {}) {
    if (!fresh()) return snapshotAct(action, args);
    if (busy || control.bufferedAmount > 4096) throw new Error('Wait for the current action to finish');
    const seq = sequence + 1n, packet = wire.command(action, hello, seq, args);
    sequence = seq; busy = true;
    try {
      const outcome = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending = null; reject(new Error('Action outcome unknown. Inspect the screen before retrying.')); }, 6500);
        pending = { seq, resolve, reject, timer };
        try { control.send(packet); } catch (error) { clearTimeout(timer); pending = null; reject(error); }
      });
      message(outcome ? 'Live • action applied' : 'Action was not applied • inspect the phone');
      return { applied: outcome };
    } finally { busy = false; }
  }
  function normalizeLabel(value) {
    return String(value || '').trim().replace(/\s+/g, ' ').toLocaleLowerCase();
  }
  function semanticTargets(value = observation) {
    const width = Number(value?.display?.width), height = Number(value?.display?.height);
    if (!(width > 0 && height > 0) || !Array.isArray(value?.uiHints)) return [];
    const hints = value.uiHints;
    return hints.flatMap((hint, index) => {
      const b = hint?.bounds;
      if (!Array.isArray(b) || b.length !== 4 || !b.every(Number.isFinite)) return [];
      const [left, top, right, bottom] = b.map(Number);
      if (!(right > left && bottom > top)) return [];
      const label = String(hint.text || hint.contentDescription || '').trim();
      if (!label) return [];
      // Android often puts an icon's label on a non-clickable child. A bounded
      // clickable parent proves that its label's center is an actionable point.
      const actionable = hint.clickable === true || hint.editable === true || hints.some(parent => {
        const p = parent?.bounds;
        return parent?.enabled !== false && (parent.clickable === true || parent.editable === true) &&
          Array.isArray(p) && p.length === 4 && p.every(Number.isFinite) &&
          p[0] <= left && p[1] <= top && p[2] >= right && p[3] >= bottom &&
          (p[2] - p[0]) * (p[3] - p[1]) < width * height * .85;
      });
      return [{
        index,
        label,
        role: String(hint.role || ''),
        clickable: actionable,
        enabled: hint.enabled !== false,
        x: ((left + right) / 2 / width),
        y: ((top + bottom) / 2 / height)
      }];
    }).filter(target => target.enabled && target.clickable && target.x >= 0 && target.x <= 1 && target.y >= 0 && target.y <= 1);
  }
  function renderSemanticTargets() {
    if (!aiTargets) return;
    const targets = semanticTargets();
    const width = Number(observation?.display?.width), height = Number(observation?.display?.height);
    const geometry = width > 0 && height > 0
      ? `Phone coordinate space: ${width}×${height} pixels. Raw coordinate taps work even without Accessibility targets. `
      : 'Phone geometry pending. ';
    aiTargets.textContent = geometry + (targets.length
      ? 'Named shortcuts: ' + targets.slice(0, 40).map(t => `${t.label}${t.role ? ' [' + t.role + ']' : ''}`).join(' • ')
      : 'No named Accessibility targets on this screen; use x/y.') + ` ${observation?.note || ''}`;
    const ready = snapshotFresh() && controllerReady && !busy && !pointer;
    const expired = observation && performance.now() - observationAt >= 85000;
    const mismatched = displayedObservationId && fallback.naturalWidth > 0 && width > 0 && height > 0 &&
      Math.abs(fallback.naturalWidth / fallback.naturalHeight - width / height) >= .04;
    if (screenInfo) screenInfo.textContent = !observation ? 'Waiting for a complete phone screen…'
      : `Full phone: ${width}×${height} • ${expired ? 'Observation expired; press Fresh screenshot.' : mismatched ? 'Image geometry changed; press Fresh screenshot.' : aiView ? 'AI view • image held for your decision' : 'Live view • choose AI view for coordinate commands'}`;
    if (phoneTargets) {
      phoneTargets.replaceChildren();
      for (const target of targets.slice(0, 40)) {
        const value = observation, button = document.createElement('button');
        button.type = 'button'; button.textContent = target.label;
        button.setAttribute('aria-label', `Tap phone: ${target.label} (${target.index + 1})`);
        button.disabled = !ready;
        button.onclick = () => {
          if (observation !== value || displayedObservationId !== value.observationId) {
            report(new Error('Phone image changed. Inspect it before choosing a target.')); return;
          }
          agentAct('tap', { x: target.x, y: target.y }, true).catch(report);
        };
        phoneTargets.append(button);
      }
    }
    if (aiExecute) aiExecute.disabled = !ready;
    if ($('tapPoint')) $('tapPoint').disabled = !ready;
  }
  function setObservation(value) {
    if (!value?.observationId || !value.image || pointer || busy) return;
    if (value.observationId === observation?.observationId) { showFallback(); renderSemanticTargets(); return; }
    observation = value;
    const age = Number.isFinite(value.receivedAtMs) ? Math.max(0, Date.now() - value.receivedAtMs) : 0;
    observationAt = performance.now() - age;
    const params = new URLSearchParams({ session: sessionId, access: capability, observationId: value.observationId });
    displayedObservationId = null;
    fallback.onload = () => {
      if (stopped || observation !== value || fallback.dataset.observationId !== value.observationId) return;
      displayedObservationId = value.observationId; showFallback(); renderSemanticTargets();
    };
    fallback.onerror = () => {
      displayedObservationId = null; renderSemanticTargets();
      if (!stopped && !fresh()) message('Phone image could not load • press Fresh screenshot');
    };
    // The first image is embedded by the Worker. Keep its bytes and ticket
    // together instead of replacing it with a racing second HTTP image fetch.
    if (fallback.dataset.observationId !== value.observationId || !fallback.getAttribute('src')) {
      fallback.dataset.observationId = value.observationId;
      fallback.src = value.image.data ? `data:image/jpeg;base64,${value.image.data}` : `/remote/frame?${params}`;
    }
    if (fallback.complete && fallback.naturalWidth > 0) fallback.onload();
    renderSemanticTargets();
  }
  function showFallback() {
    if (!stopped && !fresh() && observation && fallback.complete && fallback.naturalWidth > 0) {
      video.hidden = true; fallback.hidden = false;
      message(observation.redacted ? 'Protected/setup screen • use Home to open the launcher' : 'Screenshot mode • click the phone screen to control it');
    }
  }
  function snapshotFresh() {
    return !stopped && observation && performance.now() - observationAt < 85000 &&
      displayedObservationId === observation.observationId && !fallback.hidden &&
      fallback.complete && fallback.naturalWidth > 0 && fallback.naturalHeight > 0 &&
      observation.display?.width > 0 && observation.display?.height > 0 &&
      Math.abs(fallback.naturalWidth / fallback.naturalHeight - observation.display.width / observation.display.height) < .04;
  }
  async function pollResult(requestId) {
    const until = performance.now() + 14000;
    while (!stopped && performance.now() < until) {
      const value = await api(`agent-result?requestId=${encodeURIComponent(requestId)}`);
      if (value.result) return value.result;
      await new Promise(resolve => setTimeout(resolve, 300));
    }
    throw new Error('Action outcome unknown. Inspect a fresh screenshot before trying again.');
  }
  async function agentAct(action, args, requireVisibleSnapshot = false) {
    if (requireVisibleSnapshot && !snapshotFresh()) throw new Error('Wait for a fresh phone screenshot');
    if (!observation?.observationId || performance.now() - observationAt >= 85000) throw new Error('Wait for a fresh phone observation');
    if (busy) throw new Error('Wait for the current action to finish');
    if (!controllerReady) throw new Error('Wait for the phone controller to connect');
    const mapped = { longPress: 'long_press', text: 'type' }[action] || action;
    const input = { ...args };
    if (mapped === 'tap') delete input.durationMs;
    if (input.points?.length > 24) input.points = Array.from({length:24}, (_, i) => input.points[Math.round(i * (input.points.length - 1) / 23)]);
    if (input.durationMs !== undefined) input.durationMs = Math.round(Math.max(80, Math.min(1500, input.durationMs)));
    const command = { protocol:'aaris-link-v1', nonce:observation.commandNonce, actionId:crypto.randomUUID(),
      observationId:observation.observationId, screenVersion:observation.screenVersion, action:mapped, ...input };
    busy = true; snapshotPending = true;
    if (aiResult) aiResult.textContent = 'Running…';
    renderSemanticTargets();
    try {
      const queued = await api('agent-action', command), result = queued.result || await pollResult(queued.requestId);
      busy = false;
      if (result.observationId) setObservation(result);
      if (aiResult) aiResult.textContent = result.error || (result.applied === true ? 'Applied' : result.applied === false ? 'Not applied' : 'Outcome unknown');
      if (result.error) throw new Error(result.error);
      message(result.applied === true ? 'AI action applied' : result.applied === false ? 'Action was not applied • inspect the phone' : 'Action outcome unknown • inspect the phone');
      return result;
    } finally { snapshotPending = false; busy = false; renderSemanticTargets(); }
  }
  async function snapshotAct(action, args) {
    return agentAct(action, args, true);
  }
  async function refreshObservation() {
    if (busy) throw new Error('Wait for the current action to finish');
    busy = true; snapshotPending = true; renderSemanticTargets();
    try {
      const queued = await api('agent-refresh', {});
      const result = queued.result || await pollResult(queued.requestId);
      if (!result?.observationId) throw new Error(result?.error || 'Fresh phone observation unavailable');
      busy = false; setObservation(result);
      return result;
    } finally { busy = false; snapshotPending = false; renderSemanticTargets(); }
  }
  function resolveNamedTarget(command, value) {
    const requested = normalizeLabel(command.target ?? command.label);
    if (!requested) throw new Error('tap requires "target" or normalized x/y');
    const targets = semanticTargets(value);
    const exact = targets.filter(t => normalizeLabel(t.label) === requested);
    const prefix = exact.length ? exact : targets.filter(t => normalizeLabel(t.label).startsWith(requested));
    const contains = prefix.length ? prefix : targets.filter(t => normalizeLabel(t.label).includes(requested));
    if (contains.length !== 1) {
      const names = contains.length ? contains : targets;
      const sample = names.slice(0, 12).map(t => t.label).join(', ');
      throw new Error(contains.length > 1
        ? `Target "${command.target ?? command.label}" is ambiguous: ${sample}`
        : `Target "${command.target ?? command.label}" not found. Visible targets: ${sample || 'none'}`);
    }
    return { x: contains[0].x, y: contains[0].y };
  }
  function compileAiCommand(command, value) {
    if (!command || typeof command !== 'object' || Array.isArray(command)) throw new Error('AI command must be one JSON object');
    const action = String(command.action || '').trim().toLowerCase().replace(/-/g, '_');
    if (!action) throw new Error('Missing action');

    if (action === 'tap') {
      if (command.target !== undefined || command.label !== undefined) {
        return { action: 'tap', args: resolveNamedTarget(command, value) };
      }
      let x = Number(command.x), y = Number(command.y);
      const space = String(command.space || 'normalized').trim().toLowerCase();
      if (space === 'pixel' || space === 'pixels') {
        const width = Number(value?.display?.width), height = Number(value?.display?.height);
        if (!(width > 0 && height > 0)) throw new Error('Phone pixel geometry unavailable');
        if (!(x >= 0 && x < width && y >= 0 && y < height)) throw new Error(`pixel tap must fit ${width}×${height}`);
        x /= width; y /= height;
      } else if (space !== 'normalized' && space !== 'unit') {
        throw new Error('tap space must be "normalized" or "pixel"');
      }
      if (!(x >= 0 && x <= 1 && y >= 0 && y <= 1)) throw new Error('tap x/y must be normalized 0..1');
      return { action: 'tap', args: { x, y } };
    }
    if (action === 'long_press' || action === 'longpress') {
      const point = (command.target !== undefined || command.label !== undefined)
        ? resolveNamedTarget(command, value)
        : { x: Number(command.x), y: Number(command.y) };
      if (!(point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1)) throw new Error('long_press needs target or normalized x/y');
      return { action: 'longPress', args: { ...point, durationMs: Number(command.durationMs || 650) } };
    }
    if (action === 'type' || action === 'text') {
      const text = String(command.text ?? '');
      if (!text) throw new Error('type requires non-empty text');
      return { action: 'text', args: { text } };
    }
    if (action === 'back' || action === 'home' || action === 'recents') return { action, args: {} };
    if (action === 'swipe') {
      const direction = String(command.direction || '').toLowerCase();
      if (direction) {
        const map = {
          up: { x:.5, y:.78, toX:.5, toY:.22 },
          down: { x:.5, y:.22, toX:.5, toY:.78 },
          left: { x:.82, y:.5, toX:.18, toY:.5 },
          right: { x:.18, y:.5, toX:.82, toY:.5 }
        };
        if (!map[direction]) throw new Error('swipe direction must be up/down/left/right');
        return { action:'swipe', args:{ ...map[direction], durationMs:Number(command.durationMs || 320) } };
      }
      const args = {
        x:Number(command.x), y:Number(command.y), toX:Number(command.toX), toY:Number(command.toY),
        durationMs:Number(command.durationMs || 320)
      };
      if (![args.x,args.y,args.toX,args.toY].every(v => v >= 0 && v <= 1)) throw new Error('swipe coordinates must be normalized 0..1');
      return { action:'swipe', args };
    }
    if (action === 'open_app') {
      const app = String(command.app || '').trim();
      if (!app) throw new Error('open_app requires Android package name in "app"');
      return { action:'open_app', args:{ app } };
    }
    throw new Error(`Unsupported action "${action}"`);
  }
  async function executeAiJson() {
    if (!aiCommand) return;
    if (aiResult) aiResult.textContent = 'Running…';
    let command;
    try { command = JSON.parse(aiCommand.value); }
    catch { throw new Error('Invalid JSON'); }
    // The model decided from the visible image. Never silently replace its
    // observation before applying those coordinates to a different scene.
    if (!snapshotFresh()) throw new Error('Choose AI view and inspect a Fresh screenshot before executing');
    const value = observation;
    const compiled = compileAiCommand(command, value);
    /*
     * Deliberately use the observation-backed agent path even when live WebRTC
     * control is available. It reuses the MCP-class validation/executor instead
     * of trusting a stale browser coordinate.
     */
    const result = await agentAct(compiled.action, compiled.args, true);
    if (aiResult) aiResult.textContent = result?.applied === true ? 'Applied' : result?.error || 'Outcome unknown';
    return result;
  }
  if (aiExecute) aiExecute.onclick = () => executeAiJson().catch(error => {
    if (aiResult) aiResult.textContent = error.message || 'Command failed';
    report(error);
  });
  if (aiCommand) aiCommand.addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      aiExecute?.click();
    }
  });

  async function updateSnapshot() {
    if (stopped || fresh() || busy || pointer || document.hidden) return;
    // A decision image is pinned. Only explicit refresh/action outcomes replace
    // it; background polls must not invalidate a model's in-progress decision.
    if (aiView && observation) { renderSemanticTargets(); return; }
    try {
      const state = await api('agent-observe');
      if (state.observation) setObservation(state.observation);
      else message(!state.phoneOnline ? 'Phone offline • finish screen sharing on the phone' : state.error === 'SCREENSHOT_ADAPTER_UNAVAILABLE' ? 'Screenshot adapter unavailable • update Aaris on the phone' : state.error === 'DEVICE_LOCKED_OR_ACCESSIBILITY_OFF' ? 'Unlock the phone or restore Accessibility' : state.error && state.error !== 'OBSERVATION_PENDING' ? `Phone screenshot unavailable • ${state.error}` : 'Phone connected • preparing screenshot…');
    } catch (error) { if (!stopped && !fresh()) message('Waiting for phone screenshot • reconnecting automatically…'); }
  }
  try { setObservation(JSON.parse($('initialObservation')?.dataset.value || 'null')); } catch {}
  function report(error) { if (!stopped) message(error.message || 'Connection recovering…'); }
  const run = (action, args) => act(action, args).catch(report);
  function bindChannel(channel) {
    if (channel.label === 'control-telemetry-v1') { telemetry = channel; return; }
    if (channel.label === 'control-live-v1') {
      liveControl = channel; channel.binaryType = 'arraybuffer';
      channel.onclose = () => { if (liveControl === channel) liveControl = null; };
      return;
    }
    if (channel.label !== 'control-v1') return;
    control = channel; channel.binaryType = 'arraybuffer';
    channel.onmessage = event => {
      let packet; try { packet = wire.decode(event.data); } catch { return; }
      if (packet?.type === 'hello') {
        if (packet.width < 1 || packet.height < 1) return;
        invalidateControls(); hello = packet; sequence = 0n; short(wire.heartbeat(hello));
        message(fresh() ? 'Live • click the phone screen to control it' : 'Control connected • waiting for video or screenshot…');
      } else if (packet?.type === 'result' && pending?.seq === packet.sequence) {
        const p = pending; pending = null; clearTimeout(p.timer); p.resolve(packet.applied);
      }
    };
    channel.onclose = () => { if (control === channel) { invalidateControls(); if (!stopped) message('Reconnecting to phone…'); } };
  }
  function applyPlayoutTarget() {
    if (!videoReceiver || !('jitterBufferTarget' in videoReceiver)) {
      acceptedPlayoutTargetMs = null;
      return false;
    }
    try {
      videoReceiver.jitterBufferTarget = playout.targetMs();
      const value = videoReceiver.jitterBufferTarget;
      acceptedPlayoutTargetMs = Number.isFinite(value) && value >= 0 ? value : null;
      return acceptedPlayoutTargetMs === playout.targetMs();
    } catch {
      // A failed change cannot give the sender credit for an unapplied budget.
      acceptedPlayoutTargetMs = null;
      return false;
    }
  }
  async function connectPeer() {
    const ice = await api('ice', {});
    if (stopped) return;
    pc?.close();
    videoReceiver = null; acceptedPlayoutTargetMs = null; playout.reset(); lastStats = null; mediaEpoch++;
    pc = new RTCPeerConnection({ iceServers: ice.iceServers, bundlePolicy: 'max-bundle' });
    pc.ondatachannel = event => bindChannel(event.channel);
    pc.ontrack = event => {
      if (event.track.kind !== 'video') return;
      videoReceiver = event.receiver || null;
      lastStats = null; mediaEpoch++; playout.reset();
      // Start responsive, then buy recovery time only for measured jitter.
      applyPlayoutTarget();
      video.srcObject = new MediaStream([event.track]);
      video.play().catch(() => { $('play').hidden = false; message('Browser paused video • press Show phone'); });
    };
    pc.onicecandidate = event => {
      const c = event.candidate; if (!c) return;
      const payload = { mid: c.sdpMid, mLine: c.sdpMLineIndex, sdp: c.candidate, negotiationId: localId };
      if (!localReady) localCandidates.push(payload); else publish('candidate', payload).catch(report);
    };
    pc.onconnectionstatechange = () => {
      if (['failed', 'disconnected'].includes(pc.connectionState)) {
        invalidateControls(); message('Network changed • reconnecting…');
        publish('ice_restart', { requestId: crypto.randomUUID() }).catch(report);
      }
    };
  }
  async function signal(event) {
    if (!Number.isSafeInteger(event.seq) || event.seq <= after || seenSignals.has(event.seq)) return;
    seenSignals.add(event.seq);
    while (seenSignals.delete(after + 1)) after++;
    if (event.senderRole !== 'host') return;
    const p = event.payload;
    if (event.kind === 'description' && p.type === 'offer') {
      if (remoteId === p.negotiationId) return;
      remoteId = p.negotiationId; localId = `${instanceId}:${Date.now()}`; localReady = false; localCandidates = [];
      await pc.setRemoteDescription({ type: 'offer', sdp: p.sdp });
      for (const candidate of remoteCandidates.get(remoteId) || []) await pc.addIceCandidate(candidate);
      remoteCandidates = new Map();
      await pc.setLocalDescription(await pc.createAnswer());
      await publish('description', { type: 'answer', sdp: pc.localDescription.sdp, negotiationId: localId, replyToNegotiationId: remoteId });
      localReady = true;
      for (const candidate of localCandidates) await publish('candidate', candidate);
      localCandidates = [];
    } else if (event.kind === 'candidate') {
      const candidate = { candidate: p.sdp, sdpMid: p.mid, sdpMLineIndex: p.mLine };
      if (p.negotiationId === remoteId && pc.remoteDescription) await pc.addIceCandidate(candidate);
      else if (remoteCandidates.size < 8) {
        const list = remoteCandidates.get(p.negotiationId) || [];
        if (list.length < 128) list.push(candidate);
        remoteCandidates.set(p.negotiationId, list);
      }
    }
  }
  function socket() {
    if (stopped) return;
    const next = new WebSocket(`${location.origin.replace('https:', 'wss:').replace('http:', 'ws:')}${base}/socket?after=${after}`,
      ['aaris-remote', `auth.${capability}`, `instance.${instanceId}`]);
    ws = next;
    next.onopen = () => { retry = 0; };
    next.onmessage = event => {
      if (event.data === 'pong' || ws !== next) return;
      let data; try { data = JSON.parse(event.data); } catch { return; }
      if (data.kind === 'session' && data.session?.state === 'CLOSED') { end('Session ended on phone. Create a new link to connect again.'); return; }
      if (data.kind === 'signal_event') signalChain = signalChain.then(() => signal(data.event)).catch(report);
    };
    next.onclose = event => {
      if (stopped || ws !== next) return;
      if ([4003, 4009].includes(event.code)) { end(event.code === 4009 ? 'Controller replaced by another tab.' : 'Session ended on phone.'); return; }
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(socket, Math.min(8000, 500 * 2 ** Math.min(retry++, 4)));
    };
  }
  // Keyboard/DOM controls are real page controls: automation needs no arbitrary
  // JS execution or special browser extension to use this console.
  document.querySelectorAll('[data-action]').forEach(button => button.onclick = () => run(button.dataset.action));
  document.querySelectorAll('[data-swipe]').forEach(button => button.onclick = () => {
    const up = button.dataset.swipe === 'up'; run('swipe', { x: .5, y: up ? .75 : .25, toX: .5, toY: up ? .25 : .75, durationMs: 350 });
  });
  $('sendText').onclick = () => run('text', { text: $('text').value });
  $('tapPoint').onclick = () => run('tap', { x: Number($('x').value), y: Number($('y').value) });
  $('play').onclick = () => video.play().then(() => { $('play').hidden = true; }).catch(report);
  $('aiView').onclick = () => {
    aiView = true; video.hidden = true; showFallback(); renderSemanticTargets();
    if (!snapshotFresh()) refreshObservation().catch(report);
  };
  $('liveView').onclick = () => {
    aiView = false;
    if (mediaFresh()) { fallback.hidden = true; video.hidden = false; message('Live • click the phone screen to control it'); }
    else { showFallback(); message('Waiting for live video • phone screenshot remains available'); }
    renderSemanticTargets();
  };
  $('refresh').onclick = () => {
    if (!fresh()) {
      if (busy) return;
      refreshObservation().catch(report); return;
    }
    if (!hello) { message('Waiting for phone…'); return; }
    short(wire.refresh(hello));
    const before = rendered, start = performance.now();
    const capture = () => {
      if (stopped) return;
      if (rendered <= before && performance.now() - start < 2000) { requestAnimationFrame(capture); return; }
      if (rendered <= before || !fresh()) { message('No fresh frame yet • wait for the connection'); return; }
      const canvas = document.createElement('canvas'); canvas.width = video.videoWidth; canvas.height = video.videoHeight;
      canvas.getContext('2d').drawImage(video, 0, 0); shot.src = canvas.toDataURL('image/jpeg', .9); shot.hidden = false;
      message('Fresh frame captured • live screen above remains interactive');
    };
    requestAnimationFrame(capture);
  };
  $('disconnect').onclick = async () => { try { await api('close', {}); } catch (error) { report(error); } finally { end('Disconnected. Create a new link on the phone.'); } };
  const pointAt = (clientX, clientY) => wire.point(clientX, clientY, surface.getBoundingClientRect(), fresh() ? video.videoWidth : fallback.naturalWidth, fresh() ? video.videoHeight : fallback.naturalHeight);
  const point = event => pointAt(event.clientX, event.clientY);
  const nextSequence = () => (sequence += 1n);
  const newGestureStreamId = () => (BigInt(Date.now()) << 16n) | BigInt(1 + Math.floor(Math.random() * 65534));
  const segmentDuration = ms => Math.max(16, Math.min(56, Math.round(ms)));
  function sendGestureSegment(state, phase, points, elapsedMs) {
    if (!fresh() || state.hello !== hello || !control || control.readyState !== 'open') return false;
    const seq = nextSequence();
    const packet = wire.gestureStream(hello, seq, state.streamId, phase, points.slice(-8), segmentDuration(elapsedMs));
    if (phase === 'continue') {
      const lane = liveControl?.readyState === 'open' ? liveControl : control;
      if (!lane || lane.bufferedAmount >= 512) return false;
      lane.send(packet);
      return true;
    }
    if (control.bufferedAmount >= 4096) return false;
    control.send(packet);
    return true;
  }
  function appendPointerSamples(state, event) {
    const samples = typeof event.getCoalescedEvents === 'function' ? event.getCoalescedEvents() : [event];
    for (const sample of samples) {
      const p = pointAt(sample.clientX, sample.clientY);
      if (!p) continue;
      state.distance = Math.max(state.distance, Math.hypot(sample.clientX - state.x, sample.clientY - state.y));
      const previous = state.points.at(-1);
      if (!previous || Math.hypot(p.x - previous.x, p.y - previous.y) > 0.0008) {
        if (state.points.length < 96) state.points.push(p); else state.points[95] = p;
      }
      state.last = p;
    }
  }
  function maybeStreamPointer(state, now) {
    if (!fresh() || state.hello !== hello || state.distance < 7 || !state.last) return;
    if (!state.streaming) {
      state.streamId = newGestureStreamId();
      if (sendGestureSegment(state, 'start', [state.points[0], state.last], now - state.at)) {
        state.streaming = true;
        state.lastSentAt = now;
        state.lastSentIndex = state.points.length - 1;
      }
      return;
    }
    if (now - state.lastSentAt < 16) return;
    const unsent = state.points.slice(Math.max(state.lastSentIndex, state.points.length - 8));
    if (!unsent.length) return;
    if (sendGestureSegment(state, 'continue', unsent, now - state.lastSentAt)) {
      state.lastSentAt = now;
      state.lastSentIndex = state.points.length - 1;
    }
  }
  function endPointerStream(state, last, now) {
    if (!state?.streaming || !last || state.hello !== hello) return false;
    sendGestureSegment(state, 'end', [last], now - state.lastSentAt);
    state.streaming = false;
    return true;
  }
  surface.onpointerdown = event => {
    if ((!fresh() && !snapshotFresh()) || busy || event.button !== 0 || pointer) return;
    const p = point(event); if (!p) return;
    pointer = {
      id: event.pointerId, at: performance.now(), hello, observation, points: [p],
      last: p, x: event.clientX, y: event.clientY, distance: 0,
      streaming: false, streamId: 0n, lastSentAt: 0, lastSentIndex: 0
    };
    surface.setPointerCapture(event.pointerId); event.preventDefault();
  };
  surface.onpointermove = event => {
    if (!pointer || pointer.id !== event.pointerId) return;
    appendPointerSamples(pointer, event);
    maybeStreamPointer(pointer, performance.now());
    event.preventDefault();
  };
  surface.onpointerup = event => {
    const p = pointer;
    if (!p || p.id !== event.pointerId) return;
    appendPointerSamples(p, event);
    const last = p.last || point(event);
    const now = performance.now();
    pointer = null;
    if (!last || (fresh() ? p.hello !== hello : p.observation !== observation)) return;
    if (endPointerStream(p, last, now)) return;
    const durationMs = now - p.at;
    if (p.distance < 7 && Math.hypot(event.clientX - p.x, event.clientY - p.y) < 7) {
      run(durationMs >= 500 ? 'longPress' : 'tap', { ...last, durationMs });
    } else {
      run('drag', { points: [...p.points, last].slice(-96), durationMs });
    }
  };
  surface.onpointercancel = event => {
    const p = pointer; pointer = null;
    if (!p || p.id !== event.pointerId) return;
    const last = p.last || point(event);
    if (last) endPointerStream(p, last, performance.now());
  };
  surface.oncontextmenu = event => event.preventDefault();
  surface.onwheel = event => { event.preventDefault(); if (!busy) run('swipe', { x: .5, y: event.deltaY > 0 ? .75 : .25, toX: .5, toY: event.deltaY > 0 ? .25 : .75, durationMs: 300 }); };
  // Application-level feedback shares Android's existing telemetry channel.
  // Rendered frame callbacks, rather than video playback time, prove freshness.
  function feedback(type, values = [], floats = []) {
    if (!hello) return;
    const b = new ArrayBuffer(22 + values.length * 4), v = new DataView(b);
    v.setUint8(0, 1); v.setUint8(1, type); v.setBigInt64(2, hello.secret); v.setInt32(10, hello.generation); v.setBigInt64(14, ++telemetrySequence);
    values.forEach((value, i) => floats.includes(i) ? v.setFloat32(22 + i * 4, value) : v.setInt32(22 + i * 4, value));
    const dc = telemetry?.readyState === 'open' ? telemetry : control;
    if (dc?.readyState === 'open' && dc.bufferedAmount < 4096) dc.send(b);
  }
  timers.push(setInterval(() => {
    if (hello) short(wire.heartbeat(hello));
    if (ws?.readyState === WebSocket.OPEN) ws.send('browser_ping');
  }, 5000));
  timers.push(setInterval(async () => {
    if (!pc || !videoReceiver || stopped || !hello || document.hidden || statsInFlight) return;
    if (rendered > lastPresented) { feedback(21); lastPresented = rendered; }
    const sampledPeer = pc, sampledReceiver = videoReceiver, sampledEpoch = mediaEpoch;
    statsInFlight = true;
    try {
      const reports = await sampledReceiver.getStats();
      if (stopped || document.hidden || !hello || pc !== sampledPeer ||
          videoReceiver !== sampledReceiver || mediaEpoch !== sampledEpoch) return;
      reports.forEach(r => {
        if (r.type !== 'inbound-rtp' || r.kind !== 'video') return;
        const sample = playout.sampleStats(r, lastStats);
        lastStats = r;
        if (!sample) return;
        // Normalize against the preference accepted DURING this sample. A new
        // target selected below must not erase backlog already observed.
        const bufferState = playout.observe({
          ...sample, nowMs: performance.now(), acceptedTargetMs: acceptedPlayoutTargetMs
        });
        feedback(19, [sample.intervalMs, sample.frames, sample.decodeMs ?? -1,
          bufferState.excessDelayMs ?? -1, sample.dropped ?? -1, sample.freezes ?? -1], [2, 3]);
        if (bufferState.changed) applyPlayoutTarget();
        const actualText = sample.actualDelayMs == null ? '-' : Math.round(sample.actualDelayMs);
        const floorText = sample.minimumDelayMs == null ? '-' : Math.round(sample.minimumDelayMs);
        const bufferText = acceptedPlayoutTargetMs == null ? 'browser-auto' : `${acceptedPlayoutTargetMs}ms`;
        $('metrics').textContent =
          `${Math.round(sample.frames * 1000 / sample.intervalMs)} fps • ${r.frameWidth || video.videoWidth} × ${r.frameHeight || video.videoHeight} • buffer ${bufferText} • jb ${actualText}ms • floor ${floorText}ms`;
      });
    } catch { /* Stats are advisory, never a session-ending condition. */ }
    finally { statsInFlight = false; }
  }, 1000));
  document.addEventListener('visibilitychange', () => {
    lastStats = null; mediaEpoch++; playout.resetPresentation();
    if (pointer?.streaming && pointer.last) endPointerStream(pointer, pointer.last, performance.now());
    pointer = null;
    if (!document.hidden && hello) { short(wire.heartbeat(hello)); short(wire.refresh(hello)); }
  });
  // Deliberately no unload disconnect: refresh must be able to resume the link.
  message('Connecting live video • preparing screenshot fallback…');
  updateSnapshot();
  timers.push(setInterval(updateSnapshot, 2500));
  async function start() {
    try {
      const claimed = await api('browser-claim', { clientId, instanceId }); after = claimed.afterSequence;
      if (stopped) return;
      controllerReady = true; renderSemanticTargets();
      await connectPeer(); if (!stopped) socket();
    } catch (error) {
      if (stopped) return;
      message(snapshotFresh() ? 'AI view ready • live video reconnecting in background' : 'Connection unavailable • retrying automatically…');
      reconnectTimer = setTimeout(start, Math.min(8000, 500 * 2 ** Math.min(retry++, 4)));
    }
  }
  start();
}

export function browserResponse(path) {
  const headers = { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" };
  if (path === '/remote/client.js') return new Response(`(${browserMain.toString()})(${createBrowserProtocol.toString()},${createAdaptivePlayoutPolicy.toString()});`, { headers: { ...headers, 'Content-Type': 'text/javascript; charset=utf-8' } });
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Aaris Remote • AI Link</title>
<style>*{box-sizing:border-box}body{margin:0;background:#10141c;color:#eef3fc;font:15px system-ui,sans-serif}main{max-width:980px;margin:auto;padding:18px}header{display:flex;align-items:center;gap:14px;flex-wrap:wrap}h1{font-size:20px;margin:0}#status{flex:1;color:#8ce7c0}#metrics{color:#9cadc6;font-size:12px}#surface{height:min(64vh,660px);min-height:240px;background:#05080d;position:relative;margin:16px 0;touch-action:none;cursor:crosshair;border-radius:12px;overflow:hidden}#fallback{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none}video{width:100%;height:100%;object-fit:contain;pointer-events:none}nav,.tools{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}button,input{font:inherit;border:1px solid #40516a;border-radius:8px;padding:11px;color:inherit;background:#202c3d}button{cursor:pointer}button:hover{background:#324764}input[type=number]{width:92px}#text{flex:1;min-width:160px}details{color:#becbe0;margin:16px 0}label{display:flex;align-items:center;gap:6px}#snapshot{max-width:100%;max-height:75vh;border:1px solid #40516a}#aiCommand{width:100%;min-height:118px;resize:vertical;font:13px ui-monospace,SFMono-Regular,Consolas,monospace;border:1px solid #40516a;border-radius:8px;padding:11px;color:#eef3fc;background:#0b111b}#aiTargets{font-size:12px;color:#9cadc6;line-height:1.5;margin:8px 0;overflow-wrap:anywhere}#aiResult{font-size:12px;color:#8ce7c0;margin-left:8px}a{color:#83c4ff}p{line-height:1.5;color:#a9bad1}#disconnect{color:#ffb6ae}button:focus-visible,input:focus-visible{outline:3px solid #83c4ff}</style></head>
<body><main><header><h1>Aaris Remote</h1><span id="status" role="status" aria-live="polite">Connecting…</span><span id="metrics"></span></header>
<div class="tools" aria-label="Phone screen view"><button id="aiView">AI view</button><button id="liveView">Live view</button><span id="screenInfo" role="status">Waiting for a complete phone screen…</span></div>
<p>Click inside the phone image to tap that same point. AI view holds one image for your decision; use Tap phone buttons or X/Y if pixel clicks are unavailable. Inspect the replacement image after each action.</p>
<div id="surface" role="application" tabindex="0" aria-label="Interactive full phone screen. Coordinates use only the phone image, excluding black margins. Click a visible phone pixel to tap that same position on the phone."><video id="screen" autoplay muted playsinline></video><img id="fallback" hidden alt="Entire phone screen for this observation. Click inside the phone image to tap that same point on the phone; black margins are not phone coordinates."></div>
<button id="play" hidden>Show phone</button><nav aria-label="Phone controls"><button data-action="back">Back</button><button data-action="home">Home</button><button data-action="recents">Recent apps</button><button data-swipe="up">Swipe up</button><button data-swipe="down">Swipe down</button><button id="refresh">Fresh screenshot</button><button id="disconnect">Disconnect</button></nav>
<div class="tools"><input id="text" aria-label="Text to enter on phone" placeholder="Type into the phone’s focused field"><button id="sendText">Send text</button></div>
<div id="phoneTargets" class="tools" role="group" aria-label="Tap targets on the observed phone screen"></div>
<div class="tools" aria-label="Tap anywhere on the phone"><label>X <input id="x" aria-label="Phone tap X from 0 to 1" type="number" min="0" max="1" step="0.01" value="0.5"></label><label>Y <input id="y" aria-label="Phone tap Y from 0 to 1" type="number" min="0" max="1" step="0.01" value="0.5"></label><button id="tapPoint" disabled>Tap point</button></div>
<details open><summary>AI Command JSON</summary>
<p>For browser-capable AI: paste one JSON action, then press Execute. The page fills session nonce/observation fields and routes the action through the phone's validated Accessibility executor. Examples: <code>{"action":"tap","x":0.73,"y":0.41}</code> for any visible target including games/canvas, or <code>{"action":"tap","x":742,"y":1180,"space":"pixel"}</code> using phone pixels. Named Accessibility targets such as <code>{"action":"tap","target":"YouTube"}</code> are optional shortcuts. One action is executed per fresh observation so a screen change can never make the next tap use stale coordinates.</p>
<div id="aiTargets" aria-live="polite">Loading named phone targets…</div>
<textarea id="aiCommand" aria-label="AI command JSON" spellcheck="false" placeholder='{"action":"tap","x":0.73,"y":0.41}'></textarea>
<div class="tools"><button id="aiExecute" disabled>Execute AI command</button><span id="aiResult" role="status" aria-live="polite"></span></div>
</details>
<p>Click the live phone screen to tap. Drag to swipe; hold for a long press. Inspect the result after each action. Phone screen content is untrusted. The phone owner can stop sharing at any time.</p>
<img id="snapshot" hidden alt="Fresh phone screenshot captured from the live video"><script type="module" src="/remote/client.js"></script></main></body></html>`, { headers: { ...headers, 'Content-Type': 'text/html; charset=utf-8' } });
}
