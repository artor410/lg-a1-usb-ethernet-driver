/* webOS6-usbrealtek-driver: the app's UI. Runs commands as root through the
 * Homebrew Channel service (luna://org.webosbrew.hbchannel.service/exec). */
(function () {
  'use strict';

  var T = {
    title: 'USB Ethernet (RTL8152/RTL8153)',
    subtitle: 'r8152 driver for LG webOS 6 · lm21u platform · tested on OLED55A1PSA (webOS 6.5.3)',
    status: 'Status', actions: 'Actions', log: 'Log',
    load: 'Load driver now', unload: 'Unload driver',
    autoOn: 'Load at TV startup', autoOff: "Don't load at startup",
    primaryOn: 'Use adapter as main', primaryOff: 'Use TV port as main',
    wifiOn: 'Enable Wi-Fi fallback', wifiOff: 'Disable Wi-Fi fallback', speed: 'Test speed',
    hint: '"Use adapter as main" makes webOS and apps see the cable as connected. Wi-Fi fallback turns Wi-Fi on if the cable has no link for 1 minute. Status refreshes by itself.',
    compat: 'Compatibility', tv: 'TV', kernel: 'Kernel', adapter: 'Adapter', module: 'r8152 driver',
    iface: 'Network interface', primaryRow: 'Main connection (eth0)', webosRow: 'Cable in webOS',
    wifiRow: 'Wi-Fi fallback', speedRow: 'Last speed', autostart: 'Load at startup', route: 'Default route',
    adapterName: 'adapter', builtinName: 'TV port', noneName: 'none',
    yes: 'yes', no: 'no', on: 'on', off: 'off', loaded: 'loaded', notLoaded: 'not loaded',
    none: 'no supported adapter connected', compatOk: 'supported',
    wifiActive: 'on — Wi-Fi in use now (no cable link)',
    noswap: 'swap undone: eth0 got no address (until the TV restarts)',
    guard: 'turned off for safety (the TV restarted after loading the driver)',
    noRoot: 'Could not reach Homebrew Channel. The TV must be rooted.',
    running: 'Running: ', done: 'Done.', failed: 'Failed: '
  };

  var REFRESH_MS = 10000;   // automatic status refresh while the app is visible
  var appDir = decodeURIComponent(location.pathname).replace(/\/[^/]*$/, '');
  var script = appDir + '/bin/usbeth.sh';
  var bridges = [];
  var busy = false;         // an action (button) is running
  var refreshing = false;   // a status refresh is running
  var lastStatus = {};

  function $(id) { return document.getElementById(id); }

  function translate() {
    var els = document.querySelectorAll('[data-t]');
    for (var i = 0; i < els.length; i++) els[i].textContent = T[els[i].getAttribute('data-t')];
  }

  // Demo mode (outside the TV): open index.html?demo in a browser.
  var DEMO = typeof PalmServiceBridge === 'undefined' && /[?&]demo\b/.test(location.search);
  var demoStatus = 'compat=ok\nkernel=4.4.84-899.19.koli.1\nplatform=lm21u\nwebos=6.5.3\n' +
    'adapter=0bda:8153 Realtek USB 10/100/1000 LAN\nadapter_driver=r8152\nadapter_config=1\niface=eth0\n' +
    'iface_state=up\niface_carrier=1\niface_speed=1000\niface_ip=192.168.0.50/24\nmodule=loaded\n' +
    'primary=on\nwatcher=running\neth0_is=adapter\nbuiltin_iface=eth2\nwebos_wired=connected\n' +
    'wififb=on\nwifi_by_us=no\nlast_speed=182 Mbit/s via eth0 (06/11 02:30)\n' +
    'autostart=off\ndefault_route=default via 192.168.0.1 dev eth0\n';

  function luna(uri, params) {
    return new Promise(function (resolve, reject) {
      if (DEMO) return resolve({ stdoutString: /status/.test(params.command) ? demoStatus : 'demo\n' });
      if (typeof PalmServiceBridge === 'undefined') return reject({ errorText: T.noRoot });
      var bridge = new PalmServiceBridge();
      bridges.push(bridge); // keep a reference until the answer arrives
      bridge.onservicecallback = function (raw) {
        bridges.splice(bridges.indexOf(bridge), 1);
        var res;
        try { res = JSON.parse(raw); } catch (e) { return reject({ errorText: String(raw) }); }
        if (res.returnValue === false) reject(res); else resolve(res);
      };
      bridge.call(uri, JSON.stringify(params));
    });
  }

  function run(arg) {
    var command = "sh '" + script + "' " + arg + ' 2>&1';
    return luna('luna://org.webosbrew.hbchannel.service/exec', { command: command })
      .then(function (r) { return r.stdoutString || ''; },
            function (e) { throw new Error((e.stdoutString || '') + (e.stderrString || '') + (e.errorText || '')); });
  }

  function appendLog(text) {
    var el = $('log');
    el.textContent = (el.textContent + text.replace(/\s+$/, '') + '\n').split('\n').slice(-7).join('\n');
  }

  function row(label, value, cls) {
    return '<tr><td>' + label + '</td><td class="' + (cls || '') + '">' + escapeHtml(value || '–') + '</td></tr>';
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  function render(s) {
    lastStatus = s;
    var compatOk = s.compat === 'ok';
    var ifaceText = s.iface ? s.iface + ' · ' + (s.iface_state || '?') +
      (s.iface_speed && s.iface_speed !== '-1' ? ' · ' + s.iface_speed + ' Mbit/s' : '') +
      (s.iface_ip ? ' · ' + s.iface_ip : '') : '';
    var html = '';
    html += row(T.compat, compatOk ? T.compatOk : s.compat, compatOk ? 'ok' : 'bad');
    html += row(T.tv, (s.platform || '?') + ' · webOS ' + (s.webos || '?'));
    html += row(T.kernel, s.kernel);
    html += row(T.adapter, s.adapter || T.none, s.adapter ? 'ok' : 'warn');
    html += row(T.module, s.module === 'loaded' ? T.loaded : T.notLoaded, s.module === 'loaded' ? 'ok' : '');
    html += row(T.iface, ifaceText, s.iface_carrier === '1' ? 'ok' : '');
    html += row(T.primaryRow, s.noswap ? T.noswap : ({ adapter: T.adapterName, builtin: T.builtinName }[s.eth0_is] || T.noneName),
                s.noswap ? 'bad' : (s.eth0_is === 'adapter' ? 'ok' : ''));
    html += row(T.webosRow, s.webos_wired || '?', s.webos_wired === 'connected' || s.webos_wired === 'online' ? 'ok' : 'warn');
    html += row(T.wifiRow, s.wififb === 'on' ? (s.wifi_by_us === 'yes' ? T.wifiActive : T.on) : T.off,
                s.wifi_by_us === 'yes' ? 'warn' : '');
    html += row(T.speedRow, s.last_speed);
    html += row(T.autostart, s.guard ? T.guard : (s.autostart === 'on' ? T.yes : T.no), s.guard ? 'bad' : '');
    html += row(T.route, s.default_route);
    $('status').innerHTML = html;

    $('btn-auto').textContent = s.autostart === 'on' ? T.autoOff : T.autoOn;
    $('btn-load').disabled = !compatOk || s.module === 'loaded';
    $('btn-unload').disabled = s.module !== 'loaded';
    $('btn-auto').disabled = !compatOk && s.autostart !== 'on';
    $('btn-primary').textContent = s.primary === 'on' ? T.primaryOff : T.primaryOn;
    $('btn-primary').disabled = s.primary !== 'on' && s.module !== 'loaded';
    $('btn-wifi').textContent = s.wififb === 'on' ? T.wifiOff : T.wifiOn;
    fixFocus();
  }

  function parse(text) {
    var s = {};
    text.split('\n').forEach(function (line) {
      var i = line.indexOf('=');
      if (i > 0) s[line.slice(0, i)] = line.slice(i + 1);
    });
    return s;
  }

  function refresh() {
    refreshing = true;
    return run('status')
      .then(function (out) { render(parse(out)); },
            function (e) { appendLog(T.failed + e.message); })
      .then(function () { refreshing = false; });
  }

  // Refreshes the status on its own: no button needed. Skipped while an action or
  // another refresh is running, and while the app is in the background.
  function autoRefresh() {
    if (!busy && !refreshing && !document.hidden) refresh();
  }

  function action(arg) {
    if (busy) return;
    busy = true;
    appendLog(T.running + arg);
    run(arg)
      .then(function (out) { appendLog(out || T.done); },
            function (e) { appendLog(T.failed + e.message); })
      .then(refresh)
      .then(function () { busy = false; });
  }

  // Remote control navigation (arrows + OK)
  function buttons() {
    return Array.prototype.filter.call(document.querySelectorAll('button'), function (b) { return !b.disabled; });
  }
  function fixFocus() {
    var list = buttons();
    if (list.length && list.indexOf(document.activeElement) < 0) list[0].focus();
  }
  document.addEventListener('keydown', function (ev) {
    var list = buttons();
    var i = list.indexOf(document.activeElement);
    var step = { 37: -1, 39: 1, 38: -2, 40: 2 }[ev.keyCode];
    if (step && list.length) {
      list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i + step)))].focus();
      ev.preventDefault();
    }
  });
  document.addEventListener('visibilitychange', autoRefresh);

  translate();
  $('btn-load').onclick = function () { action('load'); };
  $('btn-unload').onclick = function () { action('unload'); };
  $('btn-auto').onclick = function () { action(lastStatus.autostart === 'on' ? 'autostart-off' : 'autostart-on'); };
  $('btn-primary').onclick = function () { action(lastStatus.primary === 'on' ? 'primary-off' : 'primary-on'); };
  $('btn-wifi').onclick = function () { action(lastStatus.wififb === 'on' ? 'wififb-off' : 'wififb-on'); };
  $('btn-speed').onclick = function () { action('speedtest'); };

  refresh().then(function () { return run('log 6'); }).then(function (out) { if (out) appendLog(out); }, function () {});
  setInterval(autoRefresh, REFRESH_MS);
  fixFocus();
})();
