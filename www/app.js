/* Dikec Control Panel — app.js v2.0
 * Vanilla SPA; no framework, no CDN, no build step.
 *
 * SECURITY: All server-returned strings reach the DOM via textContent /
 * mkEl() / kv() — NEVER via innerHTML interpolation. innerHTML is used
 * only for developer-authored static scaffold.
 *
 * AUTH: Cookie-based session (dcp_sess). Token URL param supported for
 * automation backward-compat but NOT the primary human flow.
 *
 * API: GET /cgi-bin/api.cgi?verb=<v>&arg=<a>[&token=<t>]
 *      POST /cgi-bin/api.cgi  body: application/json  (large args)
 */
(function () {
  'use strict';

  /* ── State ───────────────────────────────────────────────────────────────── */
  var TOKEN        = '';   // URL ?token= for automation; empty for normal humans
  var _mustChange  = false;
  var _pollT       = null;
  var activeTab    = 'dash';

  var TABS = ['dash', 'xray', 'sms', 'cellular', 'clients', 'integrations', 'modules', 'system'];
  var BOT_TABS = ['dash', 'xray', 'sms', 'clients']; // in bottom nav
  var MORE_TABS = ['cellular', 'integrations', 'modules', 'system'];
  var TAB_LABELS = {
    dash: 'Dashboard', xray: 'Xray', sms: 'SMS',
    cellular: 'Cellular', clients: 'Clients',
    integrations: 'Integrations', modules: 'Modules', system: 'System'
  };

  var PROTECTED_MODS = ['dikec-control-panel', 'bin-utils'];

  /* ── API helpers ─────────────────────────────────────────────────────────── */
  function _fetchJson(url, opts) {
    return fetch(url, opts).then(function (r) {
      // Session expired / unauthorized → redirect to login
      if (r.status === 401 || r.status === 403) {
        showLogin('Session expired — please sign in again.');
        return { ok: false, err: 'session' };
      }
      return r.text().then(function (t) {
        try { return JSON.parse(t); }
        catch (e) { return { ok: false, err: t || 'parse error' }; }
      });
    }).catch(function () {
      return { ok: false, err: 'network error' };
    });
  }

  // GET: all short verbs with simple args
  function api(verb, arg, arg2) {
    var url = '/cgi-bin/api.cgi?verb=' + encodeURIComponent(verb);
    if (TOKEN) url += '&token=' + encodeURIComponent(TOKEN);
    if (arg  != null && arg  !== '') url += '&arg='  + encodeURIComponent(arg);
    if (arg2 != null && arg2 !== '') url += '&arg2=' + encodeURIComponent(arg2);
    return _fetchJson(url, { credentials: 'same-origin' });
  }

  // POST JSON: for verbs with large or structured args
  function apiPost(verb, arg, arg2) {
    var body = JSON.stringify({
      verb:  verb,
      token: TOKEN,
      arg:   arg  || '',
      arg2:  arg2 || ''
    });
    return _fetchJson('/cgi-bin/api.cgi', {
      method:      'POST',
      credentials: 'same-origin',
      headers:     { 'Content-Type': 'application/json' },
      body:        body
    });
  }

  // POST application/x-www-form-urlencoded (for login.cgi / passwd.cgi)
  function postForm(url, params) {
    var body = Object.keys(params).map(function (k) {
      return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
    }).join('&');
    return fetch(url, {
      method:      'POST',
      credentials: 'same-origin',
      headers:     { 'Content-Type': 'application/x-www-form-urlencoded' },
      body:        body
    }).then(function (r) {
      return r.text().then(function (t) {
        try { return { _status: r.status, _data: JSON.parse(t) }; }
        catch (e) { return { _status: r.status, _data: { ok: false, err: t } }; }
      });
    }).catch(function () {
      return { _status: 0, _data: { ok: false, err: 'network error' } };
    });
  }

  /* ── Toast ───────────────────────────────────────────────────────────────── */
  function toast(msg, kind, ms) {
    var d = document.createElement('div');
    d.className = 'toast' + (kind === 'ok' ? ' ok' : kind === 'err' ? ' err' : '');
    d.textContent = msg;  // XSS-safe
    document.getElementById('toasts').appendChild(d);
    var delay = ms != null ? ms : (kind === 'err' ? 5000 : 3000);
    setTimeout(function () {
      d.style.opacity = '0';
      setTimeout(function () { if (d.parentNode) d.parentNode.removeChild(d); }, 240);
    }, delay);
  }

  /* ── DOM helpers ─────────────────────────────────────────────────────────── */
  // All text from server goes through textContent — NEVER innerHTML
  function mkEl(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls)  e.className = cls;
    if (text != null) e.textContent = text;  // XSS-safe
    return e;
  }

  function tx(id, v) {
    var e = document.getElementById(id);
    if (e) e.textContent = (v == null || v === '') ? '—' : String(v);  // XSS-safe
  }

  function setBar(id, pct) {
    var e = document.getElementById(id);
    if (e) e.style.width = Math.max(0, Math.min(100, Number(pct) || 0)) + '%';
  }

  // kv: key/value row — both key and val via textContent (XSS-safe)
  function kv(key, val) {
    var row = mkEl('div', 'kv');
    row.appendChild(mkEl('span', 'k', key));
    row.appendChild(mkEl('span', 'v', (val == null || val === '') ? '—' : String(val)));  // XSS-safe
    return row;
  }

  /* ── Visibility-aware poll scheduler ─────────────────────────────────────── */
  function sched(fn, ms) {
    clearTimeout(_pollT);
    if (!document.hidden) {
      _pollT = setTimeout(fn, ms || 3000);
    }
  }

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) {
      loadTab(activeTab);
    } else {
      clearTimeout(_pollT);
    }
  });

  /* ── Auth flow ───────────────────────────────────────────────────────────── */
  function showScreen(id) {
    ['screen-login', 'screen-passwd', 'screen-app'].forEach(function (s) {
      var el = document.getElementById(s);
      if (el) el.classList.toggle('hidden', s !== id);
    });
  }

  function showLogin(notice) {
    clearTimeout(_pollT);
    // Display login form
    var noticeEl = document.getElementById('login-notice');
    if (noticeEl) noticeEl.textContent = notice || 'Sign in to continue.';  // XSS-safe
    var errEl = document.getElementById('login-error');
    if (errEl) { errEl.textContent = ''; errEl.classList.add('hidden'); }
    var btn = document.getElementById('login-btn');
    if (btn) { btn.disabled = false; btn.textContent = 'Sign in'; }
    showScreen('screen-login');
    // Focus username field (after transition)
    setTimeout(function () {
      var u = document.getElementById('login-user');
      if (u) u.focus();
    }, 50);
  }

  function showPasswd(isMustChange) {
    _mustChange = !!isMustChange;
    var sub = document.getElementById('passwd-subtitle');
    if (sub) {
      sub.textContent = isMustChange
        ? 'You must set a new password before continuing.'
        : 'Enter your current password and choose a new one.';
    }
    var oldWrap = document.getElementById('passwd-old-wrap');
    if (oldWrap) oldWrap.classList.toggle('hidden', !!isMustChange);
    var errEl = document.getElementById('passwd-error');
    if (errEl) { errEl.textContent = ''; errEl.classList.add('hidden'); }
    var btn = document.getElementById('passwd-btn');
    if (btn) { btn.disabled = false; btn.textContent = 'Set password & continue'; }
    showScreen('screen-passwd');
    setTimeout(function () {
      var f = isMustChange
        ? document.getElementById('passwd-new')
        : document.getElementById('passwd-old');
      if (f) f.focus();
    }, 50);
  }

  function showApp(user) {
    var userEl = document.getElementById('sidebar-user');
    if (userEl) userEl.textContent = user || '';  // XSS-safe
    showScreen('screen-app');
    initApp();
  }

  async function initAuth() {
    // Read ?token= for automation backward-compat
    TOKEN = new URLSearchParams(location.search).get('token') || '';

    // Probe session — this verb requires NO auth
    try {
      var r = await api('session');
      if (r && r.ok) {
        if (!r.authed) {
          showLogin();
        } else if (r.must_change) {
          showPasswd(true);
        } else {
          showApp(r.user || 'admin');
        }
        return;
      }
    } catch (e) {}
    // Fallback: show login
    showLogin();
  }

  async function doLogin(e) {
    e.preventDefault();
    var user = document.getElementById('login-user').value.trim();
    var pass = document.getElementById('login-pass').value;
    if (!user || !pass) {
      setFormErr('login-error', 'Enter username and password.');
      return;
    }

    var btn = document.getElementById('login-btn');
    btn.disabled = true;
    btn.textContent = 'Signing in…';

    var res = await postForm('/cgi-bin/login.cgi', { user: user, pass: pass });
    btn.disabled = false;
    btn.textContent = 'Sign in';

    if (res._data && res._data.ok) {
      if (res._data.must_change) {
        showPasswd(true);
      } else {
        showApp(user);
      }
    } else {
      var errMsg = (res._data && res._data.error) || 'Invalid credentials.';
      setFormErr('login-error', errMsg);
    }
  }

  async function doPasswd(e) {
    e.preventDefault();
    var newPass     = document.getElementById('passwd-new').value;
    var confirmPass = document.getElementById('passwd-confirm').value;
    var oldPass     = _mustChange ? '' : (document.getElementById('passwd-old').value || '');

    if (newPass.length < 6) {
      setFormErr('passwd-error', 'New password must be at least 6 characters.');
      return;
    }
    if (newPass !== confirmPass) {
      setFormErr('passwd-error', 'Passwords do not match.');
      return;
    }
    if (!_mustChange && !oldPass) {
      setFormErr('passwd-error', 'Enter your current password.');
      return;
    }

    var btn = document.getElementById('passwd-btn');
    btn.disabled = true;
    btn.textContent = 'Updating…';

    var params = { 'new': newPass };
    if (!_mustChange) params.old = oldPass;

    var res = await postForm('/cgi-bin/passwd.cgi', params);
    btn.disabled = false;
    btn.textContent = 'Set password & continue';

    if (res._data && res._data.ok) {
      // Server invalidated session; go back to login with a notice
      showLogin('Password changed — please sign in with your new password.');
    } else {
      var errMsg = (res._data && res._data.error) || 'Failed to set password.';
      setFormErr('passwd-error', errMsg);
    }
  }

  async function doLogout() {
    clearTimeout(_pollT);
    await api('logout').catch(function () {});
    showLogin('You have been signed out.');
  }

  function setFormErr(id, msg) {
    var el = document.getElementById(id);
    if (!el) return;
    el.textContent = msg;  // XSS-safe
    el.classList.remove('hidden');
  }

  /* ── Tab management ──────────────────────────────────────────────────────── */
  function switchTab(id) {
    clearTimeout(_pollT);
    activeTab = id;

    // Update sidebar active state
    TABS.forEach(function (t) {
      var btn = document.getElementById('tab-' + t);
      if (btn) btn.classList.toggle('active', t === id);
      var view = document.getElementById('view-' + t);
      if (view) view.classList.toggle('active', t === id);
    });

    // Update bottom nav active state
    BOT_TABS.forEach(function (t) {
      var btn = document.getElementById('btab-' + t);
      if (btn) btn.classList.toggle('active', t === id);
    });
    // 'More' bottom tab is active when on a drawer-only tab
    var moreBtn = document.getElementById('btab-more');
    if (moreBtn) {
      moreBtn.classList.toggle('active', MORE_TABS.indexOf(id) !== -1);
    }

    // Update mobile app-bar title
    tx('app-bar-title', TAB_LABELS[id] || id);

    // Close mobile drawer if open
    closeSidebar();

    loadTab(id);
  }

  function loadTab(id) {
    switch (id) {
      case 'dash':         pollDash();         break;
      case 'xray':         loadXray();         break;
      case 'sms':          loadSms();          break;
      case 'cellular':     loadCellular();     break;
      case 'clients':      loadClients();      break;
      case 'integrations': loadIntegrations(); break;
      case 'modules':      loadModules();      break;
      case 'system':       loadSystem();       break;
    }
  }

  /* ── Mobile drawer ───────────────────────────────────────────────────────── */
  function openSidebar() {
    var sb  = document.getElementById('sidebar');
    var ov  = document.getElementById('sidebar-overlay');
    if (sb) sb.classList.add('open');
    if (ov) ov.classList.remove('hidden');
  }

  function closeSidebar() {
    var sb  = document.getElementById('sidebar');
    var ov  = document.getElementById('sidebar-overlay');
    if (sb) sb.classList.remove('open');
    if (ov) ov.classList.add('hidden');
  }

  function initDrawer() {
    var toggle  = document.getElementById('drawer-toggle');
    var overlay = document.getElementById('sidebar-overlay');
    if (toggle)  toggle.addEventListener('click', openSidebar);
    if (overlay) overlay.addEventListener('click', closeSidebar);

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeSidebar();
    });
  }

  /* ── App init (after auth) ───────────────────────────────────────────────── */
  function initApp() {
    // Build all view scaffolds (static HTML only — no server data yet)
    buildDash();
    buildXray();
    buildSms();
    buildCellular();
    buildClients();
    buildIntegrations();
    buildModules();
    buildSystem();

    // Wire sidebar nav items
    TABS.forEach(function (t) {
      var btn = document.getElementById('tab-' + t);
      if (btn) btn.addEventListener('click', function () { switchTab(t); });
    });

    // Wire bottom nav items
    BOT_TABS.forEach(function (t) {
      var btn = document.getElementById('btab-' + t);
      if (btn) btn.addEventListener('click', function () { switchTab(t); });
    });
    // "More" bottom tab → open drawer
    var moreBtn = document.getElementById('btab-more');
    if (moreBtn) moreBtn.addEventListener('click', openSidebar);

    // Logout buttons
    document.getElementById('header-logout').addEventListener('click', doLogout);
    document.getElementById('sidebar-logout').addEventListener('click', doLogout);

    // Init mobile drawer
    initDrawer();

    // Load initial tab — honour URL hash for direct linking / bookmarks
    var hash = location.hash.replace(/^#/, '').replace(/\?.*$/, '');
    var initialTab = (TABS.indexOf(hash) !== -1) ? hash : 'dash';
    switchTab(initialTab);
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * DASHBOARD
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildDash() {
    // Static scaffold only — server values added dynamically
    document.getElementById('view-dash').innerHTML = [
      '<div class="grid g2">',
        '<div class="card">',
          '<h3>Device</h3>',
          '<div id="d-device-kvs"></div>',
        '</div>',
        '<div class="card">',
          '<h3>Signal</h3>',
          '<div id="d-signal-kvs"></div>',
        '</div>',
      '</div>',
      '<div class="grid g2">',
        '<div class="card">',
          '<div class="tile">',
            '<div class="k">CPU</div>',
            '<div class="v"><span id="d-cpu">—</span><small>%</small></div>',
            '<div class="bar"><i id="d-cpu-bar" style="background:var(--accent);width:0"></i></div>',
          '</div>',
        '</div>',
        '<div class="card">',
          '<div class="tile">',
            '<div class="k">Memory</div>',
            '<div class="v"><span id="d-mem">—</span><small>%</small></div>',
            '<div class="bar"><i id="d-mem-bar" style="background:var(--ok);width:0"></i></div>',
          '</div>',
        '</div>',
      '</div>',
    ].join('');
  }

  async function pollDash() {
    if (activeTab !== 'dash' || document.hidden) return;

    var results = await Promise.all([api('status'), api('signal')]);
    var st = results[0], sig = results[1];

    var dkvs = document.getElementById('d-device-kvs');
    if (st && st.ok && dkvs) {
      dkvs.textContent = '';
      var up = Number(st.uptime_s) || 0;
      var h  = Math.floor(up / 3600);
      var m  = Math.floor((up % 3600) / 60);
      // All values through kv() → textContent — XSS-safe
      [
        ['Model',  st.model],
        ['Uptime', h + 'h ' + m + 'm'],
        ['Temp',   st.temp_c != null ? st.temp_c + ' °C' : null],
        ['Load',   st.load1]
      ].forEach(function (p) { dkvs.appendChild(kv(p[0], p[1])); });

      var cpuPct = Number(st.cpu_pct) || 0;
      var memPct = (st.mem_total_mb && st.mem_total_mb > 0)
        ? Math.round(st.mem_used_mb / st.mem_total_mb * 100) : 0;
      tx('d-cpu', cpuPct);
      tx('d-mem', memPct);
      setBar('d-cpu-bar', cpuPct);
      setBar('d-mem-bar', memPct);
    }

    var skvs = document.getElementById('d-signal-kvs');
    if (sig && sig.ok && skvs) {
      skvs.textContent = '';
      // All signal values via kv() → textContent — XSS-safe
      [
        ['CSQ',      sig.csq],
        ['RSSI',     sig.rssi_dbm != null ? sig.rssi_dbm + ' dBm' : null],
        ['RSRP idx', sig.rsrp || null],
        ['RSRQ idx', sig.rsrq || null]
      ].forEach(function (p) { skvs.appendChild(kv(p[0], p[1])); });
    }

    sched(pollDash, 3000);
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * XRAY
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildXray() {
    document.getElementById('view-xray').innerHTML = [
      '<div class="card">',
        '<h3>Xray Engine <span id="xray-pill" class="pill">—</span></h3>',
        '<div id="xray-stat-kvs"></div>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn ok sm" id="xray-start">&#9654; Start</button>',
          '<button class="btn danger sm" id="xray-stop">&#9632; Stop</button>',
        '</div>',
      '</div>',
      '<div class="card">',
        '<h3>Route Mode <span id="route-pill" class="pill primary">—</span></h3>',
        '<div class="row">',
          '<button class="btn sm" id="rm-tun0">tun0 (TUN/UDP)</button>',
          '<button class="btn sm" id="rm-tproxy">tproxy (transparent)</button>',
        '</div>',
        '<p class="hint">Switch takes effect immediately if Xray is running.</p>',
      '</div>',
      '<div class="card">',
        '<h3>Profiles <span class="spacer"></span>',
          '<button class="btn ghost sm" id="prof-probe">&#9201; Test speeds</button>',
          '<button class="btn ghost sm" id="prof-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="prof-list"></div>',
        '<div id="probe-results"></div>',
      '</div>',
      '<div class="card">',
        '<h3>Import Link / Subscription</h3>',
        '<div class="field">',
          '<label for="import-input">vmess:// · vless:// · trojan:// — or — https:// subscription URL</label>',
          '<textarea id="import-input" class="code" spellcheck="false"',
            ' placeholder="vmess://...  or  https://sub.example.com/sub"></textarea>',
        '</div>',
        '<div class="row">',
          '<button class="btn primary sm" id="import-btn">Import</button>',
          '<span id="import-msg" class="muted"></span>',
        '</div>',
        '<p class="hint">Subscription URLs are fetched server-side; single links are validated with xray -test before saving.</p>',
      '</div>',
    ].join('');

    document.getElementById('xray-start').addEventListener('click',  xrayStart);
    document.getElementById('xray-stop').addEventListener('click',   xrayStop);
    document.getElementById('rm-tun0').addEventListener('click',     function () { setRouteMode('tun0'); });
    document.getElementById('rm-tproxy').addEventListener('click',   function () { setRouteMode('tproxy'); });
    document.getElementById('prof-probe').addEventListener('click',  probeSpeeds);
    document.getElementById('prof-refresh').addEventListener('click',loadProfiles);
    document.getElementById('import-btn').addEventListener('click',  doImport);
  }

  async function loadXray() {
    await Promise.all([loadXrayStatus(), loadProfiles()]);
  }

  async function loadXrayStatus() {
    var r    = await api('xray_status');
    var pill = document.getElementById('xray-pill');
    var kvs  = document.getElementById('xray-stat-kvs');
    if (!r) return;
    if (r.ok) {
      if (pill) {
        pill.textContent = r.running ? 'Running' : 'Stopped';  // XSS-safe
        pill.className   = 'pill ' + (r.running ? 'ok' : 'danger');
      }
      if (kvs) {
        kvs.textContent = '';
        // All values from server through kv() → textContent — XSS-safe
        if (r.mode   != null) kvs.appendChild(kv('Mode',         r.mode));
        if (r.listen != null) kvs.appendChild(kv('Listen',       ':' + r.listen));
        kvs.appendChild(kv('VPN gateway', r.vpn_gateway ? 'yes' : 'no'));
        if (r.pid && r.pid > 0) kvs.appendChild(kv('PID', r.pid));
      }
      ['tun0', 'tproxy'].forEach(function (m) {
        var b = document.getElementById('rm-' + m);
        if (b) b.className = 'btn sm' + (r.mode === m ? ' primary' : '');
      });
      var rp = document.getElementById('route-pill');
      if (rp) rp.textContent = r.mode || '—';  // XSS-safe
    } else {
      if (pill) { pill.textContent = 'Error'; pill.className = 'pill danger'; }
    }
  }

  async function loadProfiles() {
    var r  = await api('prof_list');
    var el = document.getElementById('prof-list');
    if (!el) return;
    el.textContent = '';

    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty', 'Failed to load profiles'));
      return;
    }
    var profiles = r.profiles || [];
    if (!profiles.length) {
      el.appendChild(mkEl('div', 'empty', 'No profiles — import one below.'));
      return;
    }
    profiles.forEach(function (p) {
      var item = mkEl('div', 'prof-item' + (p.active ? ' active-prof' : ''));
      var nameEl = mkEl('span', 'prof-name');
      nameEl.textContent = p.name;  // XSS-safe
      var subEl = mkEl('span', 'prof-sub');
      // protocol/server/port are server-provided — textContent only — XSS-safe
      subEl.textContent = (p.protocol || '?') + ' · ' + (p.server || '?') + ':' + (p.port || '?');
      item.appendChild(nameEl);
      item.appendChild(subEl);
      if (p.active) {
        item.appendChild(mkEl('span', 'pill ok', 'active'));
      } else {
        var sw = mkEl('button', 'btn sm primary', 'Switch');
        (function (name) {
          sw.addEventListener('click', function () { switchProfile(name); });
        }(p.name));
        item.appendChild(sw);
      }
      el.appendChild(item);
    });
  }

  async function switchProfile(name) {
    var r = await api('prof_switch', name);
    if (r && r.ok) {
      toast('Switched to ' + name, 'ok');
      loadProfiles();
    } else {
      toast((r && r.err) || 'Switch failed', 'err');
    }
  }

  async function xrayStart() {
    var r = await api('xray_start');
    toast(r && r.ok ? 'Xray started' : (r && r.err) || 'Start failed',
          r && r.ok ? 'ok' : 'err');
    if (activeTab === 'xray') loadXrayStatus();
  }

  async function xrayStop() {
    var r = await api('xray_stop');
    toast(r && r.ok ? 'Xray stopped' : (r && r.err) || 'Stop failed',
          r && r.ok ? 'ok' : 'err');
    if (activeTab === 'xray') loadXrayStatus();
  }

  async function setRouteMode(mode) {
    var r = await api('route_mode', mode);
    if (r && r.ok) {
      toast('Route mode: ' + mode, 'ok');
      loadXrayStatus();
    } else {
      toast((r && r.err) || 'Failed', 'err');
    }
  }

  async function doImport() {
    var val = document.getElementById('import-input').value.trim();
    if (!val) { toast('Enter a link or subscription URL', 'err'); return; }

    var btn = document.getElementById('import-btn');
    var msg = document.getElementById('import-msg');
    btn.disabled = true;
    msg.textContent = 'Importing…';  // XSS-safe

    var r;
    if (/^https?:\/\//i.test(val) && !/^(vmess|vless|trojan):\/\//i.test(val)) {
      r = await apiPost('prof_import_sub', val);
    } else {
      r = await apiPost('prof_import', val);
    }
    btn.disabled = false;
    msg.textContent = '';

    if (r && r.ok) {
      if (r.imported != null) {
        toast('Imported: ' + r.imported + (r.failed ? ' · ' + r.failed + ' failed' : ''), 'ok', 5000);
      } else {
        toast('Imported: ' + (r.name || 'profile'), 'ok');
      }
      document.getElementById('import-input').value = '';
      loadProfiles();
    } else {
      toast((r && r.err) || 'Import failed', 'err', 5000);
    }
  }

  async function probeSpeeds() {
    var btn = document.getElementById('prof-probe');
    var el  = document.getElementById('probe-results');
    if (!btn || !el) return;
    btn.disabled = true;
    el.textContent = '';
    el.appendChild(mkEl('div', 'muted', 'Testing all profiles — this may take a while…'));

    var r = await api('prof_probe_all');
    el.textContent = '';

    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty', (r && r.err) || 'Probe failed'));
      btn.disabled = false;
      return;
    }
    var results = r.results || [];
    if (!results.length) {
      el.appendChild(mkEl('div', 'empty', 'No profiles to probe'));
    }
    results.forEach(function (res) {
      var row    = mkEl('div', 'kv');
      var nameEl = mkEl('span', 'k');
      // res.name is profile name from server — textContent only — XSS-safe
      nameEl.textContent = (res.ok ? '🟢 ' : '🔴 ') + (res.name || '?');
      var latEl = mkEl('span', 'v');
      latEl.textContent = res.ok ? (res.latency_ms + ' ms') : 'unreachable';  // XSS-safe
      row.appendChild(nameEl);
      row.appendChild(latEl);
      el.appendChild(row);
    });

    if (r.fastest) {
      var fastest = r.fastest;
      var sw = mkEl('button', 'btn sm primary');
      sw.textContent = '⚡ Switch to fastest (' + fastest + ')';  // XSS-safe
      sw.style.marginTop = '10px';
      sw.addEventListener('click', function () { switchProfile(fastest); });
      el.appendChild(sw);
    }
    btn.disabled = false;
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * SMS
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildSms() {
    document.getElementById('view-sms').innerHTML = [
      '<div class="card">',
        '<h3>Send SMS</h3>',
        '<div class="grid g2">',
          '<div class="field">',
            '<label for="sms-to">Recipient</label>',
            '<input type="tel" id="sms-to" placeholder="+1234567890" autocomplete="tel">',
          '</div>',
          '<div></div>',
        '</div>',
        '<div class="field">',
          '<label for="sms-text">Message (max 140 chars)</label>',
          '<textarea id="sms-text" rows="3" placeholder="Message…" maxlength="140"></textarea>',
        '</div>',
        '<button class="btn primary sm" id="sms-send-btn">Send SMS</button>',
      '</div>',
      '<div class="card">',
        '<h3>Inbox <span class="spacer"></span>',
          '<button class="btn ghost sm" id="sms-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="sms-list"></div>',
      '</div>',
      '<div class="card">',
        '<h3>SMS Remote Control</h3>',
        '<div class="toggle-wrap">',
          '<label class="toggle">',
            '<input type="checkbox" id="smscmd-en">',
            '<div class="toggle-track"></div>',
            '<div class="toggle-thumb"></div>',
          '</label>',
          '<span class="toggle-label">Enabled</span>',
        '</div>',
        '<div class="field" style="margin-top:12px">',
          '<label for="smscmd-sec">Secret keyword</label>',
          '<input type="text" id="smscmd-sec" placeholder="mysecret" autocomplete="off">',
        '</div>',
        '<div class="field">',
          '<label for="smscmd-allow">Allowed numbers (comma-separated; empty = any)</label>',
          '<input type="text" id="smscmd-allow" placeholder="+1234567890,+0987654321">',
        '</div>',
        '<div class="toggle-wrap">',
          '<label class="toggle">',
            '<input type="checkbox" id="smscmd-reply" checked>',
            '<div class="toggle-track"></div>',
            '<div class="toggle-thumb"></div>',
          '</label>',
          '<span class="toggle-label">Send reply SMS after command</span>',
        '</div>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn primary sm" id="smscmd-save">Save Config</button>',
        '</div>',
      '</div>',
    ].join('');

    document.getElementById('sms-send-btn').addEventListener('click', sendSms);
    document.getElementById('sms-refresh').addEventListener('click',  loadSmsList);
    document.getElementById('smscmd-save').addEventListener('click',  saveSmsCmdConfig);
  }

  async function loadSms() {
    await Promise.all([loadSmsList(), loadSmsCmdConfig()]);
  }

  async function loadSmsList() {
    var el = document.getElementById('sms-list');
    if (!el) return;
    el.textContent = '';
    el.appendChild(mkEl('div', 'empty', 'Loading…'));

    var r = await api('sms_list', '30');
    el.textContent = '';

    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty', 'Failed to load messages'));
      return;
    }
    var msgs = r.messages || [];
    if (!msgs.length) {
      el.appendChild(mkEl('div', 'empty', 'Inbox is empty'));
      return;
    }
    msgs.forEach(function (m) {
      var item = mkEl('div', 'sms-item' + (m.read === 0 || m.read === '0' ? ' sms-unread' : ''));
      var meta = mkEl('div', 'sms-meta');
      var addr = mkEl('span', 'sms-addr');
      addr.textContent = m.address || '?';  // XSS-safe — attacker-controlled
      meta.appendChild(addr);
      if (m.date_ms) {
        var d = new Date(Number(m.date_ms));
        if (!isNaN(d.getTime())) {
          var dateEl = mkEl('span', 'sms-date');
          dateEl.textContent = d.toLocaleDateString() + ' '
            + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });  // XSS-safe
          meta.appendChild(dateEl);
        }
      }
      var body = document.createElement('div');
      body.className = 'sms-body';
      body.textContent = m.body || '';  // XSS-safe — SMS body is attacker-controlled
      item.appendChild(meta);
      item.appendChild(body);
      el.appendChild(item);
    });
  }

  async function sendSms() {
    var to   = document.getElementById('sms-to').value.trim();
    var text = document.getElementById('sms-text').value.trim();
    if (!to || !text) { toast('Enter recipient and message', 'err'); return; }
    var r = await api('sms_send', to, text);
    if (r && r.ok) {
      toast('SMS sent', 'ok');
      document.getElementById('sms-to').value   = '';
      document.getElementById('sms-text').value = '';
    } else {
      toast((r && r.err) || 'Send failed', 'err');
    }
  }

  async function loadSmsCmdConfig() {
    var r = await api('smscmd_get');
    if (!r || !r.ok) return;
    var en    = document.getElementById('smscmd-en');
    var sec   = document.getElementById('smscmd-sec');
    var allow = document.getElementById('smscmd-allow');
    var reply = document.getElementById('smscmd-reply');
    if (en)    en.checked    = r.SMS_ENABLED === '1' || r.SMS_ENABLED === 1;
    if (sec)   sec.value     = r.SMS_SECRET  || '';  // input.value — XSS-safe
    if (allow) allow.value   = r.SMS_ALLOW   || '';  // input.value — XSS-safe
    if (reply) reply.checked = r.SMS_REPLY === 'true' || r.SMS_REPLY === true;
  }

  async function saveSmsCmdConfig() {
    var payload = JSON.stringify({
      SMS_ENABLED: document.getElementById('smscmd-en').checked    ? '1'    : '0',
      SMS_SECRET:  document.getElementById('smscmd-sec').value,
      SMS_ALLOW:   document.getElementById('smscmd-allow').value,
      SMS_REPLY:   document.getElementById('smscmd-reply').checked ? 'true' : 'false'
    });
    var r = await apiPost('smscmd_set', payload);
    if (r && r.ok) toast('SMS control config saved', 'ok');
    else toast((r && r.err) || 'Save failed', 'err');
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * CELLULAR
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildCellular() {
    document.getElementById('view-cellular').innerHTML = [
      '<div class="grid g2">',
        '<div class="card"><h3>Signal</h3><div id="cell-sig-kvs"></div></div>',
        '<div class="card"><h3>Cell Info</h3><div id="cell-info-kvs"></div></div>',
      '</div>',
    ].join('');
  }

  async function loadCellular() {
    if (activeTab !== 'cellular' || document.hidden) return;

    var results = await Promise.all([api('signal'), api('cellinfo')]);
    var sig = results[0], ci = results[1];

    var sigEl = document.getElementById('cell-sig-kvs');
    if (sig && sig.ok && sigEl) {
      sigEl.textContent = '';
      [
        ['CSQ',      sig.csq],
        ['RSSI',     sig.rssi_dbm != null ? sig.rssi_dbm + ' dBm' : null],
        ['RSRP idx', sig.rsrp || null],
        ['RSRQ idx', sig.rsrq || null]
      ].forEach(function (p) { sigEl.appendChild(kv(p[0], p[1])); });
    } else if (sigEl) {
      sigEl.textContent = '';
      sigEl.appendChild(mkEl('div', 'empty', 'Signal data unavailable'));
    }

    var ciEl = document.getElementById('cell-info-kvs');
    if (ci && ci.ok && ciEl) {
      ciEl.textContent = '';
      [
        ['Operator', ci.operator],
        ['Net type', ci.nettype],
        ['IMEI',     ci.imei],
        ['ICCID',    ci.iccid],
        ['IMSI',     ci.imsi]
      ].forEach(function (p) { ciEl.appendChild(kv(p[0], p[1])); });
    } else if (ciEl) {
      ciEl.textContent = '';
      ciEl.appendChild(mkEl('div', 'empty', 'Cell info unavailable'));
    }

    sched(loadCellular, 5000);
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * CLIENTS
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildClients() {
    document.getElementById('view-clients').innerHTML = [
      '<div class="card">',
        '<h3>Connected Clients <span class="spacer"></span>',
          '<button class="btn ghost sm" id="clients-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="clients-list"></div>',
      '</div>',
      '<div class="card">',
        '<h3>VPN Bypass</h3>',
        '<p class="hint">',
          'Bypassed clients skip the VPN tunnel and connect directly to the internet.',
        '</p>',
        '<div id="bypass-list"></div>',
      '</div>',
    ].join('');

    document.getElementById('clients-refresh').addEventListener('click', loadClients);
  }

  async function loadClients() {
    if (activeTab !== 'clients' || document.hidden) return;

    var listEl   = document.getElementById('clients-list');
    var bypassEl = document.getElementById('bypass-list');
    if (!listEl || !bypassEl) return;

    listEl.textContent   = '';
    bypassEl.textContent = '';
    listEl.appendChild(mkEl('div', 'empty', 'Loading…'));

    var results = await Promise.all([api('clients'), api('bypass_list')]);
    var cr = results[0], br = results[1];

    listEl.textContent   = '';
    bypassEl.textContent = '';

    var bypassSet = {};
    var bypassIps = [];
    if (br && br.ok && Array.isArray(br.bypass)) {
      br.bypass.forEach(function (ip) { bypassSet[ip] = true; bypassIps.push(ip); });
    }

    var connectedIps = {};
    if (!cr || !cr.ok) {
      listEl.appendChild(mkEl('div', 'empty', (cr && cr.err) || 'Failed to load clients'));
    } else if (Array.isArray(cr.clients)) {
      var clients = cr.clients;
      if (!clients.length) {
        listEl.appendChild(mkEl('div', 'empty', 'No connected clients'));
      }
      clients.forEach(function (c) {
        var ip       = String(c.ip       || '');
        var mac      = String(c.mac      || '');
        var hostname = String(c.hostname || '');
        if (ip) connectedIps[ip] = true;
        var bypassed = !!bypassSet[ip];

        var row  = mkEl('div', 'kv');
        var info = mkEl('span', 'k');
        // ip/hostname/mac are attacker-influenced — textContent only — XSS-safe
        var label = ip;
        if (hostname) label = hostname + ' (' + ip + ')';
        if (mac)      label = label + ' · ' + mac;
        info.textContent = label;  // XSS-safe

        var btnEl = mkEl('button', 'btn sm' + (bypassed ? ' danger' : ''), bypassed ? 'Un-bypass' : 'Bypass');
        (function (theIp, wasBypassed) {
          btnEl.addEventListener('click', function () {
            api(wasBypassed ? 'bypass_del' : 'bypass_add', theIp).then(function (r) {
              if (r && r.ok) {
                toast((wasBypassed ? 'Bypass removed: ' : 'Bypassed: ') + theIp, 'ok');
                loadClients();
              } else {
                toast((r && r.err) || 'Failed', 'err');
              }
            });
          });
        }(ip, bypassed));

        row.appendChild(info);
        row.appendChild(btnEl);
        listEl.appendChild(row);
      });
    } else {
      var cnt = cr.client_count != null ? String(cr.client_count) : '?';
      listEl.appendChild(mkEl('div', 'muted', cnt + ' ARP client(s) detected — detailed list not available'));
    }

    // Orphaned bypass entries (not currently connected)
    var offlineBypass = bypassIps.filter(function (ip) { return !connectedIps[ip]; });
    if (!bypassIps.length) {
      bypassEl.appendChild(mkEl('div', 'empty', 'No bypassed clients'));
    } else if (offlineBypass.length) {
      bypassEl.appendChild(mkEl('div', 'muted', 'Offline bypass entries:'));
      offlineBypass.forEach(function (ip) {
        var row  = mkEl('div', 'kv');
        var ipEl = mkEl('span', 'k');
        ipEl.textContent = ip;  // XSS-safe
        var delBtn = mkEl('button', 'btn sm danger', 'Remove');
        (function (theIp) {
          delBtn.addEventListener('click', function () {
            api('bypass_del', theIp).then(function (r) {
              if (r && r.ok) {
                toast('Bypass removed: ' + theIp, 'ok');
                loadClients();
              } else {
                toast((r && r.err) || 'Failed', 'err');
              }
            });
          });
        }(ip));
        row.appendChild(ipEl);
        row.appendChild(delBtn);
        bypassEl.appendChild(row);
      });
    }
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * INTEGRATIONS
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildIntegrations() {
    document.getElementById('view-integrations').innerHTML = [
      // Adblock
      '<div class="intg-card" id="intg-adblock">',
        '<div class="intg-header">',
          '<span class="intg-name">Adblock</span>',
          '<span id="ab-pill" class="pill">—</span>',
        '</div>',
        '<div class="intg-body">',
          '<div id="ab-kvs" class="intg-kvs"></div>',
          '<div class="intg-actions">',
            '<button class="btn ok sm" id="ab-enable">Enable</button>',
            '<button class="btn danger sm" id="ab-disable">Disable</button>',
            '<button class="btn sm" id="ab-update">&#8635; Update Lists</button>',
          '</div>',
          '<p class="hint">DNS sinkhole via dnsmasq on 127.0.0.1:5354. Does NOT touch the stock resolver.</p>',
        '</div>',
      '</div>',
      // Tailscale
      '<div class="intg-card" id="intg-tailscale">',
        '<div class="intg-header">',
          '<span class="intg-name">Tailscale</span>',
          '<span id="ts-pill" class="pill">—</span>',
        '</div>',
        '<div class="intg-body hidden" id="ts-body">',
          '<div id="ts-kvs" class="intg-kvs"></div>',
          '<div id="ts-auth-url" class="intg-auth-url hidden"></div>',
          '<div class="intg-actions" id="ts-actions"></div>',
        '</div>',
      '</div>',
      // SSH
      '<div class="intg-card" id="intg-ssh">',
        '<div class="intg-header">',
          '<span class="intg-name">SSH (Dropbear)</span>',
          '<span id="ssh-pill" class="pill">—</span>',
        '</div>',
        '<div class="intg-body hidden" id="ssh-body">',
          '<div id="ssh-kvs" class="intg-kvs"></div>',
          '<div class="intg-actions" id="ssh-actions"></div>',
        '</div>',
      '</div>',
      // Tor
      '<div class="intg-card" id="intg-tor">',
        '<div class="intg-header">',
          '<span class="intg-name">Tor</span>',
          '<span id="tor-pill" class="pill">—</span>',
        '</div>',
        '<div class="intg-body hidden" id="tor-body">',
          '<div id="tor-kvs" class="intg-kvs"></div>',
          '<div class="intg-actions" id="tor-actions"></div>',
        '</div>',
      '</div>',
    ].join('');

    document.getElementById('ab-enable').addEventListener('click',  function () { abAction('adblock_enable'); });
    document.getElementById('ab-disable').addEventListener('click', function () { abAction('adblock_disable'); });
    document.getElementById('ab-update').addEventListener('click',  abUpdate);
  }

  async function loadIntegrations() {
    await Promise.all([
      loadAdblock(),
      loadIntgStatus('tailscale', 'ts'),
      loadIntgStatus('ssh',       'ssh'),
      loadIntgStatus('tor',       'tor')
    ]);
  }

  async function loadAdblock() {
    var r    = await api('adblock_status');
    var pill = document.getElementById('ab-pill');
    var kvs  = document.getElementById('ab-kvs');
    if (!r || !r.ok) {
      if (pill) { pill.textContent = '?'; pill.className = 'pill'; }
      return;
    }
    if (pill) {
      pill.textContent = r.running ? 'Active' : (r.enabled ? 'Stopped' : 'Disabled');  // XSS-safe
      pill.className   = 'pill ' + (r.running ? 'ok' : (r.enabled ? 'warn' : ''));
    }
    if (kvs) {
      kvs.textContent = '';
      kvs.appendChild(kv('Enabled', r.enabled ? 'yes' : 'no'));
      kvs.appendChild(kv('Running', r.running ? 'yes' : 'no'));
      kvs.appendChild(kv('Domains', r.domains != null ? r.domains.toLocaleString() : null));
    }
  }

  async function abAction(verb) {
    var r = await api(verb);
    if (r && r.ok) { toast(verb.replace('adblock_', '') + ' ok', 'ok'); loadAdblock(); }
    else toast((r && r.err) || 'Failed', 'err');
  }

  async function abUpdate() {
    toast('Updating blocklists — this may take ~30 s', '', 4000);
    var r = await api('adblock_update');
    if (r && r.ok) {
      toast('Updated: ' + (r.domains != null ? r.domains.toLocaleString() : '?') + ' domains', 'ok', 5000);
    } else {
      toast((r && r.err) || 'Update failed', 'err');
    }
    loadAdblock();
  }

  // loadIntgStatus: load status for tailscale/ssh/tor and render controls
  async function loadIntgStatus(name, prefix) {
    var r        = await api(name, 'status');
    var pill     = document.getElementById(prefix + '-pill');
    var body     = document.getElementById(prefix + '-body');
    var kvs      = document.getElementById(prefix + '-kvs');
    var actions  = document.getElementById(prefix + '-actions');

    if (!r || !r.ok) {
      if (pill) { pill.textContent = '?'; pill.className = 'pill'; }
      if (body) body.classList.add('hidden');
      return;
    }

    if (!r.installed) {
      if (pill) { pill.textContent = 'Not installed'; pill.className = 'pill'; }
      if (body) body.classList.add('hidden');
      var card = document.getElementById('intg-' + name);
      if (card) card.classList.add('uninstalled');
      return;
    }

    // Integration is installed — show body
    if (body) body.classList.remove('hidden');

    if (pill) {
      pill.textContent = r.running ? 'Running' : 'Stopped';  // XSS-safe
      pill.className   = 'pill ' + (r.running ? 'ok' : 'danger');
    }

    if (kvs) {
      kvs.textContent = '';
      // All server values via kv() → textContent — XSS-safe
      kvs.appendChild(kv('Running', r.running ? 'yes' : 'no'));
      if (r.ip)        kvs.appendChild(kv('IP',        r.ip));
      if (r.port)      kvs.appendChild(kv('Port',      r.port));
      if (r.bootstrap) kvs.appendChild(kv('Bootstrap', r.bootstrap));
      if (r.mem_mb != null && r.mem_mb > 0)
                       kvs.appendChild(kv('Memory',    r.mem_mb + ' MB'));
      if (r.keys_present != null)
                       kvs.appendChild(kv('Keys',      r.keys_present ? 'present' : 'none'));
    }

    // Render integration-specific control buttons
    if (actions) {
      actions.textContent = '';
      renderIntgControls(name, prefix, r, actions);
    }

    // Tailscale: show auth/login URL if present
    if (name === 'tailscale') {
      var urlBox = document.getElementById('ts-auth-url');
      if (urlBox) {
        if (r.login_url) {
          urlBox.classList.remove('hidden');
          urlBox.textContent = '';
          var label = document.createElement('strong');
          label.textContent = 'Auth URL — open in browser:';  // XSS-safe (dev-authored)
          urlBox.appendChild(label);
          var urlText = document.createElement('span');
          urlText.textContent = r.login_url;  // XSS-safe — server-provided, set via textContent
          urlBox.appendChild(urlText);
        } else {
          urlBox.classList.add('hidden');
          urlBox.textContent = '';
        }
      }
    }
  }

  function renderIntgControls(name, prefix, status, actionsEl) {
    function addBtn(label, cls, handler) {
      var b = mkEl('button', 'btn sm ' + cls, label);
      b.addEventListener('click', handler);
      actionsEl.appendChild(b);
    }

    if (name === 'tailscale') {
      addBtn('Up',     status.running ? 'ghost' : 'ok',   function () { intgAction('tailscale', 'up',     'ts'); });
      addBtn('Down',   status.running ? 'danger' : 'ghost',function () { intgAction('tailscale', 'down',   'ts'); });
      addBtn('Logout', 'ghost',                            function () { intgAction('tailscale', 'logout', 'ts'); });
    } else if (name === 'ssh') {
      if (!status.running) {
        addBtn('Start', 'ok',     function () { intgAction('ssh', 'start', 'ssh'); });
      } else {
        addBtn('Stop',  'danger', function () { intgAction('ssh', 'stop',  'ssh'); });
      }
    } else if (name === 'tor') {
      if (!status.running) {
        addBtn('Start', 'ok',     function () { intgAction('tor', 'start', 'tor'); });
      } else {
        addBtn('Stop',  'danger', function () { intgAction('tor', 'stop',  'tor'); });
      }
    }
  }

  async function intgAction(name, action, prefix) {
    var r = await api(name, action);
    if (r && r.ok) {
      toast(name + ' ' + action + ' ok', 'ok');
    } else {
      toast((r && r.err) || name + ' ' + action + ' failed', 'err');
    }
    // Re-fetch status for this integration
    loadIntgStatus(name, prefix);
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * MODULES
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildModules() {
    document.getElementById('view-modules').innerHTML = [
      '<div id="mod-reboot-banner" class="mod-reboot-banner hidden">',
        '<span>Değişiklikler reboot sonrası uygulanır</span>',
        '<span class="spacer"></span>',
        '<button class="btn warn sm" id="mod-reboot-btn">&#9889; Reboot</button>',
      '</div>',
      '<div class="card">',
        '<h3>Kurulu Modüller <span class="spacer"></span>',
          '<button class="btn ghost sm" id="modlist-refresh">&#8635; Refresh</button>',
        '</h3>',
        '<div id="mod-list"></div>',
      '</div>',
      '<div class="card">',
        '<h3>Katalog <span id="mod-catalog-pill" class="pill hidden">çevrimdışı</span></h3>',
        '<div id="mod-catalog"></div>',
      '</div>',
      '<div class="card">',
        '<h3>Zip\'den Kur</h3>',
        '<div class="row" style="align-items:center;gap:10px;flex-wrap:wrap">',
          '<input type="file" id="mod-zip-input" accept=".zip" style="flex:1;min-width:160px">',
          '<button class="btn primary sm" id="mod-zip-btn">&#8679; Yükle &amp; Kur</button>',
        '</div>',
        '<p class="hint">Magisk modülü zip dosyasını seçin. Kurulum sonrası reboot gereklidir.</p>',
        '<div id="mod-zip-status" class="hint hidden"></div>',
      '</div>',
    ].join('');

    document.getElementById('modlist-refresh').addEventListener('click', loadModuleList);
    document.getElementById('mod-reboot-btn').addEventListener('click', modReboot);
    document.getElementById('mod-zip-btn').addEventListener('click', uploadModZip);
  }

  async function loadModules() {
    await Promise.all([loadModuleList(), loadModuleCatalog()]);
  }

  function showRebootBanner() {
    var b = document.getElementById('mod-reboot-banner');
    if (b) b.classList.remove('hidden');
  }

  async function modReboot() {
    if (!confirm('Cihazı yeniden başlat? Tüm bağlantılar kesilecek.')) return;
    var r = await api('sys_reboot');
    if (r && r.ok) {
      toast('Yeniden başlatılıyor…', 'ok', 4000);
    } else {
      toast((r && r.err) || 'Reboot başarısız', 'err');
    }
  }

  async function loadModuleList() {
    var el = document.getElementById('mod-list');
    if (!el) return;
    el.textContent = '';
    el.appendChild(mkEl('div', 'empty', 'Yükleniyor…'));

    var r = await api('mod_list');
    el.textContent = '';

    if (!r || !r.ok) {
      el.appendChild(mkEl('div', 'empty', (r && r.err) || 'Modül listesi alınamadı'));
      return;
    }

    var mods = r.modules || [];
    if (!mods.length) {
      el.appendChild(mkEl('div', 'empty', 'Kurulu modül yok'));
      return;
    }

    mods.forEach(function (m) {
      var modId    = String(m.id      || '');
      var modName  = String(m.name    || m.id || '?');
      var modVer   = m.version ? String(m.version) : (m.versionCode ? String(m.versionCode) : '');
      var enabled  = !!m.enabled;
      var removing = !!m.removing;
      var isProt   = PROTECTED_MODS.indexOf(modId) !== -1;

      var row = mkEl('div', 'mod-row');

      // ── Left: module info ──
      var info = mkEl('div', 'mod-row-info');
      var nameEl = mkEl('div', 'mod-row-name');
      nameEl.textContent = modName;  // XSS-safe
      var subEl = mkEl('div', 'mod-row-sub');
      subEl.textContent = modId + (modVer ? ' · v' + modVer : '');  // XSS-safe
      info.appendChild(nameEl);
      info.appendChild(subEl);
      row.appendChild(info);

      // ── Right: actions ──
      var acts = mkEl('div', 'mod-row-acts');

      if (removing) {
        acts.appendChild(mkEl('span', 'pill warn', "reboot'ta silinecek"));
        var undoBtn = mkEl('button', 'btn sm ghost', 'Geri Al');
        (function (mId) {
          undoBtn.addEventListener('click', function () {
            api('mod_unremove', mId).then(function (res) {
              if (res && res.ok) {
                toast(mId + ' kaldırma geri alındı', 'ok');
              } else {
                toast((res && res.err) || 'Hata', 'err');
              }
              loadModuleList();
            });
          });
        }(modId));
        acts.appendChild(undoBtn);

      } else if (isProt) {
        // Disabled toggle (greyed)
        var tWrap = mkEl('label', 'toggle');
        tWrap.style.opacity = '0.35';
        tWrap.style.cursor  = 'not-allowed';
        var tInp = document.createElement('input');
        tInp.type    = 'checkbox';
        tInp.checked = enabled;
        tInp.disabled = true;
        tWrap.appendChild(tInp);
        tWrap.appendChild(mkEl('div', 'toggle-track'));
        tWrap.appendChild(mkEl('div', 'toggle-thumb'));
        acts.appendChild(tWrap);

        var delBtnProt = mkEl('button', 'btn sm danger', 'Kaldır');
        delBtnProt.disabled = true;
        acts.appendChild(delBtnProt);

        acts.appendChild(mkEl('span', 'pill', 'korumalı'));

      } else {
        // Normal module: toggle + remove
        var nWrap = mkEl('label', 'toggle');
        var nInp  = document.createElement('input');
        nInp.type    = 'checkbox';
        nInp.checked = enabled;
        nWrap.appendChild(nInp);
        nWrap.appendChild(mkEl('div', 'toggle-track'));
        nWrap.appendChild(mkEl('div', 'toggle-thumb'));
        (function (mId, wasEnabled, inp) {
          inp.addEventListener('change', function () {
            var verb = inp.checked ? 'mod_enable' : 'mod_disable';
            inp.disabled = true;
            api(verb, mId).then(function (res) {
              inp.disabled = false;
              if (res && res.ok) {
                toast(mId + (inp.checked ? ' etkinleştirildi' : ' devre dışı bırakıldı'), 'ok');
                showRebootBanner();
                loadModuleList();
              } else {
                toast((res && res.err) || 'Hata', 'err');
                inp.checked = wasEnabled; // revert on error
              }
            });
          });
        }(modId, enabled, nInp));
        acts.appendChild(nWrap);

        var delBtn = mkEl('button', 'btn sm danger', 'Kaldır');
        (function (mId) {
          delBtn.addEventListener('click', function () {
            if (!confirm('"' + mId + '" modülünü kaldırmak istiyor musunuz?\nReboot sonrası silinecek.')) return;
            api('mod_remove', mId).then(function (res) {
              if (res && res.ok) {
                toast(mId + ' kaldırma işaretlendi — reboot sonrası silinecek', 'ok', 5000);
                showRebootBanner();
                loadModuleList();
              } else {
                toast((res && res.err) || 'Kaldırma başarısız', 'err');
              }
            });
          });
        }(modId));
        acts.appendChild(delBtn);
      }

      row.appendChild(acts);
      el.appendChild(row);
    });
  }

  async function loadModuleCatalog() {
    var el   = document.getElementById('mod-catalog');
    var pill = document.getElementById('mod-catalog-pill');
    if (!el) return;
    el.textContent = '';
    el.appendChild(mkEl('div', 'empty', 'Yükleniyor…'));

    var r = await api('mod_catalog');
    el.textContent = '';

    if (!r || r.ok !== true) {
      if (pill) { pill.textContent = 'çevrimdışı'; pill.className = 'pill warn'; }
      el.appendChild(mkEl('div', 'empty', 'Katalog şu an alınamadı — lütfen tekrar deneyin.'));
      var retryBtn = mkEl('button', 'btn ghost sm', '↻ Tekrar Dene');
      retryBtn.style.marginTop = '8px';
      retryBtn.addEventListener('click', loadModuleCatalog);
      el.appendChild(retryBtn);
      return;
    }

    if (pill) { pill.className = 'pill hidden'; }

    var catalog = r.catalog || [];
    if (!catalog.length) {
      el.appendChild(mkEl('div', 'empty', 'Katalogda modül yok'));
      return;
    }

    catalog.forEach(function (item) {
      var catId       = String(item.id              || '');
      var catName     = String(item.name            || item.id || '?');
      var catDesc     = item.description ? String(item.description) : '';
      var catVer      = item.version ? String(item.version) : '';
      var catInstalled= !!item.installed;
      var catInstVer  = item.installedVersion ? String(item.installedVersion) : '';

      var card   = mkEl('div', 'mod-cat-item');
      var header = mkEl('div', 'mod-cat-header');

      var nameEl = mkEl('span', 'mod-cat-name');
      nameEl.textContent = catName;  // XSS-safe
      header.appendChild(nameEl);

      if (catInstalled) {
        var badge = mkEl('span', 'pill ok');
        // XSS-safe: catInstVer comes from server via textContent
        badge.textContent = catInstVer ? 'kurulu v' + catInstVer : 'kurulu';
        header.appendChild(badge);
      } else {
        var instBtn = mkEl('button', 'btn sm primary', 'Kur');
        if (catVer) instBtn.title = 'v' + catVer;
        (function (mId, mName, btn) {
          btn.addEventListener('click', function () {
            btn.disabled = true;
            btn.textContent = 'kuruluyor…';
            api('mod_install_catalog', mId).then(function (res) {
              btn.disabled = false;
              btn.textContent = 'Kur';
              if (res && res.ok) {
                var msg = mName + ' kuruldu';
                if (res.reboot_required) { msg += ' — reboot gerekli'; }
                toast(msg, 'ok', 6000);
                if (res.reboot_required) showRebootBanner();
                loadModuleCatalog();
                loadModuleList();
              } else {
                toast((res && res.err) || (mName + ' kurulum başarısız'), 'err', 6000);
              }
            });
          });
        }(catId, catName, instBtn));
        header.appendChild(instBtn);
      }

      card.appendChild(header);

      if (catDesc) {
        var descEl = mkEl('div', 'mod-cat-desc');
        descEl.textContent = catDesc;  // XSS-safe
        card.appendChild(descEl);
      }

      el.appendChild(card);
    });
  }

  async function uploadModZip() {
    var input  = document.getElementById('mod-zip-input');
    var btn    = document.getElementById('mod-zip-btn');
    var status = document.getElementById('mod-zip-status');

    if (!input || !input.files || !input.files.length) {
      toast('Önce bir zip dosyası seçin', 'err');
      return;
    }
    var file     = input.files[0];
    var origText = btn.textContent;

    btn.disabled    = true;
    btn.textContent = 'yükleniyor…';
    if (status) { status.textContent = 'Dosya yükleniyor — lütfen bekleyin…'; status.classList.remove('hidden'); }

    var res;
    try {
      var resp = await fetch('/cgi-bin/upload.cgi', {
        method:      'POST',
        body:        file,
        credentials: 'same-origin'
      });
      var txt = await resp.text();
      try { res = JSON.parse(txt); } catch (ep) { res = { err: txt || 'parse error' }; }
    } catch (ef) {
      res = { err: 'network error' };
    }

    btn.disabled    = false;
    btn.textContent = origText;
    if (status) { status.textContent = ''; status.classList.add('hidden'); }

    // Treat any response where .ok !== true as an error
    if (res && res.ok === true) {
      var okMsg = 'Modül kuruldu';
      if (res.reboot_required) { okMsg += ' — reboot gerekli'; }
      toast(okMsg, 'ok', 6000);
      if (res.reboot_required) showRebootBanner();
      input.value = '';
      loadModuleList();
    } else {
      var errMsg = (res && (res.err || res.error)) || 'Yükleme başarısız';
      toast(errMsg, 'err', 6000);  // XSS-safe: textContent in toast()
    }
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * SYSTEM
   * ═════════════════════════════════════════════════════════════════════════ */
  function buildSystem() {
    document.getElementById('view-system').innerHTML = [
      '<div class="card">',
        '<h3>Device Info</h3>',
        '<div id="sys-kvs"></div>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn ghost sm" id="update-check-btn">&#9654; Check for updates</button>',
          '<span id="update-check-msg" class="muted" style="font-size:12px"></span>',
        '</div>',
      '</div>',
      '<div class="card">',
        '<h3>LAN Exposure</h3>',
        '<div class="toggle-wrap">',
          '<label class="toggle">',
            '<input type="checkbox" id="lan-expose">',
            '<div class="toggle-track"></div>',
            '<div class="toggle-thumb"></div>',
          '</label>',
          '<span class="toggle-label">Expose on LAN (0.0.0.0:8088)</span>',
        '</div>',
        '<p class="hint">',
          'Default: localhost only (127.0.0.1:8088). LAN mode adds HTTP Basic Auth as a',
          ' second layer. Takes effect on next httpd restart.',
        '</p>',
        '<div class="row" style="margin-top:12px">',
          '<button class="btn primary sm" id="lan-save">Apply</button>',
        '</div>',
      '</div>',
      '<div class="card">',
        '<h3>Change Password</h3>',
        '<div class="grid g2">',
          '<div class="field">',
            '<label for="sys-pass-old">Current password</label>',
            '<input type="password" id="sys-pass-old" autocomplete="current-password" placeholder="••••••••">',
          '</div>',
          '<div></div>',
        '</div>',
        '<div class="grid g2">',
          '<div class="field">',
            '<label for="sys-pass-new">New password</label>',
            '<input type="password" id="sys-pass-new" autocomplete="new-password" placeholder="••••••••">',
          '</div>',
          '<div class="field">',
            '<label for="sys-pass-confirm">Confirm new password</label>',
            '<input type="password" id="sys-pass-confirm" autocomplete="new-password" placeholder="••••••••">',
          '</div>',
        '</div>',
        '<div id="sys-pass-err" class="form-error hidden"></div>',
        '<button class="btn primary sm" id="sys-pass-btn">Change Password</button>',
        '<p class="hint">You will be signed out and prompted to log in with the new password.</p>',
      '</div>',
      '<div class="card">',
        '<h3>Danger Zone</h3>',
        '<div class="row">',
          '<button class="btn danger" id="reboot-btn">&#9889; Reboot Device</button>',
          '<button class="btn ghost" id="sys-logout-btn">&#8594; Sign out</button>',
        '</div>',
        '<p class="hint">Reboot sends /system/bin/reboot after a 2 s delay.</p>',
      '</div>',
    ].join('');

    document.getElementById('lan-save').addEventListener('click', function () {
      setPanelLan(document.getElementById('lan-expose').checked ? '1' : '0');
    });
    document.getElementById('reboot-btn').addEventListener('click', reboot);
    document.getElementById('sys-logout-btn').addEventListener('click', doLogout);
    document.getElementById('sys-pass-btn').addEventListener('click', doChangePassword);
    document.getElementById('update-check-btn').addEventListener('click', doUpdateCheck);
  }

  async function loadSystem() {
    var r = await api('status');
    var el = document.getElementById('sys-kvs');
    if (r && r.ok && el) {
      el.textContent = '';
      var up = Number(r.uptime_s) || 0;
      var h  = Math.floor(up / 3600);
      var m  = Math.floor((up % 3600) / 60);
      // All values via kv() → textContent — XSS-safe
      [
        ['Model',    r.model],
        ['Uptime',   h + 'h ' + m + 'm'],
        ['Module',   'v0.1.0'],
        ['Temp',     r.temp_c != null ? r.temp_c + ' °C' : null],
        ['Load',     r.load1]
      ].forEach(function (p) { el.appendChild(kv(p[0], p[1])); });
    }

    var lanR = await api('panel_lan');
    var lanEl = document.getElementById('lan-expose');
    if (lanEl && lanR && lanR.ok) {
      lanEl.checked = lanR.lan_expose === 1 || lanR.lan_expose === '1';
    }
  }

  async function setPanelLan(val) {
    var r = await api('panel_lan', val);
    if (r && r.ok) {
      toast('LAN expose → ' + (val === '1' ? 'on' : 'off') + '. Restart httpd to apply.', 'ok', 5000);
    } else {
      toast((r && r.err) || 'Failed', 'err');
      var lanEl = document.getElementById('lan-expose');
      if (lanEl) lanEl.checked = val === '0';
    }
  }

  async function doUpdateCheck() {
    var btn = document.getElementById('update-check-btn');
    var msg = document.getElementById('update-check-msg');
    if (btn) btn.disabled = true;
    if (msg) msg.textContent = 'Checking…';

    var r = await api('update_check');
    if (btn) btn.disabled = false;
    if (msg) {
      if (r && r.ok) {
        // r.latest, r.current, r.update_available — all via textContent — XSS-safe
        if (r.update_available) {
          msg.textContent = 'Update available: ' + (r.latest || '?');
        } else {
          msg.textContent = 'Up to date (' + (r.current || r.version || '?') + ')';
        }
      } else {
        msg.textContent = (r && r.err) || 'Check failed';
      }
    }
  }

  async function reboot() {
    if (!confirm('Reboot the device? All connections will drop immediately.')) return;
    var r = await api('sys_reboot');
    if (r && r.ok) {
      toast('Rebooting in 2 s…', 'ok', 4000);
    } else {
      toast((r && r.err) || 'Reboot not available', 'err');
    }
  }

  async function doChangePassword() {
    var oldPass     = (document.getElementById('sys-pass-old')     || {}).value || '';
    var newPass     = (document.getElementById('sys-pass-new')     || {}).value || '';
    var confirmPass = (document.getElementById('sys-pass-confirm') || {}).value || '';

    var errEl = document.getElementById('sys-pass-err');
    function sysPwdErr(msg) {
      if (errEl) { errEl.textContent = msg; errEl.classList.remove('hidden'); }
    }

    if (!oldPass) { sysPwdErr('Enter your current password.'); return; }
    if (newPass.length < 6) { sysPwdErr('New password must be at least 6 characters.'); return; }
    if (newPass !== confirmPass) { sysPwdErr('New passwords do not match.'); return; }

    if (errEl) { errEl.textContent = ''; errEl.classList.add('hidden'); }
    var btn = document.getElementById('sys-pass-btn');
    if (btn) { btn.disabled = true; btn.textContent = 'Updating…'; }

    var res = await postForm('/cgi-bin/passwd.cgi', { old: oldPass, 'new': newPass });
    if (btn) { btn.disabled = false; btn.textContent = 'Change Password'; }

    if (res._data && res._data.ok) {
      // Session invalidated — go to login
      showLogin('Password changed — please sign in with your new password.');
    } else {
      sysPwdErr((res._data && res._data.error) || 'Failed to change password.');
    }
  }

  /* ═══════════════════════════════════════════════════════════════════════════
   * ENTRY POINT
   * ═════════════════════════════════════════════════════════════════════════ */
  function wireLoginForm() {
    var loginForm  = document.getElementById('login-form');
    var passwdForm = document.getElementById('passwd-form');
    if (loginForm)  loginForm.addEventListener('submit',  doLogin);
    if (passwdForm) passwdForm.addEventListener('submit', doPasswd);
  }

  function init() {
    wireLoginForm();
    initAuth();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

}());
